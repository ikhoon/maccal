# Homebrew formula for maccal.
#
# The maccal repo doubles as its own Homebrew tap:
#   brew tap ikhoon/maccal https://github.com/ikhoon/maccal.git
#   brew install maccal
#
# The artifact is the universal (arm64 + x86_64) maccal.app produced by
# ./release.sh and attached to the GitHub release. Installing through brew does
# not quarantine the download, so Gatekeeper does not block the ad-hoc-signed
# bundle (unlike a manual download from the release page).
#
# After bumping the version: run ./release.sh, upload the zip to the release,
# then update `version`, `url`, and `sha256` below.
class Maccal < Formula
  desc "Scriptable macOS Calendar CLI (EventKit) — agenda, search, add/edit/rm"
  homepage "https://github.com/ikhoon/maccal"
  url "https://github.com/ikhoon/maccal/releases/download/v0.2.0/maccal-v0.2.0-macos-universal.zip"
  sha256 "00dcf17d6eead356e7da364e7e5ee1a616532c20d69628d7ee38cf9bacb5d7c0"

  depends_on :macos

  def install
    prefix.install "maccal.app"
    bin.install_symlink prefix/"maccal.app/Contents/MacOS/maccal"
    generate_completions_from_executable(bin/"maccal", "completions",
                                         shells:                [:zsh, :bash],
                                         shell_parameter_format: :arg)
  end

  def caveats
    <<~EOS
      maccal holds its own Calendar (TCC) permission via maccal.app —
      it does not grant your terminal calendar access. Authorize it once:
        maccal auth
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/maccal --version")
  end
end
