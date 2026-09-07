#!/usr/bin/env python3
"""Strict aggregate checks; English fallback never satisfies locale coverage."""
import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

website = module('website_localization', 'localize-website.py')
readme = module('readme_localization', 'localize-readmes.py')
read = website.read_json

def validate_app(code, catalog, english):
    if not isinstance(catalog, dict) or set(catalog) != set(english):
        raise ValueError(f'{code}: app missing/extra keys')
    for key, source in english.items():
        value = catalog[key]
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f'{code}:{key}: empty translation')
        if any(0xD800 <= ord(c) <= 0xDFFF or (ord(c) < 32 and c not in '\n\t') or c in '\ufffd\ufffe\uffff' for c in value):
            raise ValueError(f'{code}:{key}: invalid Unicode')
        def syntax(text):
            placeholders = Counter(re.findall(r'\{[0-9]+\}', text))
            remainder = re.sub(r'\{[0-9]+\}', '', text)
            if '{' in remainder or '}' in remainder:
                raise ValueError(f'{code}:{key}: malformed interpolation')
            return placeholders
        if syntax(source) != syntax(value):
            raise ValueError(f'{code}:{key}: changed interpolation')
        for pattern, kind in [(r'https?://[^\s<>]+', 'URL'), (r'PickVia|DuckDuckGo|Safari|HTTPS|HTTP|macOS|mailto', 'technical identifier')]:
            expected, actual = Counter(re.findall(pattern, source)), Counter(re.findall(pattern, value))
            invalid = not set(expected).issubset(actual) if kind == 'technical identifier' else expected != actual
            if invalid:
                raise ValueError(f'{code}:{key}: changed {kind}')

def validate(available=False):
    registry = read(ROOT/'Localization/locales.json')
    codes = [x['code'] for x in registry]
    if len(codes) != 80 or len(set(codes)) != 80 or sum(x['readme'] for x in registry) != 12:
        raise ValueError('Expected 80 unique app/website locales and 12 README locales')
    if {x['code'] for x in registry if x['dir'] == 'rtl'} != {'ar','he','fa','ur'}:
        raise ValueError('Incorrect RTL registry')
    for entry in registry:
        if not entry['name'].strip() or entry['dir'] not in ('ltr','rtl'):
            raise ValueError('Invalid locale registry')
    totals = {}
    for surface in ('app','website'):
        folder = ROOT/'Localization'/surface
        found = {p.stem for p in folder.glob('*.json')}
        if found - set(codes):
            raise ValueError(f'{surface}: unregistered locale catalogs {found-set(codes)}')
        english = read(folder/'en.json')
        done = 0
        for code in codes:
            path = folder/(code+'.json')
            if available and not path.exists():
                continue
            catalog = read(path)
            if code != 'en':
                copied = [key for key, source in english.items() if len(source) > 45 and catalog.get(key) == source]
                if copied:
                    raise ValueError(f'{code}:{surface}: untranslated English prose {copied}')
            (validate_app if surface=='app' else website.validate_catalog)(code, catalog, english)
            done += 1
        totals[surface] = done
        print(f'{surface}: {done}/80 catalogs; {len(english)} keys; structural validation PASS')
    baseline = (ROOT/'Localization/readme/en.md').read_text()
    count = 0
    for entry in registry:
        if not entry['readme']:
            continue
        path = ROOT/'Localization/readme'/(entry['code']+'.md')
        if available and not path.exists():
            continue
        readme.validate(entry['code'], path.read_text(), baseline)
        count += 1
    print(f'README: {count}/12 complete source documents; structure, links and commands PASS')
    return totals

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--available', action='store_true', help='Interim only; report partial coverage truthfully')
    args = parser.parse_args()
    try:
        validate(args.available)
    except (OSError, ValueError, TypeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
