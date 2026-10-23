cask "better-meeting" do
  version "0.4.8"
  sha256 "d20139ce530659349226edd4740c07cf66248fe085b048be993ef0910998ff3e"

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
