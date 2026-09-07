# PickVia

<!-- Generated language navigation -->
[English](../../README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · **한국어** · [Español](README.es.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [العربية](README.ar.md) · [हिन्दी](README.hi.md)
<!-- End language navigation -->

<p align="center">
  <img src="../../Support/Icons/PickViaArtwork.png" alt="PickVia 앱 아이콘" width="128">
</p>

<p align="center"><strong>링크를 잘못된 브라우저나 프로필로 여는 일은 이제 그만.</strong></p>

macOS는 의도하지 않은 브라우저 창이나 프로필을 재사용할 수 있으며, 모든 `mailto:` 링크는
하나의 지정된 기본 메일 앱으로 열립니다. PickVia는 링크를 열 위치를 물어보므로
실제로 필요한 브라우저 프로필이나 설치된 메일 앱을 직접 선택할 수 있습니다.

스크린샷, 주요 릴리스 소식, [변경 내역](https://kiteretsu903.github.io/pick-via/changelog.html)은
**[PickVia 웹사이트](https://kiteretsu903.github.io/pick-via/)**에서 확인하세요.

<p align="center">
  <img src="../../docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="macOS 기본 반투명 소재를 적용한 PickVia 브라우저 선택 창" width="900">
</p>

## 언어

PickVia v1.5.1는 언어 선택기와 오른쪽에서 왼쪽으로 쓰는 언어의 레이아웃을 포함하여
앱과 웹사이트에 80개 언어를, README에 12개 언어를 지원합니다. 설정에서 앱 언어를
선택하거나 시스템의 기본 언어를 따를 수 있습니다. 제품 스크린샷은
영어 인터페이스를 보여 줍니다.

## 다운로드

**[macOS용 PickVia v1.5.1 다운로드](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia를 사용하려면 **Apple Silicon**과 **macOS 14 Sonoma 이상**이 필요하며,
HTTP, HTTPS 및 `mailto:` 링크를 처리합니다.

## 주요 기능

- **웹 링크마다 브라우저나 프로필을 선택합니다.**
- **이메일 링크마다 설치된 메일 앱을 선택합니다.**
- **열었던 링크의 기록을 저장하지 않고 기기 내에서 링크를 처리합니다.**

## 메일 앱 선택

<p align="center">
  <img src="../../docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="macOS 기본 반투명 소재를 적용한 PickVia 메일 앱 선택 창" width="900">
</p>

## 한 번만 설정하세요

설정에서 브라우저 대상과 등록된 메일 앱을 활성화하거나 비활성화하고,
순서를 바꾸거나 다시 검색할 수 있습니다.

<p align="center">
  <img src="../../docs/screenshots/pickvia-settings@2x.png" alt="예시용 브라우저 프로필이 표시된 PickVia 브라우저 설정" width="900">
</p>

## 설치

1. [GitHub 릴리스](https://github.com/kiteretsu903/pick-via/releases/latest)에서
   `PickVia-v1.5.1.dmg`를 다운로드하여 엽니다.
2. **PickVia**를 설치 프로그램에 표시된 **응용 프로그램** 폴더로 드래그합니다.
3. 응용 프로그램에서 **PickVia**를 열고 시작 안내를 따릅니다.
4. **기본값으로 설정**을 선택합니다. macOS는 HTTP와 HTTPS 링크를 처리할 권한을
   각각 별도로 요청합니다.
5. 원하는 경우 설치된 메일 앱을 확인하고 PickVia를 `mailto:` 링크의 기본 처리 앱으로
   설정하거나, **메일 설정 건너뛰기**를 선택합니다.

### 첫 실행과 Gatekeeper

PickVia v1.5.1는 Apple Development 인증서로 서명되어 있으며 공증되지 않았습니다. macOS가 다운로드한 앱의
첫 실행을 차단할 수 있습니다. GitHub 릴리스에서 다운로드한 앱을 신뢰하기로 했다면
다음과 같이 진행하세요.

1. PickVia를 한 번 열어 보고 경고를 닫습니다.
2. **시스템 설정 → 개인정보 보호 및 보안**을 열고 **보안**으로 스크롤합니다.
3. **확인 없이 열기**를 클릭한 다음 **열기**를 눌러 확인합니다. 이 버튼은
   실행이 차단된 시점부터 약 한 시간 동안 표시됩니다.

**확인 없이 열기**를 사용할 수 없다면 **PickVia.app**이 응용 프로그램 폴더에 있는지 확인하고,
한 번 실행하여 차단된 후 다음 명령을 실행하세요.

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple은 이러한 Gatekeeper 예외 허용 방법과 보안에 미치는 영향을
[Mac에서 안전하게 앱 열기](https://support.apple.com/en-asia/102445)에 설명하고 있습니다.

## 브라우저 지원

| 브라우저 / 에디션 | 프로필 | 일반 | 비공개 창 |
|---|---:|---:|---:|
| Safari | 실험적 | 예 | 아니요 |
| Safari Technology Preview | 아니요 | 예 | 아니요 |
| DuckDuckGo | 아니요 | 예 | 예* |
| Chrome Stable / Beta / Dev / Canary, Chromium | 예 | 예 | 예 |
| Edge Stable / Beta / Dev / Canary | 예 | 예 | 예 |
| Brave Stable / Beta / Nightly | 예 | 예 | 예 |
| Vivaldi Stable / Snapshot | 예 | 예 | 예 |
| Firefox Stable / Developer Edition / Nightly | 예 | 예 | 예 |
| Opera, Arc, Orion | 아니요 | 예 | 아니요 |

\* DuckDuckGo 비공개 모드는 호환되는 비샌드박스 빌드에서 버전 제한 없이
격리된 일회성 상태를 사용합니다. DuckDuckGo 확장 프로그램이나 손쉬운 사용 접근 권한은
필요하지 않습니다. 일반 DuckDuckGo 링크에는 특정 버전이나 게시자 서명이 필요하지 않습니다.
비공개 상태는 PickVia가 실행 중일 때 해당 브라우저 프로세스가 종료되면 정리되거나,
다음 시작 또는 링크 라우팅 시 정리됩니다.

설치된 각 에디션은 고유한 이름과 아이콘을 가진 별도의 브라우저로 표시됩니다.
다른 설치된 에디션에 연결된 Firefox 프로필은 해당 브라우저의 프로필 목록에서 제외됩니다.
이 연결은 Firefox가 기록한 응용 프로그램 경로를 따릅니다. 메타데이터가 없거나 인식되지 않는
프로필은 기존 대체 동작을 유지하며 여러 에디션 아래에 표시될 수 있습니다.

브라우저 수준의 기본 대상은 프로필 접근 권한 없이도 작동합니다. 접근 권한을 부여하면
검색된 프로필이 추가됩니다. 비공개 창은 브라우저 수준에서 선택하며, 특정 프로필과
비공개 모드를 함께 사용하는 것은 지원하지 않습니다. Opera, Arc 및 Orion은
현재 일반 앱 수준의 라우팅만 제공합니다.

지원 여부는 브라우저 버전과 시작 상태에 따라 다릅니다.

## Safari 프로필(실험적)

브라우저 설정에서 Safari Stable 프로필을 활성화하세요. 사용자가 선택하여 활성화하는 이 기능에는
손쉬운 사용(macOS 27 이상에서는 기기 제어 및 데이터 접근)과 자동화 권한이 필요합니다.
각 링크는 선택한 프로필의 새 창에서 열립니다. Safari 프로필 라우팅은 여전히 실험적 기능입니다.

로컬 빌드 시 `PICKVIA_SIGNING_IDENTITY`를 코드 서명 인증서의 지문으로 설정하거나,
Git에서 무시되는 `.signing-identity` 파일에 저장한 다음 `scripts/build-app.sh`를 실행하세요.
macOS 권한에 사용되는 앱 ID를 유지하려면 재빌드할 때도 같은 서명 ID를 사용하세요.

## 메일 지원

PickVia는 `mailto:` 링크만 처리합니다. macOS에 이메일 링크 처리용으로 등록된 설치 앱을
검색하여 앱 수준의 선택지를 제공합니다. 계정, 프로필, 발신자 ID 또는 작성 모드를 선택하는
기능은 제공하지 않습니다. 메일 설정에서 등록된 처리 앱을 활성화하거나 비활성화하고,
순서를 바꾸거나 다시 검색할 수 있습니다. 시작 안내 중 메일 설정은 선택 사항입니다.

## 개인정보 보호

- 열린 URL은 기기 내에서 처리되며, PickVia는 URL을 전송하거나 기록하거나 영구 저장하지 않습니다.
- PickVia는 방문 기록, 쿠키, 세션, 저장된 암호 또는 페이지 콘텐츠에 접근하지 않습니다.
- 메일 앱 선택 창은 수신자, 제목, 메시지 본문 또는 원래 `mailto:` 요청을 미리 보거나 기록하거나 영구 저장하지 않습니다.

**브라우저 설정 → 프로필 접근 → 접근 권한 제거**에서 프로필 접근 권한을 제거할 수 있습니다.

전체 [개인정보 처리방침](https://kiteretsu903.github.io/pick-via/privacy.html)을 확인하세요.

## 라이선스

MIT. [LICENSE](../../LICENSE)를 참고하세요.
