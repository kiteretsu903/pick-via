#!/usr/bin/env python3
"""Generate complete translated READMEs with consistent navigation and working links."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Localization/readme'

def contract(text):
    return {
        'headings': Counter(len(m[1]) for m in re.finditer(r'^(#+) ', text, re.M)),
        'tables': len(re.findall(r'^\|', text, re.M)),
        'fences': re.findall(r'```[^\n]*\n.*?```', text, re.S),
        'code': Counter(re.findall(r'(?<!`)`([^`\n]+)`(?!`)', text)),
        'links': Counter(re.findall(r'\]\(([^)]+)\)', text)),
        'images': Counter(re.findall(r'\bsrc="([^"]+)"', text)),
    }

def validate(code, text, english):
    if not text.strip() or '\ufffd' in text or any(0xD800 <= ord(c) <= 0xDFFF for c in text):
        raise ValueError(f'{code}: empty or invalid Unicode')
    baseline, actual = contract(english), contract(text)
    for field in baseline:
        if baseline[field] != actual[field]:
            raise ValueError(f'{code}: changed README {field}')

def navigation(registry, current):
    links = []
    for entry in registry:
        code = entry['code']
        if code == current:
            links.append('**' + entry['name'] + '**')
        else:
            target = ('README.md' if code == 'en' else f'docs/readme/README.{code}.md') if current == 'en' else ('../../README.md' if code == 'en' else f'README.{code}.md')
            links.append(f'[{entry["name"]}]({target})')
    return '<!-- Generated language navigation -->\n' + ' · '.join(links) + '\n<!-- End language navigation -->'

def relocate(text):
    def adjust(value):
        if re.match(r'^[a-zA-Z][a-zA-Z\d+.-]*:', value) or value.startswith(('#', '/')):
            return value
        return '../../' + value
    text = re.sub(r'(\]\()([^)]+)(\))', lambda m: m[1] + adjust(m[2]) + m[3], text)
    return re.sub(r'(\bsrc=")([^"]+)(")', lambda m: m[1] + adjust(m[2]) + m[3], text)

def generate(available=False, check=False):
    registry = [x for x in json.loads((ROOT/'Localization/locales.json').read_text()) if x['readme']]
    if len(registry) != 12:
        raise ValueError('Expected exactly 12 README locales')
    english = (SOURCE/'en.md').read_text()
    ready = [x for x in registry if (SOURCE/(x['code']+'.md')).exists()]
    if not available and len(ready) != 12:
        raise ValueError('Missing README locales: ' + ', '.join(x['code'] for x in registry if x not in ready))
    for entry in ready:
        code = entry['code']
        text = (SOURCE/(code+'.md')).read_text()
        validate(code, text, english)
        if code != 'en':
            text = relocate(text)
        first, rest = text.split('\n', 1)
        output = first + '\n\n' + navigation(ready, code) + '\n' + rest
        destination = ROOT/'README.md' if code == 'en' else ROOT/'docs/readme'/f'README.{code}.md'
        if check:
            if not destination.exists() or destination.read_text() != output:
                raise ValueError(f'Stale README: {destination}')
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(output)
    print(f'README: {len(ready)}/12 complete translations; structure, links and commands validated; output {"checked" if check else "generated"}.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--available', action='store_true')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        generate(args.available, args.check)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
