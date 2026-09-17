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
| `-ClickNav`      |        | （記録）バッチ用に記録する。検索結果の行の選択など、URLが変わるクリックも click のまま残す | — |
| `-KojinNo <番号>` |       | （記録）記録に使った宛名番号。バッチ実行時にこの番号を差し替える | — |
| `-Batch`         |        | バッチ実行モード         | —                        |
| `-CsvFile <path>` |       | （バッチ）別ツールが出力した CSV | —                 |
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
| `wait_after_ms`      | `wait_after` を付けた操作の後に止まる時間(ms、既定 5000)。帳票プレビューの作成待ちなど |
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

`click` に付けられる印（記録の最後の質問で付く。手で書き足してもよい）:

| キー | 説明 |
| ---- | ---- |
| `wait_after: true` | 押した後、`wait_after_ms` だけ止まってから次へ進む |
| `by_index: true` ＋ `index` | ボタン名を使わず、記録した要素と同じ種類が画面に**ちょうど1件**見えている時だけ押す（2件以上・0件なら失敗） |

> `click` / `fill` / `select` / `keyboard` はページ内JavaScript（`Runtime.evaluate`）経由で実行する。ネイティブのマウス/キー入力が必要な複雑なケースは [JavaScript版](../js/README.md)（Playwright）を推奨。

---

## バッチ実行（チェック項目 × 宛名番号の一括キャプチャ）

別ツールが出力する CSV のチェック項目と宛名番号の組ごとに、対応する操作記録を宛名番号だけ差し替えて再生し、全件を自動でキャプチャする。GUI（`gui\launcher.bat`）の「バッチ実行」からも実行できる。

### 準備（チェック項目ごとに1回）

1. 対象アプリを開いてログインしておく
2. 確認画面を回る操作を、バッチ用として記録する

   ```powershell
   .\powershell\cdp_capture.ps1 -Record -ClickNav -KojinNo 11111 -OutConfig config/rec_inkan.json
   ```

   記録のしかた（件ごとに手順の先頭からやり直すため、この順で操作する）:

   1. **どの画面からでも押せるメニュー**（検索画面を開くリンク等）を最初にクリックする
   2. 検索欄に宛名番号を**キーボードで手入力**し、**検索ボタン**を押して、**対象者一覧の行**をクリックする
      - 貼り付けやオートコンプリートだと記録されないことがある
      - 入力中にサジェスト（候補）が出ても選ばない。バッチ実行では候補は出ない（下の「再生のしかた」）
   3. 確認したい画面まで、**画面内のボタンやタブで**操作する。ブラウザの「戻る」やアドレス入力は使わない

   - `-KojinNo` には、記録で実際に入力した宛名番号を指定する（バッチ時にこの番号を差し替える）
   - 記録の最後に「宛名番号 '11111' を記録内で N 箇所確認しました」と出れば OK
   - 次の警告が出たら記録し直す
     - 宛名番号が見つからない
     - 最初の操作がクリックではない
     - クリックを伴わない画面遷移があった（戻る・アドレス入力など）
   - クリックが1つも無い記録は保存されない

   記録を終えると、2つ質問される（手順の一覧が番号つきで出るので、番号をカンマ区切りで答える。無ければ Enter）:

   1. **実行後に待たせる操作はどれですか？** — 帳票プレビューの作成など、押した後しばらく「くるくる」が出る操作を選ぶ。
      選んだ操作には `wait_after` が付き、再生時は押した後 `wait_after_ms`（既定 5000ms）だけ止まる。
      くるくるは画面の中身を変えないことが多く、ツールは作成中かどうかを見分けられないため、待つ場所は人が決める。
      件と件の間の `interval_ms` では、この待ちの代わりにならない（撮影や次の操作は件の途中で起きる）
   2. **対象者ごとに表示が変わる操作はどれですか？**（`-ClickNav` の時だけ） — 候補や一覧の表示名が**氏名だけ**（宛名番号を含まない）で、それを押す操作を選ぶ（対象者一覧の行など）。
      選んだ操作には `by_index` が付き、ボタン名（記録時の人の氏名）は保存しない。再生時は候補が**ちょうど1件**の時だけ押す
      - 表示名に宛名番号が含まれる行（例「11111 山田 太郎」）は選ばなくてよい（新しい宛名番号で探すため）
      - クリック以外の番号は無視される
      - 元に戻す時は、記録ファイルの該当操作から `by_index` と `index` を消し、`text` にボタン名を書き戻す

   答えを間違えた時は記録ファイルを直接直すか、記録し直す。

3. 対応表 `config/mapping.json` を作る（[サンプル](../config/mapping.sample.json)）

   ```json
   {
     "output_dir": "output",
     "max_consecutive_fail": 5,
     "interval_ms": 1000,
     "wait_after_ms": 5000,
     "records": { "印鑑": "config/rec_inkan.json" },
     "items": {
       "04_3_印鑑_最大文字調査_外国人併記名最大": "印鑑",
       "04_7_印鑑_最大文字調査_外国人住所最大": "印鑑"
     }
   }
   ```

   - `records`：記録の論理名 → 記録ファイル
   - `items`：チェック項目 → 記録の論理名
   - `max_consecutive_fail`：同じ記録で連続してこの件数失敗したら、その記録を使う残りの行を飛ばす（既定 5）
   - `interval_ms`：件と件の間の待ち時間（ms、既定 1000）
   - `wait_after_ms`：`wait_after` を付けた操作の後に止まる時間（ms）。書けば全記録の値を上書きする。書かなければ記録ファイルの値（無ければ 5000）。プレビューが遅い環境では増やす

### 実行（毎回）

事前に Edge をデバッグポート付きで起動し、対象アプリにログインしておく（認証を保つためアプリはリロードしない）。

```powershell
.\powershell\cdp_capture.ps1 -Batch -CsvFile .\list.csv -Mapping config/mapping.json
```

CSV の形式（ヘッダなし・囲み文字なし。1行 = `チェック項目,宛名番号`。行数 = 撮影する件数。Shift_JIS / UTF-8 どちらでも可。空行は無視）:

```csv
04_3_印鑑_最大文字調査_外国人併記名最大,11111
04_7_印鑑_最大文字調査_外国人住所最大,222222
```

### 再生のしかた（バッチ用記録）

姉妹ツール cas_auto_report と同じ方式で動かす。

- **入力**：欄に値を入れて input / change を送る。キーは打たないので、入力中に出るサジェスト（候補）は開かない
- **クリック**：見つけた要素を直接クリックする（SVG のアイコンなど click() が無い要素は、マウス操作のイベントを作って送る）
- **URL での移動はしない**：URL には宛名番号以外の番号（世帯番号など）が入り、別の人の画面を開くことがあるため。URL での移動(goto)を含む記録は実行しない

クリックする要素の選び方:

| 記録時のボタン名 | 選び方 |
| ---- | ---- |
| 宛名番号を含む（例: 一覧の行「11111 山田 太郎」） | ボタン名を新しい宛名番号だけにして照合する（氏名は使わない）。記録位置の要素 → 画面のクリックできる要素の順に、宛名番号を含むものを押す。前後に数字・英字が続く所は一致とみなさない（11111 で 111119 の行は押さない） |
| 宛名番号を含まない | 記録位置＋ボタン名 → ボタン名で探す。ボタン名が無い時（アイコン等）だけ記録位置の要素を押す。見つからなければ失敗 |
| `by_index` を付けた操作（氏名だけの一覧など） | ボタン名は使わない。記録した要素と同じ種類（位置の番号は無視）が画面に**ちょうど1件**見えている時だけ押す。2件以上なら件数を出して失敗、0件でも失敗 |

`wait_after` を付けた操作は、押した後 `wait_after_ms` 止まってから次の操作・撮影に進む。

### 出力

```
output\batch_{実行日時}\{記録の論理名}_{大分類}\{宛名番号}_{大分類}_{小分類}_{ページ名}.png
```

例: `output\batch_20260916_153000\印鑑_04\222222_04_7_recorded_002.png`

大分類・小分類はチェック項目の先頭2つ（`04_7_…` → `04` と `7`）。

### 止まる／飛ばすケース

| 状況 | 動作 |
| ---- | ---- |
| CSV が見つからない／対象が1行もない／対応表が読めない | 全体を中止 |
| 列が2つでない行 | その行を飛ばして次へ（行番号を表示） |
| 対応表に無いチェック項目／記録ファイルが無い | その件を飛ばして次へ |
| チェック項目が `大分類_小分類_…` の形でない | その件を飛ばして次へ |
| バッチ用の記録ではない（`-ClickNav` なしで記録）／URL での移動(goto)を含む | その件を飛ばして次へ（別人を撮らないため） |
| 記録に `kojin_no` が無い／記録内に記録時の宛名番号が無い | その件を飛ばして次へ（別人を撮らないため） |
| 入力欄やクリック対象が見つからない・`by_index` で2件以上・待ちが時間切れ・例外 | **その件をその場で打ち切って**次の件へ（ずれた画面のまま撮らない）。それまでに撮れた画像は残る |
| 同じ記録で連続 `max_consecutive_fail` 件失敗 | その記録を使う残りの行を飛ばす（他の記録の行は続ける） |

最後に成功・スキップ・失敗の件数と理由（どの行の何ページ目の、何番目の手順の何の操作で失敗したか。手順番号は記録終了時の一覧と同じ）を表示する。スキップ／失敗が1件でもあれば終了コード 1（GUI から起動した場合は結果を読めるようウィンドウが残る）。

### 練習ページでの確認

`test/mock/search.html` は、宛名検索でよくある作り（宛名番号を打つとサジェストが出る／検索ボタンで対象者一覧（前方一致）を出す／行を選ぶと詳細へ進み、URL には世帯番号が入る／「帳票」タブで約3秒くるくるが出て、その間はメニューが効かない）を再現した練習ページ。記録や再生の動きを本物の前に確かめる時に使う。

```powershell
python -m http.server 8765 --directory test/mock
# ブラウザで http://localhost:8765/search.html を開く（?label=name で一覧・候補の表示が氏名だけになる）
```

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
