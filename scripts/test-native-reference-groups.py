#!/usr/bin/env python3
"""Run every reference case in bounded compilation groups, preserving driver policy."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
from native_reference_groups import inventory, plan


def main():
    root = Path(__file__).resolve().parent.parent
    cases, default, _, dependencies = inventory(root)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git', type=Path, action='append')
    parser.add_argument('--only', choices=cases, action='append')
    parser.add_argument('--group-size', type=int, default=12)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--list', action='store_true', help='Print the complete plan without building or running receivers.')
    args = parser.parse_args()
    if args.group_size < 1: parser.error('--group-size must be positive')
    groups = plan(cases, args.only or default, dependencies, args.group_size, check_all=args.only is None)
    if args.list:
        print(json.dumps(groups, indent=2)); return
    # Preserve the old driver's Git-outer/case-inner execution order. Compile-only
    # needs each group once because its cache is independent of the Git choice.
    engines = [None] if args.compile_only else args.git or [Path('/usr/bin/git')]
    for git in engines:
        for index, group in enumerate(groups):
            command = [sys.executable, str(root / 'scripts/test-native-reference-batch.py')]
            if git is not None: command += ['--git', str(git)]
            for case in group['compile']: command += ['--only', case]
            for case in group['include']: command += ['--include', case]
            if args.compile_only or not group['run']: command += ['--compile-only']
            print('Reference group ' + str(index + 1) + '/' + str(len(groups)) + ': ' + (', '.join(group['run']) if group['run'] else 'typecheck only: ' + ', '.join(group['compile'])) +
                  ('; compile helpers: ' + ', '.join(group['include']) if group['include'] else ''), flush=True)
            started = time.monotonic()
            subprocess.run(command, cwd=root, check=True)
            print('Reference group ' + str(index + 1) + ' completed in ' + format(time.monotonic() - started, '.2f') + ' seconds.', flush=True)


if __name__ == '__main__':
    main()
