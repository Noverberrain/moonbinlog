# Copyright 2026 Noverberrain.
# SPDX-License-Identifier: Apache-2.0
"""Build and run four offline demonstrations with checked, saved CLI output."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_EXE = ROOT / '_build/native/debug/build/cmd/moonbinlog/moonbinlog.exe'
OUTPUT = ROOT / '_build/acceptance-demo'
GTID = 'fixtures/gtid-real/crc32-full.binlog'
MINIMAL = 'fixtures/mysql-json/crc32-minimal.binlog'
SCHEMA = 'examples/mysql-8.0-json-schema.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main(executable):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    report_path = OUTPUT / 'report.json'
    # Replace a previous success before doing any work, so failure cannot leave
    # an old report looking like the result of the current invocation.
    save_json(report_path, {'format_version': 1, 'status': 'running'})
    if executable is None:
        subprocess.run(['moon', 'build', '--target', 'native'], cwd=ROOT, check=True, timeout=300)
        executable = DEFAULT_EXE
    executable = executable.resolve()
    require(executable.is_file(), f'CLI executable not found: {executable}')
    inputs = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
              for name in [GTID, MINIMAL, SCHEMA]}
    steps = []

    def run(name, args, expected_code=0):
        result = subprocess.run([str(executable), *args], cwd=ROOT, capture_output=True,
                                text=True, encoding='utf-8', timeout=90)
        (OUTPUT / f'{name}.jsonl').write_text(result.stdout, encoding='utf-8')
        (OUTPUT / f'{name}.stderr.txt').write_text(result.stderr, encoding='utf-8')
        require(result.returncode == expected_code,
                f'{name}: expected exit {expected_code}, got {result.returncode}: {result.stderr}')
        if expected_code == 0:
            require(not result.stderr, f'{name}: unexpected stderr: {result.stderr}')
        records = [json.loads(line) for line in result.stdout.splitlines()]
        steps.append({'name': name, 'arguments': args, 'exit_code': result.returncode,
                      'records': len(records), 'stdout': f'{name}.jsonl',
                      'stderr': f'{name}.stderr.txt'})
        return records, result.stderr

    events, _ = run('events', ['--stream', '--decode-gtid', '--decode-previous-gtids',
                             '--decode-rotate', GTID])
    require(len(events) == 19 and events[-1]['kind'] == 'summary' and
            events[-1]['events'] == 18, 'events: expected 18 events and one summary')
    identities = [r['gtid']['identity'] for r in events[:-1] if r['type'] == 33]
    manifest = json.loads((ROOT / 'fixtures/gtid-real/manifest.json').read_text(encoding='utf-8'))
    require(identities == [f"{manifest['server_uuid']}:{n}" for n in [2, 3, 4]],
            'events: assigned GTIDs differ from the fixed capture')
    history = next(r['previous_gtids']['sids'] for r in events[:-1] if r['type'] == 35)
    require(history == [{'sid': manifest['server_uuid'],
                         'intervals': [{'start': '1', 'end_exclusive': '2'}]}],
            'events: expected nonempty historical GTID interval [1, 2)')
    rotation = next(r['rotate'] for r in events[:-1] if r['type'] == 4)
    require(rotation['position'] == '4' and rotation['next_binlog_utf8'] == 'capture.000004',
            'events: rotation target differs from the fixed capture')
    print('[1/4] Event details: 18 events, assigned GTIDs 2/3/4, history and rotation.')

    rows, _ = run('rows', ['--stream', '--rows', '--schema', SCHEMA, MINIMAL])
    require(len(rows) == 7 and rows[-1]['kind'] == 'row_summary' and
            rows[-1]['row_events'] == 3 and rows[-1]['changes'] == 6,
            'rows: expected three row events and six changes')
    require(all(r['transaction_status'] == 'unconfirmed' for r in rows),
            'rows: standalone row output must remain unconfirmed')
    cells = [cell for row in rows[:-1] for side in ['before', 'after']
             for cell in (row[side] or [])]
    require({'absent', 'null', 'value'} <= {cell['state'] for cell in cells},
            'rows: missing Absent, SQL NULL or actual value')
    require(any(cell.get('type') == 'json' and cell.get('value') == 'null' for cell in cells),
            'rows: missing JSON null, which differs from SQL NULL')
    require(any('18446744073709551615' in cell.get('value', '') for cell in cells),
            'rows: missing exact UInt64 value in JSON text')
    print('[2/4] MINIMAL rows: six changes; Absent, SQL NULL, JSON null and exact integers.')

    tx_args = ['--stream', '--transactions', '--with-gtid', '--include-rows', '--schema', SCHEMA]
    transactions, _ = run('transactions', [*tx_args, GTID])
    require(len(transactions) == 4 and transactions[-1]['kind'] == 'transaction_summary' and
            transactions[-1]['committed_transactions'] == 3 and
            transactions[-1]['committed_changes'] == 6,
            'transactions: expected three commits and six changes')
    require([r['gtid']['identity'] for r in transactions[:-1]] == identities,
            'transactions: GTID binding differs from event identities')
    require(all(r['status'] == 'committed' for r in transactions[:-1]),
            'transactions: expected committed outcomes')
    require(sum(len(r['row_changes']) for r in transactions[:-1]) == 6 and
            all(row['transaction_status'] == 'committed' for r in transactions[:-1]
                for row in r['row_changes']), 'transactions: invalid committed rows')
    print('[3/4] GTID transactions: three commits with six committed row changes.')

    # Stop before the first XID: the first transaction has rows but no commit.
    first_xid = next(int(r['offset']) for r in events[:-1] if r['type'] == 16)
    unfinished = OUTPUT / 'unfinished.binlog'
    unfinished.write_bytes((ROOT / GTID).read_bytes()[:first_xid])
    records, error = run('unfinished', [*tx_args, str(unfinished)], expected_code=1)
    require(not records and 'IncompleteGtidTransaction' in error,
            'unfinished: expected an EOF error without pending rows or a success summary')
    print('[4/4] Unfinished transaction: expected exit 1; no pending rows or success summary.')

    require(all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
                for name, digest in inputs.items()), 'Tracked input changed during demonstration')
    save_json(report_path, {'format_version': 1, 'status': 'passed', 'steps': steps,
                            'input_sha256': inputs})
    print(f'All four demonstrations passed. Saved output: {OUTPUT}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, help='Use an existing CLI executable; skip the build')
    try:
        main(parser.parse_args().exe)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        sys.exit(f'Demonstration failed: {error}')
