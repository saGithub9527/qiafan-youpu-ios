import * as THREE from './vendor/three.module.js';

const embedded = document.body.dataset.qfEmbedded === 'true';
function notifyNative(kind) {
  if (embedded) window.webkit?.messageHandlers?.qfOrb?.postMessage({kind,generation:window.qfOrbLoadGeneration});
}
const canvas = document.querySelector('#orb');
const stage = document.querySelector('#orb-stage');
const status = document.querySelector('#status');
const pauseButton = document.querySelector('#pause');
const heartbeatDot = document.querySelector('.heartbeat-dot');
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
let renderer;
try {
  renderer = new THREE.WebGLRenderer({canvas, alpha: true, antialias: true, powerPreference: 'low-power'});
} catch {
  canvas.hidden = true;
  document.querySelector('#fallback').hidden = false;
  document.querySelector('#fallback').style.display = 'flex';
  status.textContent = '柔和光效';
}

const modes = {
  calm: {speed: .16, energy: .55, caption: '光随呼吸，缓缓流动', primary: '#168baf', secondary: '#4f3899'},
  flow: {speed: .28, energy: .85, caption: '细碎星光，环绕流转', primary: '#078f8b', secondary: '#2344a6'},
  spark: {speed: .45, energy: 1.15, caption: '每一次轻触，都有回应', primary: '#7153bc', secondary: '#167cac'},
};
for (const value of Object.values(modes)) {
  value.primaryColor=new THREE.Color(value.primary);
  value.secondaryColor=new THREE.Color(value.secondary);
}
let mode = modes.flow;
let paused = embedded || reduceMotion;
let raf;
let lastStamp = 0;
let time = 0;
let elapsed = 0;
let pulseAge = 100;
let disposed = false;
let hasValidFrame = false;
let nativeReadyNotified = false;
const pointer = {x: 0, y: 0, down: false, moved: false, lastX: 0, lastY: 0};
const rotation = {x: -.1, y: 0, targetX: -.1, targetY: 0};

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(37, 1, .1, 30);
camera.position.z = 5.1;
const orb = new THREE.Group();
scene.add(orb);
const uniforms = {
  uTime: {value: 0}, uEnergy: {value: .85}, uPulse: {value: 0}, uHeartbeat: {value: 0},
  uPrimary: {value: new THREE.Color(mode.primary)}, uSecondary: {value: new THREE.Color(mode.secondary)},
};
const noise = `
float hash(vec3 p) { p=fract(p*.3183099+vec3(.1,.2,.3)); p*=17.; return fract(p.x*p.y*p.z*(p.x+p.y+p.z)); }
float noise3(vec3 p) {
  vec3 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
  return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),
    mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
float fbm(vec3 p) { return noise3(p)*.58+noise3(p*2.03+3.1)*.28+noise3(p*4.11+7.3)*.14; }
`;
const sphereMaterial = new THREE.ShaderMaterial({
  uniforms, transparent: true, depthWrite: false,
  vertexShader: `varying vec3 vPosition; varying vec3 vNormal; varying vec3 vView;
    void main(){ vPosition=position; vec4 p=modelViewMatrix*vec4(position,1.); vNormal=normalize(normalMatrix*normal); vView=normalize(-p.xyz); gl_Position=projectionMatrix*p; }`,
  fragmentShader: `${noise}
    uniform float uTime,uEnergy,uPulse,uHeartbeat; uniform vec3 uPrimary,uSecondary;
    varying vec3 vPosition,vNormal,vView;
    void main(){
      vec3 p=normalize(vPosition); float t=uTime;
      float cloud=fbm(p*3.+vec3(t*.14,-t*.1,t*.08));
      float warp=fbm(p*2.5+vec3(-t*.2,t*.13,t*.12));
      float flow=sin(p.y*8.+p.x*3.+warp*6.+t*.65);
      float threads=pow(1.-abs(flow),16.);
      float detail=pow(1.-abs(sin(p.z*15.+p.x*7.+cloud*9.-t*.4)),22.);
      float facing=max(0.,dot(normalize(vNormal),normalize(vView)));
      float rim=pow(1.-facing,2.8);
      float central=pow(facing,3.);
      vec3 color=mix(uSecondary,uPrimary,smoothstep(.26,.77,cloud+p.y*.16));
      color*=.34+cloud*.54+threads*.52*uEnergy+detail*.22;
      color+=uPrimary*(rim*.46+central*.08);
      color+=mix(uPrimary,uSecondary,.15)*uPulse*(.18+threads*.22);
      color+=uPrimary*uHeartbeat*(.10+central*.14+rim*.12);
      // Keep the lit surface saturated on the App's light background too.
      gl_FragColor=vec4(color,.96+rim*.04);
      #include <colorspace_fragment>
    }`,
});
const sphere = new THREE.Mesh(new THREE.SphereGeometry(1, 72, 48), sphereMaterial);
orb.add(sphere);

const haloMaterial = new THREE.ShaderMaterial({
  uniforms, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false,
  vertexShader: 'varying vec2 vUv; void main(){ vUv=uv; gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.); }',
  fragmentShader: `uniform vec3 uPrimary,uSecondary; uniform float uPulse,uEnergy,uHeartbeat; varying vec2 vUv;
    void main(){ float d=length((vUv-.5)*2.); float glow=exp(-d*d*5.)*.11;
      float rim=exp(-pow((d-.45)*19.,2.))*.14; float a=(glow+rim)*(1.+uPulse*.7+uHeartbeat*.65);
      gl_FragColor=vec4(mix(uSecondary,uPrimary,vUv.y),a); }`,
});
const halo = new THREE.Mesh(new THREE.PlaneGeometry(4.5, 4.5), haloMaterial);
halo.position.z = -.18; scene.add(halo);

const particleCount = 320;
const positions = new Float32Array(particleCount * 3);
const seeds = new Float32Array(particleCount);
for (let i=0;i<particleCount;i++) {
  const phi=Math.acos(1-2*(i+.5)/particleCount), theta=i*2.39996323;
  const radius=1.06+Math.random()*.27;
  positions.set([Math.sin(phi)*Math.cos(theta)*radius,Math.cos(phi)*radius,Math.sin(phi)*Math.sin(theta)*radius],i*3);
  seeds[i]=Math.random();
}
const particleGeometry = new THREE.BufferGeometry();
particleGeometry.setAttribute('position',new THREE.BufferAttribute(positions,3));
particleGeometry.setAttribute('aSeed',new THREE.BufferAttribute(seeds,1));
const particleMaterial = new THREE.ShaderMaterial({
  uniforms: {...uniforms,uDpr:{value:1}}, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
  vertexShader: `attribute float aSeed; uniform float uTime,uEnergy,uPulse,uDpr; varying float vLight;
    void main(){ vec3 p=position*(1.+uPulse*.12); vec4 mv=modelViewMatrix*vec4(p,1.);
      vLight=.3+.7*pow(.5+.5*sin(uTime*1.4+aSeed*31.),3.);
      gl_PointSize=(1.5+aSeed*2.4)*uDpr*(5./-mv.z); gl_Position=projectionMatrix*mv; }`,
  fragmentShader: `uniform vec3 uPrimary; varying float vLight;
    void main(){ float d=length(gl_PointCoord-.5)*2.; float a=pow(max(0.,1.-d),2.)*vLight*.8;
      gl_FragColor=vec4(mix(uPrimary,vec3(.9,.95,1.),.12),a); }`,
});
const particles = new THREE.Points(particleGeometry,particleMaterial);
orb.add(particles);

const waves = new THREE.Group(); scene.add(waves);
for (let i=0;i<3;i++) {
  const waveMaterial=new THREE.MeshBasicMaterial({color:mode.primary,transparent:true,opacity:0,side:THREE.DoubleSide,depthWrite:false,blending:THREE.AdditiveBlending});
  const wave=new THREE.Mesh(new THREE.RingGeometry(1,1.007,96),waveMaterial); wave.userData.delay=i*.16; waves.add(wave);
}

// A quiet persistent ring follows the body's contraction. A second ring
// opens out from it during the light phase and dissolves before the next cycle.
const heartbeatRingMaterial = new THREE.MeshBasicMaterial({color:mode.primary,transparent:true,opacity:.12,side:THREE.DoubleSide,depthWrite:false,blending:THREE.AdditiveBlending});
const heartbeatRing = new THREE.Mesh(new THREE.RingGeometry(1.135,1.145,128),heartbeatRingMaterial);
heartbeatRing.renderOrder=1;scene.add(heartbeatRing);
const diffusionMaterial = heartbeatRingMaterial.clone();
const diffusionRing = new THREE.Mesh(new THREE.RingGeometry(1.135,1.142,128),diffusionMaterial);
diffusionRing.renderOrder=1;diffusionRing.visible=false;scene.add(diffusionRing);

function notifyNativeReady() {
  if (!embedded || !window.QFOrb || nativeReadyNotified || !hasValidFrame) return;
  nativeReadyNotified=true;notifyNative('ready');
}
function render() {
  if(!renderer||disposed||stage.clientWidth<1||stage.clientHeight<1)return;
  renderer.render(scene,camera);
  hasValidFrame=!renderer.getContext().isContextLost();notifyNativeReady();
}
function resize() {
  if (!renderer||disposed) return;
  const width=stage.clientWidth,height=stage.clientHeight;
  if(width<1||height<1)return;
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.6)); renderer.setSize(width,height,false);
  camera.aspect=width/height;
  camera.position.z= Math.max(4.6, 4.15/camera.aspect);
  camera.updateProjectionMatrix(); particleMaterial.uniforms.uDpr.value=Math.min(devicePixelRatio,1.6);
  render();
}
function tick(stamp) {
  raf=undefined;
  if (disposed||document.hidden||paused) return;
  // Limit continuous GPU work to 30 frames/second on the phone demo.
  if (stamp-lastStamp<32) { raf=requestAnimationFrame(tick); return; }
  const delta=Math.min((stamp-lastStamp)/1000,.06); lastStamp=stamp;
  time+=delta*mode.speed; elapsed+=delta; pulseAge+=delta;
  // A slow cycle contracts once, then brightens once as it opens again.
  // The light peak follows the contraction rather than forming a double beat.
  const heartPhase=(elapsed%3.4)/3.4;
  const contractDistance=heartPhase-.26-Math.round(heartPhase-.26);
  const lightDistance=heartPhase-.59-Math.round(heartPhase-.59);
  const contraction=Math.exp(-Math.pow(contractDistance/.17,2));
  const heartbeat=Math.exp(-Math.pow(lightDistance/.16,2));
  uniforms.uHeartbeat.value=heartbeat;
  uniforms.uTime.value=time;
  uniforms.uEnergy.value=THREE.MathUtils.lerp(uniforms.uEnergy.value,mode.energy,.08);
  uniforms.uPrimary.value.lerp(mode.primaryColor,.045);
  uniforms.uSecondary.value.lerp(mode.secondaryColor,.045);
  uniforms.uPulse.value=Math.exp(-pulseAge*2.6)*(1.+Math.sin(pulseAge*7.)*.18);
  rotation.x=THREE.MathUtils.lerp(rotation.x,rotation.targetX,.07);
  rotation.y=THREE.MathUtils.lerp(rotation.y,rotation.targetY,.07);
  // A visible but quiet 48-second turn, independent of the heartbeat or noise.
  // Rotating the actual mesh gives the light threads depth, not a flat spin.
  orb.rotation.set(rotation.x,rotation.y+elapsed*(Math.PI*2/48),Math.sin(elapsed*(Math.PI*2/80))*.025);
  const breath=1.-contraction*.065+heartbeat*.025+uniforms.uPulse.value*.045;
  orb.scale.setScalar(breath); halo.scale.setScalar(breath+heartbeat*.03);
  heartbeatRing.scale.setScalar(breath);
  heartbeatRing.material.opacity=.10+heartbeat*.12;
  heartbeatRing.material.color.copy(uniforms.uPrimary.value);
  const diffusionPhase=THREE.MathUtils.clamp((heartPhase-.34)/.66,0,1);
  const diffusionEase=diffusionPhase*diffusionPhase*(3-2*diffusionPhase);
  diffusionRing.visible=heartPhase>.34;
  diffusionRing.scale.setScalar(breath*(1.+diffusionEase*.55));
  diffusionRing.material.opacity=.18*Math.sin(Math.PI*diffusionPhase)*Math.pow(1.-diffusionPhase,.8);
  diffusionRing.material.color.copy(uniforms.uPrimary.value);
  if(heartbeatDot){heartbeatDot.style.opacity=String(.35+heartbeat*.65);heartbeatDot.style.transform=`scale(${.9+heartbeat*.35})`;}
  particles.rotation.y=-elapsed*(Math.PI*2/80);
  for (const wave of waves.children) {
    const age=pulseAge-wave.userData.delay;
    wave.visible=age>=0&&age<1.7;
    if (wave.visible) { wave.scale.setScalar(1.+age*.75);wave.material.opacity=(1.-age/1.7)*.16;wave.material.color.copy(uniforms.uPrimary.value); }
  }
  render(); raf=requestAnimationFrame(tick);
}
function start() { if (!renderer||disposed||paused||document.hidden||raf!==undefined) return; lastStamp=performance.now(); raf=requestAnimationFrame(tick); }
function updatePause() { pauseButton.textContent=paused?'继续':'暂停';pauseButton.setAttribute('aria-label',paused?'继续光球动画':'暂停光球动画');document.body.classList.toggle('paused',paused); status.textContent=paused?'已暂停':'自动律动'; }
function pulse() { pulseAge=0; if(paused){paused=false;updatePause();}start(); }
pauseButton.addEventListener('click',()=>{paused=!paused;updatePause();if(paused){cancelAnimationFrame(raf);raf=undefined;}else start();});
document.querySelector('#pulse').addEventListener('click',pulse);
stage.addEventListener('pointerdown',event=>{pointer.down=true;pointer.moved=false;pointer.lastX=event.clientX;pointer.lastY=event.clientY;stage.setPointerCapture(event.pointerId);});
stage.addEventListener('pointermove',event=>{
  if(!pointer.down)return;
  const dx=event.clientX-pointer.lastX,dy=event.clientY-pointer.lastY;
  if(Math.abs(dx)+Math.abs(dy)>2)pointer.moved=true;
  rotation.targetY+=dx*.007;rotation.targetX=THREE.MathUtils.clamp(rotation.targetX+dy*.007,-.8,.8);
  pointer.lastX=event.clientX;pointer.lastY=event.clientY;
  if(paused){orb.rotation.set(rotation.targetX,rotation.targetY,0);render();}
});
stage.addEventListener('pointerup',()=>{if(!pointer.moved)pulse();pointer.down=false;});
stage.addEventListener('pointercancel',()=>{pointer.down=false;});
const observer=new ResizeObserver(resize);observer.observe(stage);
document.addEventListener('visibilitychange',()=>{if(document.hidden){cancelAnimationFrame(raf);raf=undefined;}else start();});
canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();cancelAnimationFrame(raf);raf=undefined;status.textContent='光效暂时中断';hasValidFrame=false;nativeReadyNotified=false;notifyNative('error');});
canvas.addEventListener('webglcontextrestored',()=>{resize();updatePause();start();});
window.addEventListener('pagehide',event=>{
  cancelAnimationFrame(raf);raf=undefined;
  if(event.persisted)return;
  disposed=true;observer.disconnect();
  scene.traverse(object=>{object.geometry?.dispose();if(object.material)object.material.dispose();});renderer?.dispose();
});
window.addEventListener('pageshow',event=>{if(event.persisted){resize();start();}});
if(renderer){resize();updatePause();start();}

// Only these structured methods cross the UIKit/WebKit display boundary.
// Embedded playback starts paused until the native host applies its latest state.
window.QFOrb = {
  isReady() { return !!renderer && hasValidFrame && !disposed; },
  configure(state) {
    if (disposed) return;
    if (modes[state.mode]) mode = modes[state.mode];
    paused = state.active !== true || state.reduceMotion === true;
    if (paused) {
      cancelAnimationFrame(raf); raf=undefined;
      uniforms.uPrimary.value.set(mode.primary);
      uniforms.uSecondary.value.set(mode.secondary);
      heartbeatRing.material.color.copy(uniforms.uPrimary.value);
      diffusionRing.material.color.copy(uniforms.uPrimary.value);
      render();
    } else start();
    updatePause();
  },
  pulse() { if (!paused && !disposed) { pulseAge=0; start(); } },
  dispose() {
    if(disposed)return;disposed=true;cancelAnimationFrame(raf);observer.disconnect();
    scene.traverse(object=>{object.geometry?.dispose();object.material?.dispose();});
    renderer?.dispose();
  },
};
notifyNativeReady();
if(embedded&&!renderer)notifyNative('error');
