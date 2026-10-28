import assert from 'node:assert/strict';
import test from 'node:test';
import {orbBreathingAt} from '../../Packages/QFOrbRenderer/WebSource/breathing.mjs';

const period = 3.4;
const fields = ['heartbeat', 'orbScale', 'haloScale', 'heartbeatOpacity',
  'diffusionScale', 'diffusionOpacity', 'dotOpacity', 'dotScale'];

test('rendered values meet across the breathing-cycle seam', () => {
  const before = orbBreathingAt(period - 1e-7);
  const after = orbBreathingAt(period + 1e-7);
  for (const field of fields) {
    assert.ok(Math.abs(before[field] - after[field]) < 1e-5,
      `${field} jumps at the cycle seam: ${before[field]} -> ${after[field]}`);
  }
});

test('visible motion has matching velocities at all phase transitions', () => {
  const h = 1e-6;
  // Include both former nearest-distance cusps and the diffusion onset.
  for (const phase of [0, 0.09, 0.34, 0.76, 1]) {
    const t = period * (1 + phase);
    for (const field of fields) {
      const left = (orbBreathingAt(t - h)[field] - orbBreathingAt(t - 2 * h)[field]) / h;
      const right = (orbBreathingAt(t + 2 * h)[field] - orbBreathingAt(t + h)[field]) / h;
      assert.ok(Math.abs(left - right) < 1e-4,
        `${field} velocity jumps at phase ${phase}: ${left} -> ${right}`);
    }
  }
});

test('diffusion is invisible while resetting and fades in without a flash', () => {
  for (const t of [0, 0.1, 0.5, 1, 3.4]) {
    assert.equal(orbBreathingAt(t).diffusionOpacity, 0);
  }
  const onset = period * 0.34;
  assert.ok(orbBreathingAt(onset + 1e-5).diffusionOpacity < 1e-8);
  assert.ok(orbBreathingAt(period - 1e-5).diffusionOpacity < 1e-8);
});

test('successive cycles retain bounded rendering values without accumulating a jump', () => {
  for (let step = 0; step < 340; step++) {
    const time = step / 100;
    const frame = orbBreathingAt(time);
    const later = orbBreathingAt(time + 340);
    for (const field of fields) {
      assert.ok(Number.isFinite(frame[field]), field);
      assert.ok(Math.abs(frame[field] - later[field]) < 1e-9, field);
    }
    assert.ok(frame.orbScale > 0.9 && frame.orbScale < 1.1);
    assert.ok(frame.diffusionOpacity >= 0 && frame.diffusionOpacity <= 0.18);
  }
});
