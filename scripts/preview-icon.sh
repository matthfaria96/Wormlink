#!/bin/sh
# Renderiza todas as variantes do AppIcon.icon com o ictool do Icon Composer.
# Uso: scripts/preview-icon.sh <pasta-de-saída> [tamanho]
set -eu
cd "$(dirname "$0")/.."
OUT="${1:?pasta de saída}"; SIZE="${2:-512}"
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
mkdir -p "$OUT"
for R in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$IC" Resources/AppIcon.icon --export-image --output-file "$OUT/$R.png" --platform macOS \
    --rendition "$R" --width "$SIZE" --height "$SIZE" --scale 1 >/dev/null
done
echo "Prévias em $OUT"
