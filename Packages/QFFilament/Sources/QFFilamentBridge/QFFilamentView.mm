#import "QFFilamentView.h"
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndirectLight.h>
#include <filament/LightManager.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/SwapChain.h>
#include <filament/TransformManager.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <backend/PixelBufferDescriptor.h>
#include <gltfio/Animator.h>
#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/FilamentInstance.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/TextureProvider.h>
#include <gltfio/materials/uberarchive.h>
#include <utils/EntityManager.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace filament;
using namespace filament::gltfio;
using utils::Entity;

namespace {
struct Morph {
    Entity entity;
    size_t index;
};

// All calls, including destruction, stay on the UIKit/main thread. Filament
// owns its driver thread; the application never writes its scene concurrently.
struct Runtime {
    Engine* engine = nullptr;
    Renderer* renderer = nullptr;
    Scene* scene = nullptr;
    View* view = nullptr;
    SwapChain* swapChain = nullptr;
    Camera* camera = nullptr;
    Entity cameraEntity;
    Entity lightEntity;
    IndirectLight* ambient = nullptr;
    MaterialProvider* materials = nullptr;
    TextureProvider* decoder = nullptr;
    AssetLoader* loader = nullptr;
    FilamentAsset* asset = nullptr;
    Animator* animator = nullptr;
    std::unique_ptr<ResourceLoader> resources;
    std::map<std::string, std::vector<Morph>> morphs;
    std::map<std::string, float> morphOverrides;
    std::map<std::string, size_t> animations;
    std::vector<std::string> animationOrder;
    math::float3 center = {0, 0, 0};
    float halfHeight = 1;
    float cameraYaw = 0;
    int currentAnimation = -1;
    int previousAnimation = -1;
    double animationStart = 0;
    double previousTime = 0;
    double transition = 0.2;
    bool looping = false;
    bool paused = true;
    double pausedAt = CACurrentMediaTime();

    double clockTime() const { return paused ? pausedAt : CACurrentMediaTime(); }
    void resume() {
        if (!paused) return;
        animationStart += CACurrentMediaTime() - pausedAt;
        paused = false;
    }
    void pause() {
        if (paused) return;
        pausedAt = CACurrentMediaTime();
        paused = true;
    }

    Runtime(CAMetalLayer* layer) {
        Engine::Config config;
        config.jobSystemThreadCount = 2;
        engine = Engine::Builder().backend(Engine::Backend::METAL).config(&config).build();
        if (!engine) return;
        renderer = engine->createRenderer();
        scene = engine->createScene();
        view = engine->createView();
        swapChain = engine->createSwapChain((__bridge void*)layer, SwapChain::CONFIG_TRANSPARENT | SwapChain::CONFIG_READABLE);
        cameraEntity = utils::EntityManager::get().create();
        camera = engine->createCamera(cameraEntity);
        // Physical lights use lux. Unit exposure would clip a PBR character
        // white; use the same photographic exposure convention as the viewer.
        camera->setExposure(16.0f, 1.0f / 125.0f, 100.0f);
        view->setScene(scene);
        view->setCamera(camera);
        view->setBlendMode(View::BlendMode::TRANSLUCENT);
        // The transparent UIKit compositing sample uses no post-processing.
        view->setPostProcessingEnabled(false);
        renderer->setClearOptions({.clearColor = {0, 0, 0, 0}, .clear = true});
        lightEntity = utils::EntityManager::get().create();
        LightManager::Builder(LightManager::Type::DIRECTIONAL)
            .color({1.0f, 0.96f, 0.90f}).intensity(100000).direction({-1, -2, -3})
            .castShadows(false).build(*engine, lightEntity);
        scene->addEntity(lightEntity);
        math::float3 sh[9] = {};
        sh[0] = {0.65f, 0.65f, 0.65f};
        ambient = IndirectLight::Builder().irradiance(3, sh).intensity(30000).build(*engine);
        scene->setIndirectLight(ambient);
        materials = createUbershaderProvider(engine, UBERARCHIVE_DEFAULT_DATA, UBERARCHIVE_DEFAULT_SIZE);
        decoder = createStbProvider(engine);
        loader = AssetLoader::create({.engine = engine, .materials = materials});
    }

    void clearAsset() {
        currentAnimation = previousAnimation = -1;
        animator = nullptr;
        morphs.clear(); morphOverrides.clear(); animations.clear(); animationOrder.clear();
        resources.reset();
        if (asset) {
            scene->removeEntities(asset->getEntities(), asset->getEntityCount());
            loader->destroyAsset(asset);
            asset = nullptr;
        }
    }

    ~Runtime() {
        if (!engine) return;
        clearAsset();
        if (loader) AssetLoader::destroy(&loader);
        if (materials) { materials->destroyMaterials(); delete materials; }
        delete decoder;
        scene->setIndirectLight(nullptr);
        engine->destroy(ambient);
        engine->destroy(lightEntity);
        utils::EntityManager::get().destroy(lightEntity);
        engine->destroy(renderer);
        engine->destroy(view);
        engine->destroy(scene);
        engine->destroyCameraComponent(cameraEntity);
        utils::EntityManager::get().destroy(cameraEntity);
        engine->destroy(swapChain);
        Engine::destroy(&engine);
    }

    bool load(NSData* data) {
        clearAsset();
        if (!engine || !loader || data.length < 12 || data.length > 64 * 1024 * 1024) return false;
        const auto* bytes = static_cast<const uint8_t*>(data.bytes);
        if (memcmp(bytes, "glTF", 4) != 0 || bytes[4] != 2) return false;
        uint32_t length; memcpy(&length, bytes + 8, 4);
        if (length != data.length) return false;
        asset = loader->createAsset(bytes, static_cast<uint32_t>(data.length));
        if (!asset) return false;
        resources = std::make_unique<ResourceLoader>(ResourceConfiguration{engine, nullptr, true});
        resources->addTextureProvider("image/png", decoder);
        resources->addTextureProvider("image/jpeg", decoder);
        if (!resources->loadResources(asset)) { clearAsset(); return false; }
        animator = asset->getInstance()->getAnimator();
        for (size_t i = 0; i < animator->getAnimationCount(); ++i) {
            std::string name = animator->getAnimationName(i);
            if (name.empty()) name = "animation-" + std::to_string(i);
            animationOrder.push_back(name); animations[name] = i;
        }
        auto& rm = engine->getRenderableManager();
        for (size_t i = 0; i < asset->getEntityCount(); ++i) {
            Entity e = asset->getEntities()[i];
            auto instance = rm.getInstance(e);
            if (!instance) continue;
            size_t count = rm.getMorphTargetCount(instance);
            if (count > 256) { clearAsset(); return false; }
            std::vector<float> weights(count, 0);
            if (count) rm.setMorphWeights(instance, weights.data(), count);
            for (size_t j = 0; j < count; ++j) {
                const char* label = asset->getMorphTargetNameAt(e, j);
                // glTF morph target names are optional. Keep an ordinal ID
                // for anonymous targets rather than silently dropping them.
                std::string key = label && label[0] ? label :
                    "mesh-" + std::to_string(i) + ".morph-" + std::to_string(j);
                morphs[key].push_back({e, j});
            }
        }
        const auto bounds = asset->getBoundingBox();
        center = bounds.center();
        const auto extent = bounds.extent();
        halfHeight = std::max({extent.y * 1.08f, extent.x * 1.08f, 0.05f});
        scene->addEntities(asset->getEntities(), asset->getEntityCount());
        animator->updateBoneMatrices();
        asset->releaseSourceData();
        return true;
    }

    void update(uint32_t w, uint32_t h) {
        view->setViewport({0, 0, w, h});
        float aspect = static_cast<float>(w) / std::max(1u, h);
        const auto ext = asset ? asset->getBoundingBox().extent() : math::float3{1};
        float vertical = std::max(halfHeight, ext.x * 1.08f / std::max(aspect, 0.1f));
        float radius = std::max({ext.x, ext.y, ext.z, 0.1f});
        float distance = radius * 4 + 1;
        camera->setProjection(Camera::Projection::ORTHO, -vertical * aspect, vertical * aspect,
                              -vertical, vertical, 0.01, distance + radius * 4 + 1);
        camera->lookAt(center + math::float3{std::sin(cameraYaw) * distance, 0,
                                          std::cos(cameraYaw) * distance}, center, {0, 1, 0});
        if (animator && currentAnimation >= 0) {
            double time = std::max(0.0, clockTime() - animationStart);
            float duration = animator->getAnimationDuration(currentAnimation);
            float playTime = looping && duration > 0 ? std::fmod(time, duration) : std::min(time, static_cast<double>(duration));
            animator->applyAnimation(currentAnimation, playTime);
            if (previousAnimation >= 0 && transition > 0 && time < transition) {
                animator->applyCrossFade(previousAnimation, previousTime, time / transition);
            } else { previousAnimation = -1; }
            animator->updateBoneMatrices();
        }
        // Animator crossfade applies the previous animation internally. A
        // held expression / lip channel is applied last, so clips cannot
        // overwrite it. Crossfade itself only promises skeletal TRS blending.
        auto& rm = engine->getRenderableManager();
        for (const auto& entry : morphOverrides) {
            for (const auto& channel : morphs.at(entry.first)) {
                rm.setMorphWeights(rm.getInstance(channel.entity), &entry.second, 1, channel.index);
            }
        }
    }
};

struct Capture {
    void (^completion)(UIImage*);
    size_t width, height;
};

void finishCapture(void* buffer, size_t size, void* user) {
    std::unique_ptr<Capture> capture(static_cast<Capture*>(user));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(buffer, capture->width, capture->height, 8,
            capture->width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGImageRef cg = context ? CGBitmapContextCreateImage(context) : nullptr;
    UIImage* image = cg ? [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp] : nil;
    if (cg) CGImageRelease(cg);
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
    free(buffer);
    auto completion = capture->completion;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
}
}

@interface QFFilamentDisplayProxy : NSObject
@property(nonatomic, weak) QFFilamentView* view;
- (void)tick:(CADisplayLink*)link;
@end

@interface QFFilamentView ()
- (void)renderFrame;
@end

@implementation QFFilamentDisplayProxy
- (void)tick:(CADisplayLink*)link { [self.view renderFrame]; }
@end

@implementation QFFilamentView {
    std::unique_ptr<Runtime> _runtime;
    CADisplayLink* _displayLink;
    QFFilamentDisplayProxy* _proxy;
    NSUInteger _renderedFrameCount;
    void (^_capture)(UIImage*);
}
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.contentScaleFactor = UIScreen.mainScreen.scale;
        CAMetalLayer* layer = (CAMetalLayer*)self.layer;
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.opaque = NO; layer.framebufferOnly = NO;
        _runtime = std::make_unique<Runtime>(layer);
    }
    return self;
}
- (void)dealloc { [self dispose]; }
- (BOOL)isLoaded { return _runtime && _runtime->asset; }
- (BOOL)isRendering { return _displayLink != nil; }
- (NSUInteger)renderedFrameCount { return _renderedFrameCount; }
- (float)cameraYaw { return _runtime ? _runtime->cameraYaw : 0; }
- (void)setCameraYaw:(float)yaw { if (_runtime && std::isfinite(yaw)) _runtime->cameraYaw = std::clamp(yaw, -3.14159f, 3.14159f); }
- (NSArray<NSString*>*)animationNames {
    NSMutableArray* values = [NSMutableArray array];
    if (_runtime) for (const auto& name : _runtime->animationOrder) [values addObject:@(name.c_str())];
    return values;
}
- (NSArray<NSString*>*)morphTargetNames {
    NSMutableArray* values = [NSMutableArray array];
    if (_runtime) for (const auto& entry : _runtime->morphs) [values addObject:@(entry.first.c_str())];
    return values;
}
- (BOOL)loadGLBData:(NSData*)data error:(NSError**)error {
    NSAssert(NSThread.isMainThread, @"Filament must be used on the main thread");
    [self stopRendering];
    if (_runtime && _runtime->load(data)) return YES;
    if (error) *error = [NSError errorWithDomain:@"QFFilament" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The bundled GLB could not be loaded."}];
    return NO;
}
- (BOOL)playAnimationNamed:(NSString*)name looping:(BOOL)looping transitionDuration:(NSTimeInterval)duration {
    if (!_runtime) return NO;
    auto found = _runtime->animations.find(name.UTF8String);
    if (found == _runtime->animations.end()) return NO;
    _runtime->previousAnimation = _runtime->currentAnimation;
    if (_runtime->currentAnimation >= 0) {
        double elapsed = std::max(0.0, _runtime->clockTime() - _runtime->animationStart);
        float length = _runtime->animator->getAnimationDuration(_runtime->currentAnimation);
        _runtime->previousTime = _runtime->looping && length > 0 ? std::fmod(elapsed, length) : std::min(elapsed, static_cast<double>(length));
    }
    _runtime->currentAnimation = static_cast<int>(found->second);
    _runtime->animationStart = _runtime->clockTime();
    _runtime->transition = std::clamp(duration, 0.0, 1.0);
    _runtime->looping = looping;
    return YES;
}
- (BOOL)setMorphWeight:(float)weight forName:(NSString*)name {
    if (!_runtime || !std::isfinite(weight)) return NO;
    auto found = _runtime->morphs.find(name.UTF8String);
    if (found == _runtime->morphs.end()) return NO;
    float clamped = std::clamp(weight, 0.0f, 1.0f);
    _runtime->morphOverrides[name.UTF8String] = clamped;
    auto& rm = _runtime->engine->getRenderableManager();
    for (const auto& channel : found->second) {
        rm.setMorphWeights(rm.getInstance(channel.entity), &clamped, 1, channel.index);
    }
    return YES;
}
- (BOOL)clearMorphOverrideForName:(NSString*)name {
    if (!_runtime) return NO;
    auto found = _runtime->morphs.find(name.UTF8String);
    if (found == _runtime->morphs.end()) return NO;
    _runtime->morphOverrides.erase(name.UTF8String);
    // With no clip, return this released channel to the neutral rest weight.
    // An active clip will write its own value on the next frame.
    float zero = 0;
    auto& rm = _runtime->engine->getRenderableManager();
    for (const auto& channel : found->second) {
        rm.setMorphWeights(rm.getInstance(channel.entity), &zero, 1, channel.index);
    }
    return YES;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer* layer = (CAMetalLayer*)self.layer;
    layer.drawableSize = CGSizeMake(std::max(1.0, self.bounds.size.width * self.contentScaleFactor),
                                   std::max(1.0, self.bounds.size.height * self.contentScaleFactor));
}
- (void)startRendering {
    if (_displayLink || !_runtime || !_runtime->asset) return;
    _runtime->resume();
    _proxy = [QFFilamentDisplayProxy new]; _proxy.view = self;
    _displayLink = [CADisplayLink displayLinkWithTarget:_proxy selector:@selector(tick:)];
    _displayLink.preferredFramesPerSecond = 30;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)stopRendering {
    if (_runtime) _runtime->pause();
    [_displayLink invalidate]; _displayLink = nil; _proxy = nil;
}
- (void)dispose {
    [self stopRendering];
    _runtime.reset();
    if (_capture) { auto completion = _capture; _capture = nil; completion(nil); }
}
- (void)captureFrameWithCompletion:(void (^)(UIImage*))completion {
    if (!_runtime || !_runtime->asset || _capture || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) { completion(nil); return; }
    // Readback callbacks normally drain on later frames. A paused diagnostic
    // has no later display ticks: finish previous GPU work before its frame.
    if (!_runtime->engine->flushAndWait(500000000)) { completion(nil); return; }
    _runtime->engine->pumpMessageQueues();
    _capture = [completion copy];
    [self renderFrame];
}
- (void)renderFrame {
    if (!_runtime || !_runtime->asset || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    auto* r = _runtime.get();
    CGSize size = ((CAMetalLayer*)self.layer).drawableSize;
    uint32_t w = std::max(1.0, size.width), h = std::max(1.0, size.height);
    r->update(w, h);
    if (!r->renderer->beginFrame(r->swapChain)) {
        if (_capture) { auto completion = _capture; _capture = nil; completion(nil); }
        return;
    }
    r->renderer->render(r->view);
    bool captured = false;
    if (_capture) {
        captured = true;
        auto completion = _capture; _capture = nil;
        auto* capture = new Capture{[completion copy], w, h};
        void* bytes = calloc(w * h, 4);
        r->renderer->readPixels(0, 0, w, h, backend::PixelBufferDescriptor(bytes, w * h * 4,
                backend::PixelDataFormat::RGBA, backend::PixelDataType::UBYTE, finishCapture, capture));
    }
    r->renderer->endFrame();
    if (captured) {
        // Diagnostic only; normal rendering never waits for GPU readback.
        r->engine->flushAndWait(500000000);
        r->engine->pumpMessageQueues();
    }
    ++_renderedFrameCount;
}
@end
