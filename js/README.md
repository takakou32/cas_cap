# CAS Cap — JavaScript版 使い方

CDP（Chrome DevTools Protocol）経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する。
Node.js + Playwright ベースで、`networkidle` 待機やネイティブ入力などを安定してサポートする。

- スクリプト: [`cdp_capture.js`](cdp_capture.js)
- 設定ファイル: [`../config/config.json`](../config/config.json)（[サンプル](../config/config.sample.json)）

---

## 必要なもの

| 項目 | 要件 |
|------|------|
| Node.js | 18 以上 |
| ブラウザ | Microsoft Edge（Chromiumベース） |
| 依存パッケージ | `playwright`（`npm install` で導入） |

---

## セットアップ

```powershell
# 1. 依存パッケージのインストール
cd js
npm install

# 2. Playwrightのブラウザバイナリを取得（キャプチャ処理に必要）
npx playwright install chromium
cd ..

# 3. 設定ファイルを作成
copy config\config.sample.json config\config.json
```

`config\config.json` を編集して `target_url_keyword` を対象アプリのURLに合わせる。

---

## 実行手順

### 1. Edgeをデバッグポート付きで起動

```powershell
# 付属スクリプトを使う場合
.\scripts\start_edge.ps1

# 手動で起動する場合（まず全Edgeを閉じてから）
Start-Process "msedge.exe" "--remote-debugging-port=9222"
```

> ⚠️ 既にEdgeが起動している状態で起動するとデバッグポートが無視される。**必ず全Edgeを閉じてから**起動すること。

### 2. 認証exeからアプリを起動

通常どおりexeを起動する。アプリがEdgeの新しいタブとして開く。

### 3. タブ一覧を確認

```bash
node js/cdp_capture.js --list
# または: cd js && npm run list
```

出力例:
```
接続成功。コンテキスト数: 1
  [0] New Tab
      edge://newtab/
  [1] アプリ名
      https://your-app.example.com/
```

ここで表示されたURLの一部を `target_url_keyword` に設定する。

### 4. キャプチャ実行

```bash
# 設定ファイル（config/config.json）に従って実行
node js/cdp_capture.js
# または: cd js && npm start

# 設定ファイルを指定
node js/cdp_capture.js -c config/my_config.json

# CDP URL を上書き
node js/cdp_capture.js --cdp-url http://localhost:9333
```

キャプチャ画像は `output/` に `{timestamp}_{name}.png`（巡回時）または `capture_{timestamp}.png`（単発時）形式で保存される。

---

## コマンドライン引数

| 引数 | 別名 | 説明 | デフォルト |
|------|------|------|-----------|
| `--config <path>` | `-c` | 設定ファイル(JSON)のパス | `config/config.json` |
| `--list` | | タブ一覧を表示して終了 | — |
| `--cdp-url <url>` | | CDPのURL（設定を上書き） | `http://localhost:9222` |
| `--help` | `-h` | 使い方を表示 | — |

> パスは実行時のカレントディレクトリ基準。リポジトリルートから `node js/cdp_capture.js` で実行する想定。

---

## npm スクリプト

`js/package.json` には以下のショートカットを用意している（`cd js` 後に実行）。

| コマンド | 内容 |
|----------|------|
| `npm start` | `node cdp_capture.js`（キャプチャ実行） |
| `npm run list` | `node cdp_capture.js --list`（タブ一覧） |

---

## 設定ファイル

```json
{
  "cdp_url": "http://localhost:9222",
  "target_url_keyword": "your-app-url",
  "output_dir": "output",
  "full_page": true,
  "wait_state": "networkidle",
  "pages": []
}
```

| キー | 説明 |
|------|------|
| `cdp_url` | CDP接続先 |
| `target_url_keyword` | 対象タブのURLに含まれるキーワード |
| `output_dir` | 出力先ディレクトリ |
| `full_page` | ページ全体をキャプチャするか（`false`: 表示領域のみ） |
| `wait_state` | 読み込み待機（`networkidle` / `load` / `domcontentloaded`） |
| `pages` | 巡回キャプチャ設定（空配列なら現在表示中の画面のみ） |

> `settle_ms` キーはPowerShell版専用。JavaScript版では Playwright の `waitForLoadState(wait_state)` を使うため不要（記述しても無視される）。

### 巡回キャプチャ

```json
{
  "pages": [
    { "name": "top", "actions": [] },
    {
      "name": "search_result",
      "actions": [
        { "type": "fill", "selector": "input#search", "value": "検索ワード" },
        { "type": "click", "selector": "button#search-btn" },
        { "type": "wait", "selector": ".result-table" }
      ]
    }
  ]
}
```

### アクション一覧

| type | 説明 | パラメータ |
|------|------|-----------|
| `click` | 要素をクリック | `selector` |
| `fill` | テキスト入力 | `selector`, `value` |
| `wait` | 要素の表示を待機 | `selector`, `timeout`(ms、省略時5000) |
| `goto` | URLに遷移 | `url` |
| `select` | セレクトボックス選択 | `selector`, `value` |
| `keyboard` | キー入力 | `key`（例 `"Enter"`、`"Tab"`） |

各アクションは Playwright のネイティブAPI（`page.click` / `page.fill` / `page.selectOption` / `page.keyboard.press` など）で実行される。

---

## トラブルシューティング

### `Cannot find module 'playwright'`

依存パッケージが未インストール。`cd js && npm install` を実行する。

### スクリーンショットが撮れない / ブラウザエラー

`npx playwright install chromium` でブラウザバイナリを導入する。

### `対象タブが見つかりません`

- `--list` でタブ一覧を確認し、`target_url_keyword` を修正
- exeからアプリが正しく起動しているか確認

### CDPに接続できない

- Edgeが起動しているか確認: `Get-Process msedge`
- デバッグポートが有効か確認: `Invoke-RestMethod http://localhost:9222/json`
- **全Edgeを閉じてから**デバッグポート付きで起動し直す

### スクリーンショットが真っ白/真っ黒

- `wait_state` を `"networkidle"` に設定（デフォルト）
- `pages` の `actions` に `wait` アクションを追加
