---
paths:
  - ".github/workflows/**"
---

## CI (`ci.yml`)

- **`ci.yml` runs on push/PR to `master`, gated by a `dorny/paths-filter`** (`**/*.swift`,
  `rookCore/**`, `rook/**`, `project.yml`, `scripts/**`, `.swiftlint.yml`, `ci.yml`).
  Jobs: a `test` job (`swift test --enable-code-coverage` in `rookCore`, then
  `xcrun llvm-cov export … -format=lcov`, then uploads the lcov as an artifact),
  a `coverage` job (the ONLY `ubuntu-latest` job) that downloads that artifact and does a
  `continue-on-error` upload to Coveralls via `coverallsapp/github-action@v2` with `secrets.GITHUB_TOKEN`,
  a `lint` job (`brew install swiftlint` then `swiftlint lint --strict` — no build, it only parses sources),
  and a `build` job (`brew install xcodegen` then `scripts/build.sh`, Release, with
  `GhosttyKit.xcframework` + ghostty/terminfo resources restored from an `actions/cache` keyed on
  `scripts/setup.sh`), the mac jobs on `macos-26`, concurrency cancel-in-progress.
  There is NO `release.yml` — releases are cut locally; see `.claude/rules/release.md`.
- **The Coveralls upload runs on Linux ON PURPOSE.**
  `coverallsapp/github-action@v2` installs its reporter from a brew tap on macOS (blocked by Homebrew's
  new tap-trust gate), but downloads a prebuilt binary on Linux, so the mac `test` job hands the lcov to
  the `ubuntu-latest` `coverage` job to upload.
  Because the two jobs are different machines, the `test` job rewrites `llvm-cov`'s absolute `SF:` paths
  to repo-relative (strips `$GITHUB_WORKSPACE/`) so the Linux reporter resolves each source file against
  its own checkout; skip that and the reporter matches nothing and prints `🚨 Nothing to report`.
  The entire coverage path is best-effort: the lcov artifact upload (`test` job), the artifact download
  (`coverage` job), and the Coveralls submit are ALL `continue-on-error`, so a transient GitHub
  artifact-service timeout or a Coveralls hiccup never reds the build when the tests themselves passed
  (only the `test` job's `swift test` gates the build).
  The flip side: a masked failure shows green — verify the actual Coveralls build/API after changing
  anything here, never trust the check color alone.
- **CI does NOT run EITHER app-target test bundle** — it builds the app but never test-runs it;
  only the host-free `swift test` runs in CI.
  That covers the XCUITests (`rookUITests`) and, since it was added, the host-loaded unit-test bundle
  (`rookTests`): both need a built `rook.app` plus `GhosttyKit`, which is the `build` job's work, not the
  `test` job's.
  So the Coveralls badge reflects `rookCore` coverage ONLY — the app target
  (SwiftUI/AppKit/libghostty) is manually tested and excluded, not "the whole app is N% covered".
  **`rookTests` therefore only runs when someone runs it**, locally and DELIBERATELY:
  `xcodebuild test -project rook.xcodeproj -scheme rook -only-testing:rookTests`.
  The `-only-testing:` is not optional — the scheme lists both bundles, so a bare `xcodebuild test` also
  fires the XCUITests, which synthesize keyboard/mouse input and take over the machine.
  It exists for what STRUCTURALLY needs the host (a real `NSSplitView` divider band, a tracking area's
  `mouseMoved`, the process-global `NSCursor`, a named `NSPasteboard`) — host-free logic still belongs in
  `rookCore`, so adding a case here should always be a deliberate "this cannot be hoisted" call.
- **The `lint` job is `--strict`**, so any swiftlint warning fails the build (see the `make lint` note in
  the root `CLAUDE.md`).
