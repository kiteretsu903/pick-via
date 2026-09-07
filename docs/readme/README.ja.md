# PickVia

<!-- Generated language navigation -->
[English](../../README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · **日本語** · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [العربية](README.ar.md) · [हिन्दी](README.hi.md)
<!-- End language navigation -->

<p align="center">
  <img src="../../Support/Icons/PickViaArtwork.png" alt="PickViaのアプリアイコン" width="128">
</p>

<p align="center"><strong>リンクを、意図しないブラウザやプロファイルで開かないために。</strong></p>

macOSでは意図しないブラウザウインドウやプロファイルが再利用されることがあり、すべての`mailto:`リンクは固定のデフォルトメールアプリで開きます。PickViaはリンクごとに開く場所を確認するので、必要なブラウザプロファイルやインストール済みメールアプリを選べます。

スクリーンショット、リリースの主な変更点、[変更履歴](https://kiteretsu903.github.io/pick-via/changelog.html)は、**[PickViaのウェブサイト](https://kiteretsu903.github.io/pick-via/)**をご覧ください。

<p align="center">
  <img src="../../docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="macOS標準の半透明マテリアルを使ったPickViaのブラウザ選択画面" width="900">
</p>

## 対応言語

PickVia v1.5は、言語選択と右から左へのレイアウトを含むアプリとウェブサイトの80言語対応、およびREADMEの12言語対応を提供します。アプリの言語は設定で選択するか、システムの第一言語に合わせることができます。製品のスクリーンショットは英語の画面です。

## ダウンロード

**[macOS用PickVia v1.5をダウンロード](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickViaには、**Apple Silicon**搭載Macと**macOS 14 Sonoma以降**が必要です。HTTP、HTTPS、`mailto:`リンクに対応しています。

## できること

- **ウェブリンクごとにブラウザやプロファイルを選択。**
- **メールリンクごとにインストール済みのメールアプリを選択。**
- **開いたリンクの履歴を保存せず、リンクをローカルで処理。**

## メールアプリの選択

<p align="center">
  <img src="../../docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="macOS標準の半透明マテリアルを使ったPickViaのメールアプリ選択画面" width="900">
</p>

## 最初に設定するだけ

設定で、リンクを開くブラウザの選択肢と登録済みメールアプリの有効化、無効化、並べ替え、再スキャンができます。

<p align="center">
  <img src="../../docs/screenshots/pickvia-settings@2x.png" alt="サンプルのブラウザプロファイルを表示したPickViaのブラウザ設定" width="900">
</p>

## インストール

1. [GitHubリリース](https://github.com/kiteretsu903/pick-via/releases/latest)から`PickVia-v1.5.dmg`をダウンロードして開きます。
2. **PickVia**を、インストーラに表示される**アプリケーション**フォルダにドラッグします。
3. アプリケーションから**PickVia**を開き、初期設定の案内に従います。
4. **デフォルトに設定**を選択します。macOSは、HTTPリンクとHTTPSリンクを処理する許可をそれぞれ確認します。
5. 必要に応じてインストール済みメールアプリを確認し、PickViaを`mailto:`リンクのデフォルトの処理アプリに設定します。設定しない場合は**メール設定をスキップ**を選択します。

### 初回起動とGatekeeper

PickVia v1.5はApple Development証明書で署名されており、公証は受けていません。ダウンロードしたアプリの初回起動をmacOSがブロックする場合があります。GitHubリリースからダウンロードし、信頼できると判断した場合は、次の手順で開けます。

1. PickViaを一度開こうとして、警告を閉じます。
2. **システム設定 → プライバシーとセキュリティ**を開き、**セキュリティ**までスクロールします。
3. **このまま開く**をクリックし、確認画面で**開く**を選択します。このボタンは、起動がブロックされてから約1時間表示されます。

**このまま開く**が表示されない場合は、**PickVia.app**がアプリケーションフォルダにあることを確認し、一度起動を試してブロックされた後、次のコマンドを実行します。

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

このGatekeeperの例外操作とセキュリティ上の影響については、Appleの[Macでアプリを安全に開く](https://support.apple.com/en-asia/102445)をご覧ください。

## 対応ブラウザ

| ブラウザ / エディション | プロファイル | 通常 | プライベートウインドウ |
|---|---:|---:|---:|
| Safari | 実験的 | 対応 | 非対応 |
| Safari Technology Preview | 非対応 | 対応 | 非対応 |
| DuckDuckGo | 非対応 | 対応 | 対応* |
| Chrome Stable / Beta / Dev / Canary, Chromium | 対応 | 対応 | 対応 |
| Edge Stable / Beta / Dev / Canary | 対応 | 対応 | 対応 |
| Brave Stable / Beta / Nightly | 対応 | 対応 | 対応 |
| Vivaldi Stable / Snapshot | 対応 | 対応 | 対応 |
| Firefox Stable / Developer Edition / Nightly | 対応 | 対応 | 対応 |
| Opera, Arc, Orion | 非対応 | 対応 | 非対応 |

\* DuckDuckGoのプライベートモードは、対応する非サンドボックス化ビルド（現在は1.203.xリリース系列）で、分離された使い捨てのデータ領域を使用します。DuckDuckGoの拡張機能もアクセシビリティ権限も必要ありません。通常のDuckDuckGoリンクでは、特定のバージョンや発行元の署名は要求しません。プライベートモードのデータは、PickViaの実行中にそのブラウザプロセスが終了した後、または次回の起動時やリンクを開く処理の際に削除されます。

インストールされた各エディションは、それぞれの名前とアイコンを持つ別のブラウザとして表示されます。別のインストール済みエディションに関連付けられたFirefoxプロファイルは、そのブラウザのプロファイル一覧から除外されます。関連付けにはFirefoxが記録したアプリケーションのパスを使います。メタデータがない、または認識できないプロファイルには従来のフォールバック処理が適用され、複数のエディションに表示される場合があります。

ブラウザ単位の「デフォルト」は、プロファイルへのアクセス権限がなくても利用できます。アクセスを許可すると、検出されたプロファイルが追加されます。プライベートウインドウはブラウザ単位で選択します。特定のプロファイルとプライベートモードの組み合わせには対応していません。Opera、Arc、Orionは現在、通常モードでアプリを指定して開く機能のみ対応しています。

対応状況はブラウザのバージョンや起動状態によって異なります。

## Safariプロファイル（実験的）

ブラウザ設定でSafari Stableのプロファイルを有効にできます。この任意で有効にする機能には、アクセシビリティ（macOS 27以降では「デバイス制御とデータアクセス」）とオートメーションの権限が必要です。各リンクは、選択したプロファイルの新しいウインドウで開きます。Safariプロファイルへのリンク振り分けは引き続き実験的な機能です。

ローカルビルドでは、`PICKVIA_SIGNING_IDENTITY`にコード署名証明書のフィンガープリントを設定するか、Gitの追跡対象外の`.signing-identity`ファイルに保存してから、`scripts/build-app.sh`を実行してください。macOSの権限で使用されるアプリの識別情報を維持するため、再ビルドでも同じ署名IDを使ってください。

## メール対応

PickViaは`mailto:`リンクのみを処理します。macOSにメールリンク用として登録されているインストール済みアプリを検出し、アプリ単位の選択肢を表示します。アカウント、プロファイル、差出人ID、作成モードは選択しません。メール設定では、登録済みの処理アプリの有効化、無効化、並べ替え、再スキャンができます。初期設定時のメール設定は任意です。

## プライバシー

- 開いたURLはローカルで処理され、PickViaが送信、ログ記録、永続保存することはありません。
- PickViaは閲覧履歴、Cookie、セッション、保存済みパスワード、ページ内容にアクセスしません。
- メールアプリの選択画面は、宛先、件名、本文、元の`mailto:`リクエストをプレビュー、ログ記録、永続保存しません。

プロファイルへのアクセス許可は、**ブラウザ設定 → プロファイルへのアクセス → アクセスを削除**で解除できます。

詳しくは[プライバシーポリシー](https://kiteretsu903.github.io/pick-via/privacy.html)をご覧ください。

## ライセンス

MIT。[LICENSE](../../LICENSE)をご覧ください。
