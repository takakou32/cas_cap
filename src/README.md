# CAS Cap — Python版 使い方

CDP（Chrome DevTools Protocol）経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する。
オリジナル実装。Python + Playwright ベース。

- スクリプト: [`cdp_capture.py`](cdp_capture.py)
- 設定ファイル: [`../config/config.yaml`](../config/config.yaml)（[サンプル](../config/config.sample.yaml)）

> Python版は設定に **YAML**（`config/config.yaml`）を使う。PowerShell版・JavaScript版は JSON（`config/config.json`）を使う点に注意。

---

## 必要なもの

| 項目 | 要件 |
|------|------|
| Python | 3.10 以上 |
| ブラウザ | Microsoft Edge（Chromiumベース） |
| 依存パッケージ | `playwright`, `pyyaml`（`requirements.txt`） |

---

## セットアップ

```powershell
# 仮想環境作成（推奨）
python -m venv .venv
.venv\Scripts\activate

# 依存パッケージのインストール
pip install -r requirements.txt

# Playwrightのブラウザバイナリを取得
playwright install chromium

# 設定ファイルを作成
copy config\config.sample.yaml config\config.yaml
```

`config\config.yaml` を編集して `target_url_keyword` を対象アプリのURLに合わせる。

---

## 実行手順

### 1. Edgeをデバッグポート付きで起動

```powershell
.\scripts\start_edge.ps1
# または手動で（まず全Edgeを閉じてから）
Start-Process "msedge.exe" "--remote-debugging-port=9222"
```

> ⚠️ 既にEdgeが起動している状態で起動するとデバッグポートが無視される。**必ず全Edgeを閉じてから**起動すること。

### 2. 認証exeからアプリを起動

通常どおりexeを起動する。アプリがEdgeの新しいタブとして開く。

### 3. タブ一覧を確認

```bash
python src/cdp_capture.py --list
```

出力例:
```
接続成功。コンテキスト数: 1
  [0] New Tab
  [1] アプリ名
```

ここで表示されたURLの一部を `target_url_keyword` に設定する。

### 4. キャプチャ実行

```bash
# 設定ファイル（config/config.yaml）に従って実行
python src/cdp_capture.py

# 設定ファイルを指定
python src/cdp_capture.py -c config/my_config.yaml

# CDP URL を上書き
python src/cdp_capture.py --cdp-url http://localhost:9333
```

キャプチャ画像は `output/` に `{timestamp}_{name}.png`（巡回時）または `capture_{timestamp}.png`（単発時）形式で保存される。

---

## コマンドライン引数

| 引数 | 別名 | 説明 | デフォルト |
|------|------|------|-----------|
| `--config <path>` | `-c` | 設定ファイル(YAML)のパス | `config/config.yaml` |
| `--list` | | タブ一覧を表示して終了 | — |
| `--cdp-url <url>` | | CDPのURL（設定を上書き） | `http://localhost:9222` |

---

## 設定ファイル（YAML）

```yaml
cdp_url: "http://localhost:9222"
target_url_keyword: "your-app-url"
output_dir: "output"
full_page: true
wait_state: "networkidle"   # networkidle | load | domcontentloaded

# 巡回キャプチャ（省略時は現在表示中の画面のみ）
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

---

## トラブルシューティング

### CDPに接続できない

- Edgeが起動しているか確認: `Get-Process msedge`
- デバッグポートが有効か確認: `Invoke-RestMethod http://localhost:9222/json`
- **全Edgeを閉じてから**デバッグポート付きで起動し直す

### 対象タブが見つからない

- `--list` でタブ一覧を確認し、`target_url_keyword` を修正
- exeからアプリが正しく起動しているか確認

### スクリーンショットが真っ白/真っ黒

- `wait_state` を `"networkidle"` に設定（デフォルト）
- `pages` の `actions` に `wait` アクションを追加
