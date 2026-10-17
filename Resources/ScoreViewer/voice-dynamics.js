// OSMD 2.2.1 merges different dynamics at one staff timestamp, regardless
// of their voice and placement. A one-division engraving-only offset keeps
// those labels separate. Saved/exported MusicXML and audio remain exact.
window.cadenceEngravingXML = function(xml) {
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  const child = (node, name) => [...node.children].find(e => e.localName === name);
  const value = (node, name) => child(node, name)?.textContent || '';
  let changes = 0, dynamicChanges = 0;
  // OSMD 2.2.1 ignores harmony offsets and kind text. Use positioned text
  // directions for Cadence's explicitly spelled labels, in this display copy
  // only. Saved/exported harmony remains structured MusicXML.
  const cadence = [...doc.getElementsByTagName('software')].some(e => e.textContent === 'Cadence Compose');
  const pitch = (node, prefix) => {
    const alteration = Number(value(node, prefix + '-alter'));
    if (!Number.isInteger(alteration) || Math.abs(alteration) > 2) return '';
    return value(node, prefix + '-step') + (alteration < 0 ? '♭'.repeat(-alteration) : '♯'.repeat(alteration));
  };
  const labels = [];
  for (const harmony of [...doc.getElementsByTagName('harmony')]) {
    const offset = Number(value(harmony, 'offset'));
    if (!Number.isFinite(offset) || Math.abs(offset) > 1000000) continue;
    const kind = child(harmony, 'kind'), root = child(harmony, 'root');
    let display = harmony;
    if (cadence && root && kind?.hasAttribute('text')) {
      const additions = [...harmony.children].filter(n => n.localName === 'degree' && n.getAttribute('print-object') !== 'no').map(n => {
        const alteration = Number(value(n, 'degree-alter'));
        if (!Number.isInteger(alteration) || Math.abs(alteration) > 2) return '';
        return (value(n, 'degree-type') === 'subtract' ? 'no' : alteration === 0 ? 'add' : '') + (alteration < 0 ? '♭'.repeat(-alteration) : '♯'.repeat(alteration)) + value(n, 'degree-value');
      }).filter(Boolean);
      const bass = child(harmony, 'bass');
      const label = kind.textContent === 'none' ? 'N.C.' : pitch(root, 'root') + kind.getAttribute('text') + (additions.length ? '(' + additions.join(',') + ')' : '') + (bass ? '/' + pitch(bass, 'bass') : '');
      const direction = doc.createElement('direction'), type = doc.createElement('direction-type'), words = doc.createElement('words');
      direction.setAttribute('placement', 'above'); words.setAttribute('font-size', '12'); words.setAttribute('font-weight', 'bold');
      words.textContent = label; type.append(words); direction.append(type);
      const staff = child(harmony, 'staff'); if (staff) direction.append(staff.cloneNode(true));
      harmony.replaceWith(direction); display = direction; labels.push(label); changes++;
    }
    // Place the renderer cursor explicitly, then restore it before reading notes.
    // This works even when the chord changes between two written note attacks.
    if (offset !== 0) {
      for (const [before, name] of [[true, offset > 0 ? 'forward' : 'backup'], [false, offset > 0 ? 'backup' : 'forward']]) {
        const move = doc.createElement(name), duration = doc.createElement('duration'); duration.textContent = String(Math.abs(offset)); move.append(duration);
        before ? display.before(move) : display.after(move);
      }
      child(display, 'offset')?.remove(); changes++;
    }
  }
  window.cadenceHarmonyLabels = labels;
  for (const part of [...doc.documentElement.children].filter(e => e.localName === 'part')) {
    for (const measure of [...part.children].filter(e => e.localName === 'measure')) {
      let tick = 0;
      const groups = new Map();
      for (const node of measure.children) {
        if (node.localName === 'backup') tick -= Number(value(node, 'duration'));
        if (node.localName === 'forward') tick += Number(value(node, 'duration'));
        if (node.localName === 'note' && !child(node, 'chord') && !child(node, 'grace')) tick += Number(value(node, 'duration'));
        if (node.localName !== 'direction' || !node.getElementsByTagName('dynamics').length || !value(node, 'voice')) continue;
        if (Number(value(node, 'offset')) !== 0) continue;
        const key = `${value(node, 'staff') || '1'}:${tick}`;
        const group = groups.get(key) || [];
        group.push(node); groups.set(key, group);
      }
      for (const group of groups.values()) {
        if (new Set(group.map(n => value(n, 'voice'))).size < 2) continue;
        for (let i = 0; i < group.length - 1; i++) {
          const node = group[i];
          let offset = child(node, 'offset');
          if (!offset) { offset = doc.createElement('offset'); const after = [...node.children].filter(n => n.localName === 'direction-type').at(-1); node.insertBefore(offset, after.nextSibling); }
          offset.textContent = String(i + 1); changes++; dynamicChanges++;
        }
      }
    }
  }
  window.cadenceDynamicOffsets = dynamicChanges;
  return changes ? new XMLSerializer().serializeToString(doc) : xml;
};
