#!/usr/bin/env python3
"""Generate native resources deterministically from reviewed app catalogs."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result

def read(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)

def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--allow-incomplete', action='store_true', help='Development bootstrap only; never release validation.')
    args = parser.parse_args()
    registry = read(ROOT / 'Localization/locales.json')
    baseline = read(ROOT / 'Localization/app/en.json')
    resources = ROOT / 'Sources/PickViaCore/Resources'
    outputs = {resources / 'locales.json': json.dumps(registry, ensure_ascii=False, indent=2) + '\n'}
    import re
    for locale in registry:
        source = ROOT / f'Localization/app/{locale["code"]}.json'
        if not source.exists() and args.allow_incomplete:
            continue
        catalog = read(source)
        if catalog.keys() != baseline.keys():
            raise ValueError(f'{source}: missing or extra keys')
        for key, value in catalog.items():
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f'{source}: empty/non-string translation for {key}')
            value.encode('utf-8', errors='strict')
            if sorted(re.findall(r'\{\d+\}', value)) != sorted(re.findall(r'\{\d+\}', key)):
                raise ValueError(f'{source}: changed placeholders for {key}')
        outputs[resources / f'{locale["code"]}.lproj/Localizable.strings'] = '// Generated; edit Localization/app catalogs.\n' + ''.join(f'{quoted(k)} = {quoted(catalog[k])};\n' for k in sorted(catalog))
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise ValueError(f'Stale generated resource: {path}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
    print(f'App resources: {len(outputs)-1} locale catalogs verified' if args.check else f'Generated {len(outputs)-1} app locale catalogs')

if __name__ == '__main__':
    main()
