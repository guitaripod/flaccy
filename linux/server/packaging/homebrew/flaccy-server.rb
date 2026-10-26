class FlaccyServer < Formula
  desc "Headless OpenSubsonic server for one music folder, made for Flaccy"
  homepage "https://github.com/guitaripod/flaccy"
  version "@VERSION@"
  license "GPL-3.0-only"

  on_macos do
    on_arm do
      url "https://github.com/guitaripod/flaccy/releases/download/server-v@VERSION@/flaccy-server-@VERSION@-macos-arm64.tar.gz"
      sha256 "@SHA256_MACOS_ARM64@"
    end
    on_intel do
      url "https://github.com/guitaripod/flaccy/releases/download/server-v@VERSION@/flaccy-server-@VERSION@-macos-x86_64.tar.gz"
      sha256 "@SHA256_MACOS_X86_64@"
    end
  end

  depends_on "ffmpeg" => :recommended

  def install
    bin.install "flaccy-server"
  end

  service do
    run [opt_bin/"flaccy-server", "serve"]
    keep_alive true
    log_path var/"log/flaccy-server.log"
    error_log_path var/"log/flaccy-server.log"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/flaccy-server --version")
  end
end
