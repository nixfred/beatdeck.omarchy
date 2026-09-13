// The spectrum gain must never flatten a playing spectrum. Extracts
// softLimit() from BarWidget.qml and checks it against the failure it fixes:
// at the maximum 250% gain a hard clamp pinned about a third of all samples
// to full height, so a live EQ read as a solid block.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const widget = fs.readFileSync('BarWidget.qml', 'utf8');
function extract(src, name) {
  const start = src.indexOf('function ' + name + '(');
  assert.ok(start >= 0, 'expected to find function ' + name);
  let depth = 0;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') { depth--; if (depth === 0) return src.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces in ' + name);
}
const ctx = { Math, Number };
vm.createContext(ctx);
vm.runInContext(extract(widget, 'softLimit'), ctx);
const soft = ctx.softLimit;

test('quiet levels are left exactly as gained', () => {
  for (const v of [0, 0.1, 0.35, 0.6]) assert.equal(soft(v), v);
});

test('output never reaches full height across every real gain', () => {
  // Real inputs top out at band 1.0 x the 250% maximum gain = 2.5.
  for (const v of [1, 1.5, 2.5, 5]) assert.ok(soft(v) < 1, `soft(${v}) = ${soft(v)}`);
  // Far outside that range exp() underflows to 0 and the result rounds to
  // exactly 1.0 in floating point. It must still never exceed full height.
  assert.ok(soft(1000) <= 1);
});

test('a louder band always draws taller than a quieter one', () => {
  let last = -1;
  for (let v = 0; v <= 2.5; v += 0.05) {
    const y = soft(v);
    assert.ok(y > last || v === 0, `not strictly increasing at ${v}`);
    last = y;
  }
});

test('at 250% gain, typical live bands stay distinguishable', () => {
  // Real autosens band values sampled from a playing track.
  const bands = [0.19, 0.35, 0.42, 0.36, 0.37, 0.47, 0.6, 0.88, 0.7, 1, 0.52, 1];
  const drawn = bands.map((b) => soft(b * 2.5));
  const distinct = new Set(drawn.map((y) => y.toFixed(3)));
  assert.ok(distinct.size >= bands.length - 1, `only ${distinct.size} distinct heights`);
  // The old hard clamp made every band >= 0.4 identical.
  const clamped = bands.map((b) => Math.min(1, b * 2.5));
  assert.ok(new Set(clamped).size < distinct.size);
});

test('bad input draws nothing instead of throwing', () => {
  for (const v of [NaN, undefined, null, -3, 'x']) assert.equal(soft(v), 0);
});
