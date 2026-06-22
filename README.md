# CAS Cap

CDP（Chrome DevTools Protocol）経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを自動取得するツール。

認証型exeからブラウザを起動する方式のアプリケーションで、従来のBitBlt/PrintScreen方式ではキャプチャできない問題を解決する。

## 仕組み

```
[Edge + デバッグポート] ← CDP接続 ← [Playwright (本ツール)]
        ↑
   [認証exe] がタブを追加
```

1. Edgeをデバッグポート付きで起動
2. 認証exeがそのEdgeインスタンスにタブを追加
3. 本ツールがCDP経由でEdgeに接続し、対象タブを操作＋キャプチャ

Playwrightはブラウザのレンダリングエンジンから直接スクリーンショットを取得するため、ハードウェアアクセラレーションやBitBltの制約を受けない。

## 前提条件

- Python 3.10+
- Microsoft Edge（Chromiumベース）
- 認証exeがシステムのEdgeを利用する構成であること

## セットアップ

```bash
# リポジトリをクローン
git clone https://github.com/takakou32/cas_cap.git
cd cas_cap

# 仮想環境作成（推奨）
python -m venv .venv
.venv\Scripts\activate

# 依存パッケージインストール
pip install -r requirements.txt

# Playwrightのブラウザバイナリインストール
playwright install chromium

# 設定ファイルを作成
copy config\config.sample.yaml config\config.yaml
```

## 設定

`config/config.yaml` を編集する。

```yaml
# CDP接続先
cdp_url: "http://localhost:9222"

# 対象タブのURLに含まれるキーワード
target_url_keyword: "your-app-url"

# キャプチャ出力先
output_dir: "output"

# ページ全体をキャプチャするか
full_page: true
```

### 巡回キャプチャ設定

複数画面を自動で巡回してキャプチャする場合は `pages` セクションを追加する。

```yaml
pages:
  - name: "top"
    actions: []

  - name: "search_result"
    actions:
      - type: fill
        selector: "input#search"
        value: "検索ワード"
      - type: click
        selector: "button#search-btn"
      - type: wait
        selector: ".result-table"

  - name: "detail"
    actions:
      - type: click
        selector: ".result-table tr:first-child a"
```

### アクション一覧

| type | 説明 | パラメータ |
|------|------|-----------|
| `click` | 要素をクリック | `selector` |
| `fill` | テキスト入力 | `selector`, `value` |
| `wait` | 要素の表示を待機 | `selector`, `timeout`(ms) |
| `goto` | URLに遷移 | `url` |
| `select` | セレクトボックス選択 | `selector`, `value` |
| `keyboard` | キー入力 | `key` (例: `"Enter"`, `"Tab"`) |

## 使い方

### 1. Edgeをデバッグポート付きで起動

```powershell
# PowerShellスクリプトを使う場合
.\scripts\start_edge.ps1

# 手動で起動する場合
# まず全Edgeを閉じてから:
Start-Process "msedge.exe" "--remote-debugging-port=9222"
```

### 2. 認証exeからアプリを起動

通常通りexeを起動する。アプリがEdgeの新しいタブとして開く。

### 3. タブ一覧を確認

```bash
python src/cdp_capture.py --list
```

出力例:
```
接続成功。コンテキスト数: 1
  [0] New Tab - edge://newtab/
  [1] アプリ名 - https://your-app.example.com/
```

`target_url_keyword` に設定するキーワードをここで確認する。

### 4. キャプチャ実行

```bash
# 設定ファイルに従ってキャプチャ
python src/cdp_capture.py

# 設定ファイルを指定
python src/cdp_capture.py -c config/my_config.yaml
```

キャプチャ画像は `output/` ディレクトリに `{timestamp}_{name}.png` 形式で保存される。

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

- `--list` でタブ一覧を確認し、`target_url_keyword` を修正
- exeからアプリが正しく起動しているか確認

### スクリーンショットが真っ白/真っ黒

- `wait_state` を `"networkidle"` に設定（デフォルト）
- ページの読み込みに時間がかかる場合は、`pages` の `actions` に `wait` アクションを追加

## ディレクトリ構成

```
cas_cap/
├── README.md              # 本ファイル
├── requirements.txt       # 依存パッケージ
├── .gitignore
├── src/
│   └── cdp_capture.py     # メインスクリプト
├── config/
│   ├── config.sample.yaml # 設定サンプル
│   └── config.yaml        # 実環境設定（.gitignore対象）
├── output/                # キャプチャ出力先
└── scripts/
    └── start_edge.ps1     # Edge起動スクリプト
```
