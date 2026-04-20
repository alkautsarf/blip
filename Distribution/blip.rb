# Homebrew formula for blip. Lives in alkautsarf/homebrew-tap.
# Head-only strategy: builds from source on every install, so pushing to
# main + `brew upgrade --fetch-HEAD alkautsarf/tap/blip` pulls the latest.
class Blip < Formula
  desc "macOS notch app for terminal-native Claude Code users"
  homepage "https://github.com/alkautsarf/blip"
  head "https://github.com/alkautsarf/blip.git", branch: "main"
  license "MIT"

  depends_on :macos => :sonoma
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/Blip"
    bin.install ".build/release/BlipApp"
    bin.install ".build/release/BlipHooks"
    bin.install ".build/release/BlipSetup"
  end

  def caveats
    <<~EOS
      Get started:

        blip start             # launch the notch app in the background
        blip install           # wire hooks into ~/.claude/settings.json
        blip doctor            # verify everything's connected

      Grant Accessibility permission on first launch so global hotkeys
      can fire from inside tmux:

        System Settings → Privacy & Security → Accessibility → BlipApp

      For jump-to-tmux to work, set @cwd on every pane — see README.

      To remove cleanly:

        blip uninstall         # restore settings.json byte-perfect
        blip stop              # terminate the app
    EOS
  end

  test do
    system "#{bin}/blip", "help"
  end
end
