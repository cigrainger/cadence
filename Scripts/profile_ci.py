#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Profile a completed hosted run using GitHub timestamps and retained evidence."""
import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess


def seconds(start, end):
    return round((datetime.datetime.fromisoformat(end.replace('Z', '+00:00')) -
                  datetime.datetime.fromisoformat(start.replace('Z', '+00:00'))).total_seconds(), 3)


def execution_seconds(text):
    # Swift 6.2 runs a combined bundle; 6.4 can run each target separately.
    # Count only All-tests completions, never duplicate nested suite totals.
    return round(sum(float(value) for value in re.findall(
        r"Test Suite 'All tests' passed[^\n]*\n\s*Executed \d+ tests[^\n]*? in ([\d.]+) \(", text)), 3)


def evidence_profile(folder):
    reports = [json.loads(path.read_text()) for path in folder.rglob('summary.json')]
    full = next((r for r in reports if r.get('mode') == 'full'), None)
    if full is None:
        raise ValueError('Missing full native-verification report')
    digests = {r.get('sourceInputsSHA256') for r in reports if r.get('passed') is True}
    if len(digests) != 1 or None in digests:
        raise ValueError('Evidence comes from different source inputs')
    tests = next(folder.rglob('tests.log'), None)
    builds = [p for p in folder.rglob('release-build.log')]
    staged = full.get('preparedStages', {})
    compile_times = re.findall(r'Build complete! \(([\d.]+)s\)', tests.read_text()) if tests else []
    release_times = [float(v) for p in builds for v in re.findall(r'Build complete! \(([\d.]+)s\)', p.read_text())]
    return {'sourceInputsSHA256': digests.pop(), 'passed': full.get('passed'), 'tests': full.get('tests'),
            'unitCompileSeconds': float(compile_times[-1]) if compile_times else None,
            'testExecutionSeconds': execution_seconds(tests.read_text()) if tests else None,
            'productionCompileSeconds': max(release_times) if release_times else None,
            'unitStageSeconds': staged.get('unit', {}).get('seconds'),
            'productionStageSeconds': staged.get('release', {}).get('seconds'),
            'nativeMatrixSeconds': full.get('previewMatrixSeconds'),
            'verifierSeconds': full.get('seconds'), 'scenariosPerBuild': len(full.get('previews', {})),
            'toolchain': full.get('toolchain'), 'skippedNativeScenarios': full.get('skippedNativeScenarios')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, type=int)
    parser.add_argument('--repo', default='cigrainger/cadence')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    def api(path):
        return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + args.repo + '/' + path]))
    run = api(f'actions/runs/{args.run}')
    if run['status'] != 'completed':
        raise ValueError('Wait for the run to complete; do not profile a partial success')
    jobs = api(f'actions/runs/{args.run}/attempts/{run["run_attempt"]}/jobs?per_page=100')['jobs']
    artifacts = api(f'actions/runs/{args.run}/artifacts?per_page=100')['artifacts']
    selected = []
    for kind in ('unit-evidence', 'production-evidence', 'cadence-verification'):
        name = kind + '-' + str(run['run_attempt'])
        if not any(a['name'] == name for a in artifacts): name = kind  # Previous monolithic workflow.
        if any(a['name'] == name and not a['expired'] for a in artifacts):
            selected.append(name)
            subprocess.run(['gh', 'run', 'download', str(args.run), '--repo', args.repo,
                            '--name', name, '--dir', str(args.output / name)], check=True)
    profile = {'run': args.run, 'attempt': run['run_attempt'], 'commit': run['head_sha'],
               'conclusion': run['conclusion'], 'url': run['html_url'], 'artifacts': selected,
               'workflowWallSeconds': seconds(run['created_at'], run['updated_at']),
               'jobs': [{'name': j['name'], 'conclusion': j['conclusion'],
                         'seconds': seconds(j['started_at'], j['completed_at']),
                         'steps': [{'name': s['name'], 'seconds': seconds(s['started_at'], s['completed_at'])}
                                   for s in j['steps'] if s.get('started_at') and s.get('completed_at')]}
                        for j in jobs], 'evidence': evidence_profile(args.output)}
    (args.output / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
    print(json.dumps(profile, indent=2))


if __name__ == '__main__': main()
