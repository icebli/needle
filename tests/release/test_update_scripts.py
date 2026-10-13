"""Release guards run with synthetic tools; no signing keys or network needed."""
import os
import plistlib
import stat
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UpdateScriptTests(unittest.TestCase):
    def test_build_numbers_increase_across_version_boundaries(self):
        source = (ROOT / 'scripts/build-desktop.sh').read_text()
        prefix = source.split('cargo build --manifest-path', 1)[0]
        values = []
        for version in ['0.2.4', '0.2.10', '0.3.0', '1.0.0']:
            env = dict(os.environ, NEEDLE_APP_VERSION=version)
            env.pop('NEEDLE_BUILD_NUMBER', None)
            result = subprocess.run(['bash', '-c', prefix + '\nprintf "%s" "$BUILD_NUMBER"', str(ROOT / 'scripts/build-desktop.sh')],
                                    env=env, capture_output=True, text=True, check=True)
            values.append(int(result.stdout))
        self.assertEqual(values, [2004, 2010, 3000, 1000000])

    def test_invalid_versions_and_build_overrides_fail_before_build(self):
        prefix = (ROOT / 'scripts/build-desktop.sh').read_text().split('cargo build --manifest-path', 1)[0]
        for version, build in [('0.1000.0', ''), ('next', ''), ('0.2.4', '0'), ('0.2.4', 'bad')]:
            env = dict(os.environ, NEEDLE_APP_VERSION=version, NEEDLE_BUILD_NUMBER=build)
            result = subprocess.run(['bash', '-c', prefix, str(ROOT / 'scripts/build-desktop.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)

    def test_packager_uses_shared_build_number_policy(self):
        source = (ROOT / "scripts/package-desktop.sh").read_text()
        self.assertNotIn("NEEDLE_BUILD_NUMBER=", source)
        self.assertIn("--preview-updates", source)
        self.assertIn("SUPublicEDKey", source)
        self.assertIn("requires the ad-hoc signing identity", source)

    def test_unsigned_preview_does_not_weaken_production_appcast_gates(self):
        source = (ROOT / "scripts/update-appcast.sh").read_text()
        self.assertIn('if [[ "$PREVIEW" == 1 ]]; then', source)
        self.assertIn("codesign --verify --deep --strict", source)
        self.assertIn("Authority=Developer ID Application:", source)
        self.assertIn("xcrun stapler validate", source)
        self.assertIn("spctl --assess", source)
        self.assertIn('"{%s}edSignature"', source)
        self.assertIn("hdiutil attach -plist", source)
        self.assertIn("plistlib.loads", source)
        self.assertIn("SUVerifyUpdateBeforeExtraction", source)

    def test_source_capture_records_exact_build_inputs(self):
        source = (ROOT / "scripts/collect-third-party-sources.sh").read_text()
        self.assertIn("homebrew-ffmpeg.json", source)
        self.assertIn("THIRD_PARTY_SOURCE_MANIFEST.json", source)
        self.assertIn("corresponding_source_status", source)
        self.assertIn("source-archive-checksum-required", source)
        self.assertIn("--download-sources", source)
        self.assertIn("THIRD_PARTY_LICENSES.txt", source)
        self.assertIn("resolved-copyleft-dependencies", source)
        self.assertIn("download_pypi", source)
        self.assertIn("version_evidence", source)
        self.assertIn("bundled_library_owners", source)
        self.assertIn("published checksum missing", source)
        self.assertIn("pinned-git-commit-archive", source)
        self.assertIn("missing Homebrew source checksum and git revision", source)
        self.assertIn("unowned bundled Homebrew libraries", source)
        self.assertIn("Homebrew version mismatch", source)
        self.assertIn("pinned-release-tag-and-package-resolved-revision", source)

    def test_wrong_or_mixed_archives_never_reach_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / 'sparkle/bin'
            tools.mkdir(parents=True)
            generator = tools / 'generate_appcast'
            generator.write_text('#!/bin/bash\nexit 99\n')
            generator.chmod(0o755)
            archives = root / 'archives'
            archives.mkdir()
            for names in [[], ['Needle-0.2.3.dmg'], ['Needle-0.2.4.dmg', 'Needle-0.2.3.dmg']]:
                for item in archives.iterdir():
                    item.unlink()
                for name in names:
                    (archives / name).touch()
                result = subprocess.run(['bash', str(ROOT / 'scripts/update-appcast.sh'),
                                         str(archives), '0.2.4'],
                                        env=dict(os.environ, SPARKLE_ROOT=str(root / 'sparkle')),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn('containing only Needle-0.2.4.dmg', result.stderr)

    def test_preview_appcast_validates_ad_hoc_bundle_with_spaces_in_mount_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            mount = root / 'Needle Preview Volume'
            app = mount / 'Needle.app'
            (app / 'Contents').mkdir(parents=True)
            key = ''.join((ROOT / 'desktop/Resources/UpdatePublicKey.txt').read_text().split())
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleShortVersionString': '0.2.5',
                'CFBundleVersion': '2005',
                'SUFeedURL': 'https://raw.githubusercontent.com/icebli/needle/main/appcast.xml',
                'SUPublicEDKey': key,
                'SUVerifyUpdateBeforeExtraction': True,
            }))
            archives = root / 'archives'
            archives.mkdir()
            archive = archives / 'Needle-0.2.5.dmg'
            archive.write_bytes(b'preview-dmg')

            hdiutil = bin_dir / 'hdiutil'
            hdiutil.write_text(f'''#!/bin/sh
if [ "$1" = attach ]; then
  /usr/bin/python3 -c 'import plistlib,sys; print(plistlib.dumps({{"system-entities":[{{"mount-point":sys.argv[1]}}]}}).decode())' "{mount}"
else
  exit 0
fi
''')
            codesign = bin_dir / 'codesign'
            codesign.write_text('#!/bin/sh\nif [ "$1" = "-dv" ]; then echo Signature=adhoc >&2; fi\nexit 0\n')
            generator = bin_dir / 'generate_appcast'
            generator.write_text(f'''#!/usr/bin/env python3
import base64, pathlib, sys
updates = pathlib.Path(sys.argv[-1])
archive = next(updates.glob("*.dmg"))
sig = base64.b64encode(bytes(64)).decode()
(updates / "appcast.xml").write_text(f"""<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>2005</sparkle:version><sparkle:shortVersionString>0.2.5</sparkle:shortVersionString><enclosure url="https://github.com/icebli/needle/releases/download/v0.2.5/Needle-0.2.5.dmg" length="{{archive.stat().st_size}}" sparkle:edSignature="{{sig}}" /></item></channel></rss>""")
''')
            for tool in (hdiutil, codesign, generator):
                tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
            result = subprocess.run(
                ['bash', str(ROOT / 'scripts/update-appcast.sh'), '--preview', str(archives), '0.2.5'],
                env=dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', SPARKLE_ROOT=str(root)),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('sparkle:edSignature', (archives / 'appcast.xml').read_text())


if __name__ == '__main__':
    unittest.main()
