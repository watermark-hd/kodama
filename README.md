# コダマ (Kodama)

A lightweight 3-pane web reader for PowerPC Macs (G3/G4/G5) running Mac OS X 10.4 Tiger.

[日本語](#日本語) | [English](#english)

---

## 日本語

PowerPC Mac (G3/G4/G5) 上の Mac OS X 10.4 Tiger 向け、超軽量3ペイン型Webリーダーです。
WebKitを使わず、記事本文を構造化して読みやすく表示することに特化しています。

### これは何か

現代のWebページはJavaScript・広告・巨大な画像だらけで、当時のPowerPC Macでは
まともに開けません。コダマはそれらを一切読み込まず、libxml2でHTMLを解析して
「見出し・本文・画像リンク」だけを抽出し、OS標準のCocoaコンポーネントに
直接描画します。JavaScriptもCSSも実行しないため、G3 450MHz機でも軽快に動作する
ことを目標にしています。

- 左ペイン: 見出し(h1〜h3)の一覧。クリックで本文の該当箇所へジャンプ、
  または(見出しがリンクの場合は)別記事へ直接遷移
- 中央ペイン: 記事本文。画像は`[ 画像N を表示 ]`というリンクに置き換わり、
  クリックした時だけ読み込む
- 右ペイン: クリックした画像のプレビュー。普段は隠れている「隠れ3ペイン」方式
- アドレスバー下に折りたたみ式のブックマークバー
- 日本語/英語のUI切り替え
- ファイルダウンロード(.dmg/.zip/.pdf等)は実際のレスポンスヘッダから判定し、
  保存ダイアログで保存

### 動作要件

- Mac OS X 10.4 (Tiger)、PowerPC G3/G4/G5
- モダンなHTTPS通信のために、[Tigerbrew](https://github.com/mistydemeo/tigerbrew)
  または MacPorts で導入した新しい`curl`が必要です。Tiger標準のシステムcurl
  (OpenSSLが古い)では現代のTLS1.2/1.3サイトへの接続にほぼ失敗します。

### ビルド方法

Xcodeプロジェクトは使わず、Makefileだけで完結します。PowerPC実機(または実機と
SSH接続できる環境)で以下を実行してください。

```sh
make app   # build/Kodama.app が生成されます
make run   # ビルドして起動
```

Xcode 2.5相当のgcc 4.0.0を前提にしています。開発は別のMac(Apple Silicon/Intel)で
行い、`rsync`でPowerPC実機へ転送してビルドする、という運用を想定しています。

### 既知の制限

- HTMLフォーム(検索ボックス等)には対応していません。URL欄に検索語を入力すると
  DuckDuckGoのHTML版検索(`html.duckduckgo.com`)に問い合わせる簡易対応のみです
- サイトごとのナビゲーション除外は簡易的なヒューリスティックのため、
  レイアウトによっては広告・メニュー等が本文に混ざることがあります

---

## English

An ultra-lightweight 3-pane web reader for PowerPC Macs (G3/G4/G5) running Mac OS X
10.4 Tiger. Built without WebKit, focused on turning article pages into a
structured, readable layout.

### What is this

Modern web pages are full of JavaScript, ads, and huge images that a PowerPC Mac
from the mid-2000s simply cannot handle. Kodama loads none of that: it parses the
raw HTML with libxml2, extracts only headings, body text, and image links, and
draws them directly with stock Cocoa components. No JavaScript, no CSS engine —
the goal is to stay usable even on a 450MHz G3.

- Left pane: a list of headings (h1–h3). Click to jump to that spot in the body,
  or to navigate straight to another article if the heading is itself a link
- Center pane: the article body. Images are replaced with `[ Show image N ]`
  links and only fetched on click
- Right pane: a preview of whichever image you clicked. Hidden by default —
  a "hidden third pane" layout
- A collapsible bookmark bar under the address bar
- Japanese/English UI switch, live at runtime
- File downloads (.dmg/.zip/.pdf/etc.) are detected from the actual response
  headers and saved via a save dialog

### Requirements

- Mac OS X 10.4 (Tiger), PowerPC G3/G4/G5
- A modern `curl` binary installed via [Tigerbrew](https://github.com/mistydemeo/tigerbrew)
  or MacPorts, needed for real HTTPS support. Tiger's stock system `curl` ships
  with an ancient OpenSSL that fails against almost every modern TLS 1.2/1.3 site.

### Building

No Xcode project — just a Makefile. Run this on real PowerPC hardware (or
something you can SSH into):

```sh
make app   # produces build/Kodama.app
make run   # build and launch
```

Assumes gcc 4.0.0 (the compiler that shipped with Xcode 2.5). The intended
workflow is: edit on a separate, modern Mac, `rsync` the source over to the
PowerPC machine, and build there.

### Known limitations

- No HTML form support (e.g. search boxes on a page). Typing a non-URL string
  into the address bar falls back to DuckDuckGo's HTML search endpoint
  (`html.duckduckgo.com`) instead
- Per-site navigation stripping is a simple heuristic, so ads/menus can still
  leak into the article body depending on how a given site is marked up

---

## License / ライセンス

MIT License
