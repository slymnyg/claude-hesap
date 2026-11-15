cask "claude-hesap" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/slymnyg/claude-hesap/releases/download/v#{version}/ClaudeHesap-#{version}.zip"
  name "Claude Hesap"
  desc "Claude Code ve Claude masaüstü için hesap değiştirici"
  homepage "https://github.com/slymnyg/claude-hesap"

  depends_on macos: ">= :sonoma"

  app "Claude Hesap.app"
  binary "#{appdir}/Claude Hesap.app/Contents/MacOS/ClaudeHesap", target: "claude-hesap"

  # Uygulama Apple Developer ID ile imzalı değil; Gatekeeper engellemesin diye karantina kaldırılır.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Claude Hesap.app"]
  end

  zap trash: "~/.claude-hesap"
end
