/* SPDX-License-Identifier: AGPL-3.0-or-later */
'use strict';
(() => {
  const play = document.querySelector('#hear-demo');
  const status = document.querySelector('#demo-status');
  let harmony = 'original', context, timer, playing = false, generation = 0;
  const finish = () => {
    clearTimeout(timer); playing = false;
    if (play) { play.textContent = '▶ Hear the route'; play.setAttribute('aria-label', 'Hear the chord progression'); }
  };
  const stop = () => { generation++; if (context) { context.close().catch(() => {}); context = null; } finish(); };
  document.querySelectorAll('[data-harmony]').forEach(button => button.addEventListener('click', () => {
    stop(); harmony = button.dataset.harmony;
    document.querySelectorAll('[data-harmony]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.querySelector('#middle-chord').textContent = harmony === 'original' ? 'G7' : 'D♭7';
    status.textContent = harmony === 'original' ? 'G moves down a fifth to C. Listen to the bass.' : 'D♭ moves down a semitone to C. The upper notes stay the same.';
  }));
  if (play) play.addEventListener('click', async () => {
    if (playing) { stop(); status.textContent = 'Stopped.'; return; }
    try {
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) throw new Error('Audio unavailable');
      const request = ++generation;
      const active = new AudioContext(); context = active; playing = true;
      await active.resume();
      if (request !== generation) return;
      play.textContent = '■ Stop'; play.setAttribute('aria-label', 'Stop the demonstration');
      status.textContent = harmony === 'original' ? 'Playing Dm7 → G7 → Cmaj7.' : 'Playing Dm7 → D♭7 → Cmaj7.';
      const chords = [[38, 53, 60], [harmony === 'original' ? 43 : 37, 53, 59], [36, 52, 59]];
      const bus = context.createGain(); bus.gain.value = .22; bus.connect(context.destination);
      chords.forEach((notes, i) => notes.forEach((note, voice) => {
        const oscillator = context.createOscillator(), gain = context.createGain(), start = context.currentTime + .08 + i * 1.35;
        oscillator.type = voice === 0 ? 'sine' : 'triangle'; oscillator.frequency.value = 440 * 2 ** ((note - 69) / 12);
        gain.gain.setValueAtTime(0, start); gain.gain.linearRampToValueAtTime(.3, start + .02); gain.gain.exponentialRampToValueAtTime(.06, start + 1.05); gain.gain.linearRampToValueAtTime(0, start + 1.3);
        oscillator.connect(gain); gain.connect(bus); oscillator.start(start); oscillator.stop(start + 1.31);
      }));
      timer = setTimeout(() => { stop(); status.textContent = 'Try the other route. What changed when the bass moved?'; }, 4250);
    } catch { stop(); status.textContent = 'Audio is unavailable in this browser. The diagram shows the same guide-tone movement.'; }
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
