# PickVia localization sources

The shared `locales.json` registry defines 80 app/website locale variants, their autonyms and direction, and the 12 README memberships. English is included in these counts. Source and generated files are intentionally separate.

- `app/en.json`: canonical app messages (137 keys); translated `<code>.json` files generate native `.strings` resources.
- `website/en.json`: canonical website text (139 keys), including inline markup, metadata and accessibility labels. `website/templates` supplies the four page templates.
- `readme/en.md`: full English README baseline; the 11 other source documents preserve all sections, commands and links.
- `review/<code>.json`: AI translation/review provenance, source hashes and any specific unresolved issues. This is AI review, not a claim of native-speaker or native UI review.

Update English sources before assigning translation changes. Keep the exact key set and interpolation placeholders in sync. Do not use copied English paragraphs as translation filler. Browser names, user labels, URLs, commands and release values must retain their meaning. The generated site explicitly distinguishes development localization from the existing v1.4 download and labels screenshots as English.

Run from the repository root:

```sh
python3 scripts/validate-localizations.py
python3 scripts/generate-app-localizations.py
python3 scripts/localize-website.py
python3 scripts/localize-readmes.py
python3 scripts/generate-app-localizations.py --check
python3 scripts/localize-website.py --check
python3 scripts/localize-readmes.py --check
python3 scripts/test_localization_validation.py
python3 scripts/test_localize_website.py
```

The `--available`/`--allow-incomplete` flags are only interim development helpers. Default validation requires complete coverage; runtime English fallback never counts as a completed translation. Production app builds run complete app generation and embed the native resource bundle and localized permission descriptions before signing with the configured fixed identity.

App runtime details, matching rules and OS-owned dialog limitations are documented in `docs/development/localization.md`. Catalog correctness, build results, browser rendering and native UI interaction are separate evidence levels. Generating translated pages does not deploy them; building an app does not install or release it.
