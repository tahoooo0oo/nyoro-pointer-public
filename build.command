#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p '.build/module-cache' 'にょろポインタ.app/Contents/MacOS' 'にょろポインタ.app/Contents/Resources'
/usr/bin/swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" -module-cache-path .build/module-cache \
  -framework AppKit -framework CoreGraphics -framework Carbon \
  NyoroPointer.swift -o 'にょろポインタ.app/Contents/MacOS/NyoroPointer'
/usr/bin/python3 - <<'PY'
import plistlib
from pathlib import Path
plist = {
  'CFBundleExecutable': 'NyoroPointer',
  'CFBundleIdentifier': 'local.taho.NyoroPointer',
  'CFBundleName': 'にょろポインタ',
  'CFBundleDisplayName': 'にょろポインタ',
  'CFBundlePackageType': 'APPL',
  'CFBundleVersion': '1',
  'CFBundleShortVersionString': '1.0',
  'LSUIElement': True,
  'LSMinimumSystemVersion': '13.0',
  'NSHighResolutionCapable': True,
}
Path('にょろポインタ.app/Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
/usr/bin/codesign --force --sign - 'にょろポインタ.app'
'にょろポインタ.app/Contents/MacOS/NyoroPointer' --self-test
print 'できました：にょろポインタ.app をダブルクリックして起動してください。'
