cask "better-meeting@beta" do
  version "0.4.9b6"
  sha256 "95d9e694b406271443c78bbefb7fe173c7f798766149f3aa2a32963f67642a9f"

  url "https://github.com/kremnyi/better-meeting-menubar/releases/download/v#{version}/Better-Meeting-#{version}-arm64.zip"
  name "Better Meeting Beta"
  desc "Beta builds of Better Meeting, the local meeting recorder and transcriber"
  homepage "https://kremnyi.github.io/better-meeting-menubar/"

  auto_updates true
  conflicts_with cask: "better-meeting"
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Better Meeting.app"

  zap trash: [
    "~/Library/Application Support/BetterMeeting",
    "~/Library/Caches/com.kremnyi.bettermeeting",
    "~/Library/Preferences/com.kremnyi.bettermeeting.plist",
    "~/Library/Saved Application State/com.kremnyi.bettermeeting.savedState",
  ]

  caveats <<~EOS
    This app uses a self-signed certificate and is not notarized by Apple.
    If macOS blocks opening it, use System Settings > Privacy & Security > Open Anyway.
    This cask follows beta releases, and the stable release that ends each beta series.
    Turn on Options > App & updates > Include beta releases so the app updates itself to betas too.
  EOS
end
