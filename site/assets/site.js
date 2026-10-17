/* SPDX-License-Identifier: AGPL-3.0-or-later */
'use strict';
(() => {
  const play = document.querySelector('#hear-demo');
  const status = document.querySelector('#demo-status');
  const bassToggle = document.querySelector('#demo-bass-only');
  // The score labels and sounding voicings share this data, including enharmonic spelling.
  const routes = {
    original: { chord: 'G7', bass: 'G', guide: 'B', notes: [43, 53, 59],
      explanation: 'G falls a fifth to C. Above it, B stays put and F resolves to E.' },
    substitute: { chord: 'D♭7', bass: 'D♭', guide: 'C♭', notes: [37, 53, 59],
      explanation: 'D♭ falls a semitone to C. C♭ is the same piano key as B; the upper voices sound unchanged.' }
  };
  let harmony = 'original', bassOnly = false, context, timer, playing = false, generation = 0;
  const selectionStatus = () => bassOnly
    ? `Selected bass: D → ${routes[harmony].bass} → C. Press play to compare.`
    : `Selected Dm7 → ${routes[harmony].chord} → Cmaj7. Press play to compare.`;
  const finish = () => {
    clearTimeout(timer); playing = false;
    if (play) { play.textContent = '▶ Hear the route'; play.setAttribute('aria-label', 'Hear the chord progression'); }
  };
  const stop = () => { generation++; if (context) { context.close().catch(() => {}); context = null; } finish(); };
  document.querySelectorAll('[data-harmony]').forEach(button => button.addEventListener('click', () => {
    const selected = routes[button.dataset.harmony];
    if (!selected) return;
    stop(); harmony = button.dataset.harmony;
    document.querySelectorAll('[data-harmony]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.querySelector('#middle-chord').textContent = selected.chord;
    document.querySelector('#middle-bass').textContent = selected.bass;
    document.querySelector('#middle-guide').textContent = selected.guide;
    document.querySelector('#voice-diagram').setAttribute('aria-label', `Upper voices: C to ${selected.guide} to B, and F to F to E.`);
    document.querySelector('#harmony-explanation').textContent = selected.explanation;
    status.textContent = selectionStatus();
  }));
  if (bassToggle) bassToggle.addEventListener('click', () => {
    stop(); bassOnly = !bassOnly;
    bassToggle.setAttribute('aria-pressed', String(bassOnly));
    status.textContent = selectionStatus();
  });
  if (play) play.addEventListener('click', async () => {
    if (playing) { stop(); status.textContent = 'Stopped.'; return; }
    const request = ++generation;
    try {
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) throw new Error('Audio unavailable');
      const active = new AudioContext(); context = active; playing = true;
      await active.resume();
      if (request !== generation) return;
      play.textContent = '■ Stop'; play.setAttribute('aria-label', 'Stop the demonstration');
      status.textContent = bassOnly ? `Playing bass: D → ${routes[harmony].bass} → C.`
        : `Playing Dm7 → ${routes[harmony].chord} → Cmaj7.`;
      const chords = [[38, 53, 60], routes[harmony].notes, [36, 52, 59]];
      const bus = context.createGain(); bus.gain.value = .22; bus.connect(context.destination);
      // A pure low sine can disappear on small speakers. Its octave/upper harmonics
      // make the same bass pitch audible without changing the written voicing.
      const bassWave = context.createPeriodicWave(new Float32Array(5), new Float32Array([0, 1, .8, .45, .2]));
      chords.forEach((notes, i) => (bassOnly ? notes.slice(0, 1) : notes).forEach((note, voice) => {
        const oscillator = context.createOscillator(), gain = context.createGain(), start = context.currentTime + .08 + i * 1.35;
        if (voice === 0) oscillator.setPeriodicWave(bassWave); else oscillator.type = 'triangle';
        oscillator.frequency.value = 440 * 2 ** ((note - 69) / 12);
        const level = voice === 0 ? .5 : .2;
        gain.gain.setValueAtTime(0, start); gain.gain.linearRampToValueAtTime(level, start + .02); gain.gain.exponentialRampToValueAtTime(level * .2, start + 1.05); gain.gain.linearRampToValueAtTime(0, start + 1.3);
        oscillator.connect(gain); gain.connect(bus); oscillator.start(start); oscillator.stop(start + 1.31);
      }));
      timer = setTimeout(() => { stop(); status.textContent = 'Try the other route. Listen for G versus D♭ in the middle; the upper notes stay the same.'; }, 4250);
    } catch { if (request !== generation) return; stop(); status.textContent = 'Audio is unavailable in this browser. The diagram shows the same guide-tone movement.'; }
  });
  document.addEventListener('visibilitychange', () => { if (document.hidden && playing) { stop(); status.textContent = 'Paused when you left this page.'; } });
  window.addEventListener('pagehide', stop);
  const search = document.querySelector('#reference-search');
  if (search) search.addEventListener('input', () => {
    const query = search.value.trim().toLocaleLowerCase(); let visible = 0;
    document.querySelectorAll('[data-reference]').forEach(item => { item.hidden = !(item.textContent + " " + (item.dataset.search || "")).toLocaleLowerCase().includes(query); if (!item.hidden) visible++; });
    document.querySelector('#reference-status').textContent = visible ? `${visible} matching guides` : "No matching guide. Try another musical term.";
  });
})();
