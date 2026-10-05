#!/bin/bash
# Dikte — başka bir Mac'e kurulum için disk görüntüsü üretir: dist/Dikte-<sürüm>.dmg
# Kullanım: Tools/make-dmg.sh   (önce ./build.sh çalışmış olmalı; yoksa kendisi çalıştırır)
set -e
cd "$(dirname "$0")/.."

APP="build/Dikte.app"
[ -d "${APP}" ] || ./build.sh

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")"
OUT="dist/Dikte-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
cp "Tools/Kurulum.txt" "${STAGE}/Kurulum — önce beni oku.txt"

mkdir -p dist
rm -f "${OUT}"
hdiutil create -volname "Dikte ${VERSION}" -srcfolder "${STAGE}" -ov -format UDZO "${OUT}" >/dev/null

echo "✅ ${OUT} ($(du -h "${OUT}" | cut -f1 | tr -d ' '))"
echo "   Dilimler: $(lipo -archs "${APP}/Contents/MacOS/Dikte")"
