# Signed + Notarized DMG Distribution (GitHub Releases + Homebrew cask)

## Overview
- Ship `agterm` as a Developer ID **signed + Apple-notarized + stapled** `.dmg` so macOS Gatekeeper runs it without the "unidentified developer / cannot be opened" block.
- Two channels: a GitHub Release artifact (direct download) and a Homebrew **cask** in the existing `umputun/homebrew-apps` tap (`brew install --cask umputun/apps/agterm`).
- Release is run **locally on the maintainer's Mac** via `scripts/release.sh` (no GitHub Actions). The Developer ID cert lives in the login keychain; notary creds are stored once via `xcrun notarytool store-credentials` and referenced by profile name.
- No Sparkle / in-app auto-update (out of scope). Updates come from `brew upgrade` or a new release download.
- arm64-only (Apple Silicon): `GhosttyKit.xcframework` ships only a `macos-arm64` slice (`libghostty-internal-fat.a`, statically linked), so the bundle is self-contained but not universal. Universal would require rebuilding ghostty for x86_64 — explicitly out of scope.

## Context (from discovery)
- `project.yml`: ad-hoc signing (`CODE_SIGN_IDENTITY "-"`, `DEVELOPMENT_TEAM ""`), `ENABLE_HARDENED_RUNTIME YES`, `ARCHS arm64`, `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` hardcoded `0.0.0`. Entitlements at `agterm/agterm.entitlements`.
- Existing `Bundle agtermctl CLI` postBuildScript in `project.yml` already builds `agtermctl` release, copies it to `Contents/MacOS/agtermctl`, signs it, and re-signs the whole app `codesign --force --deep --options runtime --sign -`. **This is the signing integration point.**
- `scripts/build.sh` (Release build), `scripts/setup.sh` (builds GhosttyKit from pinned upstream ghostty). App is statically linked and self-contained (app + static ghostty + `Resources/ghostty` + `Resources/terminfo` + bundled `agtermctl`). No git tags yet, no `.github/workflows`.
- Tap `umputun/homebrew-apps` (tap name `umputun/apps`) exists; `Casks/` holds only `.gitkeep` (existing entries are GoReleaser **Formulae** for CLI tools). `agterm` is its **first cask**.

## Reference recipes (verified by reading the repos)
- **macterm** (`thdxg/macterm`): release/DMG/cask plumbing structure — but ships **ad-hoc, NOT notarized** (its `AGENTS.md` tells users to `xattr -cr`). Borrow plumbing only.
- **cmux** (`manaflow-ai/cmux`, `.github/workflows/nightly.yml`): the real sign+notarize recipe. Locally we drop the keychain-import step (cert already local) and use `--keychain-profile` instead of `--apple-id/--password`. Core sequence: `ditto -c -k --sequesterRsrc --keepParent app app.zip` → `xcrun notarytool submit app.zip --wait` (check status `Accepted`, dump `notarytool log` on failure) → `xcrun stapler staple app` → `stapler validate` → `spctl -a -vv --type execute` → build DMG → notarize + staple the DMG too.

## Development Approach
- **Testing approach**: Regular / validation-based. This is packaging plumbing (project.yml, shell script, a cask `.rb`, README) — there is no host-free unit-testable logic added. The gates are: `cd agtermCore && swift test` stays green, and a normal **ad-hoc Debug build still works unchanged** (the `AGTERM_SIGN_IDENTITY` default `-` path).
- Make small, focused changes; keep scope minimal (personal-project local release flow, not CI).
- **Do NOT run the full UI suite as a gate** (per the CLAUDE.md test-cadence convention) — distribution changes don't touch app behavior. Run focused checks only.
- Maintain backward compatibility: day-to-day `scripts/run.sh` / `scripts/build.sh` must behave exactly as before.

## Testing Strategy
- **swift test**: `cd agtermCore && swift test` must stay green (no core changes expected, but verify).
- **ad-hoc build regression**: after the `project.yml` change, a plain `scripts/run.sh` / Debug build must still produce a launchable ad-hoc app (no Developer ID required).
- **release.sh dry-run (pre-Apple)**: the build + DMG-packaging portion must run end-to-end producing an unsigned/ad-hoc DMG locally, so everything except the Apple-gated notarization is exercised before membership is active.
- **Notarized validation (Apple-gated)**: once the cert + creds exist, run the full `release.sh`, confirm `spctl -a -vv --type execute` passes and `stapler validate` succeeds, and verify a fresh download opens on a clean/second Mac without a Gatekeeper prompt.

## Prerequisites (Apple — manual, external, BLOCKS final validation)
These cannot be done in the codebase and block the notarization tasks until complete:
1. Enroll in the Apple Developer Program (individual, $99/yr) and wait for activation.
2. Create a **Developer ID Application** certificate; confirm it + its private key are in the login keychain. Note the identity string `Developer ID Application: <name> (TEAMID)` and the Team ID.
3. Create an app-specific password at appleid.apple.com, then store notary creds: `xcrun notarytool store-credentials agterm-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>` (profile name `agterm-notary`).

Until these are done, implement Tasks 1–4 (the `-` ad-hoc path stays the default and keeps working) and run the dry-run; Task 5 is the gated final validation.

## What Goes Where
- **Implementation Steps** (`[ ]`): `project.yml` signing parameterization, `scripts/release.sh`, the cask file content, README — all in this repo (the cask content is authored here even though it's published to the tap repo).
- **Post-Completion** (no checkboxes): Apple enrollment/cert/creds (above), publishing the cask to `umputun/homebrew-apps`, and the clean-Mac install verification.

## Implementation Steps

### Task 1: Parameterize signing identity + secure timestamp in the bundle build phase

**Files:**
- Modify: `project.yml` (the `Bundle agtermctl CLI` postBuildScript)

- [ ] Replace the two hardcoded `--sign -` calls (the nested `agtermctl` sign and the `--deep` whole-app reseal) with `--sign "${AGTERM_SIGN_IDENTITY:--}"` so the default stays ad-hoc and `release.sh` can inject a Developer ID identity.
- [ ] Add a secure timestamp to **BOTH** `codesign` calls on the real-identity path: when `AGTERM_SIGN_IDENTITY` is set and not `-`, both the nested-helper sign and the `--deep` reseal pass `--timestamp` (notarization requires a secure timestamp on every Mach-O, including `agtermctl`). Ad-hoc signatures cannot be timestamped, so the `-` path must NOT pass `--timestamp`. Keep `--options runtime` for both calls in both paths. (Implement as a shell var, e.g. `ts=""; [ "$id" != "-" ] && ts="--timestamp"`, applied to both calls.)
- [ ] `xcodegen generate` and run a normal Debug build (`scripts/run.sh` or `xcodebuild … Debug`); confirm the app still builds ad-hoc, `codesign --verify --deep --strict` passes, and `agtermctl` runs — i.e. zero behavior change when `AGTERM_SIGN_IDENTITY` is unset.
- [ ] `cd agtermCore && swift test` — must stay green.
- Note: the outer reseal keeps `--deep` (works for this single-nested-helper bundle and retains the entitlements). Apple discourages `--deep` for distribution; since the helper is already signed individually first, the fallback if notarization ever rejects nested-code signing is to switch the outer call to a non-`--deep` sign of just the app bundle. Not needed unless notarization complains.

### Task 2: scripts/release.sh — local build → (gated) notarize → DMG → publish

**Files:**
- Create: `scripts/release.sh`

- [ ] Accept a version (`VERSION=x.y.z` env or `$1`), validate `^[0-9]+\.[0-9]+\.[0-9]+$`; derive `TAG="v$VERSION"`.
- [ ] Build: `scripts/setup.sh` → `xcodegen generate` → plain `xcodebuild … -configuration Release -derivedDataPath build/DerivedData build` passing `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION="$VERSION"`, and (when signing) `CODE_SIGN_IDENTITY`/`DEVELOPMENT_TEAM`. Use the **same plain `build` path as `scripts/build.sh`** (NOT `archive`/`-exportArchive`): the `Bundle agtermctl CLI` postBuildScript already produces a signed, self-contained `.app` at `build/DerivedData/Build/Products/Release/agterm.app`. Copy that `.app` into a staging dir; no ExportOptions.plist / archive export needed.
- [ ] Signing identity resolution: if a `Developer ID Application` identity is available (configurable via env, e.g. `AGTERM_SIGN_IDENTITY`/`AGTERM_TEAM_ID`), export it so the build phase signs Developer ID; otherwise warn and produce an ad-hoc dry-run build (so the script is runnable before Apple membership).
- [ ] Notarize the app (gated on creds): `ditto -c -k --sequesterRsrc --keepParent <app> <zip>` → `xcrun notarytool submit <zip> --keychain-profile agterm-notary --wait`; on non-`Accepted` status dump `xcrun notarytool log` and exit non-zero → `xcrun stapler staple <app>` + `stapler validate` + `spctl -a -vv --type execute <app>` (app-level Gatekeeper check).
- [ ] Package DMG via `hdiutil create -volname agterm -srcfolder <staging> -ov -format UDZO build/agterm-$VERSION.dmg` with an `/Applications` symlink in the staging dir (avoids the `create-dmg` node dependency).
- [ ] Notarize + staple the DMG too (same notarytool/stapler steps), then validate the DMG itself with `spctl -a -vv -t open --context context:primary-signature build/agterm-$VERSION.dmg` (DMG assessment uses `-t open`, not `--type execute`). Gated on creds.
- [ ] Publish: `gh release create "$TAG" --title "Version $VERSION" --generate-notes` (or `upload --clobber` if it exists) and upload `build/agterm-$VERSION.dmg`.
- [ ] Bump cask: compute `shasum -a 256` of the DMG, clone/update `umputun/homebrew-apps`, `sed` `version`/`sha256` in `Casks/agterm.rb`, commit + push (guarded so a no-op diff is skipped). If `Casks/agterm.rb` doesn't exist yet in the tap (first publish), seed it from `packaging/agterm.rb` before the `sed` so the first `release.sh` run doesn't fail on a missing file (see Task 6 ordering note).
- [ ] `set -euo pipefail`, clear status messages per stage, and make the notarize/publish stages conditional so the build+DMG dry-run works before Apple membership is active.
- [ ] Dry-run validation: run `scripts/release.sh 0.0.1` without creds; confirm it produces `build/agterm-0.0.1.dmg` (ad-hoc) and stops cleanly before notarization/publish.

### Task 3: Homebrew cask content

**Files:**
- Create: `packaging/agterm.rb` (source-of-truth copy in this repo; published to `umputun/homebrew-apps:Casks/agterm.rb`)

- [ ] Write the cask: `version`, `sha256`, `url "https://github.com/umputun/agterm/releases/download/v#{version}/agterm-#{version}.dmg"`, `name "agterm"`, `desc`, `homepage`.
- [ ] Constraints: `depends_on macos: ">= :sonoma"` (macOS 14 floor) and `depends_on arch: :arm64`.
- [ ] `app "agterm.app"`; add a `binary` stanza linking the bundled `agtermctl` with an explicit deterministic name: `binary "#{appdir}/agterm.app/Contents/MacOS/agtermctl", target: "agtermctl"`. The cask owns this symlink for cask users — so the README/Task 4 must tell cask users NOT to also run the in-app Help ▸ Install Command Line Tool (it would create a competing `/usr/local/bin/agtermctl` symlink).
- [ ] `zap trash:` the app's state/support dirs (e.g. `~/Library/Application Support/agterm`) for clean uninstall.
- [ ] Note in the file header that `scripts/release.sh` rewrites `version`/`sha256` on each release.

### Task 4: README distribution/install section

**Files:**
- Modify: `README.md`

- [ ] Add an Install/Distribution section: `brew install --cask umputun/apps/agterm` and the direct DMG download from Releases.
- [ ] State it's **arm64-only (Apple Silicon)** and signed + notarized (no `xattr` workaround needed).
- [ ] Cross-reference the `agtermctl` CLI: the cask `binary` stanza installs it automatically (cask users should NOT run the in-app installer); the in-app Help ▸ Install Command Line Tool is for **direct DMG** users only.

### Task 5 (Apple-gated): Full notarized release validation
- [ ] ⚠️ BLOCKED until Apple membership active + Developer ID cert in keychain + `notarytool store-credentials agterm-notary` done (see Prerequisites).
- [ ] Run `scripts/release.sh` for a real version with signing; confirm app + DMG both notarized `Accepted` and `stapler validate` passes for both. Verify the app with `spctl -a -vv --type execute <app>` AND the DMG with `spctl -a -vv -t open --context context:primary-signature <dmg>` — both must report `accepted` / `source=Notarized Developer ID`.
- [ ] Download the published DMG on a clean/second Mac (or a fresh user); confirm it opens with no Gatekeeper block.

### Task 6: [Final] Docs + cleanup
- [ ] Update CLAUDE.md if the release flow introduces conventions worth recording (the `AGTERM_SIGN_IDENTITY` hook, the local-release model, arm64-only).
- [ ] Publish `packaging/agterm.rb` to `umputun/homebrew-apps:Casks/agterm.rb` (first cask in the tap).
- [ ] Move this plan to `docs/plans/completed/`.

## Post-Completion
*Manual / external — no checkboxes*
- Apple Developer Program enrollment + Developer ID cert + `notarytool store-credentials` (Prerequisites).
- First-time tap setup: commit `Casks/agterm.rb` to `umputun/homebrew-apps`; verify `brew install --cask umputun/apps/agterm` end-to-end.
- Clean-Mac Gatekeeper verification of a downloaded DMG.
- Optional future scope (not now): universal (x86_64) build, CI-based release, Sparkle auto-update.
