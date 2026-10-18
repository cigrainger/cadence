// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Exercise the real render/ready orchestration; native previews separately
// check OSMD's actual cursor geometry in WKWebView.
function fixture(tabNotes = 0) {
  const messages = [], pending = [], checks = [];
  const bounds = {left: 0, top: 0, width: 700, height: 200};
  const score = {replaceChildren(){}, append(){}, scrollHeight: 220, getBoundingClientRect: () => bounds};
  const document = {
    getElementById: () => score,
    querySelectorAll: selector => selector === '.vf-tabnote' ? Array(tabNotes).fill({}) : [{}],
    createElement: () => ({setAttribute(){}}),
  };
  class OSMD {
    constructor() {
      let ended = false;
      this.EngravingRules = {};
      this.cursor = {
        Iterator: {get EndReached(){return ended;}, CurrentMeasureIndex: 0,
          CurrentRelativeInMeasureTimestamp: {RealValue: 0}},
        reset(){ended = false;}, show(){}, hide(){}, next(){ended = true;},
        cursorElement: {getBoundingClientRect: () => bounds},
      };
    }
    load() { return new Promise(resolve => pending.push(resolve)); }
    render() {}
  }
  const window = {webkit: {messageHandlers: {study: {postMessage: value => messages.push(value)}}},
    cadenceEngravingXML: xml => xml};
  const context = vm.createContext({window, document, opensheetmusicdisplay: {OpenSheetMusicDisplay: OSMD},
    ResizeObserver: class {observe(){}}, clearTimeout(){}, setTimeout(){}});
  vm.runInContext(fs.readFileSync('Resources/ScoreViewer/score.js', 'utf8'), context);
  context.passageXML = xml => xml;
  window.setStudyFeedback = () => ({feedbackMapped: true});
  window.setStudyFocus = () => ({focusMapped: true});
  window.verifyStudyCursor = () => {checks.push(true); return {continuousCursor: true, cursorCheckPreservesScroll: true};};
  return {window, messages, pending, checks, ready: () => messages.filter(m => m.kind === 'ready')};
}

test('preview ready includes cursor assertions before it crosses the native bridge', async () => {
  const f = fixture();
  const render = f.window.loadStudy('<score/>', 'P1', 0, 1, [4, 4], false, true);
  f.pending.shift()(); await render;
  assert.equal(f.ready().length, 1);
  assert.equal(f.ready()[0].continuousCursor, true);
  assert.equal(f.ready()[0].cursorCheckPreservesScroll, true);
  assert.equal(f.checks.length, 1);
});
test('ordinary playback does not run the diagnostic cursor exercise', async () => {
  const f = fixture(), render = f.window.loadStudy('<score/>', 'P1', 0, 1);
  f.pending.shift()(); await render;
  assert.equal(f.ready().length, 1);
  assert.equal(f.checks.length, 0);
  assert.equal(Object.hasOwn(f.ready()[0], 'continuousCursor'), false);
});
test('a superseded load cannot emit ready or cursor results for the current render', async () => {
  const f = fixture();
  const older = f.window.loadStudy('<old/>', 'P1', 0, 0, [4], false, true);
  const current = f.window.loadStudy('<new/>', 'P1', 0, 2, [4, 4, 4], false, true);
  f.pending[1](); await current;
  f.pending[0](); await older;
  assert.equal(f.ready().length, 1);
  assert.equal(f.ready()[0].bars, 3);
  assert.equal(f.checks.length, 1);
});
test('a cursor-check error stays visible rather than emitting incomplete ready data', async () => {
  const f = fixture();
  f.window.verifyStudyCursor = () => {throw new Error('cursor unavailable');};
  const render = f.window.loadStudy('<score/>', 'P1', 0, 1, [4, 4], false, true);
  f.pending.shift()(); await render;
  assert.equal(f.ready().length, 0);
  assert.equal(f.messages.at(-1).kind, 'error');
  assert.equal(f.messages.at(-1).message, 'cursor unavailable');
});

test('linked tab requires both the source staff and actual rendered tab notes', async () => {
  for (const [xml, notes, expected] of [['<sign>TAB</sign>', 8, true], ['<sign>TAB</sign>', 0, false], ['<sign>G</sign>', 8, false]]) {
    const f = fixture(notes), render = f.window.loadStudy(xml, 'P1', 0, 0);
    f.pending.shift()(); await render;
    assert.equal(f.ready()[0].linkedTab, expected);
    assert.equal(f.ready()[0].tabNoteCount, notes);
  }
});
