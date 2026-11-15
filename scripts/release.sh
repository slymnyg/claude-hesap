#!/bin/zsh
# Yeni sürüm yayınlar: derler, zip'ler, GitHub Release açar ve Homebrew tap'indeki cask'ı günceller.
# Kullanım: scripts/release.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?kullanım: scripts/release.sh <sürüm>}"
REPO="slymnyg/claude-hesap"
TAP="slymnyg/homebrew-tap"

[[ -z "$(git status --porcelain)" ]] || { echo "Çalışma dizini temiz değil, önce commit et."; exit 1; }
echo "$VERSION" > VERSION
scripts/build-app.sh "$VERSION"

ZIP="dist/ClaudeHesap-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "dist/Claude Hesap.app" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

git add VERSION
git commit -m "Sürüm $VERSION" || true
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "v$VERSION" --generate-notes

TMP=$(mktemp -d)
gh repo clone "$TAP" "$TMP" -- --depth 1
mkdir -p "$TMP/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" packaging/claude-hesap.rb > "$TMP/Casks/claude-hesap.rb"
git -C "$TMP" add Casks/claude-hesap.rb
git -C "$TMP" commit -m "claude-hesap $VERSION"
git -C "$TMP" push
rm -rf "$TMP"
echo "Yayınlandı: v$VERSION ($SHA)"
