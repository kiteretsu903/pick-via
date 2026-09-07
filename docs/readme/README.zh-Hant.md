# PickVia

<!-- Generated language navigation -->
[English](../../README.md) · [简体中文](README.zh-Hans.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [العربية](README.ar.md) · [हिन्दी](README.hi.md)
<!-- End language navigation -->

<p align="center">
  <img src="../../Support/Icons/PickViaArtwork.png" alt="PickVia 應用程式圖示" width="128">
</p>

<p align="center"><strong>別再讓連結開啟在錯誤的瀏覽器或設定檔中。</strong></p>

macOS 可能會重複使用錯誤的瀏覽器視窗或設定檔，而每個 `mailto:` 連結都會
交給同一個固定的預設郵件應用程式。PickVia 會詢問每個連結的開啟位置，讓你
選擇真正需要的瀏覽器設定檔或已安裝的郵件應用程式。

**[造訪 PickVia 網站](https://kiteretsu903.github.io/pick-via/)**，查看
螢幕截圖、版本重點與[更新紀錄](https://kiteretsu903.github.io/pick-via/changelog.html)。

<p align="center">
  <img src="../../docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="採用 macOS 原生半透明材質的 PickVia 瀏覽器選擇器" width="900">
</p>

## 語言

PickVia v1.5 的應用程式與網站支援 80 種語言，包含語言選擇器及
從右至左的版面配置，另外提供 12 種 README 語言版本。你可以在「設定」中
選擇應用程式語言，或跟隨系統的主要語言。產品螢幕截圖顯示的是英文介面。

## 下載

**[下載 macOS 版 PickVia v1.5](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia 需要搭載 **Apple Silicon** 的 Mac，作業系統為 **macOS 14 Sonoma 或以上版本**，
可處理 HTTP、HTTPS 與 `mailto:` 連結。

## 功能

- **為每個網頁連結選擇瀏覽器或設定檔。**
- **為每個電子郵件連結選擇已安裝的郵件應用程式。**
- **在本機處理連結，不儲存已開啟連結的歷史紀錄。**

## 郵件選擇器

<p align="center">
  <img src="../../docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="採用 macOS 原生半透明材質的 PickVia 郵件選擇器" width="900">
</p>

## 一次設定

在「設定」中啟用、停用、重新排序及重新掃描瀏覽器目標與已註冊的郵件應用程式。

<p align="center">
  <img src="../../docs/screenshots/pickvia-settings@2x.png" alt="顯示範例瀏覽器設定檔的 PickVia 瀏覽器設定" width="900">
</p>

## 安裝

1. 從 [GitHub 版本發布頁面](https://github.com/kiteretsu903/pick-via/releases/latest)
   下載並開啟 `PickVia-v1.5.dmg`。
2. 將 **PickVia** 拖移至安裝程式中顯示的「**應用程式**」檔案夾。
3. 從「應用程式」開啟 **PickVia**，並依照歡迎流程操作。
4. 選擇「**設為預設值**」。macOS 會分別詢問是否允許處理
   HTTP 與 HTTPS 連結。
5. 你也可以檢查已安裝的郵件應用程式，將 PickVia 設為
   `mailto:` 連結的預設處理程式，或選擇「**略過郵件設定**」。

### 首次啟動與 Gatekeeper

PickVia v1.5 使用 Apple Development 憑證簽署，未經公證。macOS 可能會阻擋下載後的
應用程式首次啟動。如果你是從 GitHub 版本發布頁面下載，且選擇信任它：

1. 嘗試開啟 PickVia 一次，然後關閉警告。
2. 開啟「**系統設定 → 隱私權與安全性**」，並捲動至「**安全性**」。
3. 按一下「**強制打開**」，再確認「**打開**」。這個按鈕會在
   啟動遭阻擋後約一小時內顯示。

如果沒有顯示「**強制打開**」，請確認 **PickVia.app** 位於「應用程式」中，
嘗試啟動一次並讓系統阻擋後，再執行：

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple 在[於 Mac 上安全地開啟 App](https://support.apple.com/en-asia/102445)
中說明了這項 Gatekeeper 例外操作及其安全性影響。

## 瀏覽器支援

| 瀏覽器／版本 | 設定檔 | 一般視窗 | 私密視窗 |
|---|---:|---:|---:|
| Safari | 實驗性 | 是 | 否 |
| Safari Technology Preview | 否 | 是 | 否 |
| DuckDuckGo | 否 | 是 | 是* |
| Chrome Stable / Beta / Dev / Canary、Chromium | 是 | 是 | 是 |
| Edge Stable / Beta / Dev / Canary | 是 | 是 | 是 |
| Brave Stable / Beta / Nightly | 是 | 是 | 是 |
| Vivaldi Stable / Snapshot | 是 | 是 | 是 |
| Firefox Stable / Developer Edition / Nightly | 是 | 是 | 是 |
| Opera、Arc、Orion | 否 | 是 | 否 |

\* DuckDuckGo 私密模式在相容且未使用沙盒的版本中，使用隔離的一次性狀態
（目前為 1.203.x 版本系列）。它不需要 DuckDuckGo 擴充功能或「輔助使用」
權限。一般 DuckDuckGo 連結不要求特定版本或發行者簽章。當 PickVia 執行時，
私密狀態會在其瀏覽器程序結束後清除；也可能在下次啟動或處理連結時清除。

每個已安裝的瀏覽器版本都會以自己的名稱與圖示，顯示為獨立的瀏覽器項目。
與其他已安裝版本關聯的 Firefox 設定檔，不會出現在該瀏覽器的設定檔清單中。
關聯依據是 Firefox 記錄的應用程式路徑；如果設定檔的中繼資料遺失或無法辨識，
則保留現有的後備行為，可能會出現在多個版本之下。

瀏覽器層級的「預設」目標不需要設定檔存取權限即可使用；授予權限後，才會加入
找到的設定檔。私密視窗是瀏覽器層級的選項：不支援將特定設定檔與私密模式
搭配使用。Opera、Arc 與 Orion 目前僅支援應用程式層級的一般連結開啟方式。

支援程度依瀏覽器版本與啟動狀態而異。

## Safari 設定檔（實驗性）

在「瀏覽器設定」中啟用 Safari Stable 設定檔。這項選用功能需要「輔助使用」
（macOS 27 或以上版本稱為「裝置控制與資料存取」）與「自動化」權限。
每個連結都會在所選設定檔的新視窗中開啟。Safari 設定檔的連結開啟功能
仍屬實驗性。

如要在本機建置，請將 `PICKVIA_SIGNING_IDENTITY` 設為程式碼簽署憑證的
指紋，或將其儲存在已忽略的 `.signing-identity` 檔案中，然後執行
`scripts/build-app.sh`。重新建置時請持續使用相同的簽署身分，以保留
macOS 權限所使用的應用程式身分。

## 郵件支援

PickVia 僅處理 `mailto:` 連結，會找出 macOS 已註冊為可處理電子郵件連結的
已安裝應用程式，並提供應用程式層級的選項，而非帳號、設定檔、寄件身分
或撰寫模式。「郵件設定」可啟用、停用、重新排序及重新掃描已註冊的處理程式；
在初始設定流程中，郵件設定仍是選用步驟。

## 隱私權

- 開啟的 URL 都在本機處理；PickVia 不會傳送、記錄或永久儲存這些 URL。
- PickVia 不會存取瀏覽紀錄、Cookie、工作階段、已儲存的密碼或網頁內容。
- 郵件選擇器不會預覽、記錄或永久儲存收件者、主旨、郵件內文，
  或原始的 `mailto:` 請求。

若要移除設定檔存取權限，請前往「**瀏覽器設定 → 設定檔存取權限 → 移除存取權限**」。

請參閱完整的[隱私權政策](https://kiteretsu903.github.io/pick-via/privacy.html)。

## 授權條款

MIT。請參閱 [LICENSE](../../LICENSE)。
