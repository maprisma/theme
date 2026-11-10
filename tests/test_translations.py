"""Run with python3 -m unittest discover -s tests. No external dependencies."""
import ast
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODES = ('de', 'fr', 'es', 'it', 'pt', 'nl', 'pl')
CALL = re.compile(r'''\btrf?\(\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')''')


def literal(token):
    # Dart escapes dollar signs; Python and Rust do not need that escape.
    return ast.literal_eval(token.replace(r'\$', '$'))


def source_keys():
    keys = {}
    for folder, suffix in [('flutter_app/lib', '*.dart'),
                           ('packages/maprisma_theme_core/lib', '*.dart'),
                           ('cosmic/helper/src', '*.rs'), ('cosmic/applet/src', '*.rs')]:
        for file in (ROOT / folder).rglob(suffix):
            if file.name == 'translations.g.dart':
                continue
            for match in CALL.finditer(file.read_text()):
                keys.setdefault(literal(match[1]), set()).add(str(file.relative_to(ROOT)))
    return keys


class TranslationsTest(unittest.TestCase):
    def test_all_literal_keys_have_seven_translations(self):
        keys = source_keys()
        self.assertGreater(len(keys), 500)
        for code in CODES:
            base = json.loads((ROOT / f'translations/{code}.json').read_text())
            extra = json.loads((ROOT / f'translations/extra/{code}.json').read_text())
            catalog = {**base, **extra}
            for key, files in keys.items():
                with self.subTest(language=code, key=key, files=files):
                    self.assertIsInstance(catalog.get(key), str)
                    self.assertTrue(catalog.get(key))
                    # Argument order may change; argument identities must not.
                    self.assertEqual(set(re.findall(r'\{\d+\}', key)),
                                     set(re.findall(r'\{\d+\}', catalog.get(key, ''))))

    def test_generated_source_is_current(self):
        file = ROOT / 'packages/maprisma_theme_core/lib/src/translations.g.dart'
        before = file.read_bytes()
        subprocess.run([str(ROOT / 'tools/gen-translations')], check=True)
        self.assertEqual(before, file.read_bytes())

    def test_desktop_entries(self):
        for file in list((ROOT / 'packaging').glob('*.desktop')) + list((ROOT / 'cosmic/applet/data').glob('*.desktop')):
            text = file.read_text()
            for code in CODES:
                self.assertIn(f'Name[{code}]=', text)
                self.assertIn(f'Comment[{code}]=', text)


if __name__ == '__main__':
    unittest.main()
