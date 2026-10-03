#!/bin/bash
# Dikte — release derleme + .app paketi
# Kullanım: ./build.sh [install]
set -e
cd "$(dirname "$0")"

APP_NAME="Dikte"
BUNDLE_DIR="build/${APP_NAME}.app"

echo "==> Release derleniyor (arm64)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> .app paketi oluşturuluyor…"
rm -rf build
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BIN_DIR}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/"
cp "Resources/Info.plist" "${BUNDLE_DIR}/Contents/"
printf 'APPL????' > "${BUNDLE_DIR}/Contents/PkgInfo"

# İkon varsa ekle (Resources/AppIcon.icns)
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${BUNDLE_DIR}/Contents/Info.plist" 2>/dev/null || true
fi

# İmza: TCC izinleri (mikrofon, sistem sesi, erişilebilirlik) imza kimliğine bağlanır.
# Ad-hoc imza her derlemede değiştiği için izinler düşer; Apple Development kimliği
# varsa onunla imzala ki yeniden derlemede izinler yerinde kalsın.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "${IDENTITY}" ]; then
    echo "==> İmzalanıyor: ${IDENTITY}"
    codesign --force --deep --sign "${IDENTITY}" "${BUNDLE_DIR}"
else
    echo "==> Ad-hoc imzalanıyor (Apple Development kimliği bulunamadı)…"
    codesign --force --deep --sign - "${BUNDLE_DIR}"
fi

echo ""
echo "✅ Hazır: ${BUNDLE_DIR}"

if [ "$1" == "install" ]; then
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${BUNDLE_DIR}" "/Applications/${APP_NAME}.app"
    echo "   Kuruldu → /Applications/${APP_NAME}.app"
else
    echo "   Kurulum: ./build.sh install"
fi
