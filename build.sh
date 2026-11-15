#!/bin/zsh
# Kaynaktan derleyip ~/Applications'a kurar, CLI'yi ~/.local/bin'e bağlar.
set -euo pipefail
cd "$(dirname "$0")"
scripts/build-app.sh
APP="$HOME/Applications/Claude Hesap.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "dist/Claude Hesap.app" "$APP"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/ClaudeHesap" "$HOME/.local/bin/claude-hesap"
echo "Kuruldu: $APP"
