#!/usr/bin/env python3
"""Run every reference case in bounded compilation groups, preserving driver policy."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import signal
import tempfile
import sys
import time
from native_reference_groups import inventory, plan


def write_results(path, results, total):
    path.parent.mkdir(parents=True, exist_ok=True)
    report = dict(groups=results, total_groups=total,
                  passed_groups=sum(row['status'] == 'passed' for row in results),
                  failed_groups=sum(row['status'] == 'failed' for row in results),
                  complete=len(results) == total and all(row['status'] != 'running' and row.get('cleanup_complete', False) for row in results))
    path.write_text(json.dumps(report, indent=2) + '\n')


def approved_images(root, git):
    images = {str(Path('/bin/sleep').resolve())}
    if git is not None:
        images.add(str(git.resolve()))
    selected = subprocess.run(['/usr/bin/xcrun', '--find', 'git'], capture_output=True, text=True, timeout=10)
    if selected.returncode == 0:
        images.add(str(Path(selected.stdout.strip()).resolve()))
    bundle = root / 'build/Build/Products/Debug/TurtleGitMac.app/Contents'
    for directory in (bundle / 'Helpers', bundle / 'MacOS'):
        if directory.is_dir():
            images.update(str(path.resolve()) for path in directory.rglob('*')
                          if path.is_file() and path.suffix not in ('.dylib', '.so') and os.access(path, os.X_OK))
    return images


def private_path(name, context):
    # lsof reports retained deleted cwd/files by their original absolute name.
    # Do not follow a possibly replaced fixture symlink during ownership checks.
    if name.endswith(' (deleted)'):
        name = name[:-10]
    path = os.path.normpath(name)
    return path if path == str(context) or path.startswith(str(context) + os.sep) else None


def parse_process_files(data):
    """Parse NUL fields; raw Git filename newlines cannot introduce PID records."""
    records, current, descriptor, kind = {}, None, None, None
    for field in data.split(b'\0'):
        field = field.lstrip(b'\n')  # lsof's record separator, before the field tag.
        if not field:
            continue
        tag, value = field[:1], os.fsdecode(field[1:])
        if tag == b'p':
            if not value.isdecimal():
                raise RuntimeError('Cannot parse private helper process identity')
            current = records.setdefault(int(value), dict(images=set(), resources=[], scripts=[]))
            descriptor, kind = None, None
        elif current is not None:
            if tag == b'f':
                descriptor, kind = value, None
            elif tag == b't':
                kind = value
            elif tag == b'n':
                current['resources'].append(value)
                if descriptor == 'txt':
                    current['images'].add(value.removesuffix(' (deleted)'))
                if kind == 'REG':
                    current['scripts'].append(value)
    return records


def inspect_processes():
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-u', str(os.getuid()), '-F0pftn'],
                            capture_output=True, timeout=20)
    if result.returncode != 0:
        raise RuntimeError('Cannot inspect owned private group resources')
    return parse_process_files(result.stdout)


def process_start(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                            capture_output=True, text=True, timeout=5)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    raise RuntimeError('Cannot verify owned private helper lifetime')


def owned_processes(records, context, images):
    owned = {}
    shells = {str(Path('/bin/sh').resolve()), str(Path('/bin/bash').resolve())}
    for pid, record in records.items():
        resources = [private_path(name, context) for name in record['resources']]
        if not any(resources):
            continue
        actual = {str(Path(name).resolve()) for name in record['images']}
        approved = bool(actual.intersection(images))
        if not approved and actual.intersection(shells):
            # Shells require an exact authored-script argv plus that script's
            # regular-file resource in this unique context, not just its cwd.
            command = subprocess.run(['/bin/ps', '-ww', '-p', str(pid), '-o', 'command='],
                                     capture_output=True, text=True, timeout=5)
            if command.returncode == 0:
                for name in record['scripts']:
                    script = private_path(name, context)
                    if script is not None:
                        for shell in ('/bin/sh', '/bin/bash'):
                            prefix = shell + ' ' + script
                            if command.stdout.strip() == prefix or command.stdout.strip().startswith(prefix + ' '):
                                approved = True
        if not approved:
            # Never signal an unapproved process, even inside our private root.
            raise RuntimeError('Unapproved owner of private group resources; continuation refused')
        start = process_start(pid)
        if start is not None:
            owned[pid] = (start, frozenset(actual.intersection(images | shells)))
    return owned


def cleanup_group(context, images, inspect=None, identify=None, signal_pid=None, start=None, pause=None):
    """Drain exact owned PIDs, including helpers in independently created PGIDs.

    Individual PID signalling avoids killing unproved members of a process group.
    The unique private-resource proof is required at admission; each subsequent
    signal revalidates process start and executable identity against that receipt.
    Unknown or uninspectable private owners stop further group execution.
    """
    inspect = inspect or inspect_processes
    identify = identify or owned_processes
    signal_pid = signal_pid or os.kill
    start = start or process_start
    pause = pause or time.sleep
    tracked, needed = {}, False
    proof_images = images | {str(Path('/bin/sh').resolve()), str(Path('/bin/bash').resolve())}
    for number in (signal.SIGTERM, signal.SIGKILL):
        records = inspect()
        tracked.update(identify(records, context, images))
        needed = needed or bool(tracked)
        if not tracked:
            return needed
        for pid, identity in list(tracked.items()):
            fresh = inspect()
            # Refuse unexpected owners before signalling any previously owned PID.
            identify(fresh, context, images)
            record = fresh.get(pid)
            current_start = start(pid)
            if current_start is None or current_start != identity[0]:
                tracked.pop(pid, None)
                continue
            actual = frozenset(str(Path(name).resolve()) for name in record['images']).intersection(proof_images) if record else frozenset()
            if actual != identity[1]:
                raise RuntimeError('Owned helper executable identity changed; continuation refused')
            try:
                signal_pid(pid, number)
            except ProcessLookupError:
                tracked.pop(pid, None)
        deadline = time.monotonic() + 3
        while True:
            fresh = inspect()
            current = identify(fresh, context, images)
            tracked.update(current)
            for pid, identity in list(tracked.items()):
                current_start = start(pid)
                if current_start is None or current_start != identity[0]:
                    tracked.pop(pid, None)
            if not tracked:
                return needed
            if time.monotonic() >= deadline:
                break
            pause(.03)
    raise RuntimeError('Owned private helper survived TERM/KILL; continuation refused')


def main():
    root = Path(__file__).resolve().parent.parent
    cases, default, _, dependencies = inventory(root)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git', type=Path, action='append')
    parser.add_argument('--only', choices=cases, action='append')
    parser.add_argument('--group-size', type=int, default=12)
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--list', action='store_true', help='Print the complete plan without building or running receivers.')
    parser.add_argument('--results', type=Path, default=root / 'build/qa/native-reference-groups-results.json',
                        help='Incremental independent-group results; native assertion and cleanup logs remain with the delegated driver.')
    args = parser.parse_args()
    if args.group_size < 1: parser.error('--group-size must be positive')
    groups = plan(cases, args.only or default, dependencies, args.group_size, check_all=args.only is None)
    if args.list:
        print(json.dumps(groups, indent=2)); return 0
    # Preserve the old driver's Git-outer/case-inner execution order. Compile-only
    # needs each group once because its cache is independent of the Git choice.
    engines = [None] if args.compile_only else args.git or [Path('/usr/bin/git')]
    results, total = [], len(engines) * len(groups)
    write_results(args.results, results, total)
    stop = False
    for git in engines:
        if stop: break
        images = approved_images(root, git)
        for index, group in enumerate(groups):
            command = [sys.executable, str(root / 'scripts/test-native-reference-batch.py')]
            if git is not None: command += ['--git', str(git)]
            for case in group['compile']: command += ['--only', case]
            for case in group['include']: command += ['--include', case]
            compile_only = args.compile_only or not group['run']
            if compile_only: command += ['--compile-only']
            print('Reference group ' + str(index + 1) + '/' + str(len(groups)) + ': ' + (', '.join(group['run']) if group['run'] else 'typecheck only: ' + ', '.join(group['compile'])) +
                  ('; compile helpers: ' + ', '.join(group['include']) if group['include'] else ''), flush=True)
            row = dict(engine=str(git) if git is not None else None, group=index + 1,
                       run=group['run'], compile=group['compile'], include=group['include'],
                       compile_only=compile_only, status='running', returncode=None)
            results.append(row)
            write_results(args.results, results, total)
            context = Path(tempfile.mkdtemp(prefix='turtlegit-reference-group-')).resolve()
            row['private_context'] = str(context)
            environment = dict(os.environ, TMPDIR=str(context) + os.sep)
            started = time.monotonic()
            try:
                # The delegated driver owns compilation caches, assertions and
                # receiver/helper cleanup. Its nonzero result retires this group,
                # not independent groups or the remaining Git engine.
                result = subprocess.run(command, cwd=root, env=environment, check=False)
                row.update(returncode=result.returncode, status='passed' if result.returncode == 0 else 'failed')
            except OSError as error:
                row.update(status='failed', error=str(error))
            except BaseException as error:
                row.update(status='failed', error=type(error).__name__)
                raise
            finally:
                try:
                    row['fallback_helper_cleanup'] = cleanup_group(context, images)
                    row['cleanup_complete'] = True
                    if row['fallback_helper_cleanup']:
                        row['status'] = 'failed'
                        row['error'] = 'Delegated driver left an owned helper; exact fallback cleanup drained it'
                    shutil.rmtree(context)
                except Exception as error:
                    row.update(status='failed', cleanup_complete=False, cleanup_error=str(error))
                    stop = True
                write_results(args.results, results, total)
            row['seconds'] = round(time.monotonic() - started, 3)
            write_results(args.results, results, total)
            print('Reference group ' + str(index + 1) + ' ' + row['status'] + ' in ' + format(row['seconds'], '.2f') +
                  ' seconds; exit=' + str(row['returncode']) + (('; launch error=' + row['error']) if 'error' in row else '') + '.', flush=True)
            if stop:
                print('Reference groups stopped: private helper cleanup could not prove drainage; context retained: ' + str(context), flush=True)
                break
    failed = [row for row in results if row['status'] == 'failed']
    print('Reference groups finished: ' + str(len(results) - len(failed)) + ' passed, ' + str(len(failed)) +
          ' failed; results: ' + str(args.results), flush=True)
    for row in failed:
        print('Failed reference group ' + str(row['group']) + '; engine=' + str(row['engine']) +
              '; exit=' + str(row['returncode']) + '; cases=' + ','.join(row['run'] or row['compile']), flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
