import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import build as vendor


class VendorTests(unittest.TestCase):
    def setUp(self):
        cache = vendor.ROOT / ".cache"
        cache.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=cache, prefix="test-")
        self.addCleanup(self.temporary.cleanup)
        project = Path(self.temporary.name)
        self.root = project / "devtools"
        self.source = self.root / vendor.FRONTEND
        self.source.mkdir(parents=True)
        self.files = {
            "inspector.html": b'<link href="design_system_tokens.css" rel="stylesheet">',
            "design_system_tokens.css": b":root { --sys-color-surface: white; }",
            "third_party/codemirror.next/editor.js": b"export const editor = true;",
        }
        manifest = '<grit><includes><include file="${protocol_file}" />' + ''.join(
            f'<include resource_path="{name}" file="{name}.compressed" />' for name in self.files
        ) + '</includes></grit>'
        (self.source / "devtools_resources.grd").write_text(manifest)
        for name, contents in self.files.items():
            destination = self.source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(contents)
        (self.source / "debug.test.js").write_text("This must not ship")
        (self.root / "theme.css").write_text(":root { --sys-color-surface: #0d1117; }")
        (self.root / "LICENSE").write_text("Chromium license")
        (self.root / "theme-source").mkdir()
        (self.root / "theme-source/LICENSE.txt").write_text("GitHub theme license")
        self.lock = {
            "chromiumMajor": 153, "snapshot": "test", "url": "https://invalid.test/never-download.zip",
            "resourcesSha256": vendor.fingerprint(sorted(self.files), self.files.__getitem__),
        }
        self.write_lock()
        sources = project / "macos/Sources/macos/Resources/sources.json"
        sources.parent.mkdir(parents=True)
        sources.write_text(json.dumps({"helium": {"chromiumVersion": "153.0.8010.52"}}))
        root_patch = patch.object(vendor, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.destination = project / "output"

    def write_lock(self):
        (self.root / "DevTools.lock").write_text(json.dumps(self.lock))

    def test_offline_build_changes_only_theme_and_removes_stale_output(self):
        self.destination.mkdir()
        (self.destination / "stale.js").write_text("old build")
        with patch("urllib.request.urlopen", side_effect=AssertionError("Unexpected network request")):
            vendor.build(self.destination)
            vendor.build(self.destination)
        for name, contents in self.files.items():
            staged = (self.destination / name).read_bytes()
            if name == "design_system_tokens.css":
                self.assertEqual(staged, contents + b"\n" + (self.root / "theme.css").read_bytes())
            else:
                self.assertEqual(staged, contents)
            self.assertEqual((self.source / name).read_bytes(), contents)
        self.assertFalse((self.destination / "stale.js").exists())
        self.assertFalse((self.destination / "debug.test.js").exists())
        self.assertEqual((self.destination / "GitHub-Theme-LICENSE.txt").read_text(), "GitHub theme license")

    def test_modified_payload_is_rejected_before_staging(self):
        (self.source / "inspector.html").write_text("modified")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            vendor.build(self.destination)
        self.assertFalse(self.destination.exists())

    def test_wrong_chromium_major_is_rejected(self):
        self.lock["chromiumMajor"] = 154
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "Chromium major"):
            vendor.build(self.destination)

    def test_local_zip_uses_same_verification_and_assets(self):
        with zipfile.ZipFile(self.root / "devtools-frontend.zip", "w") as archive:
            for path in self.source.rglob("*"):
                if path.is_file():
                    archive.write(path, str(vendor.FRONTEND / path.relative_to(self.source)))
        # Make the automatic extracted path unavailable without deleting input.
        self.source.rename(self.source.with_name("saved-source"))
        with patch("urllib.request.urlopen", side_effect=AssertionError("Unexpected network request")):
            vendor.build(self.destination)
        self.assertEqual((self.destination / "inspector.html").read_bytes(), self.files["inspector.html"])

    def test_manifest_rejects_traversal_and_duplicate_resources(self):
        for name in ("../secret.js", "/secret.js", "a/./b.js", "a//b.js", "a\\b.js"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                vendor.resource_paths(f'<grit><include resource_path="{name}" /></grit>')
        with self.assertRaises(ValueError):
            vendor.resource_paths('<grit><include resource_path="a.js"/><include resource_path="a.js"/></grit>')


if __name__ == "__main__":
    unittest.main()
