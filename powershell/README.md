# CAS Cap — PowerShell版 使い方

CDP（Chrome DevTools Protocol）経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する。
**外部依存ゼロ**（Windows標準のPowerShellのみ。pip/npm不要）で動作する。

- スクリプト: [`cdp_capture.ps1`](cdp_capture.ps1)
- 設定ファイル: [`../config/config.json`](../config/config.json)（[サンプル](../config/config.sample.json)）

---

## 必要なもの

| 項目       | 要件                                     |
| ---------- | ---------------------------------------- |
| OS         | Windows 10 / 11                          |
| PowerShell | Windows標準（5.1）以上。PowerShell 7も可 |
| ブラウザ   | Microsoft Edge（Chromiumベース）         |

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

キャプチャ画像は `output/` に `{timestamp}_{name}.png`（巡回時）または `capture_{timestamp}.png`（単発時）形式で保存される（バッチ実行時は後述の形式）。

---

## コマンドライン引数

| 引数               | 別名   | 説明                     | デフォルト                |
| ------------------ | ------ | ------------------------ | ------------------------- |
| `-Config <path>` | `-c` | 設定ファイル(JSON)のパス | `config/config.json`    |
| `-List`          |        | タブ一覧を表示して終了   | —                        |
| `-CdpUrl <url>`  |        | CDPのURL（設定を上書き） | `http://localhost:9222` |
| `-Record`        |        | 操作記録モード           | —                        |
| `-Name <name>`   |        | （記録）ページ名の接頭辞 | `recorded`              |
| `-OutConfig <path>` |     | （記録）保存先           | `config/recorded.json`  |
| `-ClickNav`      |        | （記録）バッチ用に記録する。サジェスト候補の選択など、URLが変わるクリックも click のまま残す | — |
| `-KojinNo <番号>` |       | （記録）記録に使った宛名番号。バッチ実行時にこの番号を差し替える | — |
| `-Batch`         |        | バッチ実行モード         | —                        |
| `-BatFile <path>` |       | （バッチ）別ツールが出力した bat | —                 |
| `-Mapping <path>` |       | （バッチ）チェック項目と記録の対応表 | `config/mapping.json` |

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

| キー                   | 説明                                                        |
| ---------------------- | ----------------------------------------------------------- |
| `cdp_url`            | CDP接続先                                                   |
| `target_url_keyword` | 対象タブのURLに含まれるキーワード                           |
| `output_dir`         | 出力先ディレクトリ                                          |
| `full_page`          | ページ全体をキャプチャするか（`false`: 表示領域のみ）     |
| `settle_ms`          | ページ待機後の追加待ち時間(ms)。`networkidle`の近似に使用 |
| `pages`              | 巡回キャプチャ設定（空配列なら現在表示中の画面のみ）        |

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

| type         | 説明                 | パラメータ                    | 実装方式                                      |
| ------------ | -------------------- | ----------------------------- | --------------------------------------------- |
| `click`    | 要素をクリック       | `selector`                  | ページ内JS（`el.click()`）                  |
| `fill`     | テキスト入力         | `selector`, `value`       | ページ内JS（value設定＋input/changeイベント） |
| `wait`     | 要素の表示を待機     | `selector`, `timeout`(ms) | ページ内JSでポーリング                        |
| `goto`     | URLに遷移            | `url`                       | `Page.navigate`                             |
| `select`   | セレクトボックス選択 | `selector`, `value`       | ページ内JS                                    |
| `keyboard` | キー入力             | `key`（例 `"Enter"`）     | ページ内JSで`KeyboardEvent`発火             |

> `click` / `fill` / `select` / `keyboard` はページ内JavaScript（`Runtime.evaluate`）経由で実行する。ネイティブのマウス/キー入力が必要な複雑なケースは [JavaScript版](../js/README.md)（Playwright）を推奨。

---

## バッチ実行（チェック項目 × 宛名番号の一括キャプチャ）

別ツールが出力する bat のチェック項目と宛名番号の組ごとに、対応する操作記録を宛名番号だけ差し替えて再生し、全件を自動でキャプチャする。GUI（`gui\launcher.bat`）の「バッチ実行」からも実行できる。

### 準備（チェック項目ごとに1回）

1. 対象アプリを開いてログインしておく
2. **検索欄に宛名番号を入力し、サジェスト候補をクリックして**確認画面を回る操作を、バッチ用として記録する

   ```powershell
   .\powershell\cdp_capture.ps1 -Record -ClickNav -KojinNo 11111 -OutConfig config/rec_inkan.json
   ```

   - `-KojinNo` には、記録で実際に入力した宛名番号を指定する（バッチ時にこの番号を差し替える）
   - 記録の最後に「宛名番号 '11111' を記録内で N 箇所確認しました」と出れば OK。見つからない旨の警告が出たら記録し直す

3. 対応表 `config/mapping.json` を作る（[サンプル](../config/mapping.sample.json)）

   ```json
   {
     "output_dir": "output",
     "records": { "印鑑": "config/rec_inkan.json" },
     "items": {
       "04_3_印鑑_最大文字調査_外国人併記名最大": "印鑑",
       "04_7_印鑑_最大文字調査_外国人住所最大": "印鑑"
     }
   }
   ```

   - `records`：記録の論理名 → 記録ファイル
   - `items`：チェック項目 → 記録の論理名

### 実行（毎回）

事前に Edge をデバッグポート付きで起動し、対象アプリにログインしておく（認証を保つためアプリはリロードしない）。

```powershell
.\powershell\cdp_capture.ps1 -Batch -BatFile .\list.bat -Mapping config/mapping.json
```

bat の形式（2行固定。`/` 区切りで、同じ位置同士が組になる。Shift_JIS / UTF-8 どちらでも可）:

```bat
set taisho_title=04_3_印鑑_最大文字調査_外国人併記名最大/04_7_印鑑_最大文字調査_外国人住所最大
set taisho_kojinNo=11111/222222
```

### 出力

```
output\batch_{実行日時}\{記録の論理名}_{大分類}\{宛名番号}_{大分類}_{小分類}_{ページ名}.png
```

例: `output\batch_20260916_153000\印鑑_04\222222_04_7_recorded_002.png`

大分類・小分類はチェック項目の先頭2つ（`04_7_…` → `04` と `7`）。

### 止まる／飛ばすケース

| 状況 | 動作 |
| ---- | ---- |
| チェック項目と宛名番号の件数が違う | 全体を中止（取り違え防止） |
| 対応表に無いチェック項目／記録ファイルが無い | その件を飛ばして次へ |
| チェック項目が `大分類_小分類_…` の形でない | その件を飛ばして次へ |
| 記録に `kojin_no` が無い／記録内に記録時の宛名番号が無い | その件を飛ばして次へ（別人を撮らないため） |
| 途中で失敗 | 次の件へ進む |

最後に成功・スキップ・失敗の件数と理由を表示する。スキップ／失敗が1件でもあれば終了コード 1（GUI から起動した場合は結果を読めるようウィンドウが残る）。

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
