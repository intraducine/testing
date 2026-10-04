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
    environment = {'evidence': 'synthetic production component renders and actual simulator system attempts',
                   'iridium_commit': REFERENCE, 'source_sha256': SOURCES, 'architecture': platform.machine()}
    manifest = {'synthetic_data': True, 'status': 'running', 'components': [], 'system': [],
                'limitations': ['Notification Center is not a locked-device authentication test.',
                    'Home/expanded screenshots are requested surfaces; inspect pixels to confirm presentation.',
                    'Terminal states may disappear from Dynamic Island under the real production end policy.',
                    'Large-text override is app/component-only; system Dynamic Type remains unchanged.',
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
            run(['xcrun', 'simctl', 'install', device, str(app)])
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
            results = build / 'Capture.xcresult'
            run([*base, '-resultBundlePath', str(results), '-parallel-testing-enabled', 'NO',
                 '-test-iterations', '1', 'test-without-building'], timeout=600)
            system = output / 'system'
            run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(results), '--output-path', str(system)])
            shutil.copy2(generated / 'app-events.json', output / 'app-events.json')
            components = json.loads((output / 'components/manifest.json').read_text())
            if len(components) != 66 or len({r['file'] for r in components}) != 66:
                raise RuntimeError('Expected 66 distinct production component PNGs')
            for record in components:
                name = record['file']
                if Path(name).name != name:
                    raise RuntimeError('Component manifest path is not a filename')
                if png_dimensions(output / 'components' / name) != (record['widthPixels'], record['heightPixels']):
                    raise RuntimeError('Component PNG dimensions do not match manifest')
            manifest['components'] = components
            labels = {}
            for file in system.rglob('*.json'):
                labels.update(attachment_labels(json.loads(file.read_text())))
            for file in sorted(system.rglob('*.png')):
                name = labels.get(file.name, file.name)
                manifest['system'].append({'file':str(file.relative_to(output)), 'requested_capture':name,
                    'evidence':'actual simulator screenshot; requested surface, not proof of visible Activity',
                    'dimensions':png_dimensions(file)})
                if any(tag in name for tag in ['downloading-', 'completed-notification', 'failed-app', 'cancelled-app']):
                    slug = re.sub(r'[^a-zA-Z0-9._-]', '-', name)[:100]
                    run(['sips', '-Z', '1100', str(file), '--out', str(output / 'preview' / (slug + '.png'))])
            if not manifest['system']:
                raise RuntimeError('Native UI tests exported no system screenshots')
            manifest['status'] = 'completed; system visibility requires pixel inspection'
            persist()
        except Exception as error:
            manifest['status'] = 'failed'
            manifest['error'] = clean(str(error))
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
            persist()
            if cleanup_errors and not primary_error:
                raise RuntimeError('Disposable simulator cleanup failed')
    files = sorted(p for p in output.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
    (output / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(output)}\n' for p in files))
    if sum(p.stat().st_size for p in (output / 'preview').iterdir()) > 20 * 1024 * 1024:
        raise RuntimeError('Preview PNGs exceed the 20 MiB retrieval budget')
    print('Saved 66 component PNGs, contact sheets and native system screenshot attempts. Inspect manifest and pixels.')


if __name__ == '__main__':
    main()
