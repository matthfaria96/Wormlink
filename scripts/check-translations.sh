#!/bin/zsh
# Lista textos da interface que ainda não têm tradução em Resources/en.lproj/Localizable.strings.
# O compilador extrai as chaves (Text("…"), String(localized: "…") etc.) durante um build.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
touch Sources/Wormlink/App/WormlinkApp.swift Sources/WormlinkCore/FileSystem.swift
swift build --target Wormlink -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >"$OUT/build.log" 2>&1 || { grep "error:" "$OUT/build.log"; exit 1; }
python3 - "$OUT" <<'PY'
import glob, json, sys
import subprocess
known = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", "Resources/en.lproj/Localizable.strings"],
                                  capture_output=True, check=True).stdout)
missing = {}
for path in glob.glob(sys.argv[1] + "/*.stringsdata"):
    data = json.load(open(path))
    source = data.get("source", "")
    if "/Sources/Wormlink" not in source:
        continue
    for entries in data["tables"].values():
        for e in entries:
            if e["key"] and e["key"] not in known:
                missing.setdefault(e["key"], f'{source.split("Sources/")[1]}:{e["location"]["startingLine"]}')
for key, where in sorted(missing.items()):
    print(f"{where}: {json.dumps(key, ensure_ascii=False)}")
print(f"{len(missing)} texto(s) sem tradução para o inglês.", file=sys.stderr)
sys.exit(1 if missing else 0)
PY
