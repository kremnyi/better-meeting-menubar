cask "better-meeting" do
  version "0.3.27"
  sha256 "abee3aa0cbfb940a80f7f7ff04da7088f27b3ca08ac4bcee2b90da15ee2464ad"

  url "https://github.com/kremnyi/better-meeting-menubar/releases/download/v#{version}/Better-Meeting-#{version}-arm64.zip"
  name "Better Meeting"
  desc "Record meetings from the menu bar and transcribe them locally"
  homepage "https://github.com/kremnyi/better-meeting-menubar"

  auto_updates true

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Better Meeting.app"

  caveats <<~EOS
    This app uses a self-signed certificate and is not notarized by Apple.
    If macOS blocks opening it, use System Settings > Privacy & Security > Open Anyway.
  EOS
end
