#!/bin/bash
# Dikte — release derleme + .app bundle oluşturma
# Kullanım: ./build.sh
set -e

APP_NAME="Dikte"
BUNDLE_DIR="build/${APP_NAME}.app"

echo "==> Release derleniyor (arm64)…"
swift build -c release --arch arm64

echo "==> .app bundle oluşturuluyor…"
rm -rf build
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp ".build/arm64-apple-macosx/release/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/"
cp "Resources/Info.plist" "${BUNDLE_DIR}/Contents/"

# İkon varsa ekle (Resources/AppIcon.icns)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${BUNDLE_DIR}/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc imza: TCC izinlerinin (mikrofon/erişilebilirlik) kalıcı olması için şart
echo "==> Ad-hoc imzalanıyor…"
codesign --force --deep --sign - "${BUNDLE_DIR}"

echo ""
echo "✅ Hazır: ${BUNDLE_DIR}"
echo "   Kurulum: cp -R ${BUNDLE_DIR} /Applications/"
echo "   İlk açılışta 'tanımlanamayan geliştirici' uyarısı için: sağ tık > Aç"
