#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UIKit owns layout and touch routing; this view only owns one Filament scene.
@interface QFFilamentView : UIView
@property(nonatomic, readonly, getter=isLoaded) BOOL loaded;
@property(nonatomic, readonly, getter=isRendering) BOOL rendering;
@property(nonatomic, readonly) NSUInteger renderedFrameCount;
@property(nonatomic, readonly, copy) NSArray<NSString *> *animationNames;
@property(nonatomic, readonly, copy) NSArray<NSString *> *morphTargetNames;
/// Diagnostic orbit in radians; normal character preview uses the front view.
@property(nonatomic) float cameraYaw;
- (BOOL)loadGLBData:(NSData *)data error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(load(glb:));
- (BOOL)playAnimationNamed:(NSString *)name looping:(BOOL)looping transitionDuration:(NSTimeInterval)duration NS_SWIFT_NAME(playAnimation(named:looping:transitionDuration:));
- (BOOL)setMorphWeight:(float)weight forName:(NSString *)name NS_SWIFT_NAME(setMorph(weight:name:));
/// Releases this layer's held weight so a clip can control the channel again.
- (BOOL)clearMorphOverrideForName:(NSString *)name NS_SWIFT_NAME(clearMorphOverride(name:));
- (void)startRendering;
- (void)stopRendering;
/// Idempotent; releases the scene, loader, GPU objects and engine threads.
- (void)dispose;
/// Diagnostic readback; not used by normal UI rendering.
- (void)captureFrameWithCompletion:(void (^)(UIImage * _Nullable))completion NS_SWIFT_NAME(captureFrame(completion:));
@end

NS_ASSUME_NONNULL_END
