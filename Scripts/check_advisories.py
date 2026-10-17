#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Query OSV for known runtime package versions. Unknown bundle versions are reported, not cleared."""
import json
from pathlib import Path
import sys
import urllib.request

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'Dependencies/components.json').read_text())
queries, labels = [], []
for component in manifest['components']:
    if component.get('purl', '').startswith('pkg:npm/'):
        queries.append({'package': {'ecosystem': 'npm', 'name': component['name']}, 'version': component['version']})
        labels.append(component['name'] + '@' + component['version'])
    elif component['id'] == 'zipfoundation':
        queries.append({'commit': component['revision']}); labels.append('ZIPFoundation@' + component['version'])
request = urllib.request.Request('https://api.osv.dev/v1/querybatch', data=json.dumps({'queries': queries}).encode(),
                                 headers={'Content-Type': 'application/json'}, method='POST')
with urllib.request.urlopen(request, timeout=45) as response:
    results = json.load(response)['results']
if len(results) != len(queries): raise RuntimeError('OSV returned an incomplete response')
found = False
for label, result in zip(labels, results):
    ids = [v['id'] for v in result.get('vulns', [])]
    found |= bool(ids)
    print(label + ': ' + (', '.join(ids) if ids else 'no advisories returned'))
print('Not checked: unknown OSMD transitive versions, the independent sound bank and Apple system frameworks.')
sys.exit(1 if found else 0)
