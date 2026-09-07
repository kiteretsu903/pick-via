# PickVia

<!-- Generated language navigation -->
[English](../../README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · **Deutsch** · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [العربية](README.ar.md) · [हिन्दी](README.hi.md)
<!-- End language navigation -->

<p align="center">
  <img src="../../Support/Icons/PickViaArtwork.png" alt="PickVia-App-Symbol" width="128">
</p>

<p align="center"><strong>Öffne Links nicht mehr im falschen Browser oder Profil.</strong></p>

macOS kann das falsche Browserfenster oder Profil wiederverwenden, während jeder
`mailto:`-Link an eine feste Standard-Mail-App geht. PickVia fragt, wo jeder Link
geöffnet werden soll. So wählst du das Browserprofil oder die installierte Mail-App,
die du tatsächlich brauchst.

**[Besuche die PickVia-Website](https://kiteretsu903.github.io/pick-via/)** für
Screenshots, die wichtigsten Neuerungen und den [Versionsverlauf](https://kiteretsu903.github.io/pick-via/changelog.html).

<p align="center">
  <img src="../../docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="PickVia-Browserauswahl mit nativem durchscheinendem macOS-Material" width="900">
</p>

## Sprachen

PickVia v1.5 unterstützt 80 Sprachen für App und Website, einschließlich
Sprachauswahl und Layouts von rechts nach links, sowie 12 README-Sprachen. Wähle
die App-Sprache in den Einstellungen oder verwende die primäre Systemsprache.
Produkt-Screenshots zeigen die englische Oberfläche.

## Download

**[PickVia v1.5 für macOS herunterladen](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia benötigt **macOS 14 Sonoma oder neuer** auf **Apple Silicon** und
verarbeitet HTTP-, HTTPS- und `mailto:`-Links.

## Funktionen

- **Für jeden Weblink einen Browser oder ein Profil wählen.**
- **Für jeden E-Mail-Link eine installierte Mail-App wählen.**
- **Links lokal verarbeiten, ohne einen Verlauf geöffneter Links zu speichern.**

## Mail-Auswahl

<p align="center">
  <img src="../../docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="PickVia-Mail-Auswahl mit nativem durchscheinendem macOS-Material" width="900">
</p>

## Einmal einrichten

In den Einstellungen kannst du Browserziele und registrierte Mail-Apps aktivieren,
deaktivieren, neu anordnen und erneut suchen.

<p align="center">
  <img src="../../docs/screenshots/pickvia-settings@2x.png" alt="PickVia-Browsereinstellungen mit fiktiven Browserprofilen" width="900">
</p>

## Installation

1. Lade `PickVia-v1.5.dmg` aus der
   [GitHub-Veröffentlichung](https://github.com/kiteretsu903/pick-via/releases/latest) herunter und öffne die Datei.
2. Ziehe **PickVia** in den im Installationsfenster angezeigten Ordner **Programme**.
3. Öffne **PickVia** aus „Programme“ und folge der Begrüßungseinrichtung.
4. Wähle **Als Standard festlegen**. macOS fragt getrennt nach der Berechtigung
   zum Verarbeiten von HTTP- und HTTPS-Links.
5. Prüfe bei Bedarf die installierten Mail-Apps und lege PickVia als Standard
   für `mailto:`-Links fest, oder wähle **Mail-Einrichtung überspringen**.

### Erster Start und Gatekeeper

PickVia v1.5 ist mit einem Apple Development-Zertifikat signiert und nicht notarisiert. macOS blockiert möglicherweise
den ersten Start der heruntergeladenen App. Wenn du sie aus der GitHub-Veröffentlichung
heruntergeladen hast und ihr vertraust:

1. Versuche einmal, PickVia zu öffnen, und schließe die Warnmeldung.
2. Öffne **Systemeinstellungen → Datenschutz & Sicherheit** und scrolle zu **Sicherheit**.
3. Klicke auf **Dennoch öffnen** und bestätige mit **Öffnen**. Die Taste ist etwa
   eine Stunde nach dem blockierten Startversuch verfügbar.

Wenn **Dennoch öffnen** nicht verfügbar ist, stelle sicher, dass **PickVia.app**
in „Programme“ liegt, versuche den blockierten Start einmal und führe dann Folgendes aus:

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple beschreibt diese Gatekeeper-Ausnahme und ihre Sicherheitsfolgen unter
[Apps auf dem Mac sicher öffnen](https://support.apple.com/en-asia/102445).

## Browser-Unterstützung

| Browser / Editionen | Profile | Normal | Privates Fenster |
|---|---:|---:|---:|
| Safari | Experimentell | Ja | Nein |
| Safari Technology Preview | Nein | Ja | Nein |
| DuckDuckGo | Nein | Ja | Ja* |
| Chrome Stable / Beta / Dev / Canary, Chromium | Ja | Ja | Ja |
| Edge Stable / Beta / Dev / Canary | Ja | Ja | Ja |
| Brave Stable / Beta / Nightly | Ja | Ja | Ja |
| Vivaldi Stable / Snapshot | Ja | Ja | Ja |
| Firefox Stable / Developer Edition / Nightly | Ja | Ja | Ja |
| Opera, Arc, Orion | Nein | Ja | Nein |

\* DuckDuckGo Privat verwendet isolierte temporäre Daten auf kompatiblen Builds
ohne Sandbox (derzeit die Versionsfamilie 1.203.x). Weder eine DuckDuckGo-Erweiterung
noch Zugriff auf Bedienungshilfen ist erforderlich. Normale DuckDuckGo-Links erfordern
keine bestimmte Version oder Herausgebersignatur. Private Daten werden nach dem
Beenden ihres Browserprozesses gelöscht, sofern PickVia läuft, oder bei einem
späteren Start bzw. Öffnen eines Links.

Jede installierte Edition erscheint als separater Browser mit eigenem Namen und
Symbol. Firefox-Profile, die einer anderen installierten Edition zugeordnet sind,
werden aus der Profilliste dieses Browsers ausgeschlossen. Die Zuordnung folgt
dem von Firefox gespeicherten Anwendungspfad. Bei Profilen mit fehlenden oder
unbekannten Metadaten bleibt das bisherige Ersatzverhalten erhalten; sie können
unter mehr als einer Edition erscheinen.

Standardziele auf Browser-Ebene funktionieren ohne Profilzugriff; nach Erteilen
des Zugriffs werden erkannte Profile ergänzt. Private Fenster sind Optionen auf
Browser-Ebene: Die Kombination eines bestimmten Profils mit privatem Modus wird
nicht unterstützt. Opera, Arc und Orion bieten derzeit nur normales Öffnen von
Links auf App-Ebene.

Die Unterstützung hängt von der Browserversion und dem Startzustand ab.

## Safari-Profile (experimentell)

Aktiviere Profile für Safari Stable in den Browsereinstellungen. Diese optional
aktivierbare Funktion benötigt Berechtigungen für Bedienungshilfen (ab macOS 27:
Gerätesteuerung und Datenzugriff) und Automation. Jeder Link wird in einem neuen
Fenster des ausgewählten Profils geöffnet. Das Öffnen in Safari-Profilen bleibt
experimentell.

Setze für lokale Builds `PICKVIA_SIGNING_IDENTITY` auf den Fingerabdruck deines
Codesignaturzertifikats oder speichere ihn in der ignorierten Datei `.signing-identity`.
Führe anschließend `scripts/build-app.sh` aus. Verwende bei erneuten Builds dieselbe
Identität, damit die App-Identität für macOS-Berechtigungen erhalten bleibt.

## Mail-Unterstützung

PickVia verarbeitet ausschließlich `mailto:`-Links. Es erkennt installierte Apps,
die macOS für E-Mail-Links registriert, und bietet eine Auswahl auf App-Ebene –
keine Konten, Profile, Identitäten oder Verfassungsmodi. In den Mail-Einstellungen
lassen sich registrierte Apps aktivieren, deaktivieren, neu anordnen und erneut
suchen. Die Mail-Einrichtung bleibt während der Ersteinrichtung optional.

## Datenschutz

- Geöffnete URLs werden lokal verarbeitet; PickVia sendet, protokolliert oder speichert sie niemals dauerhaft.
- PickVia greift nicht auf Browserverlauf, Cookies, Sitzungen, gespeicherte Passwörter oder Seiteninhalte zu.
- Die Mail-Auswahl zeigt Empfänger, Betreffzeilen, Nachrichtentexte oder die ursprüngliche `mailto:`-Anfrage weder in einer Vorschau an noch protokolliert oder speichert sie diese dauerhaft.

Entferne erteilte Profilzugriffe unter **Browsereinstellungen → Profilzugriff → Zugriff entfernen**.

Siehe die vollständige [Datenschutzerklärung](https://kiteretsu903.github.io/pick-via/privacy.html).

## Lizenz

MIT. Siehe [LICENSE](../../LICENSE).
