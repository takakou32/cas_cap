# CAS Cap

CDP（Chrome DevTools Protocol）経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを自動取得するツール。

認証型exeからブラウザを起動する方式のアプリケーションで、従来のBitBlt/PrintScreen方式ではキャプチャできない問題を解決する。

## 仕組み

```
[Edge + デバッグポート] ← CDP接続 ← [CAS Cap (本ツール)]
        ↑
   [認証exe] がタブを追加
```

1. Edgeをデバッグポート付きで起動
2. 認証exeがそのEdgeインスタンスにタブを追加
3. 本ツールがCDP経由でEdgeに接続し、対象タブを操作＋キャプチャ

ブラウザのレンダリングエンジンから直接スクリーンショットを取得するため、ハードウェアアクセラレーションやBitBltの制約を受けない。

## 実装バリエーション

同じ機能を3つの実装で提供する。**それぞれ単体で動作**し、互いに依存しない。用途に合わせて1つを選べばよい。
各実装の詳しい使い方は、それぞれの使い方ドキュメント（下表「使い方」列）を参照。

| 実装 | 使い方 | 必要なもの | 特徴 |
|------|--------|-----------|------|
| **PowerShell** | [powershell/README.md](powershell/README.md) | Windows標準のPowerShellのみ | **外部依存ゼロ**。.NETの`ClientWebSocket`でCDPを直接操作 |
| **JavaScript** | [js/README.md](js/README.md) | Node.js + Playwright | Playwrightベースで安定。`networkidle`待機などをフルサポート |
| Python（オリジナル） | [src/README.md](src/README.md) | Python + Playwright | 元実装 |

設定ファイルは **JSON**（`config/config.json`）を PowerShell版・JavaScript版で共通利用する。
（Python版は従来どおり `config/config.yaml` を使用）

## 前提条件

- Microsoft Edge（Chromiumベース）
- 認証exeがシステムのEdgeを利用する構成であること
- 実装に応じて以下のいずれか:
  - PowerShell版: 追加インストール不要（Windows 10/11 標準）
  - JavaScript版: Node.js 18+
  - Python版: Python 3.10+

---

## セットアップ

### 共通: 設定ファイルの作成

```powershell
# PowerShell版 / JavaScript版（JSON）
copy config\config.sample.json config\config.json

# Python版（YAML）
copy config\config.sample.yaml config\config.yaml
```

### PowerShell版

追加セットアップは不要。

### JavaScript版

```powershell
cd js
npm install
npx playwright install chromium
cd ..
```

### Python版

```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
playwright install chromium
```

---

## 設定

`config/config.json` を編集する（Python版は `config/config.yaml`）。

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
| `output_dir` | キャプチャ出力先ディレクトリ |
| `full_page` | ページ全体をキャプチャするか（`false`: 表示領域のみ） |
| `wait_state` | ページ読み込み待機（`networkidle` / `load` / `domcontentloaded`）。JS/Python版で使用 |
| `settle_ms` | 待機後の追加待ち時間(ms)。PowerShell版での`networkidle`近似に使用 |
| `pages` | 巡回キャプチャ設定（省略・空配列なら現在表示中の画面のみ） |

### 巡回キャプチャ設定

複数画面を自動で巡回してキャプチャする場合は `pages` を設定する。

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
    },
    {
      "name": "detail",
      "actions": [
        { "type": "click", "selector": ".result-table tr:first-child a" }
      ]
    }
  ]
}
```

キャプチャ画像は `output/` に `{timestamp}_{name}.png` 形式で保存される。

### アクション一覧

| type | 説明 | パラメータ |
|------|------|-----------|
| `click` | 要素をクリック | `selector` |
| `fill` | テキスト入力 | `selector`, `value` |
| `wait` | 要素の表示を待機 | `selector`, `timeout`(ms) |
| `goto` | URLに遷移 | `url` |
| `select` | セレクトボックス選択 | `selector`, `value` |
| `keyboard` | キー入力 | `key`（例: `"Enter"`, `"Tab"`） |

> PowerShell版の `click` / `fill` / `select` / `keyboard` はページ内JavaScript（`Runtime.evaluate`）経由で実行する。複雑なネイティブ入力が必要な場合はJavaScript版（Playwright）を推奨。

---

## 使い方

### 1. Edgeをデバッグポート付きで起動

```powershell
# PowerShellスクリプトを使う場合
.\scripts\start_edge.ps1

# 手動で起動する場合（まず全Edgeを閉じてから）
Start-Process "msedge.exe" "--remote-debugging-port=9222"
```

### 2. 認証exeからアプリを起動

通常通りexeを起動する。アプリがEdgeの新しいタブとして開く。

### 3. タブ一覧を確認

```powershell
# PowerShell版
.\powershell\cdp_capture.ps1 -List

# JavaScript版
node js/cdp_capture.js --list

# Python版
python src/cdp_capture.py --list
```

出力例:
```
接続成功。ページ数: 2
  [0] New Tab - edge://newtab/
  [1] アプリ名 - https://your-app.example.com/
```

`target_url_keyword` に設定するキーワードをここで確認する。

### 4. キャプチャ実行

```powershell
# PowerShell版
.\powershell\cdp_capture.ps1
.\powershell\cdp_capture.ps1 -Config config/my_config.json
.\powershell\cdp_capture.ps1 -CdpUrl http://localhost:9333

# JavaScript版
node js/cdp_capture.js
node js/cdp_capture.js -c config/my_config.json
node js/cdp_capture.js --cdp-url http://localhost:9333

# Python版
python src/cdp_capture.py
python src/cdp_capture.py -c config/my_config.yaml
```

---

## トラブルシューティング

### CDPに接続できない

```
接続エラー: http://localhost:9222
```

- Edgeが起動しているか確認: `Get-Process msedge`
- デバッグポートが有効か確認: `Invoke-RestMethod http://localhost:9222/json`
- **全Edgeを閉じてから**デバッグポート付きで起動し直す（既存インスタンスがある状態で起動するとデバッグポートが無視される）

### 対象タブが見つからない

```
対象タブが見つかりません
```

- `-List` / `--list` でタブ一覧を確認し、`target_url_keyword` を修正
- exeからアプリが正しく起動しているか確認

### スクリーンショットが真っ白/真っ黒

- JS/Python版: `wait_state` を `"networkidle"` に設定（デフォルト）
- PowerShell版: `settle_ms` を増やす（例: `1500`）
- ページの読み込みに時間がかかる場合は、`pages` の `actions` に `wait` アクションを追加

---

## ディレクトリ構成

```
cas_cap/
├── README.md                  # 本ファイル
├── .gitignore
├── config/
│   ├── config.sample.json     # 設定サンプル（PowerShell版 / JavaScript版）
│   ├── config.sample.yaml     # 設定サンプル（Python版）
│   └── config.json/.yaml      # 実環境設定（.gitignore対象）
├── powershell/
│   └── cdp_capture.ps1        # PowerShell版（外部依存なし）
├── js/
│   ├── cdp_capture.js         # JavaScript版（Node.js + Playwright）
│   └── package.json
├── src/
│   └── cdp_capture.py         # Python版（オリジナル）
├── requirements.txt           # Python版の依存パッケージ
├── output/                    # キャプチャ出力先
└── scripts/
    └── start_edge.ps1         # Edge起動スクリプト
```
