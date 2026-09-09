// Extracts the theme-palette helpers from the QML and evaluates them as plain
// JavaScript. Checks parsing and hue maths; it does not render QML.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const widget = fs.readFileSync('BarWidget.qml', 'utf8');
const album = fs.readFileSync('AlbumPalette.qml', 'utf8');
const ctx = {};
vm.createContext(ctx);

// Slice each function out by brace-matching from its signature, so the test
// does not depend on how the QML happens to be indented.
function extract(src, name) {
  const start = src.indexOf('function ' + name + '(');
  assert.ok(start >= 0, 'expected to find function ' + name);
  let depth = 0, i = src.indexOf('{', start);
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') { depth--; if (depth === 0) return src.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces in ' + name);
}
for (const n of ['parsePalette', 'hexHue']) vm.runInContext(extract(widget, n), ctx);
vm.runInContext(extract(album, 'nearestHue'), ctx);
vm.runInContext(extract(album, 'localPath'), ctx);

// Replays refresh()'s dispatch against a stub sampler, so the real function
// stays the single source of truth for the branch order.
function decide(url) {
  const sampler = { payload: '', command: null, running: false };
  const scope = Object.assign(Object.create(null), {
    sampler, sampled: null, fallback: null,
    localPath: ctx.localPath, String, decodeURIComponent,
  });
  const body = extract(album, 'refresh')
    .replace(/^function refresh\(\)\s*\{/, '').replace(/\}$/, '')
    .replace(/sourceUrl/g, 'URL');
  vm.runInNewContext('(function(URL){' + body + '})(u)',
    Object.assign(scope, { u: url }));
  return sampler;
}

test('parses quoted and bare hex, ignores everything else', () => {
  const p = ctx.parsePalette(['mode = "dark"', 'accent = "#7d82d9"', 'orange = #eb8b54',
    '  green = "#92a593"  # comment', 'font = "sans"'].join('\n'));
  assert.equal(p.accent, '#7d82d9');
  assert.equal(p.orange, '#eb8b54');
  assert.equal(p.green, '#92a593');
  assert.equal(p.mode, undefined);
  assert.equal(p.font, undefined);
});

test('an empty or missing file is an empty palette, not a crash', () => {
  for (const input of ['', null, undefined, 'nothing = here']) {
    assert.equal(Object.keys(ctx.parsePalette(input)).length, 0);
  }
});

test('hue of the primaries', () => {
  assert.equal(ctx.hexHue('#ff0000'), 0);
  assert.ok(Math.abs(ctx.hexHue('#00ff00') - 1 / 3) < 1e-9);
  assert.ok(Math.abs(ctx.hexHue('#0000ff') - 2 / 3) < 1e-9);
  assert.equal(ctx.hexHue('#808080'), -1);
});

test('nearest hue picks the closest theme hue', () => {
  const hues = [0.0, 1 / 3, 2 / 3];
  assert.equal(ctx.nearestHue(0.30, hues), 1 / 3);
  assert.equal(ctx.nearestHue(0.60, hues), 2 / 3);
  assert.equal(ctx.nearestHue(0.05, hues), 0.0);
});

test('hue is a circle: 0.97 snaps to 0.0, not to 0.66', () => {
  assert.equal(ctx.nearestHue(0.97, [0.0, 2 / 3]), 0.0);
  assert.equal(ctx.nearestHue(0.02, [0.95, 0.5]), 0.95);
});

test('no theme hues means nothing to snap to', () => {
  assert.equal(ctx.nearestHue(0.4, []), -1);
});

test('the album tint guards near-greys rather than inventing a hue', () => {
  assert.ok(/hslSaturation\s*<\s*0\.08/.test(album),
    'snapHue must leave a near-grey sample alone');
});

// ── album art source dispatch ───────────────────────────────────────────────
// refresh() decides how to sample from the shape of the MPRIS art URL. These
// check the decision, not the sampling: what command it builds and whether the
// payload is fed over stdin.
test('a file:// url is opened directly, with no stdin payload', () => {
  const r = decide('file:///home/pi/art.png');
  assert.equal(r.payload, '');
  assert.equal(r.command[0], 'magick');
  assert.ok(r.command[1].endsWith('[0]'), 'should select the first frame');
});

test('a base64 data: url is decoded over stdin, never argv', () => {
  const r = decide('data:image/jpeg;base64,AAAA');
  assert.equal(r.payload, 'AAAA');
  assert.equal(r.command[0], 'sh');
  assert.ok(/base64 -d \| magick -/.test(r.command[2]));
  assert.ok(!r.command.join(' ').includes('AAAA'), 'payload must not reach argv');
});

test('urls we cannot sample leave the tint alone', () => {
  for (const url of ['', null, 'https://example.com/art.jpg',
                     'data:image/png,notbase64', 'data:malformed']) {
    const r = decide(url);
    assert.equal(r.command, null, 'should not run for ' + url);
    assert.equal(r.payload, '');
  }
});
