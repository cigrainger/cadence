// SPDX-License-Identifier: AGPL-3.0-or-later
// Run the real site controller against a small DOM/audio boundary, with no sound.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function fixture({ deferred = false, audio = true } = {}) {
  const elements = new Map(), listeners = {}, pending = [], timers = new Map(), contexts = [];
  class Element {
    constructor(dataset = {}) { this.dataset = dataset; this.attrs = {}; this.textContent = ''; this.events = {}; }
    setAttribute(key, value) { this.attrs[key] = value; }
    addEventListener(key, action) { this.events[key] = action; }
    click() { return this.events.click(); }
  }
  for (const id of ['hear-demo','demo-status','middle-chord','middle-bass','middle-guide','voice-diagram','harmony-explanation']) elements.set('#' + id, new Element());
  const buttons = ['original','substitute'].map(harmony => new Element({harmony}));
  const document = { hidden: false, querySelector: id => elements.get(id), querySelectorAll: id => id === '[data-harmony]' ? buttons : [], addEventListener: (name, fn) => listeners[name] = fn };
  class Audio {
    constructor() { this.currentTime = 0; this.frequencies = []; this.closed = false; contexts.push(this); }
    resume() { return deferred ? new Promise(resolve => pending.push(resolve)) : Promise.resolve(); }
    close() { this.closed = true; return Promise.resolve(); }
    createGain() { return { gain: { setValueAtTime(){}, linearRampToValueAtTime(){}, exponentialRampToValueAtTime(){} }, connect(){} }; }
    createOscillator() { const item = {frequency: {value: 0}, connect(){}, stop(){}, start: () => this.frequencies.push(item.frequency.value)}; return item; }
  }
  const window = { AudioContext: audio ? Audio : undefined, addEventListener: (name, fn) => listeners[name] = fn };
  vm.runInNewContext(fs.readFileSync('site/assets/site.js','utf8'), {document, window,
    setTimeout: fn => { const id = timers.size + 1; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) });
  return {elements, buttons, contexts, pending, timers, listeners, document, play: elements.get('#hear-demo')};
}
const hz = midi => 440 * 2 ** ((midi - 69) / 12);
test('substitution changes the visible bass and spelling to match the sounding pitches', async () => {
  const f = fixture(); f.buttons[1].click();
  assert.equal(f.elements.get('#middle-bass').textContent, 'D♭');
  assert.equal(f.elements.get('#middle-guide').textContent, 'C♭');
  assert.equal(f.buttons[1].attrs['aria-pressed'], 'true');
  assert.equal(f.buttons[0].attrs['aria-pressed'], 'false');
  await f.play.click();
  assert.deepEqual(f.contexts[0].frequencies, [38,53,60,37,53,59,36,52,59].map(hz));
  assert.match(f.elements.get('#voice-diagram').attrs['aria-label'], /C♭/);
});
test('original route restores G bass and B while retaining the same upper pitches', async () => {
  const f = fixture(); f.buttons[1].click(); f.buttons[0].click(); await f.play.click();
  assert.equal(f.elements.get('#middle-bass').textContent, 'G');
  assert.equal(f.elements.get('#middle-guide').textContent, 'B');
  assert.deepEqual(f.contexts[0].frequencies, [38,53,60,43,53,59,36,52,59].map(hz));
});
test('changing harmony stops sound and a pending audio resume cannot start stale notes', async () => {
  const f = fixture({deferred:true}); const playing = f.play.click();
  f.buttons[1].click(); f.pending[0](); await playing;
  assert.equal(f.contexts[0].closed, true); assert.equal(f.contexts[0].frequencies.length, 0);
  assert.equal(f.timers.size, 0); assert.match(f.elements.get('#demo-status').textContent, /Selected/);
});
test('stop clears scheduled completion and closes the audio context', async () => {
  const f = fixture(); await f.play.click(); await f.play.click();
  assert.equal(f.contexts[0].closed, true); assert.equal(f.timers.size, 0);
  assert.equal(f.elements.get('#demo-status').textContent, 'Stopped.');
});
test('completion releases audio and returns a playable control', async () => {
  const f = fixture(); await f.play.click(); [...f.timers.values()][0]();
  assert.equal(f.contexts[0].closed, true); assert.match(f.play.textContent, /Hear the route/);
});
test('leaving the page stops playback', async () => {
  const f = fixture(); await f.play.click(); f.document.hidden = true; f.listeners.visibilitychange();
  assert.equal(f.contexts[0].closed, true); assert.equal(f.timers.size, 0);
});
test('unavailable audio reports the limitation and allows another try', async () => {
  const f = fixture({audio:false}); await f.play.click();
  assert.match(f.elements.get('#demo-status').textContent, /unavailable/);
  assert.match(f.play.textContent, /Hear the route/); assert.equal(f.timers.size, 0);
});
