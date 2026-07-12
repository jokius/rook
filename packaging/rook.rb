# Source-of-truth Homebrew cask for rook. scripts/release.sh seeds this into
# jokius/homebrew-apps (Casks/rook.rb) on first publish and rewrites the
# version + sha256 lines on every release.
cask "rook" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jokius/rook/releases/download/v#{version}/rook-#{version}.dmg"
  name "rook"
  desc "Native macOS terminal on libghostty with a workspace/session sidebar"
  homepage "https://github.com/jokius/rook"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "rook.app"
  binary "#{appdir}/rook.app/Contents/MacOS/rookctl", target: "rookctl"

  # strip Homebrew's com.apple.quarantine so brew install/upgrade opens with no
  # "downloaded from the internet" prompt. the app is Developer ID signed, notarized,
  # and stapled, but that only removes the unidentified-developer block and the online
  # check - Gatekeeper still shows the first-launch confirm whenever the quarantine attr
  # is present, and brew re-stamps it on every fresh bundle.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/rook.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/rook",
    "~/Library/Preferences/com.rook.app.plist",
    "~/Library/Saved Application State/com.rook.app.savedState",
  ]
end
