#!/usr/bin/env python3
"""Summarize real .app event evidence, without synthesizing hardware events."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent / '.build/native-system-audit'
summary = {}
confirmation_path = root / 'user-confirmations.json'
confirmations = json.loads(confirmation_path.read_text()) if confirmation_path.exists() else {}
for choice in ('denied', 'allowed'):
    path = root / choice / 'events.jsonl'
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    assertions = [r for r in rows if r['event'] == 'assertion']
    # Preserve the final result of each named assertion rather than counting retries.
    checks = {r['name']: {'passed': r['passed'], 'at': r['at']} for r in assertions}
    if choice == 'denied':
        denial = [r for r in rows if r['event'] == 'permission-change'
                  and r.get('permission') == 'permission.denied']
        if denial and confirmations.get('denied', {}).get('choice') == 'denied':
            first = denial[0]
            checks['notification.denial.no-generic-error'] = {
                'passed': not first.get('error'), 'at': first['at'],
                'actual': first.get('error', ''),
                'note': 'The user confirmed selecting Do Not Allow in the real macOS prompt.'}
    summary[choice] = dict(checks=checks,
        physical_sleep_results=[r for r in rows if r['event'] == 'sleep-result'],
        display_events=[r for r in rows if r['event'] in ('ready', 'display-change')],
        diagnostics=[r for r in rows if r['event'] == 'authorization-diagnostic'],
        blocked=[r for r in rows if r['event'] == 'blocked'])
hotplug_path = root / 'hotplug-result.json'
if hotplug_path.exists():
    summary['hotplug'] = json.loads(hotplug_path.read_text())
output = root / 'summary.json'
output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print(output)
for choice, result in summary.items():
    checks = result['checks']
    outcomes = [c if isinstance(c, bool) else c['passed'] for c in checks.values()]
    print(f'{choice}: {sum(outcomes)} passed, {sum(not c for c in outcomes)} failed, '
          f'{len(result.get("physical_sleep_results", []))} physical sleep scenario(s)')
