#!/usr/bin/env python3
"""Focused corruption and routing-contract checks for the website generator."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('website', Path(__file__).with_name('localize-website.py'))
website = importlib.util.module_from_spec(spec)
spec.loader.exec_module(website)


class CatalogValidationTests(unittest.TestCase):
    def test_rejects_duplicate_keys(self):
        with self.assertRaisesRegex(ValueError, 'duplicate JSON key'):
            json.loads('{"a":"one","a":"two"}', object_pairs_hook=website.unique_object)

    def test_rejects_incomplete_extra_empty_unicode_and_markup(self):
        english = {'a': 'Wait 5 seconds. <a href="https://example.com">Retry</a> {count}'}
        mutations = [
            {}, {'a': english['a'], 'extra': 'x'}, {'a': ''}, {'a': '\ud800'},
            {'a': english['a'].replace('5', '6')},
            {'a': english['a'].replace('{count}', '{number}')},
            {'a': english['a'].replace('example.com', 'example.org')},
            {'a': english['a'].replace('</a>', '</em>')},
        ]
        for mutation in mutations:
            with self.subTest(mutation=ascii(mutation)), self.assertRaises(ValueError):
                website.validate_catalog('test', mutation, english)

    def test_allows_month_name_to_numeric_month_and_shaped_digits(self):
        website.validate_numbers('test', 'date', 'Effective August 14, 2026', '2026年8月14日')
        website.validate_numbers('test', 'date', '06 SEP 2026', '٢٠٢٦/٠٩/٠٦')
        website.validate_numbers('test', 'date', 'Effective August 14, 2026', '14.08.2026')
        website.validate_numbers('test', 'date', 'Effective August 14, 2026', '2026.08.14')
        website.validate_numbers('test', 'count', 'Use one click', '1 回クリック')
        with self.assertRaises(ValueError):
            website.validate_numbers('test', 'date', '06 SEP 2026', '2026/08/06')


class RenderingTests(unittest.TestCase):
    def setUp(self):
        self.catalog = website.read_json(website.CATALOGS / 'en.json')
        self.registry = [{'code': 'en', 'name': 'English', 'dir': 'ltr'}, {'code': 'ar', 'name': 'العربية', 'dir': 'rtl'}]

    def test_explicit_locale_routes_and_accessibility_label(self):
        self.catalog['index.aria-label.003'] = 'Localized star label'
        template = (website.CATALOGS / 'templates' / 'index.html').read_text()
        rendered = website.build_page(template, 'index.html', self.registry[1], self.registry, self.catalog)
        self.assertIn('<html lang="ar" dir="rtl">', rendered)
        self.assertIn('rel="canonical" href="https://kiteretsu903.github.io/pick-via/ar/"', rendered)
        self.assertIn('hreflang="x-default"', rendered)
        self.assertIn('<option value="../en/"', rendered)
        self.assertIn('<option value="../ar/" lang="ar" dir="rtl" selected>', rendered)
        self.assertIn('aria-label="Localized star label"', rendered)
        self.assertIn('src="../assets/browser-chooser.png"', rendered)
        self.assertNotIn('{{', rendered)

    def test_selector_preserves_secondary_page_and_legacy_root(self):
        template = (website.CATALOGS / 'templates' / 'terms.html').read_text()
        rendered = website.build_page(template, 'terms.html', self.registry[0], self.registry, self.catalog, legacy=True)
        self.assertIn('<option value="ar/terms.html"', rendered)
        self.assertIn('src="assets/icon.png"', rendered)
        self.assertIn('hreflang="ar" href="https://kiteretsu903.github.io/pick-via/ar/terms.html"', rendered)


if __name__ == '__main__':
    unittest.main()
