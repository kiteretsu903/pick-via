# PickVia

<!-- Generated language navigation -->
[English](../../README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · **Français** · [Deutsch](README.de.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [العربية](README.ar.md) · [हिन्दी](README.hi.md)
<!-- End language navigation -->

<p align="center">
  <img src="../../Support/Icons/PickViaArtwork.png" alt="Icône de l’application PickVia" width="128">
</p>

<p align="center"><strong>N’ouvrez plus vos liens dans le mauvais navigateur ou profil.</strong></p>

macOS peut réutiliser la mauvaise fenêtre ou le mauvais profil de navigateur,
tandis que tous les liens `mailto:` sont envoyés à une seule application de messagerie
par défaut. PickVia vous demande où ouvrir chaque lien, pour que vous choisissiez
le profil de navigateur ou l’application de messagerie installée dont vous avez besoin.

**[Consultez le site de PickVia](https://kiteretsu903.github.io/pick-via/)** pour
voir les captures d’écran, les nouveautés des versions et le [journal des modifications](https://kiteretsu903.github.io/pick-via/changelog.html).

<p align="center">
  <img src="../../docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="Sélecteur de navigateur PickVia avec l’effet translucide natif de macOS" width="900">
</p>

## Langues

PickVia v1.5 prend en charge 80 langues pour l’application et le site web, avec
un sélecteur de langue et des interfaces de droite à gauche, ainsi que 12 langues
pour le README. Choisissez la langue de l’application dans les réglages ou suivez
la langue principale du système. Les captures du produit présentent l’interface en anglais.

## Téléchargement

**[Télécharger PickVia v1.5 pour macOS](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia nécessite **macOS 14 Sonoma ou une version ultérieure** sur **Apple Silicon**
et prend en charge les liens HTTP, HTTPS et `mailto:`.

## Fonctionnalités

- **Choisissez un navigateur ou un profil pour chaque lien web.**
- **Choisissez une application de messagerie installée pour chaque lien d’e-mail.**
- **Traitez les liens localement, sans conserver l’historique des liens ouverts.**

## Sélecteur de messagerie

<p align="center">
  <img src="../../docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="Sélecteur de messagerie PickVia avec l’effet translucide natif de macOS" width="900">
</p>

## Une seule configuration suffit

Activez, désactivez et réorganisez les destinations de navigateur et les applications
de messagerie enregistrées, ou relancez leur détection dans les réglages.

<p align="center">
  <img src="../../docs/screenshots/pickvia-settings@2x.png" alt="Réglages des navigateurs de PickVia avec des exemples fictifs de profils" width="900">
</p>

## Installation

1. Téléchargez et ouvrez `PickVia-v1.5.dmg` depuis la
   [version publiée sur GitHub](https://github.com/kiteretsu903/pick-via/releases/latest).
2. Faites glisser **PickVia** dans le dossier **Applications** affiché dans le programme d’installation.
3. Ouvrez **PickVia** depuis Applications et suivez les étapes d’accueil.
4. Choisissez **Définir par défaut**. macOS demande séparément l’autorisation
   de gérer les liens HTTP et HTTPS.
5. Si vous le souhaitez, examinez vos applications de messagerie installées et
   définissez PickVia comme gestionnaire par défaut des liens `mailto:`, ou choisissez
   **Ignorer la configuration de la messagerie**.

### Premier lancement et Gatekeeper

PickVia v1.5 est signé avec un certificat Apple Development et n’est pas notarié. macOS peut bloquer
le premier lancement de l’application téléchargée. Si vous l’avez téléchargée
depuis la version publiée sur GitHub et décidez de lui faire confiance :

1. Essayez d’ouvrir PickVia une fois et fermez l’avertissement.
2. Ouvrez **Réglages Système → Confidentialité et sécurité** et faites défiler jusqu’à **Sécurité**.
3. Cliquez sur **Ouvrir quand même**, puis confirmez avec **Ouvrir**. Le bouton reste
   disponible pendant environ une heure après la tentative de lancement bloquée.

Si **Ouvrir quand même** n’est pas disponible, vérifiez que **PickVia.app** se trouve
dans Applications, tentez une fois de la lancer malgré le blocage, puis exécutez :

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple décrit ce contournement de Gatekeeper et ses conséquences pour la sécurité dans
[Ouvrir des apps en toute sécurité sur votre Mac](https://support.apple.com/en-asia/102445).

## Navigateurs pris en charge

| Navigateur / éditions | Profils | Normal | Fenêtre privée |
|---|---:|---:|---:|
| Safari | Expérimental | Oui | Non |
| Safari Technology Preview | Non | Oui | Non |
| DuckDuckGo | Non | Oui | Oui* |
| Chrome Stable / Beta / Dev / Canary, Chromium | Oui | Oui | Oui |
| Edge Stable / Beta / Dev / Canary | Oui | Oui | Oui |
| Brave Stable / Beta / Nightly | Oui | Oui | Oui |
| Vivaldi Stable / Snapshot | Oui | Oui | Oui |
| Firefox Stable / Developer Edition / Nightly | Oui | Oui | Oui |
| Opera, Arc, Orion | Non | Oui | Non |

\* DuckDuckGo Privé utilise des données isolées et temporaires avec les versions
compatibles sans bac à sable (actuellement la famille de versions 1.203.x). Il ne
nécessite ni extension DuckDuckGo ni accès d’accessibilité. Les liens DuckDuckGo
normaux ne nécessitent pas de version particulière ni de signature d’éditeur.
Les données privées sont supprimées après l’arrêt du processus du navigateur si
PickVia est en cours d’exécution, ou lors d’un démarrage ou d’une ouverture de lien ultérieurs.

Chaque édition installée apparaît comme un navigateur distinct, avec son propre
nom et sa propre icône. Les profils Firefox associés à une autre édition installée
sont exclus de la liste des profils de ce navigateur. L’association suit le chemin
de l’application enregistré par Firefox ; les profils dont les métadonnées sont
absentes ou non reconnues conservent le comportement de repli existant et peuvent
apparaître sous plusieurs éditions.

Les destinations par défaut au niveau du navigateur fonctionnent sans accès aux
profils ; accorder cet accès ajoute les profils détectés. Les fenêtres privées
sont des choix au niveau du navigateur : il n’est pas possible de combiner un
profil précis avec le mode privé. Opera, Arc et Orion permettent actuellement
uniquement l’ouverture normale au niveau de l’application.

La prise en charge varie selon la version du navigateur et son état au démarrage.

## Profils Safari (expérimental)

Activez les profils Safari Stable dans les réglages des navigateurs. Cette fonction
facultative nécessite les autorisations d’accessibilité (Contrôle des appareils et
accès aux données sous macOS 27 ou version ultérieure) et d’automatisation. Chaque
lien s’ouvre dans une nouvelle fenêtre du profil sélectionné. L’ouverture dans les
profils Safari reste expérimentale.

Pour les compilations locales, définissez `PICKVIA_SIGNING_IDENTITY` avec l’empreinte
de votre certificat de signature de code, ou enregistrez-la dans le fichier ignoré
`.signing-identity`, puis exécutez `scripts/build-app.sh`. Conservez la même identité
lors des recompilations pour préserver l’identité de l’application auprès des
autorisations macOS.

## Messagerie prise en charge

PickVia gère uniquement les liens `mailto:`. Il détecte les applications installées
que macOS enregistre pour les liens d’e-mail et propose des choix au niveau de
l’application, sans choix de compte, de profil, d’identité ou de mode de rédaction.
Les réglages de messagerie permettent d’activer, de désactiver et de réorganiser
les gestionnaires enregistrés, ou de relancer leur détection ; la configuration de
la messagerie reste facultative lors de l’accueil.

## Confidentialité

- Les URL ouvertes sont traitées localement ; PickVia ne les envoie, ne les journalise et ne les conserve jamais.
- PickVia n’accède ni à l’historique de navigation, ni aux cookies, ni aux sessions, ni aux mots de passe enregistrés, ni au contenu des pages.
- Le sélecteur de messagerie n’affiche pas d’aperçu, ne journalise pas et ne conserve pas les destinataires, les objets, les corps des messages ou la demande `mailto:` d’origine.

Retirez les autorisations d’accès aux profils dans **Réglages des navigateurs → Accès aux profils → Retirer l’accès**.

Consultez la [Politique de confidentialité](https://kiteretsu903.github.io/pick-via/privacy.html) complète.

## Licence

MIT. Consultez [LICENSE](../../LICENSE).
