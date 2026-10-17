// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Run the real load/resize/ready orchestration. Native previews separately
// check OSMD's actual note targets, selection, playhead and scroll geometry.
function fixture({allowScroll = true} = {}) {
  const messages = [], pending = [], timers = new Map();
  let resize, nextTimer = 0, verified = 0;
  const host = {clientWidth: 800, scrollHeight: 1000, replaceChildren(){}, querySelectorAll: () => [{}]};
  const layer = {replaceChildren(){}};
  const document = {getElementById: id => id === 'score-host' ? host : layer};
  const window = {scrollY: 0, addEventListener(){}, cadenceEngravingXML: xml => xml,
    scrollTo(x, y){this.scrollY = allowScroll ? y : 0;},
    webkit: {messageHandlers: {editor: {postMessage: value => messages.push(value)}}}};
  class OSMD {
    constructor(){this.EngravingRules = {};}
    load(){return new Promise(resolve => pending.push(resolve));}
    render(){window.scrollY = 0;}
  }
  const context = vm.createContext({window, document, performance: {now: () => 12},
    console: {error(){}, warn(){}}, opensheetmusicdisplay: {OpenSheetMusicDisplay: OSMD},
    ResizeObserver: class {constructor(callback){resize = callback;} observe(){}},
    clearTimeout(id){timers.delete(id);}, setTimeout(callback){timers.set(++nextTimer, callback); return nextTimer;}});
  vm.runInContext(fs.readFileSync('Resources/EditorViewer/editor.js', 'utf8'), context);
  context.mapOSMD = () => {};
  context.paintTargets = () => {};
  window.verifyEditor = () => {verified++; return {allEventsMapped: true, continuousPlayhead: true};};
  const model = (id = 'original', bars = 4) => ({id, barCount: bars, instrument: 'Piano', events: [{id}]});
  return {window, messages, pending, model, ready: () => messages.filter(m => m.kind === 'ready'),
    verified: () => verified, resize(){host.clientWidth += 100; resize(); for (const [id, callback] of timers) {
      timers.delete(id); callback();
    }}};
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('editor ready carries geometry assertions atomically, including after resize', async () => {
  const f = fixture(), load = f.window.loadEditor(f.model(), 'OSMD', '<score/>', '', true);
  f.pending.shift()(); await load;
  f.resize(); f.pending.shift()(); await tick();
  assert.equal(f.ready().length, 2);
  for (const ready of f.ready()) {
    assert.equal(ready.allEventsMapped, true);
    assert.equal(ready.continuousPlayhead, true);
    assert.equal(ready.scrollRetained, true);
  }
  assert.equal(f.verified(), 2);
});
test('long-score scroll proof waits for an actual redraw and emits no intermediate ready', async () => {
  const f = fixture(), load = f.window.loadEditor(f.model('long', 24), 'OSMD', '<score/>', '', true);
  f.pending.shift()(); await tick();
  assert.equal(f.ready().length, 0);
  assert.equal(f.pending.length, 1);
  f.pending.shift()(); await load;
  assert.equal(f.ready().length, 1);
  assert.equal(f.ready()[0].scrollRetained, true);
  assert.equal(f.ready()[0].allEventsMapped, true);
  assert.equal(f.window.scrollY, 0);
});
test('failed scroll movement remains a failed assertion', async () => {
  const f = fixture({allowScroll: false});
  const load = f.window.loadEditor(f.model('long', 24), 'OSMD', '<score/>', '', true);
  f.pending.shift()(); await tick(); f.pending.shift()(); await load;
  assert.equal(f.ready()[0].scrollRetained, false);
});
test('ordinary long-score rendering performs no diagnostic redraw or selection exercise', async () => {
  const f = fixture(), load = f.window.loadEditor(f.model('long', 24), 'OSMD', '<score/>', '');
  f.pending.shift()(); await load;
  assert.equal(f.ready().length, 1);
  assert.equal(f.pending.length, 0);
  assert.equal(f.verified(), 0);
  assert.equal(Object.hasOwn(f.ready()[0], 'allEventsMapped'), false);
});
test('a superseded editor load cannot publish stale ready data', async () => {
  const f = fixture(), older = f.window.loadEditor(f.model('old'), 'OSMD', '<old/>', '', true);
  const current = f.model('new'); current.events.push({id: 'second'});
  await f.window.loadEditor(current, 'OSMD', '<new/>', '', true);
  f.pending.shift()(); await tick();
  assert.equal(f.ready().length, 0);
  f.pending.shift()(); await older;
  assert.equal(f.ready().length, 1);
  assert.equal(f.ready()[0].events, 2);
  assert.equal(f.verified(), 1);
});
test('superseding a scroll-proof redraw also discards its old assertions', async () => {
  const f = fixture(), older = f.window.loadEditor(f.model('old', 24), 'OSMD', '<old/>', '', true);
  f.pending.shift()(); await tick();
  await f.window.loadEditor(f.model('new'), 'OSMD', '<new/>', '', true);
  f.pending.shift()(); await tick();
  assert.equal(f.ready().length, 0);
  f.pending.shift()(); await older;
  assert.equal(f.ready().length, 1);
  assert.equal(f.verified(), 1);
});
test('a diagnostic error cannot publish an incomplete editor ready message', async () => {
  const f = fixture();
  f.window.verifyEditor = () => {throw new Error('selection unavailable');};
  const load = f.window.loadEditor(f.model(), 'OSMD', '<score/>', '', true);
  f.pending.shift()(); await load;
  assert.equal(f.ready().length, 0);
  assert.equal(f.messages.at(-1).kind, 'error');
  assert.equal(f.messages.at(-1).message, 'selection unavailable');
});
