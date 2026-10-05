# SPDX-License-Identifier: AGPL-3.0-only
import hashlib
import gzip
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

import capture
import project
import apply_design


class HarnessTests(unittest.TestCase):
    def test_pinned_sources_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            upstream = Path(folder)
            for name in project.SOURCES:
                p = upstream / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Pinned production source mismatch'):
                project.verify_sources(upstream)

    def test_native_target_boundaries_and_embedding(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.object(project, 'verify_sources'):
                generated = project.generate(root, root / 'upstream', root / 'generated')
            text = (generated / 'project.pbxproj').read_text()
            self.assertIn('IRIDIUM_APP IRIDIUM_ACTIVITY_RENDERING', text)
            self.assertIn('com.apple.product-type.app-extension', text)
            self.assertIn('com.apple.product-type.bundle.ui-testing', text)
            self.assertIn('Embed App Extensions', text)
            self.assertNotIn('SteamEngine.cs', text)
            app = plistlib.loads((root / 'generated/ActivityDemo-Info.plist').read_bytes())
            widget = plistlib.loads((root / 'generated/SteamDownloadWidget-Info.plist').read_bytes())
            self.assertTrue(app['NSSupportsLiveActivities'])
            self.assertEqual(widget['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.widgetkit-extension')
            scheme = ET.parse(generated / 'xcshareddata/xcschemes/ActivityDemo.xcscheme')
            self.assertEqual(len(scheme.findall('.//TestableReference')), 1)

    def test_linux_guard_creates_no_output_or_native_process(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'output'
            with patch.object(sys, 'argv', ['capture.py', '--upstream', folder, '--output', str(output)]), \
                 patch.object(capture.platform, 'system', return_value='Linux'), \
                 patch.object(capture.subprocess, 'run') as native:
                with self.assertRaises(SystemExit) as result:
                    capture.main()
            self.assertEqual(result.exception.code, 2)
            self.assertFalse(output.exists())
            native.assert_not_called()

    def test_png_header_and_dimensions(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'sample.png'
            p.write_bytes(b'\x89PNG\r\n\x1a\n' + b'\x00\x00\x00\rIHDR' + struct.pack('>II', 640, 320))
            self.assertEqual(capture.png_dimensions(p), (640, 320))
            p.write_bytes(b'not a PNG')
            with self.assertRaises(ValueError): capture.png_dimensions(p)

    def test_export_attachment_names_are_preserved(self):
        data = [{'attachments':[{'exportedFileName':'uuid.png', 'suggestedHumanReadableName':'downloading-home-compact-attempt'}]}]
        self.assertEqual(capture.attachment_labels(data), {'uuid.png':'downloading-home-compact-attempt'})
        self.assertEqual(capture.attachment_labels({'unrelated':'not a surface'}), {})

    def test_reviewed_manifest_and_patch_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'fixtures').mkdir()
            for name in ['activity-design.json', 'activity-design.patch.gz']:
                (root / 'fixtures' / name).write_bytes((apply_design.ROOT / 'fixtures' / name).read_bytes())
            spec, patch_data = apply_design.load_spec(root)
            self.assertEqual(spec['base_commit'], project.REFERENCE)
            (root / 'fixtures/activity-design.patch.gz').write_bytes(gzip.compress(patch_data + b'changed', mtime=0))
            with self.assertRaisesRegex(ValueError, 'patch digest mismatch'):
                apply_design.load_spec(root)
            manifest = root / 'fixtures/activity-design.json'
            manifest.write_bytes(manifest.read_bytes() + b' ')
            with self.assertRaisesRegex(ValueError, 'manifest digest mismatch'):
                apply_design.load_spec(root)

    def test_design_after_hashes_reject_modified_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); (root / 'source').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'after source mismatch'):
                apply_design.verify_hashes(root, {'files': {'source': {'after': hashlib.sha256(b'reviewed').hexdigest()}}}, 'after')

    def test_failed_ui_test_exports_partial_images_from_current_container(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); output = root / 'output'
            old = root / 'old/Documents/activity-captures'
            current = root / 'current/Documents/activity-captures'
            (old / 'components').mkdir(parents=True); (old / 'preview').mkdir()
            current.mkdir(parents=True)
            (old / 'app-events.json').write_text('old container must not be used')
            (current / 'payload-checks.json').write_text('{"status":"passed"}')
            png = b'\x89PNG\r\n\x1a\n' + b'\x00\x00\x00\rIHDR' + struct.pack('>II', 640, 320)
            records = []
            for i in range(78):
                name = f'{i}.png'; (old / 'components' / name).write_bytes(png)
                records.append({'file': name, 'widthPixels': 640, 'heightPixels': 320})
            (old / 'components/manifest.json').write_text(json.dumps(records))
            (old / 'preview/components.png').write_bytes(png)
            spec = {'patch_sha256': 'reviewed', 'patched_tree': 'reviewed-tree'}
            (root / '.design-identity.json').write_text(json.dumps(dict(spec, verified=True)))
            commands = []; containers = iter([root / 'old', root / 'current'])
            def native(argv, **kwargs):
                commands.append(argv)
                text = ''; code = 0
                if argv[0] == 'git': text = project.REFERENCE
                elif argv[:4] == ['xcrun', 'simctl', 'list', '--json']:
                    text = json.dumps({'runtimes': [{'isAvailable': True, 'identifier': 'com.apple.iOS-18-0',
                        'version': '18.0', 'supportedDeviceTypes': [{'productFamily': 'iPhone', 'name': 'iPhone 17 Pro', 'identifier': 'iPhone17Pro'}]}]})
                elif argv[:3] == ['xcrun', 'simctl', 'create']: text = 'disposable-device'
                elif argv[:3] == ['xcrun', 'simctl', 'get_app_container']: text = str(next(containers))
                elif 'test-without-building' in argv: code = 65; text = 'Exact synthetic XCTest failure'
                elif argv[:4] == ['xcrun', 'xcresulttool', 'export', 'attachments']:
                    system = Path(argv[-1]); system.mkdir()
                    (system / 'native.png').write_bytes(png)
                    (system / 'attachments.json').write_text(json.dumps([{'attachments': [{
                        'exportedFileName': 'native.png', 'suggestedHumanReadableName': 'downloading-home-compact-attempt'}]}]))
                elif argv[0] == 'sips': Path(argv[-1]).write_bytes(png)
                return subprocess.CompletedProcess(argv, code, text)
            with patch.object(sys, 'argv', ['capture.py', '--upstream', str(root), '--output', str(output)]), \
                 patch.object(capture, 'ROOT', root), patch.object(capture.platform, 'system', return_value='Darwin'), \
                 patch.object(capture, 'load_spec', return_value=(spec, None)), \
                 patch.object(capture, 'verify_hashes'), patch.object(capture, 'generate', return_value=root / 'generated.xcodeproj'), \
                 patch.object(capture.subprocess, 'run', side_effect=native):
                with self.assertRaisesRegex(RuntimeError, 'Native UI test exited 65'):
                    capture.main()
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(manifest['status'], 'failed')
            self.assertEqual(manifest['ui_test_exit_code'], 65)
            self.assertEqual(len(manifest['components']), 78)
            self.assertEqual(len(manifest['system']), 1)
            self.assertEqual(manifest['missing_app_records'], ['app-events.json'])
            self.assertFalse((output / 'app-events.json').exists())
            self.assertTrue((output / 'payload-checks.json').is_file())
            self.assertTrue((output / 'preview/downloading-home-compact-attempt.png').is_file())
            self.assertIn('Exact synthetic XCTest failure', (output / 'commands.log').read_text())
            self.assertTrue(any(cmd[:3] == ['xcrun', 'simctl', 'shutdown'] for cmd in commands))
            self.assertTrue(any(cmd[:3] == ['xcrun', 'simctl', 'delete'] for cmd in commands))
            for line in (output / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest, name)


if __name__ == '__main__':
    unittest.main()
