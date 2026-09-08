#!/bin/zsh
# Copyright 2026 tahoooo0oo
# SPDX-License-Identifier: Apache-2.0
set -eu
cd -- "${0:A:h}"

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  print -u2 'にょろポインタはmacOS専用です。'
  exit 1
fi
macos_version="$(/usr/bin/sw_vers -productVersion)"
if (( ${macos_version%%.*} < 13 )); then
  print -u2 'macOS 13 Ventura以降が必要です。'
  exit 1
fi
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1 || ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  print -u2 'Xcode Command Line Toolsが必要です。ターミナルで xcode-select --install を実行し、インストール完了後に再実行してください。'
  exit 1
fi

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
/bin/cp LICENSE NOTICE 'にょろポインタ.app/Contents/Resources/'
/usr/bin/codesign --force --sign - 'にょろポインタ.app'
'にょろポインタ.app/Contents/MacOS/NyoroPointer' --self-test
# Refresh this app's Launch Services record after replacing the executable and
# Info.plist; a stale record can make Finder fail with error -10810.
if ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$PWD/にょろポインタ.app"; then
  print -u2 'アプリの登録情報を更新できませんでした。build.commandをもう一度実行してください。'
  exit 1
fi
print 'できました：にょろポインタ.app をダブルクリックして起動してください。'
