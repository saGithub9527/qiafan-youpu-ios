// The authored rendering values live here so numerical checks exercise the
// same cycle used by the offline WebGL runtime, without starting WebKit/GPU.
export function orbBreathingAt(elapsed, pulse = 0) {
  const phase = (elapsed % 3.4) / 3.4;
  // A periodic cosine pulse has no nearest-distance cusp. The denominator
  // preserves the old Gaussian's width near its peak while remaining smooth.
  const peak = (at, width) => Math.exp(
    (Math.cos(2 * Math.PI * (phase - at)) - 1) / (2 * Math.PI ** 2 * width ** 2));
  const contraction = peak(.26, .17);
  const heartbeat = peak(.59, .16);
  const orbScale = 1 - contraction * .065 + heartbeat * .025 + pulse * .045;
  const diffusionPhase = Math.max(0, Math.min(1, (phase - .34) / .66));
  const diffusionEase = diffusionPhase * diffusionPhase * (3 - 2 * diffusionPhase);
  // Reset the radius smoothly during the invisible part, rather than jumping
  // from an expanded ring to the starting radius at the cycle boundary.
  const reset = Math.min(1, phase / .34);
  const resetEase = reset * reset * (3 - 2 * reset);
  const diffusionRadius = phase < .34 ? 1 - resetEase : diffusionEase;
  return {
    heartbeat, orbScale, haloScale: orbScale + heartbeat * .03,
    heartbeatOpacity: .10 + heartbeat * .12,
    diffusionScale: orbScale * (1 + diffusionRadius * .55),
    diffusionOpacity: .18 * Math.sin(Math.PI * diffusionPhase) ** 2 * Math.pow(1 - diffusionPhase, .8),
    dotOpacity: .35 + heartbeat * .65, dotScale: .9 + heartbeat * .35
  };
}
