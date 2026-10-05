#!/usr/bin/env python3
"""Capture synthetic production components and native simulator system attempts."""
# SPDX-License-Identifier: AGPL-3.0-only
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import time

from project import BUNDLE, REFERENCE, SOURCES, generate
from apply_design import load_spec, verify_hashes

ROOT = Path(__file__).resolve().parents[1]


def png_dimensions(path):
    with path.open('rb') as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR':
        raise ValueError(f'Invalid PNG: {path.name}')
    width, height = struct.unpack('>II', header[16:24])
    if min(width, height) <= 0:
        raise ValueError('Empty PNG')
    return width, height


def attachment_labels(value):
    """Preserve xcresult's human names; never infer a system surface from pixels."""
    result = {}
    def visit(item):
        if isinstance(item, dict):
            filename = item.get('exportedFileName')
            name = item.get('suggestedHumanReadableName') or item.get('name')
            if isinstance(filename, str) and isinstance(name, str):
                result[filename] = name
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    return result


def collect_app_records(read, device, output):
    # XCTest may reinstall the app. Resolve its current container after testing.
    container = Path(read(['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data']))
    generated = container / 'Documents/activity-captures'
    missing = []
    for name in ['app-events.json', 'payload-checks.json']:
        source = generated / name
        if source.is_file():
            shutil.copy2(source, output / name)
        else:
            missing.append(name)
    return missing


def capture_system_accessibility(run, device, base, results, report):
    """Use the installed simctl interface, verify its value, then restore it."""
    target = 'accessibility-extra-large'
    report.update(target=target, status='checking support', restoration='not needed')
    help_result = run(['xcrun', 'simctl', 'help', 'ui'], timeout=15, check=False)
    if help_result.returncode or 'content_size' not in help_result.stdout or target not in help_result.stdout:
        report.update(status='skipped', reason='Installed simctl help does not advertise content_size accessibility-extra-large',
                      help_exit_code=help_result.returncode)
        return
    categories = {'extra-small', 'small', 'medium', 'large', 'extra-large', 'extra-extra-large',
                  'extra-extra-extra-large', 'accessibility-medium', 'accessibility-large', target,
                  'accessibility-extra-extra-large', 'accessibility-extra-extra-extra-large'}
    command = ['xcrun', 'simctl', 'ui', device, 'content_size']
    previous = run(command, timeout=15).stdout.strip()
    report['previous'] = previous
    if previous not in categories:
        report['status'] = 'failed'
        raise RuntimeError('Unrecognized simctl content_size readback; system setting was not changed')
    primary_error = None
    try:
        report['restoration'] = 'required'
        run([*command, target], timeout=15)
        report['readback'] = run(command, timeout=15).stdout.strip()
        if report['readback'] != target:
            raise RuntimeError('Simulator system accessibility size readback mismatch')
        result = run([*base, '-resultBundlePath', str(results), '-parallel-testing-enabled', 'NO',
                      '-only-testing:ActivityCaptureTests/CaptureTests/testSystemAccessibilityStates',
                      'test-without-building'], timeout=600, check=False)
        report['ui_test_exit_code'] = result.returncode
        if result.returncode:
            raise RuntimeError(f'System accessibility UI test exited {result.returncode}; see commands.log')
        report['status'] = 'passed; inspect system screenshots for fit'
    except Exception as error:
        primary_error = error
        report.update(status='failed', error=str(error))
        raise
    finally:
        try:
            run([*command, previous], timeout=15)
            report['restored_readback'] = run(command, timeout=15).stdout.strip()
            if report['restored_readback'] != previous:
                raise RuntimeError('Simulator system text size restoration readback mismatch')
            report['restoration'] = 'verified'
        except Exception as error:
            report.update(restoration='failed', restoration_error=str(error))
            if primary_error is None:
                report['status'] = 'failed'
                raise


def export_system_captures(run, results, system, output, manifest, clean):
    """Retain original screenshots even when XCTest returns a failure."""
    errors = []
    try:
        run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(results), '--output-path', str(system)])
    except Exception as error:
        errors.append(clean(str(error)))
    labels = {}
    for file in system.rglob('*.json'):
        try:
            labels.update(attachment_labels(json.loads(file.read_text())))
        except Exception as error:
            errors.append(f'{file.name}: {clean(str(error))}')
    for file in sorted(system.rglob('*.png')):
        name = labels.get(file.name, file.name)
        try:
            dimensions = png_dimensions(file)
        except Exception as error:
            errors.append(f'{file.name}: {clean(str(error))}')
            continue
        manifest['system'].append({'file': str(file.relative_to(output)), 'requested_capture': name,
            'evidence': 'actual simulator screenshot; requested surface, not proof of visible Activity',
            'dimensions': dimensions})
        system_surface = re.search(r'-(?:island-expanded-attempt|notification-center-lock-style-attempt)(?:_|\.|$)', name)
        if any(tag in name for tag in ['preparing-', 'downloading-', 'completed-notification', 'failed-app', 'cancelled-app']) or (
                system_surface and any(tag in name for tag in ['failed-', 'foreground-', 'long-title-', 'large-text-'])):
            slug = re.sub(r'[^a-zA-Z0-9._-]', '-', name)[:100]
            try:
                run(['sips', '-Z', '1100', str(file), '--out', str(output / 'preview' / (slug + '.png'))])
            except Exception as error:
                errors.append(clean(str(error)))
    return errors


def write_checksums(output):
    files = sorted(p for p in output.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
    (output / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(output)}\n' for p in files))


def failure_evidence(device, output, clean, log, since):
    """Best-effort evidence before deletion; never retry launch or replace its error."""
    folder = output / 'diagnostics'
    folder.mkdir(exist_ok=True)
    deadline = time.monotonic() + 75
    records = []
    device_data = Path.home() / 'Library/Developer/CoreSimulator/Devices' / device / 'data'
    def attempt(name, argv, timeout):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            records.append({'name': name, 'status': 'skipped; diagnostic deadline'})
            return ''
        record = {'name': name, 'command': clean(repr(argv))}
        raw = folder / (name + '.raw')
        try:
            with raw.open('w') as stream:
                result = subprocess.run(argv, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                    text=True, timeout=min(timeout, remaining), check=False)
            record.update(status='returned', exit_code=result.returncode)
        except Exception as error:
            record.update(status='failed', error=clean(str(error)))
        finally:
            size = raw.stat().st_size if raw.exists() else 0
            with raw.open('rb') if raw.exists() else open('/dev/null', 'rb') as stream:
                stream.seek(max(0, size - 262_144)); data = stream.read(262_144)
            raw.unlink(missing_ok=True)
        text = clean(data[-262_144:].decode(errors='replace'))
        if name == 'processes':
            text = '\n'.join(line for line in text.splitlines() if re.search(
                r'ActivityDemo|SteamDownloadWidget|CoreSimulatorService|launchd_sim|SpringBoard|backboardd|runningboardd|installd|simctl', line))
        encoded = text.encode()
        text = encoded[-262_144:].decode(errors='ignore')
        (folder / (name + '.log')).write_text(text)
        record.update(output_bytes=size, truncated=size > 262_144 or len(encoded) > 262_144)
        records.append(record)
        log.write('$ diagnostic ' + json.dumps(record) + '\n'); log.flush()
        return data.decode(errors='replace') if record.get('exit_code') == 0 else ''
    processes = attempt('processes', ['ps', '-axo', 'pid,ppid,etime,stat,pcpu,comm'], 5)
    for line in processes.splitlines():
        if str(device_data) in line and '.app/ActivityDemo' in line and line.split()[0].isdigit():
            attempt('app-sample', ['sample', line.split()[0], '2', '10'], 8)
            break
    container = attempt('container', ['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data'], 8).strip()
    copied = []; copy_errors = []; image_bytes = 0
    if container:
        try:
            generated = Path(container).resolve() / 'Documents/activity-captures'
            if not generated.is_relative_to(device_data.resolve()):
                raise ValueError('Diagnostic container is outside the disposable simulator')
            for relative in ['startup-progress.json', 'payload-checks.json', 'app-events.json',
                             'components/manifest.json', *[str(p.relative_to(generated)) for kind in ['components', 'preview']
                                 for p in sorted((generated / kind).glob('*.png'))]][:86]:
                source = generated / relative
                if not source.is_file() or source.is_symlink():
                    continue
                if not source.resolve().is_relative_to(generated):
                    raise ValueError('Diagnostic app file is outside its capture directory')
                target = folder / 'app' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.suffix == '.png':
                    size = source.stat().st_size
                    if image_bytes + size > 8 * 1024 * 1024:
                        copy_errors.append(relative + ': exceeds 8 MiB diagnostic PNG budget'); continue
                    shutil.copyfile(source, target); image_bytes += size
                else:
                    with source.open('rb') as stream: data = stream.read(262_144)
                    target.write_text(clean(data[:262_144].decode(errors='replace')))
                    if source.stat().st_size > 262_144: copy_errors.append(relative + ': truncated at 256 KiB')
                copied.append(relative)
        except Exception as error:
            copy_errors.append(clean(str(error)))
    attempt('failure-screen', ['xcrun', 'simctl', 'io', device, 'screenshot', str(folder / 'failure-screen.png')], 8)
    predicate = 'process IN {"ActivityDemo", "SteamDownloadWidget", "SpringBoard", "runningboardd", "backboardd", "installd"}'
    attempt('simulator-log', ['xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '3m',
                            '--style', 'compact', '--predicate', predicate], 15)
    attempt('services', ['xcrun', 'simctl', 'spawn', device, 'launchctl', 'print', 'system'], 8)
    attempt('host-log', ['log', 'show', '--last', '3m', '--style', 'compact', '--predicate',
        f'process == "CoreSimulatorService" AND (eventMessage CONTAINS "{device}" OR eventMessage CONTAINS "{BUNDLE}")'], 10)
    attempt('launch-help', ['xcrun', 'simctl', 'help', 'launch'], 5)
    crashes = []
    for directory in [Path.home() / 'Library/Logs/DiagnosticReports', device_data / 'Library/Logs/CrashReporter']:
        for source in sorted(directory.glob('*')):
            if len(crashes) >= 8 or time.monotonic() >= deadline: break
            if source.is_symlink() or not source.is_file() or not source.name.startswith(('ActivityDemo', 'SteamDownloadWidget')):
                continue
            if source.stat().st_mtime < since: continue
            with source.open('rb') as stream: data = stream.read(524_288)
            (folder / f'crash-{len(crashes)}.log').write_text(clean(data[:524_288].decode(errors='replace')))
            size = source.stat().st_size
            crashes.append({'file': clean(source.name), 'bytes': size, 'truncated': size > 524_288})
    (folder / 'manifest.json').write_text(json.dumps({'commands': records, 'app_files': copied,
        'copy_errors': copy_errors, 'crashes': crashes, 'limit_seconds': 75,
        'evidence': 'failure diagnostics only; screenshots require pixel inspection'}, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Requires the macOS Actions runner and an installed iOS Simulator SDK/runtime')
    upstream, output = args.upstream.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = ROOT / '.build/activity-capture'
    device = None
    started = time.time()
    environment = {'evidence': 'synthetic production component renders and actual simulator system attempts',
                   'iridium_commit': REFERENCE, 'source_sha256': SOURCES, 'architecture': platform.machine()}
    manifest = {'synthetic_data': True, 'status': 'running', 'components': [], 'system': [],
                'limitations': ['Notification Center is not a locked-device authentication test.',
                    'Home/expanded screenshots are requested surfaces; inspect pixels to confirm presentation.',
                    'Terminal states may disappear from Dynamic Island under the real production end policy.',
                    'Normal-pass large-text override is app/component-only; the separate system accessibility pass is support-gated.',
                    'Long-title system request uses the production 80-character title limit.',
                    'No Steam engine, login, network download, physical device or private signing credentials.']}
    def persist():
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        (output / 'environment.json').write_text(json.dumps(environment, indent=2) + '\n')
    persist()
    with (output / 'commands.log').open('w') as log:
        def clean(text):
            text = text.replace(str(ROOT), '<workspace>')
            text = text.replace(str(Path.home()), '<runner-home>')
            return re.sub(r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b', '<simulator>', text)
        def run(argv, timeout=60, check=True):
            log.write('$ ' + clean(repr([str(item) for item in argv])) + '\n'); log.flush()
            try:
                result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, timeout=timeout, check=False)
            except subprocess.TimeoutExpired as error:
                captured = error.stdout or ''
                log.write(clean(captured.decode(errors='replace') if isinstance(captured, bytes) else captured))
                log.write(f'\nTimeout after {timeout} seconds.\n'); log.flush()
                raise RuntimeError(f'Command timed out after {timeout}s: {clean(repr(argv))}') from None
            log.write(clean(result.stdout) + '\n'); log.flush()
            if check and result.returncode:
                raise RuntimeError(f'Command exited {result.returncode}: {clean(repr(argv))}; see commands.log')
            return result
        def read(argv):
            return run(argv).stdout.strip()
        try:
            if read(['git', '-C', str(upstream), 'rev-parse', 'HEAD']) != REFERENCE:
                raise RuntimeError('Upstream checkout is not the pinned production commit')
            spec, _ = load_spec()
            verify_hashes(upstream, spec, 'after')
            identity = json.loads((ROOT / '.design-identity.json').read_text())
            if identity != dict(spec, verified=True):
                raise RuntimeError('Reviewed design application receipt mismatch')
            (output / 'design-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
            environment.update(design_patch_sha256=spec['patch_sha256'], iridium_tree=spec['patched_tree'])
            environment.update(testing_commit=read(['git', 'rev-parse', 'HEAD']),
                               xcode=read(['xcodebuild', '-version']), swift=read(['xcrun', 'swiftc', '--version']),
                               macos=read(['sw_vers', '-productVersion']),
                               simulator_sdk=read(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version']))
            project = generate(ROOT, upstream, build / 'generated')
            inventory = json.loads(read(['xcrun', 'simctl', 'list', '--json']))
            runtimes = [r for r in inventory['runtimes'] if r.get('isAvailable') and '.iOS-' in r['identifier']
                        and int(r['version'].split('.')[0]) >= 18]
            if not runtimes:
                raise RuntimeError('No installed iOS 18+ runtime; no installation is attempted')
            runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
            models = [m for m in runtime['supportedDeviceTypes'] if m['productFamily'] == 'iPhone']
            island = [m for m in models if re.search(r'iPhone (?:1[4-9]|[2-9]\d).*Pro', m.get('name', ''))]
            if not island:
                raise RuntimeError('No installed Dynamic Island iPhone model is supported by this runtime')
            model = max(island, key=lambda m: (int(re.search(r'iPhone (\d+)', m['name'])[1]), 'Max' not in m['name']))
            environment.update(simulator_os=runtime['version'], simulator_model=model['name'],
                               signature_policy='Simulator ad-hoc signing only; no team or personal certificate')
            persist()
            device = read(['xcrun', 'simctl', 'create', 'Synthetic Iridium Activity', model['identifier'], runtime['identifier']])
            run(['xcrun', 'simctl', 'boot', device])
            run(['xcrun', 'simctl', 'bootstatus', device, '-b'], timeout=180)
            run(['xcrun', 'simctl', 'ui', device, 'appearance', 'dark'])
            base = ['xcodebuild', '-project', str(project), '-scheme', 'ActivityDemo', '-configuration', 'Debug',
                    '-sdk', 'iphonesimulator', '-destination', f'id={device}', '-derivedDataPath', str(build / 'DerivedData'),
                    'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'PROVISIONING_PROFILE_SPECIFIER=']
            run([*base, 'build-for-testing'], timeout=240)
            # Preserve usable component images before attempting system UI tests.
            app = build / 'DerivedData/Build/Products/Debug-iphonesimulator/ActivityDemo.app'
            install_started = time.monotonic()
            run(['xcrun', 'simctl', 'install', device, str(app)], timeout=180)
            log.write(f'Simulator install completed in {time.monotonic() - install_started:.1f}s.\n'); log.flush()
            run(['xcrun', 'simctl', 'launch', device, BUNDLE])
            container = Path(read(['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data']))
            generated = container / 'Documents/activity-captures'
            deadline = time.monotonic() + 90
            while not (generated / 'components/manifest.json').is_file():
                if time.monotonic() >= deadline:
                    raise RuntimeError('Native component renderer did not finish within 90 seconds')
                time.sleep(1)
            for name in ['components', 'preview']:
                shutil.copytree(generated / name, output / name)
            components = json.loads((output / 'components/manifest.json').read_text())
            if len(components) != 78 or len({r['file'] for r in components}) != 78:
                raise RuntimeError('Expected 78 distinct production component PNGs')
            for record in components:
                name = record['file']
                if Path(name).name != name:
                    raise RuntimeError('Component manifest path is not a filename')
                if png_dimensions(output / 'components' / name) != (record['widthPixels'], record['heightPixels']):
                    raise RuntimeError('Component PNG dimensions do not match manifest')
            manifest['components'] = components
            persist()
            results = build / 'Capture.xcresult'
            test_error = None
            try:
                result = run([*base, '-resultBundlePath', str(results), '-parallel-testing-enabled', 'NO',
                              '-only-testing:ActivityCaptureTests/CaptureTests/testSyntheticStates',
                              'test-without-building'], timeout=600, check=False)
                manifest['ui_test_exit_code'] = result.returncode
                if result.returncode:
                    test_error = f'Native UI test exited {result.returncode}; see commands.log'
            except Exception as error:
                test_error = clean(str(error))
            manifest['ui_test_error'] = test_error
            system = output / 'system'
            export_errors = export_system_captures(run, results, system, output, manifest, clean)
            try:
                manifest['missing_app_records'] = collect_app_records(read, device, output)
            except Exception as error:
                manifest['missing_app_records'] = ['app-events.json', 'payload-checks.json']
                export_errors.append(clean(str(error)))
            manifest['export_errors'] = export_errors
            if test_error:
                raise RuntimeError(test_error)
            if export_errors or manifest['missing_app_records']:
                raise RuntimeError('Capture export incomplete; see export_errors and missing_app_records in manifest.json')
            payload = json.loads((output / 'payload-checks.json').read_text())
            if payload.get('status') != 'passed':
                raise RuntimeError(f'Native payload checks failed: {payload.get("error", "missing passed status")}')
            if not manifest['system']:
                raise RuntimeError('Native UI tests exported no system screenshots')
            accessibility = manifest['system_accessibility'] = {}
            ax_results = build / 'AccessibilityCapture.xcresult'
            ax_error = None
            try:
                capture_system_accessibility(run, device, base, ax_results, accessibility)
            except Exception as error:
                ax_error = clean(str(error))
            if accessibility.get('restoration') in ['verified', 'failed']:
                ax_system = system / 'accessibility'
                before = len(manifest['system'])
                accessibility['export_errors'] = export_system_captures(run, ax_results, ax_system, output, manifest, clean)
                ax_system.mkdir(parents=True, exist_ok=True)
                try:
                    accessibility['missing_app_records'] = collect_app_records(read, device, ax_system)
                except Exception as error:
                    accessibility['missing_app_records'] = ['app-events.json', 'payload-checks.json']
                    accessibility['export_errors'].append(clean(str(error)))
                accessibility['screenshot_count'] = len(manifest['system']) - before
                if ax_error:
                    raise RuntimeError(ax_error)
                if accessibility['export_errors'] or accessibility['missing_app_records']:
                    raise RuntimeError('System accessibility capture export incomplete; see manifest.json')
                if not accessibility['screenshot_count']:
                    raise RuntimeError('System accessibility UI test exported no screenshots')
                ax_payload = json.loads((ax_system / 'payload-checks.json').read_text())
                if ax_payload.get('status') != 'passed':
                    raise RuntimeError(f'System accessibility payload checks failed: {ax_payload.get("error", "missing passed status")}')
            elif ax_error:
                raise RuntimeError(ax_error)
            if sum(p.stat().st_size for p in (output / 'preview').iterdir()) > 20 * 1024 * 1024:
                raise RuntimeError('Preview PNGs exceed the 20 MiB retrieval budget')
            manifest['status'] = 'completed; system visibility requires pixel inspection'
            persist()
        except Exception as error:
            manifest['status'] = 'failed'
            manifest['error'] = clean(str(error))
            if device:
                try:
                    failure_evidence(device, output, clean, log, started)
                except Exception as diagnostic_error:
                    manifest['diagnostic_error'] = clean(str(diagnostic_error))
            persist()
            raise
        finally:
            primary_error = sys.exc_info()[0] is not None
            cleanup_errors = []
            if device:
                for action in ['shutdown', 'delete']:
                    try:
                        run(['xcrun', 'simctl', action, device])
                    except Exception as error:
                        cleanup_errors.append(clean(str(error)))
            manifest['cleanup_errors'] = cleanup_errors
            if cleanup_errors and not primary_error:
                manifest['status'] = 'failed'
                manifest['error'] = 'Disposable simulator cleanup failed'
            persist()
            log.flush()
            write_checksums(output)
            if cleanup_errors and not primary_error:
                raise RuntimeError('Disposable simulator cleanup failed')
    print('Saved 78 component PNGs, contact sheets and native system screenshot attempts. Inspect manifest and pixels.')


if __name__ == '__main__':
    main()
