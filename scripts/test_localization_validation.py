#!/usr/bin/env python3
"""Corruption tests for the aggregate localization contract."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('validation', Path(__file__).with_name('validate-localizations.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

class CatalogContractTests(unittest.TestCase):
    def test_missing_extra_empty_duplicate_unicode_rejected(self):
        for value in [{}, {'Hello':'Bonjour','extra':'x'}, {'Hello':''}, {'Hello':'\ufffd'}, {'Hello':'\ud800'}]:
            with self.assertRaises(ValueError):
                v.validate_app('fr',value,{'Hello':'Hello'})
        with self.assertRaises(ValueError):
            v.website.json.loads('{"a":"b","a":"c"}',object_pairs_hook=v.website.unique_object)

    def test_interpolation_and_url_corruption_rejected(self):
        for translated in ['Bonjour {1}','Bonjour {0','Bonjour {name}','Bonjour {0} {1}']:
            with self.assertRaises(ValueError):
                v.validate_app('fr',{'Hello {0}':translated},{'Hello {0}':'Hello {0}'})
        with self.assertRaises(ValueError):
            v.validate_app('fr',{'Visit https://example.org':'Voir https://example.com'},{'Visit https://example.org':'Visit https://example.org'})

    def test_brand_suffixes_and_non_latin_boundaries_are_valid(self):
        v.validate_app('fi',{'About PickVia':'Tietoja PickViasta'},{'About PickVia':'About PickVia'})
        v.validate_app('ja',{'About PickVia':'PickViaについて'},{'About PickVia':'About PickVia'})
        with self.assertRaises(ValueError):
            v.validate_app('fr',{'About PickVia':'À propos de Safari'},{'About PickVia':'About PickVia'})

    def test_readme_command_change_rejected(self):
        source='# App\n\n```sh\ncommand --safe\n```\n'
        with self.assertRaises(ValueError):
            v.readme.validate('fr',source.replace('--safe','--unsafe'),source)

    def test_readme_link_relocation_preserves_external_destinations(self):
        text='[Local](docs/a.md) [Web](https://example.org) [Section](#hello) <img src="Support/a.png">'
        output=v.readme.relocate(text)
        self.assertIn('(../../docs/a.md)',output)
        self.assertIn('(https://example.org)',output)
        self.assertIn('(#hello)',output)
        self.assertIn('src="../../Support/a.png"',output)

if __name__=='__main__':
    unittest.main()
