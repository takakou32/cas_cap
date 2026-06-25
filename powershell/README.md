# CAS Cap — PowerShell版 使い方

CDP（Chrome DevTools Protocol）経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する。
**外部依存ゼロ**（Windows標準のPowerShellのみ。pip/npm不要）で動作する。

- スクリプト: [`cdp_capture.ps1`](cdp_capture.ps1)
- 設定ファイル: [`../config/config.json`](../config/config.json)（[サンプル](../config/config.sample.json)）

---

## 必要なもの

| 項目 | 要件 |
|------|------|
| OS | Windows 10 / 11 |
| PowerShell | Windows標準（5.1）以上。PowerShell 7も可 |
| ブラウザ | Microsoft Edge（Chromiumベース） |

追加インストールは不要。.NET の `System.Net.WebSockets.ClientWebSocket` で CDP を直接操作する。

---

## セットアップ

設定ファイルを作成する。

```powershell
copy config\config.sample.json config\config.json
```

`config\config.json` を編集して `target_url_keyword` を対象アプリのURLに合わせる（後述の「タブ一覧を確認」で確認可能）。

---

## 実行手順

### 1. Edgeをデバッグポート付きで起動

```powershell
# 付属スクリプトを使う場合（既存Edgeの終了確認つき）
.\scripts\start_edge.ps1

# 手動で起動する場合（まず全Edgeを閉じてから）
Start-Process "msedge.exe" "--remote-debugging-port=9222"
```

> ⚠️ 既にEdgeが起動している状態で起動するとデバッグポートが無視される。**必ず全Edgeを閉じてから**起動すること。

### 2. 認証exeからアプリを起動

通常どおりexeを起動する。アプリがEdgeの新しいタブとして開く。

### 3. タブ一覧を確認

```powershell
.\powershell\cdp_capture.ps1 -List
```

出力例:
```
接続成功。ページ数: 2
  [0] New Tab
      edge://newtab/
  [1] アプリ名
      https://your-app.example.com/
```

ここで表示されたURLの一部を `target_url_keyword` に設定する。

### 4. キャプチャ実行

```powershell
# 設定ファイル（config/config.json）に従って実行
.\powershell\cdp_capture.ps1

# 設定ファイルを指定
.\powershell\cdp_capture.ps1 -Config config/my_config.json

# CDP URL を上書き（設定ファイルの cdp_url より優先）
.\powershell\cdp_capture.ps1 -CdpUrl http://localhost:9333
```

キャプチャ画像は `output/` に `{timestamp}_{name}.png`（巡回時）または `capture_{timestamp}.png`（単発時）形式で保存される。

---

## コマンドライン引数

| 引数 | 別名 | 説明 | デフォルト |
|------|------|------|-----------|
| `-Config <path>` | `-c` | 設定ファイル(JSON)のパス | `config/config.json` |
| `-List` | | タブ一覧を表示して終了 | — |
| `-CdpUrl <url>` | | CDPのURL（設定を上書き） | `http://localhost:9222` |

> PowerShellの引数はシングルダッシュ（`-List`）が基本。`--list` 形式は使えない点に注意。

---

## 設定ファイル

```json
{
  "cdp_url": "http://localhost:9222",
  "target_url_keyword": "your-app-url",
  "output_dir": "output",
  "full_page": true,
  "wait_state": "networkidle",
  "settle_ms": 800,
  "pages": []
}
```

| キー | 説明 |
|------|------|
| `cdp_url` | CDP接続先 |
| `target_url_keyword` | 対象タブのURLに含まれるキーワード |
| `output_dir` | 出力先ディレクトリ |
| `full_page` | ページ全体をキャプチャするか（`false`: 表示領域のみ） |
| `settle_ms` | ページ待機後の追加待ち時間(ms)。`networkidle`の近似に使用 |
| `pages` | 巡回キャプチャ設定（空配列なら現在表示中の画面のみ） |

> `wait_state` キーは互換のため保持しているが、PowerShell版では `document.readyState === 'complete'` 到達 ＋ `settle_ms` 待機で読み込み完了を近似する。

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

| type | 説明 | パラメータ | 実装方式 |
|------|------|-----------|---------|
| `click` | 要素をクリック | `selector` | ページ内JS（`el.click()`） |
| `fill` | テキスト入力 | `selector`, `value` | ページ内JS（value設定＋input/changeイベント） |
| `wait` | 要素の表示を待機 | `selector`, `timeout`(ms) | ページ内JSでポーリング |
| `goto` | URLに遷移 | `url` | `Page.navigate` |
| `select` | セレクトボックス選択 | `selector`, `value` | ページ内JS |
| `keyboard` | キー入力 | `key`（例 `"Enter"`） | ページ内JSで`KeyboardEvent`発火 |

> `click` / `fill` / `select` / `keyboard` はページ内JavaScript（`Runtime.evaluate`）経由で実行する。ネイティブのマウス/キー入力が必要な複雑なケースは [JavaScript版](../js/README.md)（Playwright）を推奨。

---

## 動作の仕組み

1. `Invoke-RestMethod "<cdp_url>/json"` でタブ一覧を取得し、`target_url_keyword` に一致するタブを選ぶ
2. そのタブの `webSocketDebuggerUrl` に `ClientWebSocket` で接続
3. `Page.enable` → アクション実行（`Runtime.evaluate` / `Page.navigate`）→ `Page.captureScreenshot`
4. `full_page` 時は `Page.getLayoutMetrics` でコンテンツ全体サイズを取得し `clip` 指定でキャプチャ
5. 受信したbase64データをデコードしてPNG保存

---

## トラブルシューティング

### スクリプトが実行できない（実行ポリシー）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\powershell\cdp_capture.ps1
```

### `接続エラー: http://localhost:9222`

- Edgeが起動しているか確認: `Get-Process msedge`
- デバッグポートが有効か確認: `Invoke-RestMethod http://localhost:9222/json`
- **全Edgeを閉じてから**デバッグポート付きで起動し直す

### `対象タブが見つかりません`

- `-List` でタブ一覧を確認し、`target_url_keyword` を修正
- exeからアプリが正しく起動しているか確認

### スクリーンショットが真っ白/真っ黒

- `settle_ms` を増やす（例: `1500`）
- `pages` の `actions` に `wait` アクションを追加してコンテンツ表示を待つ
