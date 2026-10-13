# Releasing Needle

Forgejo is the everyday development remote. GitHub at [icebli/needle](https://github.com/icebli/needle) is the secondary source snapshot and download channel. Publish a version after a meaningful user-facing upgrade, with a curated changelog and tested installer. Routine commits do not need a release.

## Current release boundary

The first distribution candidate is **0.2.0**. The planned shared build targets **Apple Silicon / arm64 and macOS 15+**, pending validation of the exact artifact. It starts as a **draft preview**, not a production release. Developer ID signing is not configured. Packaging success alone does not establish notarization, clean-machine compatibility, Spotify playback, or fulfillment of third-party redistribution requirements.

The current local review artifact was built on macOS 27.0.1 and its FFmpeg declares a macOS 27 minimum in `LC_BUILD_VERSION`. It therefore requires macOS 27. Do not publish it as a macOS 14 or 15 compatible build. The Swift GUI source deployment target is macOS 14, but the installer minimum is the highest requirement across all bundled executable code and dependencies.

The owner has authorized a public GitHub sharing repository only after the exported source and history pass privacy review. Keep it private until the required secret scans, private-data checks, and manual review succeed. Public source availability does not publish a draft installer. Draft releases remain restricted to repository users with the relevant write access.

## Preserve everyday Git behavior

Keep `origin` pointing at Forgejo and the `main` upstream at `origin/main`. GitHub is recorded under the name `github` for the export helper. **Never push the development `main` branch or original history directly to GitHub.** Do not replace `origin`, add GitHub as another `origin` push URL, or use `git push --mirror`.

Inspect the actual configuration before changing it:

```bash
git remote -v
git config --get branch.main.remote
git config --get branch.main.merge
git config --get remote.pushDefault
git config --get branch.main.pushRemote
```

The intended values are `branch.main.remote=origin`, `branch.main.merge=refs/heads/main`, and `remote.pushDefault=origin`. A branch-specific `pushRemote` overrides `remote.pushDefault`; keep it consistent. Normal `git push` continues to use Forgejo. Publishing to GitHub goes through `scripts/export-distribution.sh`, which validates the expected destination.

If the secondary remote has not been created yet, after verifying the destination repository:

```bash
git remote add github https://github.com/icebli/needle.git
git config remote.pushDefault origin
```

See [Git's documented push-remote precedence](https://git-scm.com/docs/git-config#Documentation/git-config.txt-remotepushDefault).

## Prepare a version

Update [CHANGELOG.md](../CHANGELOG.md) with the changes a friend will notice, supported Macs, upgrade instructions, and known limitations. Keep `Draft preview` until the release is actually published. Align the Rust workspace version in `Cargo.toml`, desktop bundle version, build number, release tag, and artifact labels. The first distribution version is 0.2.0. Add the curated release body at `docs/releases/v0.2.0.md` (and the matching versioned path for future releases).

Use a minor version for a substantial compatible feature upgrade, a patch version for fixes, and a major version for changes requiring a breaking migration. Previews should remain clearly labeled.

GitHub's generated notes summarize GitHub pull requests. Because development happens on Forgejo, maintain the user-facing notes here and supply a notes file when creating the release. [GitHub release-note behavior](https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes).

## Build a candidate

Build on an Apple Silicon Mac with the supported Swift and Rust toolchains. For GitHub Actions, the currently documented standard `macos-15` runner is arm64; `macos-15-intel` is Intel. Assert `uname -m` in the job and recheck labels when changing runners. [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Run the repository quality gates before packaging:

```bash
cargo test
cargo clippy --workspace --all-targets
swift test --package-path desktop
node --test browser-extension/tests/*.test.js spicetify/tests/*.test.js
```

The packager accepts explicit tool paths so a release can record exactly what it shipped. Example using already downloaded and verified tools:

```bash
./scripts/package-desktop.sh \
  --version 0.2.0 \
  --format dmg \
  --arch arm64 \
  --yt-dlp /absolute/path/to/yt-dlp_macos \
  --ffmpeg /absolute/path/to/ffmpeg \
  --ffprobe /absolute/path/to/ffprobe \
  --node /absolute/path/to/node
```

Use `./scripts/package-desktop.sh --help` for the current full option list. The default signing identity is ad-hoc. That is useful for local validation and does not produce an Apple-notarized release. Packaging does not install the app, change Spotify, or publish a release.

The packager derives the minimum supported macOS version from the bundled binaries. Inspect that value in the generated manifest and app metadata and carry it into the release notes. Building on the macOS 15 CI runner is expected to permit a macOS 15 package; the runner label alone does not prove this.

The first user-facing artifact is a DMG containing Needle and an Applications shortcut. Keep technical manifests and source archives available alongside the installer when needed, but direct friends to the DMG in the release notes.

## Bundled tools and source obligations

For each candidate, record upstream version, download URL, checksum, architecture, license, and exact build configuration. Verify upstream checksums before executing downloaded tools. Include the matching license texts and corresponding source materials required for the binaries and libraries being redistributed. A notice linking only to an upstream home page does not establish completion of those obligations.

- **yt-dlp:** use the upstream standalone `yt-dlp_macos` artifact, not a Homebrew Python wrapper or the Python-dependent Unix zip executable. The official release provides checksum files and signatures. Standalone distributions contain third-party code and are GPLv3+, although yt-dlp's own source is Unlicense. Full YouTube support also needs EJS and a supported JavaScript runtime. [Upstream assets and dependencies](https://github.com/yt-dlp/yt-dlp#installation).
- **FFmpeg/FFprobe:** use matching builds. Audit every non-system dynamic library copied into the app and preserve source/build provenance. The current Homebrew formula enables GPL/version 3 and is GPL-3.0-or-later, not LGPL. A build with `--enable-nonfree` is not redistributable. [FFmpeg licensing](https://ffmpeg.org/doxygen/trunk/md_LICENSE.html), [FFmpeg's source/distribution checklist](https://ffmpeg.org/legal.html).
- **JavaScript runtime and other bundled dependencies:** include their own notices and fulfill their applicable distribution conditions. Validate the runtime used by the packaged app rather than relying on a developer's PATH.

These are release gates. The presence of `THIRD_PARTY_NOTICES.md` or a toolchain manifest inside the app is useful evidence, not a declaration that all source obligations are fulfilled.

## Signing and notarization

A smooth first launch requires **Developer ID Application** signing, hardened runtime, secure timestamps, and successful notarization. Apple Development certificates and ad-hoc signatures do not satisfy this requirement. All nested executables must have valid signatures. A signed `.pkg` additionally needs a **Developer ID Installer** certificate. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [certificate types](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

Store signing certificates/passwords and notarization credentials as protected CI secrets, never repository files. GitHub documents importing an encrypted certificate into a temporary keychain for signing and cleaning up afterward. [GitHub macOS signing workflow](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

After signing all nested code, the app, and the DMG with Developer ID Application, use a previously configured `notarytool` keychain profile:

```bash
./scripts/notarize-release.sh dist/Needle-0.2.0.dmg NEEDLE_NOTARY_PROFILE
```

The script verifies that the DMG has a Developer ID Application signature, submits with `notarytool`, requires an `Accepted` status in Apple's JSON response, staples and validates the ticket, and runs a Gatekeeper assessment. It fails if any step fails. Credentials remain in the keychain profile. This path cannot be validated end to end until the required signing identity and notarization credentials are available.

Supplying the packager's `--sign` option alone is not evidence of notarization. Do not automatically fall back to ad-hoc signing if production credentials are missing.

## Validate the actual installer

Mount the DMG, copy Needle to Applications, and launch that copy. Test with a clean account or machine without Homebrew, Rust, Python, or developer PATH entries. Verify startup, readiness checks, a real search, artwork, audio preview, a user-approved save, and the saved file's tags. Check all executable architectures, minimum macOS load commands, and dynamic-library paths; no dependency may point into the build machine's home directory or Homebrew installation. Test the advertised minimum macOS version directly before claiming support.

Test Spotify setup separately: enable Local Files, select the Needle folder, confirm local playback, and verify a named playlist addition with the optional companion. A saved file or bridge acknowledgement is not proof of playback. Record any acceptance check that could not run in the release notes.

After significant runtime changes, also run the repository's canonical local installer and verify the installed CLI/app as required by AGENTS.md. Installer validation and local developer installation are separate checks.

## Create the release

Commit the reviewed changes before releasing from `main`. The release script requires a clean tracked working tree, a matching version in `Cargo.toml`, and a nonempty curated notes file at `docs/releases/vVERSION.md`. Isolate unrelated tracked changes in a clean checkout; do not discard them to satisfy the check.

```bash
NEEDLE_GITLEAKS=/absolute/path/to/verified/gitleaks \
  ./scripts/release.sh 0.2.0
```

The script creates an annotated Forgejo `v0.2.0` tag when absent, rejects an existing tag pointing at another development commit, and pushes `main` and that tag to `origin` only. It then invokes the source-export helper. It does not change ordinary push defaults. Never move a published tag to a different commit.

### Export public-facing source without development history

`scripts/export-distribution.sh VERSION` reads committed `HEAD` using `git archive` and an explicit allowlist. It excludes the development tracker, agent configuration, original commit messages, and original author email history. The first GitHub export starts a new release-only history; subsequent exports add reviewed source snapshots to that history. The GitHub `v0.2.0` tag intentionally identifies a different commit from Forgejo's tag.

The helper requires a verified Gitleaks executable, supplied through `NEEDLE_GITLEAKS` or an already verified PATH installation. It scans the exported directory for secrets, scans for private paths/addresses, creates a release snapshot with a neutral release identity, and scans the resulting Git history before pushing it. Review the allowlist and actual exported files for each release. Automated scans alone cannot determine whether every development note is appropriate to share.

### Update the Sparkle feed without touching tags

After a signed, notarized asset has been uploaded to the GitHub release, the feed can be refreshed independently. Commit the reviewed `appcast.xml` on Forgejo first, then run:

```bash
NEEDLE_GITLEAKS=/absolute/path/to/verified/gitleaks \
  ./scripts/export-distribution.sh 0.2.0 --feed-only
```

The feed-only mode clones the configured GitHub remote, replaces only its `appcast.xml` with the committed source version, scans the result, and pushes `main`. It never creates, moves, or force-updates a GitHub version tag and does not export source files. If the feed is already current, it exits without a commit or push. Keep the GitHub repository private until the same privacy review required for source snapshots is complete.

When unrelated tracked local work must be preserved, the normal release script correctly refuses the dirty checkout. Either use a clean checkout or, after the release commit and Forgejo version tag have been explicitly verified and pushed, export that committed `HEAD` directly:

```bash
NEEDLE_GITLEAKS=/absolute/path/to/verified/gitleaks \
  ./scripts/export-distribution.sh 0.2.0
```

The export helper ignores uncommitted content rather than exporting it. Verify `HEAD`, the committed version, and curated notes before this path; it does not replace the normal release preparation checks. Never work around a failed scan with a direct GitHub push. Keep the repository private and repair the export if any privacy gate fails. Change GitHub visibility to public only after successful scans and manual review of the actual exported snapshot and history.

The GitHub tag workflow runs on arm64 `macos-15`, installs build prerequisites, verifies the pinned standalone yt-dlp download, tests source, and packages the app with FFmpeg/FFprobe and Node. It always prepares an **unsigned draft** with the curated version notes, DMG, and checksums. It refuses to overwrite an already-published release. CI success does not complete the outstanding signing/notarization, corresponding-source, or clean-machine acceptance gates.

If the tag-triggered workflow already created a draft, update that draft instead of creating another. Otherwise, create a draft explicitly with the verified artifact paths and curated release notes:

```bash
gh release create v0.2.0 \
  --repo icebli/needle \
  --verify-tag \
  --draft \
  --prerelease \
  --title 'Needle 0.2.0 preview' \
  --notes-file /absolute/path/to/release-notes.md \
  /absolute/path/to/Needle-0.2.0.dmg
```

`--verify-tag` prevents the CLI from creating a tag implicitly from the repository's default branch. [GitHub release CLI](https://cli.github.com/manual/gh_release_create).

Add checksums and required corresponding-source artifacts to the same release. Read back the tag's commit, draft/prerelease state, release body, and asset list. Publish only after the applicable signing, portability, source/license, and user-workflow checks are satisfied. Keep the initial unsigned candidate as a draft and state the remaining blocker plainly.
