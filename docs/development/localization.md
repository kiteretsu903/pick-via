# Localization resources and runtime

PickVia's localization registry is `Localization/locales.json`: 80 app and website locales, with 12 README locales. Each row preserves the locale code, native name, direction, and README membership. These locales ship in v1.5.

## App source contract

`Localization/app/en.json` contains 137 English source messages. Every locale catalog must contain precisely these keys; values translate the prose while preserving `{0}`, `{1}` placeholders, brand names, commands, URLs, technical filenames, and numeric meaning. Counts use either count-independent sentences or label/value constructions rather than imposing English singular/plural grammar on other languages.

`python3 scripts/generate-app-localizations.py` validates complete catalogs and generates native `Localizable.strings` under `Sources/PickViaCore/Resources/<code>.lproj`, plus the registry resource. `--check` rejects stale generated resources. `--allow-incomplete` exists only to bootstrap local development while translation assignments are unfinished; it does not fill gaps with copied English and must not be used for release acceptance.

SwiftPM declares English as the development language and processes the resources in PickViaCore. `scripts/build-app.sh` performs complete generation before building and calls `scripts/embed-app-localizations.py` to embed the resource bundle, all 80 `CFBundleLocalizations`, and localized AppleEvents permission explanations in the app's root resource directory. `L10n` first loads the embedded resource bundle from `Contents/Resources`, falling back to `Bundle.module` only for SwiftPM command-line/test builds. This prevents an installed app from depending on a developer build-directory resource path.

The historical `scripts/build-e2e-app.sh` pinned-descriptor helper has not been extended for the new resources. Use the production build for localization Computer Use verification; do not claim that helper currently packages localized resources.

## Language resolution

The persistent UserDefaults key `appLanguage` stores the explicit locale code or `system`. Explicit selection wins. System mode resolves only the first system-preferred language; an unsupported primary preference resolves to English even if a supported language appears later. Existing browser configuration, browser profile IDs, and user labels remain unchanged.

Resolution normalizes underscores, supports `no`→`nb`, `tl`→`fil`, `iw`→`he`, and `in`→`id`, and stops parsing at BCP 47 extension singletons. Explicit scripts override region guesses. Chinese distinguishes Hans/Hant; Portuguese distinguishes Brazil/Portugal. Serbian, Mongolian, and Kazakh use Cyrillic; Punjabi uses Gurmukhi; Azerbaijani and Uzbek use Latin. Explicitly unsupported scripts resolve to English, rather than silently choosing another script.

Every SwiftUI view observes the language preference while retaining its view identity, so disclosures and controls stay open across language changes. Hosting roots inject the active locale and RTL direction; Arabic, Hebrew, Persian, and Urdu are RTL. URLs retain LTR direction. SwiftUI controls use translated strings, while OS-owned permission dialogs and any non-overridable standard file-panel controls follow macOS's own localization policy. PickVia translates its custom folder-panel prompt/message and the AppleEvents explanation shipped for macOS to select.

Errors remain canonical source messages until rendered. Safari discovery stores a count and formats it during rendering. This permits an already-visible error or result to change language without rerunning the action. Generated private-mode suffixes are translated only for unmodified detected labels; browser/profile names and user-edited labels are preserved.

Settings width accounts for translated chooser-size labels measured in the current native font. Chooser width accounts for localized footer controls. Hosting roots clamp resized native windows to their current display's visible frame. Browser option columns accept natural width rather than fixing English-only column sizes. Real long-text, RTL, and complex-script inspection remains a separate native UI verification requirement.

## Verification boundaries

Runtime tests cover registry completeness, primary-only system fallback, aliases, script/region/extension resolution, nonrecursive interpolation, and English resilience. Catalog validation must still report missing resources even though runtime fallback is resilient. Native UI language selection, quit/reopen persistence, open-disclosure updates, and screenshots are separate evidence and must be recorded with the exact tested app build.

Translations and review provenance live alongside the catalogs in `Localization/review`. AI review is the linguistic review used in this rollout; it is not native-speaker review.
