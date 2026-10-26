cask "better-meeting@beta" do
  version "0.4.9b5"
  sha256 "d8d331bd2ff2478dc38e04d4d4844a44cb4044edd0f3c6ed5add0d0bc7a01f90"

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
