# Third-party release inventory

This document is the release-readiness inventory for the Apple Silicon
`Needle-0.2.4.dmg` artifact. It records what the package actually contains and
what must accompany a public release. It is an engineering checklist, not a
legal opinion or a statement that the corresponding-source obligations are
complete.

## Artifact examined

- Artifact: `target/github-release-0.2.4/Needle-0.2.4.dmg`
- SHA-256: `e1c6c29cf503960dc42cb18f4ec27969495dc0ca714c3d1895df5f1d7776a588`
- Architecture: arm64
- Manifest: `NeedleToolchain.json`, with `required_macos: 15.0`
- Build evidence: GitHub Actions run [38338230233](https://github.com/icebli/needle/actions/runs/38338230233)
- Bundle inspection: the packaged app has no `/opt/homebrew` or `/usr/local`
  load paths; its non-system FFmpeg dependencies are copied under
  `Contents/Resources/lib`.

The hashes and file list below are observations from this artifact. A future
release must regenerate this inventory from its own manifest and checksums.

The release workflow now runs `scripts/collect-third-party-sources.sh` while
the exact Homebrew build environment is still available. It uploads
`THIRD_PARTY_SOURCE_MANIFEST.json`, `THIRD_PARTY_SOURCE_MATERIALS.md`, and
`Needle-third-party-provenance.tar.gz`, containing the formula/dependency JSON,
tap revision, builder configuration, and hashes of the packaged files. This is
provenance capture; it deliberately remains marked incomplete until matching
source archives, checksums, and notices are attached.

The yt-dlp source archive includes its upstream `THIRD_PARTY_LICENSES.txt`,
which is captured separately. The standalone `yt-dlp_macos` executable also
contains a PyInstaller Python runtime and optional modules. The collector
therefore downloads and verifies the exact PyPI sdists for the GPL mutagen
module and PyInstaller bootloader used by the pinned macOS build. The other
embedded components are covered by yt-dlp's upstream notice file and their
permissive licenses; the generated manifest records all of these distinctions.
The PyInstaller `6.22.0` pin is taken from the official yt-dlp
`bundle/requirements/macos.txt` included in the `2026.08.19` source archive.

## Directly bundled components

| Component | Version / identity | Evidence in 0.2.4 | Release material still required |
| --- | --- | --- | --- |
| yt-dlp standalone | 2026.08.19; official `yt-dlp_macos` asset SHA-256 `0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202` | `Contents/Resources/bin/.yt-dlp-real`; wrapper injects the bundled Node EJS runtime | Preserve the exact release asset, upstream checksum/signature, yt-dlp source at the release revision, GPLv3+ notices, and notices/source for code shipped inside the standalone asset. |
| FFmpeg / FFprobe | 9.0.1; FFmpeg binary SHA-256 `2f0998c6fdad131c5056e8936fb829f04a43c8f4e2919d5a3e57ca7a991e200f`; FFprobe SHA-256 `0f88f7db4612978814efe3ca5436ca0520f543ebd66d1b3aa158aeabd4a0007e` | Manifest records Homebrew-style flags including `--enable-gpl`, `--enable-version3`, x264, x265, SVT-AV1, and OpenSSL | Capture the exact Homebrew formula revision, bottle/source digest, patches, source tarballs, configure/build commands, and complete license/source bundle. The current manifest says “packager-provided” and is insufficient provenance by itself. |
| Node.js | v24.14.1; SHA-256 `eff8e6ce8fef0b2f4246cf62383e8fd1bc8414755b58537f19214aa7c24a5c3d` | `Contents/Resources/bin/node`; official darwin-arm64 runtime used for yt-dlp EJS | Retain the exact official archive and `SHASUMS256.txt`, Node.js MIT license and bundled third-party notices, and a release asset or source archive sufficient to satisfy the applicable Node.js terms. |
| Sparkle | 2.10.0, revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`; SwiftPM ZIP checksum `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959` | `Contents/Frameworks/Sparkle.framework`; `SPARKLE_LICENSE` is included | Include the pinned Sparkle source/release reference and license/notice text with the release materials. Sparkle is not part of the media-tool manifest, so it must remain covered by the release checklist. |

## FFmpeg libraries copied into the app

The 0.2.4 app contains these non-system dynamic libraries under
`Contents/Resources/lib`: `libavcodec.63`, `libavdevice.63`, `libavfilter.12`,
`libavformat.63`, `libavutil.61`, `libswresample.7`, `libswscale.10`,
`libcrypto.3`, `libssl.3`, `libdav1d.7`, `liblzma.5`, `libmp3lame.0`,
`libmpg123.0`, `libopus.0`, `libSvtAv1Enc.4`, `libvmaf.3`, `libvpx.12`,
`libx264.165`, and `libx265.217`.

The FFmpeg configure line indicates GPL and version-3 components. The release
process must therefore preserve the license and corresponding-source material for
FFmpeg itself and each redistributed library, including the Homebrew formula
and any patches used to produce this exact build. Do not publish a “source
available” claim based only on the FFmpeg homepage or the binary hash.

System frameworks and libraries such as Foundation, CoreAudio, VideoToolbox,
libSystem, libz, libbz2, and libiconv are linked from macOS and are not copied
into the bundle. They still need to remain excluded from the corresponding-
source archive inventory.

## Release gate

The corresponding-source gate is **open / incomplete** for 0.2.4. Before
publishing a friend-ready release, add a release asset (or a clearly referenced
source archive) containing, at minimum:

1. The exact yt-dlp standalone release, checksum/signature records, source
   revision, and third-party notices.
2. The exact Node.js v24.14.1 darwin-arm64 archive, checksum record, license,
   and third-party notices.
3. The exact FFmpeg 9.0.1 build provenance: Homebrew formula revision and
   bottle/source digest, patches, configure flags, source tarballs, and license
   files for FFmpeg and all 19 copied non-system libraries.
4. Sparkle 2.10.0's pinned release/source reference and license materials.
5. A generated manifest tying each source archive and license file to the
   packaged binary SHA-256 and release tag.

The release workflow should fail when any row lacks a URL, checksum, license,
and corresponding-source reference. `THIRD_PARTY_NOTICES.md` and
`NeedleToolchain.json` remain useful in-app audit evidence, but do not close
this gate on their own.

## Remaining engineering work

No account credentials or owner-supplied files are needed for this inventory.
The release process must collect the exact FFmpeg Homebrew formula/bottle
(or rebuild from reproducible source), pinned source archives and notices,
and upload those materials alongside the signed release. Keep Apple signing
and notarization credentials separate from these source artifacts.
