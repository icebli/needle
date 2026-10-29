#!/usr/bin/env bash
set -euo pipefail

# Capture the exact provenance visible at package time. This does not pretend
# that a URL is a corresponding-source offer: the generated manifest marks
# missing source archives/checksums explicitly so the release gate can fail
# closed while still preserving the build evidence needed to finish it.

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 APP_PATH OUTPUT_DIR [--download-sources]" >&2
  exit 2
fi

APP_PATH="$1"
OUTPUT_DIR="$2"
MANIFEST="$APP_PATH/Contents/Resources/NeedleToolchain.json"
DOWNLOAD_SOURCES="${3:-}"

[[ -d "$APP_PATH/Contents" ]] || { echo "app bundle not found: $APP_PATH" >&2; exit 1; }
[[ -s "$MANIFEST" ]] || { echo "toolchain manifest not found: $MANIFEST" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required to capture FFmpeg provenance" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
brew info --json=v2 ffmpeg > "$OUTPUT_DIR/homebrew-ffmpeg.json"
tap_head="$(brew tap-info --json homebrew/core | python3 -c 'import json,sys; x=json.load(sys.stdin); print(x[0].get("head", ""))' 2>/dev/null || true)"
brew_config="$OUTPUT_DIR/homebrew-config.txt"
brew config > "$brew_config"

export APP_PATH OUTPUT_DIR MANIFEST TAP_HEAD="$tap_head"
export DOWNLOAD_SOURCES
export PACKAGE_RESOLVED="$(cd "$(dirname "$0")/.." && pwd)/desktop/Package.resolved"
python3 - <<'PY'
import hashlib
import json
import os
import shutil
import pathlib
import subprocess
import tarfile
import tempfile
import urllib.request

app = pathlib.Path(os.environ["APP_PATH"])
out = pathlib.Path(os.environ["OUTPUT_DIR"])
toolchain = json.loads(pathlib.Path(os.environ["MANIFEST"]).read_text())
resolved = json.loads(pathlib.Path(os.environ["PACKAGE_RESOLVED"]).read_text())
sparkle = next(pin["state"] for pin in resolved["pins"] if pin["identity"] == "sparkle")
sparkle_revision = sparkle["revision"]
sparkle_version = sparkle["version"]

def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def brew_json(*names: str) -> dict:
    result = subprocess.run(
        ["brew", "info", "--json=v2", *names],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)

def download(url: str, target: pathlib.Path) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "needle-release-source-capture/1"})
    with urllib.request.urlopen(request, timeout=90) as response, target.open("wb") as handle:
        shutil.copyfileobj(response, handle)
    return sha256(target)

def download_verified(url: str, target: pathlib.Path, expected: str | None = None) -> tuple[str, str | None]:
    actual = download(url, target)
    if expected and actual != expected:
        raise SystemExit(f"source checksum mismatch for {url}: {actual} != {expected}")
    return actual, expected

def download_pypi(name: str, version: str, target: pathlib.Path) -> tuple[str, str]:
    metadata_url = f"https://pypi.org/pypi/{name}/{version}/json"
    request = urllib.request.Request(metadata_url, headers={"User-Agent": "needle-release-source-capture/1"})
    with urllib.request.urlopen(request, timeout=90) as response:
        metadata = json.load(response)
    release = next((item for item in metadata["urls"] if item["packagetype"] == "sdist"), None)
    if not release:
        raise SystemExit(f"PyPI sdist missing for {name}=={version}")
    actual = download(release["url"], target)
    expected = release["digests"]["sha256"]
    if actual != expected:
        raise SystemExit(f"PyPI source checksum mismatch for {name}: {actual} != {expected}")
    return actual, expected

def extract_license(archive: pathlib.Path, destination: pathlib.Path) -> str | None:
    try:
        with tarfile.open(archive) as tar:
            members = [m for m in tar.getmembers() if (
                pathlib.PurePosixPath(m.name).name.lower().startswith(("license", "copying", "unlicense"))
                or pathlib.PurePosixPath(m.name).name.lower() in {"notice", "notice.txt"}
            ) and m.isfile()]
            if not members:
                return None
            member = sorted(members, key=lambda item: (item.name.count("/"), len(item.name)))[0]
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)
            return member.name
    except (tarfile.TarError, OSError):
        return None

ffmpeg = json.loads((out / "homebrew-ffmpeg.json").read_text())["formulae"][0]
names = [ffmpeg["name"], *ffmpeg.get("dependencies", [])]
dependency_info = {item["name"]: item for item in brew_json(*names).get("formulae", [])}

# Record the formula that owns every copied non-system FFmpeg dylib. Direct
# formula dependencies alone are insufficient because Homebrew can add runtime
# dependencies that are not declared directly by ffmpeg.
bundled_libs = []
runtime_names = [item.get("full_name", item.get("name")) for item in ffmpeg.get("installed", [{}])[0].get("runtime_dependencies", [])]
all_formula_names = list(dict.fromkeys([*names, *runtime_names]))
dependency_info = {item["name"]: item for item in brew_json(*all_formula_names).get("formulae", [])}
for lib in sorted((app / "Contents/Resources/lib").glob("*.dylib")):
    owners = []
    for formula in all_formula_names:
        prefix = subprocess.run(["brew", "--prefix", formula], check=False, capture_output=True, text=True).stdout.strip()
        if prefix and any(candidate.name == lib.name for candidate in pathlib.Path(prefix, "lib").glob(f"{lib.name}*")):
            owners.append(formula)
    bundled_libs.append({"path": str(lib.relative_to(app)), "sha256": sha256(lib), "owners": owners})
owner_names = sorted({owner for item in bundled_libs for owner in item["owners"]})
unowned_libs = [item["path"] for item in bundled_libs if not item["owners"]]
source_formula_names = list(dict.fromkeys([*names, *owner_names]))
if all_formula_names != names:
    dependency_info = {item["name"]: item for item in brew_json(*all_formula_names).get("formulae", [])}

def upstream_formula(item: dict) -> dict:
    urls = item.get("urls", {}).get("stable", {})
    return {
        "name": item.get("full_name", item.get("name")),
        "version": item.get("versions", {}).get("stable"),
        "license": item.get("license"),
        "homepage": item.get("homepage"),
        "source_url": urls.get("url"),
        "source_sha256": urls.get("checksum"),
        "formula_revision": item.get("revision"),
        "formula_source_path": item.get("ruby_source_path"),
        "formula_source_sha256": item.get("ruby_source_checksum"),
        "dependencies": item.get("dependencies", []),
        "installed": item.get("installed", []),
    }

binary_entries = {}
for key, record in toolchain.items():
    if not isinstance(record, dict) or "path" not in record:
        continue
    path = app / record["path"]
    if path.is_file():
        binary_entries[key] = {
            "path": record["path"],
            "sha256": sha256(path),
            "version": record.get("version"),
        }
    if record.get("real_path"):
        real = app / record["real_path"]
        if real.is_file():
            binary_entries[f"{key}_real"] = {
                "path": record["real_path"],
                "sha256": sha256(real),
                "version": record.get("version"),
            }

yt_version = str(toolchain.get("yt_dlp", {}).get("version", ""))
node_version = str(toolchain.get("node", {}).get("version", "")).lstrip("v")
sources = [
    {
        "component": "yt-dlp",
        "license": "GPL-3.0-or-later (standalone release includes yt-dlp and third-party code)",
        "release_url": f"https://github.com/yt-dlp/yt-dlp/releases/tag/{yt_version}",
        "source_url": f"https://github.com/yt-dlp/yt-dlp/archive/refs/tags/{yt_version}.tar.gz",
        "release_checksums_url": f"https://github.com/yt-dlp/yt-dlp/releases/download/{yt_version}/SHA2-256SUMS",
        "source_sha256": None,
        "status": "source-archive-checksum-required",
    },
    {
        "component": "Node.js",
        "license": "MIT",
        "release_url": f"https://nodejs.org/dist/v{node_version}/",
        "source_url": f"https://nodejs.org/dist/v{node_version}/node-v{node_version}.tar.gz",
        "release_checksums_url": f"https://nodejs.org/dist/v{node_version}/SHASUMS256.txt",
        "source_sha256": None,
        "status": "source-archive-checksum-required",
    },
    {
        "component": "Sparkle",
        "license": "MIT",
        "release_url": f"https://github.com/sparkle-project/Sparkle/releases/tag/{sparkle_version}",
        "source_url": f"https://github.com/sparkle-project/Sparkle/archive/{sparkle_revision}.tar.gz",
        "release_checksums_url": None,
        "source_sha256": None,
        "status": "source-archive-checksum-required",
    },
]

manifest = {
    "schema": 1,
    "artifact": {
        "app": app.name,
        "required_macos": toolchain.get("required_macos"),
        "architecture": "arm64",
    },
    "binaries": binary_entries,
    "homebrew": {
        "tap": "homebrew/core",
        "tap_head": os.environ.get("TAP_HEAD") or None,
        "ffmpeg": upstream_formula(ffmpeg),
        "dependencies": [upstream_formula(dependency_info[name]) for name in names[1:] if name in dependency_info],
        "bundled_library_owners": bundled_libs,
        "unowned_bundled_libraries": unowned_libs,
        "owner_formulas": [upstream_formula(dependency_info[name]) for name in owner_names if name in dependency_info],
        "formula_json": "homebrew-ffmpeg.json",
        "config": "homebrew-config.txt",
    },
    "sources": sources,
    "corresponding_source_status": "incomplete-until-archives-and-checksums-are-attached",
}

source_dir = out / "sources"
license_dir = out / "licenses"
source_records = []
if os.environ.get("DOWNLOAD_SOURCES") == "--download-sources":
    if unowned_libs:
        raise SystemExit("unowned bundled Homebrew libraries: " + ", ".join(unowned_libs))
    source_dir.mkdir(parents=True, exist_ok=True)
    license_dir.mkdir(parents=True, exist_ok=True)
    for formula_name in source_formula_names:
        item = dependency_info.get(formula_name)
        if not item:
            raise SystemExit(f"missing Homebrew formula metadata for {formula_name}")
        stable_version = item.get("versions", {}).get("stable")
        installed = item.get("installed", [])
        if not stable_version or not installed:
            raise SystemExit(f"missing installed Homebrew version for {formula_name}")
        installed_version = installed[0].get("version")
        formula_revision = item.get("revision", 0) or 0
        expected_version = f"{stable_version}_{formula_revision}" if formula_revision else stable_version
        if installed_version != expected_version:
            raise SystemExit(f"Homebrew version mismatch for {formula_name}: installed {installed_version}, formula {expected_version}")
        stable = item.get("urls", {}).get("stable", {})
        url = stable.get("url")
        expected = stable.get("checksum")
        source_revision = stable.get("revision")
        if not url:
            raise SystemExit(f"missing Homebrew source URL for {item.get('name')}")
        if expected:
            filename = pathlib.PurePosixPath(url.split("?", 1)[0]).name or f"{item['name']}.source"
            archive = source_dir / f"{item['name']}-{item.get('versions', {}).get('stable', 'unknown')}-{filename}"
            actual = download(url, archive)
            if actual != expected:
                raise SystemExit(f"Homebrew source checksum mismatch for {item['name']}: {actual} != {expected}")
            source_basis = "homebrew-published-sha256"
        elif source_revision:
            # Git-backed formulas such as x264 have no tarball checksum. Pin
            # the exact Homebrew revision and archive that commit locally.
            archive = source_dir / f"{item['name']}-{item.get('versions', {}).get('stable', 'unknown')}-{source_revision}.tar.gz"
            with tempfile.TemporaryDirectory(prefix="needle-source-") as checkout:
                subprocess.run(["git", "init", "--quiet", checkout], check=True)
                subprocess.run(["git", "-C", checkout, "remote", "add", "origin", url], check=True)
                subprocess.run(["git", "-C", checkout, "fetch", "--quiet", "--depth", "1", "origin", source_revision], check=True)
                with archive.open("wb") as output:
                    subprocess.run(["git", "-C", checkout, "archive", "--format=tar.gz", source_revision], check=True, stdout=output)
            actual = sha256(archive)
            source_basis = "pinned-git-commit-archive"
        else:
            raise SystemExit(f"missing Homebrew source checksum and git revision for {item.get('name')}")
        license_name = extract_license(archive, license_dir / f"{item['name']}-LICENSE")
        formula = subprocess.run(["brew", "cat", item.get("full_name", item["name"])], check=True, capture_output=True, text=True)
        (out / "formulae").mkdir(parents=True, exist_ok=True)
        formula_path = out / "formulae" / f"{item['name']}.rb"
        formula_path.write_text(formula.stdout)
        source_records.append({
            "component": item.get("full_name", item["name"]),
            "source_url": url,
            "source_sha256": actual,
            "source_revision": source_revision,
            "verification_basis": source_basis,
            "license": item.get("license"),
            "license_file": str(pathlib.Path("licenses") / f"{item['name']}-LICENSE") if license_name else None,
            "formula_file": str(pathlib.Path("formulae") / f"{item['name']}.rb"),
            "status": "verified" if license_name else "license-file-required",
        })
    yt_version = str(toolchain.get("yt_dlp", {}).get("version", ""))
    node_version = str(toolchain.get("node", {}).get("version", "")).lstrip("v")
    extras = [
        ("yt-dlp", f"https://github.com/yt-dlp/yt-dlp/releases/download/{yt_version}/yt-dlp.tar.gz", "GPL-3.0-or-later", f"https://github.com/yt-dlp/yt-dlp/releases/download/{yt_version}/SHA2-256SUMS", "yt-dlp.tar.gz"),
        ("node", f"https://nodejs.org/dist/v{node_version}/node-v{node_version}.tar.gz", "MIT", f"https://nodejs.org/dist/v{node_version}/SHASUMS256.txt", f"node-v{node_version}.tar.gz"),
        ("sparkle", f"https://github.com/sparkle-project/Sparkle/archive/{sparkle_revision}.tar.gz", "MIT", None, None),
    ]
    for name, url, license_id, checksums_url, checksum_name in extras:
        filename = pathlib.PurePosixPath(url).name
        archive = source_dir / filename
        expected = None
        if checksums_url:
            checksum_text = urllib.request.urlopen(urllib.request.Request(checksums_url, headers={"User-Agent": "needle-release-source-capture/1"}), timeout=90).read().decode()
            expected = next((line.split()[0] for line in checksum_text.splitlines() if line.split()[-1] == checksum_name), None)
            if not expected:
                raise SystemExit(f"published checksum missing for {name}: {checksum_name}")
        actual, _ = download_verified(url, archive, expected)
        license_name = extract_license(archive, license_dir / f"{name}-LICENSE")
        bundled_notice = None
        if name == "yt-dlp":
            try:
                with tarfile.open(archive) as tar:
                    notice = next(m for m in tar.getmembers() if pathlib.PurePosixPath(m.name).name == "THIRD_PARTY_LICENSES.txt")
                    bundled_notice = license_dir / "yt-dlp-THIRD_PARTY_LICENSES.txt"
                    with tar.extractfile(notice) as source, bundled_notice.open("wb") as output:
                        shutil.copyfileobj(source, output)
            except (StopIteration, tarfile.TarError, OSError):
                bundled_notice = None
        source_records.append({
            "component": name,
            "source_url": url,
            "source_sha256": actual,
            "published_sha256": expected,
            "source_revision": sparkle_revision if name == "sparkle" else None,
            "package_resolved_revision": sparkle_revision if name == "sparkle" else None,
            "verification_basis": "pinned-package-resolved-revision" if name == "sparkle" else ("official-published-checksum" if expected else None),
            "license": license_id,
            "license_file": str(pathlib.Path("licenses") / f"{name}-LICENSE") if license_name else None,
            "bundled_third_party_notice": str(pathlib.Path("licenses") / bundled_notice.name) if bundled_notice else None,
            "bundled_dependency_source_status": "resolved-copyleft-dependencies" if name == "yt-dlp" else "not-applicable",
            "status": "verified" if license_name else "license-file-required",
        })
    # The macOS standalone yt-dlp build uses PyInstaller and mutagen. Mutagen
    # is GPL-2.0-or-later; PyInstaller's bootloader is GPL with an exception.
    # Capture their exact sdists from PyPI instead of treating the yt-dlp source
    # archive as sufficient for the executable's embedded runtime.
    for name, version, license_id in [("mutagen", "1.48.1", "GPL-2.0-or-later"), ("pyinstaller", "6.22.0", "GPL-2.0-or-later-with-exception")]:
        archive = source_dir / f"{name}-{version}.tar.gz"
        actual, expected = download_pypi(name, version, archive)
        license_name = extract_license(archive, license_dir / f"{name}-LICENSE")
        source_records.append({
            "component": name,
            "version": version,
            "source_url": f"https://pypi.org/project/{name}/{version}/",
            "version_evidence": "yt-dlp 2026.10.26 bundle/requirements/macos.txt (official release tag)",
            "source_sha256": actual,
            "published_sha256": expected,
            "license": license_id,
            "license_file": str(pathlib.Path("licenses") / f"{name}-LICENSE") if license_name else None,
            "status": "verified" if license_name else "license-file-required",
        })
    manifest["sources"] = source_records
    standalone_sources_complete = all(
        item.get("bundled_dependency_source_status") != "unresolved-for-standalone-binary"
        for item in source_records
    ) and all(item.get("status") == "verified" for item in source_records)
    manifest["corresponding_source_status"] = (
        "complete" if standalone_sources_complete else "incomplete-yt-dlp-standalone-dependencies"
    )
else:
    manifest["corresponding_source_status"] = (
        "incomplete-unowned-bundled-library" if unowned_libs
        else "incomplete-until-archives-and-checksums-are-attached"
    )
(out / "THIRD_PARTY_SOURCE_MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")

lines = [
    "# Needle corresponding-source capture",
    "",
    "This release artifact records package-time provenance. It is not, by itself, a corresponding-source offer.",
    "",
    f"- App: `{app.name}` (arm64; macOS {toolchain.get('required_macos', 'unknown')})",
    f"- Homebrew tap HEAD: `{os.environ.get('TAP_HEAD') or 'not available'}`",
    "- Status: **complete only when invoked with `--download-sources` and every record is verified**.",
    "",
    "## Captured material",
    "",
    "- `THIRD_PARTY_SOURCE_MANIFEST.json`: binary hashes, formula revisions, licenses, URLs, and dependency metadata.",
    "- `homebrew-ffmpeg.json`: exact Homebrew formula and installed runtime dependency record.",
    "- `homebrew-config.txt`: builder configuration evidence.",
    "",
    "When `--download-sources` is used, `sources/`, `licenses/`, and `formulae/` contain the downloaded archives, extracted license texts, and exact Homebrew formula recipes. The release process must attach these materials and retain the generated manifest with the package.",
]
(out / "THIRD_PARTY_SOURCE_MATERIALS.md").write_text("\n".join(lines) + "\n")
PY

echo "Captured third-party provenance in $OUTPUT_DIR"
