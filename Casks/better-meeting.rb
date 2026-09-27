cask "better-meeting" do
  version "0.4.3"
  sha256 "3f58395cedaa9d9474ad4c0e549c802a055901319dbe607a77e6970070a92035"

  url "https://github.com/kremnyi/better-meeting-menubar/releases/download/v#{version}/Better-Meeting-#{version}-arm64.zip"
  name "Better Meeting"
  desc "Record meetings from the menu bar and transcribe them locally"
  homepage "https://kremnyi.github.io/better-meeting-menubar/"

  auto_updates true

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
  EOS
end
