#!/usr/bin/env python3
"""Validate catalogs and deterministically render PickVia's static locale routes.

Source: Localization/website/templates/*.html and <locale>.json.
Use --available only for development previews while translations are in progress.
The default requires all 80 catalogs; --check additionally rejects stale output.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
import unicodedata
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
CATALOGS = ROOT / 'Localization/website'
SITE = ROOT / 'site'
BASE = 'https://kiteretsu903.github.io/pick-via/'
PAGES = ('index.html', 'changelog.html', 'privacy.html', 'terms.html')
VOID = {'br', 'wbr', 'img', 'input', 'meta', 'link', 'hr'}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_object)


class Markup(HTMLParser):
    def __init__(self, value):
        super().__init__(convert_charrefs=False)
        self.signature = Counter()
        self.stack = []
        self.text = []
        self.feed(value)
        if self.stack:
            raise ValueError(f'unclosed markup: {self.stack}')

    def handle_starttag(self, tag, attrs):
        self.signature[('tag', tag, tuple(sorted(attrs)))] += 1
        if tag not in VOID:
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            raise ValueError(f'unbalanced markup: {tag}')

    def handle_data(self, value):
        if '<' in value or '>' in value:
            raise ValueError('malformed or unescaped HTML markup')
        self.text.append(value)

    def handle_comment(self, value):
        raise ValueError('unexpected HTML comment')

    def handle_decl(self, value):
        raise ValueError('unexpected HTML declaration')

    def handle_entityref(self, name):
        self.text.append(html.unescape('&' + name + ';'))

    def handle_charref(self, name):
        self.text.append(html.unescape('&#' + name + ';'))


def numeric_tokens(value):
    # Compare meaning across Unicode digits, leading zeros and digit shaping.
    digits = ''.join(str(unicodedata.decimal(c)) if c.isdecimal() else c for c in value)
    return Counter('.'.join(str(int(part)) for part in number.split('.'))
                   for number in re.findall(r'\d+(?:\.\d+)*', digits))


def validate_numbers(locale, key, source, translated):
    # A dotted three-part calendar date is a date here, not a software version.
    if re.search(r'\b(?:aug|august|sep|september)\b', source, re.I):
        translated = re.sub(r'(?<!\d)(\d{1,4})\.(\d{1,2})\.(\d{1,4})(?!\d)', r'\1 \2 \3', translated)
    original, target = numeric_tokens(source), numeric_tokens(translated)
    # Month names may become numeric months (for example 14 August -> 8/14),
    # and the words one/first may legitimately become a digit. These permitted
    # additions are semantic, not arbitrary placeholder-count exemptions.
    optional = Counter()
    months = {'aug': '8', 'august': '8', 'sep': '9', 'september': '9'}
    for month, number in months.items():
        if re.search(r'\b' + month + r'\b', source, re.I):
            optional[number] += 1
    number_words = {'1': 'one|first', '2': 'two|second', '3': 'three|third'}
    for number, words in number_words.items():
        optional[number] += len(re.findall(r'\b(?:' + words + r')\b', source, re.I))
    missing, added = original - target, target - original
    if missing or added - optional:
        raise ValueError(f'{locale}:{key}: altered number/version/date')


def validate_catalog(locale, catalog, english):
    if not isinstance(catalog, dict) or set(catalog) != set(english):
        missing = set(english) - set(catalog)
        extra = set(catalog) - set(english)
        raise ValueError(f'{locale}: missing keys {sorted(missing)}; extra keys {sorted(extra)}')
    for key, source in english.items():
        value = catalog[key]
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f'{locale}:{key}: empty or non-string translation')
        if any(0xD800 <= ord(c) <= 0xDFFF or (ord(c) < 32 and c not in '\n\t') or c in '\ufffd\ufffe\uffff' for c in value):
            raise ValueError(f'{locale}:{key}: invalid Unicode/control character')
        original, translated = Markup(source), Markup(value)
        if original.signature != translated.signature:
            raise ValueError(f'{locale}:{key}: altered HTML tags, attributes or URLs')
        for pattern, description in [(r'\{[^{}]+\}', 'placeholder'), (r'https?://[^\s<>"\']+', 'URL'), (r'mailto:', 'mail protocol')]:
            if Counter(re.findall(pattern, source)) != Counter(re.findall(pattern, value)):
                raise ValueError(f'{locale}:{key}: altered {description}')
        validate_numbers(locale, key, ''.join(original.text), ''.join(translated.text))


def url_for(code, page):
    return BASE + code + '/' + ('' if page == 'index.html' else page)


def build_page(template, page, locale, registry, catalog, *, legacy=False):
    code = locale['code']
    prefix = '' if legacy else '../'
    head = []
    for entry in registry:
        head.append(f'<link rel="alternate" hreflang="{entry["code"]}" href="{url_for(entry["code"], page)}" />')
    head.append(f'<link rel="alternate" hreflang="x-default" href="{BASE + ("" if page == "index.html" else page)}" />')
    for asset, kind in [('localization.css', 'css'), ('localization.js', 'js')]:
        digest = hashlib.sha256((SITE / 'assets' / asset).read_bytes()).hexdigest()[:12]
        address = f'{prefix}assets/{asset}?v={digest}'
        head.append(f'<link rel="stylesheet" href="{address}" />' if kind == 'css' else f'<script src="{address}" defer></script>')
    options = []
    for entry in registry:
        destination = prefix + entry['code'] + '/' + ('' if page == 'index.html' else page)
        selected = ' selected' if entry['code'] == code else ''
        options.append(f'<option value="{destination}" lang="{entry["code"]}" dir="{entry["dir"]}"{selected}>{html.escape(entry["name"])}</option>')
    selector = (f'<div class="shell language-bar"><label for="website-language">{html.escape(catalog["shared.language"])}</label>'
                f'<select id="website-language" aria-label="{html.escape(catalog["shared.languageNavigation"], quote=True)}">'
                + ''.join(options) + '</select></div>')
    result = template.replace('{{locale.head}}', '\n    '.join(head)).replace('{{locale.selector}}', selector)
    # Resolve all markers in two passes. Attribute values are escaped separately
    # from vetted inline HTML, without compiling one expression per catalog key.
    result = re.sub(r'([\w-]+)="\{\{([\w.-]+)\}\}"',
                    lambda match: match[1] + '="' + html.escape(html.unescape(catalog[match[2]]), quote=True) + '"', result)
    result = re.sub(r'\{\{([\w.-]+)\}\}', lambda match: catalog[match[1]], result)
    # This label is nested in a translated HTML block. Its separate key keeps
    # immutable markup validation independent of accessibility translation.
    result = result.replace('aria-label="Give PickVia a star on GitHub"',
                            'aria-label="' + html.escape(catalog['index.aria-label.003'], quote=True) + '"')
    result = result.replace('<html lang="en">', f'<html lang="{code}" dir="{locale["dir"]}">')
    result = re.sub(r'<link rel="canonical" href="[^"]+" />', f'<link rel="canonical" href="{url_for(code, page)}" />', result)
    if not legacy:
        result = result.replace('src="assets/', 'src="../assets/')
    if '{{' in result:
        raise ValueError(f'{code}/{page}: unresolved source marker')
    return result


class PageReferences(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.references = []
        self.ids = set()
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if attributes.get('id'):
            if attributes['id'] in self.ids:
                raise ValueError('duplicate page id: ' + attributes['id'])
            self.ids.add(attributes['id'])
        if tag in {'a', 'link'} and attributes.get('href'):
            self.references.append(attributes['href'])
        if tag in {'img', 'script'} and attributes.get('src'):
            self.references.append(attributes['src'])


def validate_references(expected):
    pages = {path: PageReferences(content) for path, content in expected.items() if path.suffix == '.html'}
    for path, page in pages.items():
        base_url = BASE + path.relative_to(SITE).as_posix()
        for reference in page.references:
            destination = urljoin(base_url, reference)
            if not destination.startswith(BASE):
                continue
            parsed = urlparse(destination)
            relative = unquote(parsed.path[len(urlparse(BASE).path):])
            target = SITE / relative
            if not target.suffix:
                target = target / 'index.html'
            if target not in expected and not target.is_file():
                raise ValueError(f'{path.relative_to(SITE)}: broken local link {reference}')
            if parsed.fragment and target in pages and unquote(parsed.fragment) not in pages[target].ids:
                raise ValueError(f'{path.relative_to(SITE)}: broken anchor {reference}')


def generate(*, available=False, check=False):
    registry = read_json(ROOT / 'Localization/locales.json')
    if len(registry) != 80 or len({entry['code'] for entry in registry}) != 80:
        raise ValueError('registry must contain exactly 80 unique locale codes')
    english = read_json(CATALOGS / 'en.json')
    catalogs = {}
    for entry in registry:
        code = entry['code']
        path = CATALOGS / (code + '.json')
        if available and not path.exists():
            continue
        catalog = read_json(path)
        validate_catalog(code, catalog, english)
        catalogs[code] = catalog
    # A preview lists only actual available translations and never English filler.
    active_registry = [entry for entry in registry if entry['code'] in catalogs]
    expected = {}
    for entry in active_registry:
        for page in PAGES:
            template = (CATALOGS / 'templates' / page).read_text()
            expected[SITE / entry['code'] / page] = build_page(template, page, entry, active_registry, catalogs[entry['code']])
            if entry['code'] == 'en':
                expected[SITE / page] = build_page(template, page, entry, active_registry, catalogs['en'], legacy=True)
    sitemap = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for entry in active_registry:
        for page in PAGES:
            sitemap.append('  <url><loc>' + url_for(entry['code'], page) + '</loc>')
            for alternate in active_registry:
                sitemap.append(f'    <xhtml:link rel="alternate" hreflang="{alternate["code"]}" href="{url_for(alternate["code"], page)}" />')
            sitemap.append(f'    <xhtml:link rel="alternate" hreflang="x-default" href="{BASE + ("" if page == "index.html" else page)}" />')
            sitemap.append('  </url>')
    sitemap.append('</urlset>')
    expected[SITE / 'sitemap.xml'] = '\n'.join(sitemap) + '\n'
    validate_references(expected)
    for path, content in expected.items():
        if check:
            if not path.exists() or path.read_text() != content:
                raise ValueError(f'generated output is stale: {path.relative_to(ROOT)}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
    print(f'Website: {len(catalogs)}/80 complete catalogs; {len(english)} keys each; {len(catalogs) * len(PAGES)} locale pages; deterministic output {"checked" if check else "generated"}.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--available', action='store_true', help='development preview: render only complete available catalogs')
    parser.add_argument('--check', action='store_true', help='validate catalogs and reject stale generated pages')
    args = parser.parse_args()
    try:
        generate(available=args.available, check=args.check)
    except (OSError, ValueError, TypeError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
