# SPDX-License-Identifier: AGPL-3.0-only
import hashlib
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


if __name__ == '__main__':
    unittest.main()
