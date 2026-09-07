#!/usr/bin/env python3
"""Embed generated native localization resources into a built macOS app before signing."""
import json
import plistlib
import shutil
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1])
bundle = Path(sys.argv[2])
resources = app / 'Contents/Resources'
registry = json.loads((ROOT / 'Localization/locales.json').read_text())
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleLocalizations'] = [row['code'] for row in registry]
info_path.write_bytes(plistlib.dumps(info, sort_keys=True))
destination = resources / bundle.name
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(bundle, destination)
key = 'Open links in the Safari profile you select, using its newly created window.'
for locale in registry:
    code = locale['code']
    catalog = json.loads((ROOT / f'Localization/app/{code}.json').read_text())
    target = resources / f'{code}.lproj/InfoPlist.strings'
    target.parent.mkdir(parents=True, exist_ok=True)
    # A plist is accepted as a native strings table and avoids manual escaping.
    target.write_bytes(plistlib.dumps({'NSAppleEventsUsageDescription': catalog[key]}, fmt=plistlib.FMT_XML))
print(f'Embedded {len(registry)} app locales and localized permission descriptions')
