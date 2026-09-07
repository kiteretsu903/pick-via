# PickVia

<p align="center">
  <img src="Support/Icons/PickViaArtwork.png" alt="PickVia 应用图标" width="128">
</p>

<p align="center"><strong>别再让链接打开在错误的浏览器或个人资料中。</strong></p>

macOS 可能会重复使用错误的浏览器窗口或个人资料，而所有 `mailto:` 链接
都只会打开同一个默认邮件应用。PickVia 会询问每个链接的打开方式，让你
选择真正需要的浏览器个人资料或已安装的邮件应用。

**[访问 PickVia 网站](https://kiteretsu903.github.io/pick-via/)**，查看
截图、版本亮点和[更新日志](https://kiteretsu903.github.io/pick-via/changelog.html)。

<p align="center">
  <img src="docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="采用 macOS 原生半透明材质的 PickVia 浏览器选择器" width="900">
</p>

## 语言

PickVia v1.5 的应用和网站支持 80 种语言，包括语言选择器和从右到左的布局，
并提供 12 种语言的 README。可在设置中选择应用语言，或跟随系统的首选语言。
产品截图展示的是英文界面。

## 下载

**[下载适用于 macOS 的 PickVia v1.5](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia 要求使用搭载 **Apple Silicon** 的 Mac，系统为 **macOS 14 Sonoma 或更新版本**，
可处理 HTTP、HTTPS 和 `mailto:` 链接。

## 功能

- **为每个网页链接选择浏览器或个人资料。**
- **为每个电子邮件链接选择已安装的邮件应用。**
- **在本地处理链接，不保存已打开链接的历史记录。**

## 邮件选择器

<p align="center">
  <img src="docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="采用 macOS 原生半透明材质的 PickVia 邮件选择器" width="900">
</p>

## 一次设置即可

在设置中启用、停用、重新排序和重新扫描浏览器目标及已注册的邮件应用。

<p align="center">
  <img src="docs/screenshots/pickvia-settings@2x.png" alt="包含示例浏览器个人资料的 PickVia 浏览器设置" width="900">
</p>

## 安装

1. 从 [GitHub 发行版](https://github.com/kiteretsu903/pick-via/releases/latest)
   下载并打开 `PickVia-v1.5.dmg`。
2. 将 **PickVia** 拖到安装窗口中显示的**应用程序**文件夹。
3. 从“应用程序”打开 **PickVia**，然后按照欢迎向导操作。
4. 选择**设为默认**。macOS 会分别询问是否允许处理 HTTP 和 HTTPS 链接。
5. 你还可以查看已安装的邮件应用，并将 PickVia 设为 `mailto:` 链接的默认处理程序，
   或选择**跳过邮件设置**。

### 首次启动与 Gatekeeper

PickVia v1.5 使用 Apple Development 证书签名，未经公证。macOS 可能会阻止下载的应用首次启动。
如果你从 GitHub 发行版下载该应用并决定信任它：

1. 尝试打开 PickVia 一次，然后关闭警告。
2. 打开**系统设置 → 隐私与安全性**，滚动到**安全性**。
3. 点击**仍要打开**，然后点击**打开**确认。此按钮在启动被阻止后大约一小时内可用。

如果没有**仍要打开**选项，请确认 **PickVia.app** 位于“应用程序”文件夹中，
尝试启动一次以触发阻止，然后运行：

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple 在[安全地打开 Mac 上的 App](https://support.apple.com/en-asia/102445) 中
介绍了这种绕过 Gatekeeper 的方法及其安全影响。

## 浏览器支持

| 浏览器 / 版本渠道 | 个人资料 | 普通窗口 | 隐私窗口 |
|---|---:|---:|---:|
| Safari | 实验性 | 是 | 否 |
| Safari Technology Preview | 否 | 是 | 否 |
| DuckDuckGo | 否 | 是 | 是* |
| Chrome Stable / Beta / Dev / Canary、Chromium | 是 | 是 | 是 |
| Edge Stable / Beta / Dev / Canary | 是 | 是 | 是 |
| Brave Stable / Beta / Nightly | 是 | 是 | 是 |
| Vivaldi Stable / Snapshot | 是 | 是 | 是 |
| Firefox Stable / Developer Edition / Nightly | 是 | 是 | 是 |
| Opera、Arc、Orion | 否 | 是 | 否 |

\* DuckDuckGo 隐私模式在兼容的非沙盒版本（目前为 1.203.x 系列）中使用相互隔离、
用后清理的状态数据。不需要 DuckDuckGo 扩展或辅助功能权限。普通 DuckDuckGo 链接
不要求特定版本或发布者签名。PickVia 运行期间，隐私浏览器进程退出后会清理其状态数据；
否则会在后续启动或处理链接时清理。

每个已安装的版本渠道都会显示为独立的浏览器，拥有自己的名称和图标。
Firefox 个人资料如果关联到另一个已安装的版本渠道，就不会出现在当前浏览器的
个人资料列表中。关联关系依据 Firefox 记录的应用路径确定；元数据缺失或无法识别的
个人资料仍沿用现有的后备处理方式，可能会出现在多个版本渠道下。

浏览器级别的默认目标不需要个人资料访问权限；授予访问权限后，会添加发现的个人资料。
隐私窗口是浏览器级别的选项：不支持同时选择指定个人资料和隐私模式。
Opera、Arc 和 Orion 目前仅支持应用级别的普通链接打开方式。

支持情况因浏览器版本和启动状态而异。

## Safari 个人资料（实验性）

在浏览器设置中启用 Safari Stable 个人资料。此功能需要主动启用，并要求辅助功能
（macOS 27 或更新版本中称为“设备控制与数据访问”）和自动化权限。
每个链接都会在所选个人资料的新窗口中打开。Safari 个人资料链接打开功能仍处于实验阶段。

进行本地构建时，将 `PICKVIA_SIGNING_IDENTITY` 设置为代码签名证书的指纹，
或将其保存到被 Git 忽略的 `.signing-identity` 文件中，然后运行
`scripts/build-app.sh`。重新构建时请使用同一签名身份，以保持 macOS 权限所对应的
应用身份不变。

## 邮件支持

PickVia 仅处理 `mailto:` 链接，会发现 macOS 已注册为电子邮件链接处理程序的
已安装应用，并提供应用级别的选择，不涉及账户、个人资料、身份或撰写模式。
邮件设置可用于启用、停用、重新排序和重新扫描已注册的处理程序；首次设置时
可以跳过邮件设置。

## 隐私

- 已打开的 URL 均在本地处理；PickVia 从不发送、记录或持久保存这些 URL。
- PickVia 不访问浏览历史、Cookie、会话、已保存的密码或网页内容。
- 邮件选择器不会预览、记录或持久保存收件人、主题、邮件正文或原始 `mailto:` 请求。

在**浏览器设置 → 个人资料访问 → 移除访问权限**中撤销个人资料访问授权。

请参阅完整的[隐私政策](https://kiteretsu903.github.io/pick-via/privacy.html)。

## 许可证

MIT。参阅 [LICENSE](LICENSE)。
