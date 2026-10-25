#!/bin/sh
# Gera build/Wormlink.app (release, universal quando possível) com o ícone Liquid Glass e assina ad hoc.
# Uso: ./build-app.sh [--install]   (--install copia o app para /Applications)
set -eu
cd "$(dirname "$0")"

# Os plugins de macro do SwiftUI e o actool vêm com o Xcode, não com as Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if swift build -c release --arch arm64 --arch x86_64 >/tmp/wormlink-build.log 2>&1; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Wormlink"
else
  echo "Build universal indisponível; gerando só para $(uname -m)."
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Wormlink"
fi

APP="build/Wormlink.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Wormlink"
cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Wormlink Disk (extensão File Provider): monta servidores no Finder.
DISK_BIN="$(dirname "$BIN")/WormlinkDisk"
if [ -f "$DISK_BIN" ]; then
  APPEX="$CONTENTS/PlugIns/WormlinkDisk.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$DISK_BIN" "$APPEX/Contents/MacOS/WormlinkDisk"
  cp Resources/Disk/Info.plist "$APPEX/Contents/Info.plist"
fi

# Linha de comando: Contents/SharedSupport/bin/wormlink (o menu Wormlink instala um link em /usr/local/bin).
CLI_BIN="$(dirname "$BIN")/wormlink-cli"
if [ -f "$CLI_BIN" ]; then
  mkdir -p "$CONTENTS/SharedSupport/bin"
  cp "$CLI_BIN" "$CONTENTS/SharedSupport/bin/wormlink"
  strip -x "$CONTENTS/SharedSupport/bin/wormlink" 2>/dev/null || true
  codesign --force --options runtime --identifier app.wormlink.cli --sign - "$CONTENTS/SharedSupport/bin/wormlink"
fi

# Dicionário AppleScript.
cp Resources/Wormlink.sdef "$CONTENTS/Resources/Wormlink.sdef"

# Traduções (o português é a língua de origem; en.lproj traduz a partir dele).
for lproj in Resources/*.lproj; do cp -R "$lproj" "$CONTENTS/Resources/"; done

# Ícone do Icon Composer: Assets.car (camadas com Liquid Glass, modos escuro/tingido/transparente)
# mais AppIcon.icns de reserva para sistemas e ferramentas que não leem o .car.
# Caminhos absolutos: o actool roda como serviço compartilhado e resolve relativos no diretório dele.
# O catálogo traz a cor de destaque (verde do ícone), usada pelo sistema nos controles quando o Mac está em "Multicor".
xcrun actool "$PWD/Resources/AppIcon.icon" "$PWD/Resources/Assets.xcassets" --compile "$PWD/$CONTENTS/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor --target-device mac \
  --output-partial-info-plist /tmp/wormlink-icon.plist >/dev/null

# Ações do Atalhos (App Intents): o SwiftPM gera os .swiftconstvalues, mas não roda o processador
# de metadados que o Xcode roda; fazemos isso aqui para o macOS descobrir as ações.
CONSTS="$(find .build/out/Intermediates.noindex/Wormlink.build/Release -path '*Wormlink-*' -path '*arm64*' -name '*.swiftconstvalues' 2>/dev/null | head -1)"
if [ -n "$CONSTS" ]; then
  WORK="$(mktemp -d)"
  ls "$(dirname "$CONSTS")"/*.swiftconstvalues > "$WORK/consts.txt"
  find "$PWD/Sources/Wormlink" -name '*.swift' > "$WORK/sources.txt"
  xcrun appintentsmetadataprocessor --output "$PWD/$CONTENTS/Resources" \
    --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" --module-name Wormlink \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
    --source-file-list "$WORK/sources.txt" --swift-const-vals-list "$WORK/consts.txt" --force >/dev/null 2>&1 \
    || echo "Aviso: metadados do Atalhos não gerados."
else
  echo "Aviso: .swiftconstvalues não encontrados; ações do Atalhos ficam de fora."
fi

# Licenças: GPL-3 do Wormlink e avisos das bibliotecas incluídas.
mkdir -p "$CONTENTS/Resources/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$CONTENTS/Resources/Licenses/"
cp Vendor/Citadel/LICENSE "$CONTENTS/Resources/Licenses/Citadel-LICENSE.txt"
cp Vendor/swift-nio-ssh/LICENSE.txt "$CONTENTS/Resources/Licenses/swift-nio-ssh-LICENSE.txt"
cp Vendor/swift-nio-ssl/LICENSE.txt "$CONTENTS/Resources/Licenses/swift-nio-ssl-LICENSE.txt"

strip -x "$CONTENTS/MacOS/Wormlink" 2>/dev/null || true

# Sparkle (atualizações dentro do app), com os serviços XPC dele, achado pelo rpath.
mkdir -p "$CONTENTS/Frameworks"
cp -R "$(dirname "$BIN")/Sparkle.framework" "$CONTENTS/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Wormlink" 2>/dev/null || true
codesign --force --options runtime --sign - "$CONTENTS/Frameworks/Sparkle.framework"
cp .build/checkouts/Sparkle/LICENSE "$CONTENTS/Resources/Licenses/Sparkle-LICENSE.txt" 2>/dev/null || true
[ -f "$CONTENTS/PlugIns/WormlinkDisk.appex/Contents/MacOS/WormlinkDisk" ] && strip -x "$CONTENTS/PlugIns/WormlinkDisk.appex/Contents/MacOS/WormlinkDisk" 2>/dev/null || true
[ -d "$CONTENTS/PlugIns/WormlinkDisk.appex" ] && \
  codesign --force --options runtime --entitlements Resources/Disk/Disk.entitlements --sign - "$CONTENTS/PlugIns/WormlinkDisk.appex"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"

echo "Pronto: $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Wormlink.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Wormlink.app
  pluginkit -a /Applications/Wormlink.app/Contents/PlugIns/WormlinkDisk.appex 2>/dev/null || true
  echo "Instalado em /Applications/Wormlink.app"
fi
