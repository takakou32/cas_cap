<#
.SYNOPSIS
    CAS Cap (PowerShell版) - CDP経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する

.DESCRIPTION
    外部依存なし（.NET の ClientWebSocket で Chrome DevTools Protocol を直接操作）。
    Python版・JavaScript版と同等の機能を、PowerShell単体で提供する。

    前提:
      1. Edgeを全プロセス終了
      2. scripts/start_edge.ps1 でデバッグポート付きEdgeを起動
      3. exeからアプリを起動（Edgeにタブが追加される）
      4. このスクリプトを実行: .\powershell\cdp_capture.ps1

.PARAMETER Config
    設定ファイル(JSON)のパス（デフォルト: config/config.json）

.PARAMETER List
    接続中のEdgeのタブ一覧を表示して終了する

.PARAMETER CdpUrl
    CDPのURL（指定時は設定ファイルの cdp_url を上書き）

.PARAMETER Record
    操作記録モード。ブラウザ操作を記録して -OutConfig に保存する

.PARAMETER ClickNav
    （記録時）バッチ用の記録にする。URLが変わるクリック（サジェスト候補の選択など）も
    goto に変換せず click のまま残すので、入力した宛名番号に応じて遷移先が変わる

.PARAMETER KojinNo
    （記録時）記録に使った宛名番号。バッチ実行時にこの番号を CSV の宛名番号へ差し替える

.PARAMETER Batch
    バッチ実行モード。-CsvFile の CSV と -Mapping の対応表に従い、全件を自動キャプチャする

.PARAMETER CsvFile
    （バッチ時）別ツールが出力した CSV（ヘッダなし・囲み文字なし。1行 = チェック項目,宛名番号）

.PARAMETER Mapping
    （バッチ時）チェック項目と記録の対応表（デフォルト: config/mapping.json）

.EXAMPLE
    .\powershell\cdp_capture.ps1 --list
.EXAMPLE
    .\powershell\cdp_capture.ps1 -Config config/my_config.json
.EXAMPLE
    .\powershell\cdp_capture.ps1 -Record -ClickNav -KojinNo 11111 -OutConfig config/rec_inkan.json
.EXAMPLE
    .\powershell\cdp_capture.ps1 -Batch -CsvFile .\list.csv -Mapping config/mapping.json
#>

[CmdletBinding()]
param(
    [Alias("c")]
    [string]$Config = "config/config.json",
    [switch]$List,
    [string]$CdpUrl,
    [switch]$Record,
    [string]$Name = "recorded",
    [string]$OutConfig = "config/recorded.json",
    [switch]$ClickNav,
    [string]$KojinNo,
    [switch]$Batch,
    [string]$CsvFile,
    [string]$Mapping = "config/mapping.json"
)

$ErrorActionPreference = "Stop"
$script:CdpId = 0
$script:BatchMode = $false   # バッチ実行中か（本物の入力で操作し、合わなければその件を打ち切る）

# .NET の相対パス基準(WriteAllBytes等)を PowerShell のカレントに合わせる。
# これをしないと、別ディレクトリから起動した際に出力先がずれる。
[System.IO.Directory]::SetCurrentDirectory((Get-Location).Path)

# ---------------------------------------------------------------------------
# 設定読み込み
# ---------------------------------------------------------------------------
function Get-CapConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "設定ファイルが見つかりません: $Path"
        Write-Host "config/config.sample.json をコピーして config/config.json を作成してください"
        exit 1
    }
    return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# CDP HTTPエンドポイント
# ---------------------------------------------------------------------------
function Get-CdpTabs {
    param([string]$BaseUrl)
    try {
        $tabs = Invoke-RestMethod -Uri "$BaseUrl/json" -Method Get
    } catch {
        Write-Host "接続エラー: $BaseUrl"
        Write-Host "  Edgeがデバッグポート付きで起動しているか確認してください"
        exit 1
    }
    # ページタイプのタブのみ対象（service_worker等を除外）
    return @($tabs | Where-Object { $_.type -eq "page" })
}

# ---------------------------------------------------------------------------
# CDP WebSocket 通信
# ---------------------------------------------------------------------------
function Connect-CdpSocket {
    param([string]$WsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = [Uri]$WsUrl
    $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    return $ws
}

function Send-CdpRaw {
    param($Ws, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $Ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Receive-CdpRaw {
    param($Ws)
    $buffer = New-Object byte[] 131072
    $sb = New-Object System.Text.StringBuilder
    do {
        $segment = [System.ArraySegment[byte]]::new($buffer)
        $result = $Ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
    } while (-not $result.EndOfMessage)
    return $sb.ToString()
}

# CDPコマンドを送信し、対応するid応答を待つ（途中のイベント通知は読み飛ばす）
function Invoke-CdpCommand {
    param($Ws, [string]$Method, $Params = $null)
    $script:CdpId++
    $id = $script:CdpId
    $msg = @{ id = $id; method = $Method }
    if ($null -ne $Params) { $msg.params = $Params }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    Send-CdpRaw -Ws $Ws -Json $json

    while ($true) {
        $raw = Receive-CdpRaw -Ws $Ws
        $obj = $raw | ConvertFrom-Json
        if ($obj.id -eq $id) {
            if ($obj.error) { throw "CDPエラー [$Method]: $($obj.error.message)" }
            return $obj.result
        }
        # idが一致しないものはイベント通知なので無視
    }
}

# ページコンテキストでJavaScriptを評価する
function Invoke-PageScript {
    param($Ws, [string]$Expression, [bool]$AwaitPromise = $false)
    $result = Invoke-CdpCommand -Ws $Ws -Method "Runtime.evaluate" -Params @{
        expression   = $Expression
        awaitPromise = $AwaitPromise
        returnByValue = $true
    }
    if ($result.exceptionDetails) {
        $desc = $result.exceptionDetails.exception.description
        if (-not $desc) { $desc = $result.exceptionDetails.text }
        throw "JS実行エラー: $desc"
    }
    return $result.result.value
}

# ページ遷移中はJS実行コンテキストが破棄され Runtime.evaluate が失敗する。
# 遷移由来の一時的エラーは少し待って新しいコンテキストでリトライする。
function Invoke-PageScriptSafe {
    param($Ws, [string]$Expression, [bool]$AwaitPromise = $false, [int]$Retries = 40)
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            return Invoke-PageScript -Ws $Ws -Expression $Expression -AwaitPromise $AwaitPromise
        } catch {
            $msg = "$_"
            if ($msg -match "Execution context was destroyed" -or
                $msg -match "Cannot find context" -or
                $msg -match "Inspected target navigated or closed" -or
                $msg -match "uniqueContextId") {
                Start-Sleep -Milliseconds 200
                continue
            }
            throw
        }
    }
    throw "ページ評価がナビゲーションにより安定しませんでした"
}

# 文字列を安全なJSリテラルに変換（JSON文字列はJS文字列としても妥当）
function ConvertTo-JsLiteral {
    param([string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------------------
# 待機処理
#   1) ready_selector が指定されていれば、その要素が表示されるまで待つ
#   2) readyState=complete かつ DOMが stable_ms の間変化しなくなるまで待つ（最大 timeout）
#   3) 仕上げに settle_ms 待つ
# これにより「readyStateはcompleteだが中身はまだローディング中」を撮ってしまうのを防ぐ。
# stable_ms / load_timeout_ms / ready_selector は $script: 変数で上書き可（Invoke-Captureで設定）。
# ---------------------------------------------------------------------------
function Wait-PageReady {
    param($Ws, [int]$SettleMs = 800, [int]$TimeoutMs = 0)

    $timeout  = if ($TimeoutMs -gt 0) { $TimeoutMs }
                elseif ($script:LoadTimeoutMs) { [int]$script:LoadTimeoutMs } else { 30000 }
    $stable   = if ($null -ne $script:StableMs) { [int]$script:StableMs } else { 1000 }
    $selector = if ($script:ReadySelector) { [string]$script:ReadySelector } else { "" }

    # 1) 目印要素の出現待ち（任意）
    if ($selector) {
        $sel = ConvertTo-JsLiteral $selector
        $expr = @"
new Promise((resolve, reject) => {
  const deadline = Date.now() + $timeout;
  (function check() {
    const el = document.querySelector($sel);
    if (el && el.offsetParent !== null) return resolve(true);
    if (Date.now() > deadline) return reject(new Error('ready_selector timeout: ' + $sel));
    setTimeout(check, 100);
  })();
})
"@
        Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
    }

    # 2) readyState完了 ＋ DOM安定待ち（コンテンツの挿入が止まるまで）
    $expr = @"
new Promise((resolve) => {
  const idle = $stable, deadline = Date.now() + $timeout;
  let last = Date.now();
  let obs = null;
  try {
    obs = new MutationObserver(() => { last = Date.now(); });
    obs.observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
  (function check() {
    const now = Date.now();
    if (document.readyState === 'complete' && (now - last) >= idle) {
      if (obs) obs.disconnect();
      return resolve('idle');
    }
    if (now > deadline) {
      if (obs) obs.disconnect();
      return resolve('timeout');
    }
    setTimeout(check, 100);
  })();
})
"@
    Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null

    if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
}

# ---------------------------------------------------------------------------
# バッチ実行時の操作（本物のマウス操作・キー入力）
#   業務システムの部品には、プログラムから投げたイベントでは反応しないものがある
#   （キーを離した時だけ検索する／マウスを押した瞬間に候補を選ぶ 等）。
#   バッチ用記録の再生では、人と同じ入力を Edge に送る。
# ---------------------------------------------------------------------------

# 画面上の座標をマウスでクリックする（移動 → 押す → 離す）
function Send-MouseClick {
    param($Ws, [double]$X, [double]$Y)
    Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchMouseEvent" -Params @{ type = "mouseMoved"; x = $X; y = $Y } | Out-Null
    Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchMouseEvent" -Params @{ type = "mousePressed"; x = $X; y = $Y; button = "left"; buttons = 1; clickCount = 1 } | Out-Null
    Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchMouseEvent" -Params @{ type = "mouseReleased"; x = $X; y = $Y; button = "left"; buttons = 0; clickCount = 1 } | Out-Null
}

# 文字を入力しないキー（Backspace など）を押して離す
function Send-KeyStroke {
    param($Ws, [string]$Key, [string]$Code, [int]$KeyCode, [int]$Modifiers = 0)
    Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchKeyEvent" -Params @{ type = "rawKeyDown"; key = $Key; code = $Code; windowsVirtualKeyCode = $KeyCode; modifiers = $Modifiers } | Out-Null
    Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchKeyEvent" -Params @{ type = "keyUp"; key = $Key; code = $Code; windowsVirtualKeyCode = $KeyCode; modifiers = $Modifiers } | Out-Null
}

# 文字列を1文字ずつキー入力する（キーを押す → 離す）
function Send-KeyText {
    param($Ws, [string]$Text)
    foreach ($ch in $Text.ToCharArray()) {
        $c = [string]$ch
        $down = @{ type = "keyDown"; key = $c; text = $c }
        $up   = @{ type = "keyUp"; key = $c }
        $code = $null; $keyCode = 0
        if ($c -match '^[0-9]$') { $code = "Digit$c"; $keyCode = 48 + [int]$c }
        elseif ($c -match '^[A-Za-z]$') { $code = "Key$($c.ToUpper())"; $keyCode = [int][char]($c.ToUpper()) }
        if ($code) {
            $down.code = $code; $down.windowsVirtualKeyCode = $keyCode
            $up.code = $code;   $up.windowsVirtualKeyCode = $keyCode
        }
        Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchKeyEvent" -Params $down | Out-Null
        Invoke-CdpCommand -Ws $Ws -Method "Input.dispatchKeyEvent" -Params $up | Out-Null
        Start-Sleep -Milliseconds 30
    }
}

# 操作対象に付けた目印（data-cap-target）を外す
$script:ClearTargetMarkJs = @'
(function(){ Array.prototype.forEach.call(document.querySelectorAll('[data-cap-target]'), function(e){ e.removeAttribute('data-cap-target'); }); return true; })()
'@

# 目印を付けた要素を、座標が他の要素に隠れていたときだけ直接クリックする
$script:ClickMarkedTargetJs = @'
(function(){ var e=document.querySelector('[data-cap-target]'); if(!e) return false; e.removeAttribute('data-cap-target'); e.click(); return true; })()
'@

# バッチ実行のクリック。見つからない・特定できないときは例外（＝その件を打ち切る）。
#   ボタン名に宛名番号が入っていたクリック（match_kojin_no あり）
#     → 宛名番号を含む要素だけで探す。氏名や位置では選ばない（別人の候補を押さないため）
#   それ以外
#     → 記録位置＋ボタン名 → ボタン名 →（ボタン名が無い時のみ）記録位置
#     → それでも無ければ、記録した要素と同じ種類（位置の番号は無視）が画面に1つだけならそれ
function Invoke-BatchClick {
    param($Ws, $Action)
    $findJs = @'
new Promise(function (resolve) {
  var sel = __SEL__, text = __TXT__, no = __NO__, deadline = Date.now() + __TO__, started = Date.now(), singleSeen = 0, sameCount = 0;
  var CLICKABLE = 'a,button,[role=button],[role=tab],[role=menuitem],[role=link],[role=option],li,[tabindex],[onclick]';
  function visible(e){ return e && (e.offsetParent !== null || (e.getClientRects && e.getClientRects().length > 0)); }
  function txtOf(e){
    var s=(e.innerText||e.textContent||'').trim();
    if(!s){ try { s=((e.getAttribute('aria-label')||e.getAttribute('title'))||'').trim(); } catch(_){} }
    return s;
  }
  function matches(a,b){
    if(!a||!b) return false;
    if(a===b) return true;
    return (b.length>=2 && a.indexOf(b)>=0) || (a.length>=2 && b.indexOf(a)>=0);
  }
  // 前後が英数字でない位置に宛名番号があるか（11111 が 111119 に当たらないように）
  function hasNo(s){
    var i = s.indexOf(no);
    while (i >= 0) {
      var before = i === 0 ? '' : s.charAt(i - 1), after = s.charAt(i + no.length);
      if (!/[0-9A-Za-z]/.test(before) && !/[0-9A-Za-z]/.test(after)) return true;
      i = s.indexOf(no, i + 1);
    }
    return false;
  }
  function all(q){ try { return Array.prototype.slice.call(document.querySelectorAll(q)).filter(visible); } catch(e){ return []; } }
  (function check(){
    var el = null; try { el = document.querySelector(sel); } catch(e){}
    var target = null, how = '', ambiguous = false;
    if (no) {
      if (visible(el) && hasNo(txtOf(el))) { target = el; how = 'number'; }
      else {
        var hits = all(CLICKABLE).filter(function(e){ return hasNo(txtOf(e)); });
        // 入れ子（候補の行と、その中のリンク等）は内側を優先
        hits = hits.filter(function(e){ return !hits.some(function(o){ return o !== e && e.contains(o); }); });
        if (hits.length === 1) { target = hits[0]; how = 'number'; }
        else if (hits.length > 1) { ambiguous = true; }
      }
    } else {
      if (visible(el) && (!text || matches(txtOf(el), text))) { target = el; how = 'recorded'; }
      else {
        var byText = null;
        if (text) {
          var list = all(CLICKABLE);
          byText = list.find(function(e){ return txtOf(e) === text; }) || list.find(function(e){ return matches(txtOf(e), text); });
        }
        if (byText) { target = byText; how = 'text'; }
        else if (!text && visible(el)) { target = el; how = 'notext'; }
        else if (text && Date.now() - started >= 1000) {
          // 描画途中の一瞬を拾わないよう、1秒待ってから2回続けて1件だった時だけ採用
          var same = all(sel.replace(/:nth-of-type\(\d+\)/g, ''));
          sameCount = same.length;
          if (same.length === 1) { singleSeen++; if (singleSeen >= 2) { target = same[0]; how = 'single'; } }
          else { singleSeen = 0; }
        }
      }
    }
    if (target) {
      Array.prototype.forEach.call(document.querySelectorAll('[data-cap-target]'), function(e){ e.removeAttribute('data-cap-target'); });
      target.setAttribute('data-cap-target', '1');
      target.scrollIntoView({ block: 'center', inline: 'center' });
      var r = target.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      var hit = document.elementFromPoint(x, y);
      var covered = !(hit && (hit === target || target.contains(hit)));
      return resolve(JSON.stringify({ status: 'found', how: how, x: x, y: y, covered: covered, label: txtOf(target).slice(0, 40) }));
    }
    if (Date.now() > deadline) return resolve(JSON.stringify({ status: ambiguous ? 'ambiguous' : (sameCount > 1 ? 'ambiguous-same' : 'notfound'), count: sameCount }));
    setTimeout(check, 150);
  })();
})
'@
    $no = if ($Action.match_kojin_no) { [string]$Action.match_kojin_no } else { "" }
    $expr = $findJs.Replace('__SEL__', (ConvertTo-JsLiteral ([string]$Action.selector)))
    $expr = $expr.Replace('__TXT__', (ConvertTo-JsLiteral ([string]$Action.text)))
    $expr = $expr.Replace('__NO__', (ConvertTo-JsLiteral $no))
    $expr = $expr.Replace('__TO__', [string]$script:ActionTimeoutMs)
    $st = (Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true) | ConvertFrom-Json

    if ($st.status -eq 'ambiguous') {
        throw "宛名番号 $no を含む候補が複数あり、1つに決められません: $($Action.selector)"
    }
    if ($st.status -eq 'ambiguous-same') {
        throw "ボタン名 '$($Action.text)' が見つからず、同じ種類の要素が $($st.count) 件あって1つに決められません: $($Action.selector)"
    }
    if ($st.status -ne 'found') {
        if ($no) { throw "宛名番号 $no を含むクリック対象が見つかりません: $($Action.selector)" }
        throw "クリック対象が見つかりません: $($Action.selector) (ボタン名: $($Action.text))"
    }

    if ($st.covered) {
        # 座標に別の要素が重なっていてマウスが届かない → 要素を直接クリック
        Invoke-PageScriptSafe -Ws $Ws -Expression $script:ClickMarkedTargetJs | Out-Null
        $method = "直接"
    } else {
        Send-MouseClick -Ws $Ws -X ([double]$st.x) -Y ([double]$st.y)
        Invoke-PageScriptSafe -Ws $Ws -Expression $script:ClearTargetMarkJs | Out-Null
        $method = "マウス"
    }
    $how = switch ($st.how) {
        'number'   { "宛名番号一致" }
        'recorded' { "記録位置" }
        'text'     { "ボタン名一致" }
        'notext'   { "記録位置(ボタン名なし)" }
        'single'   { "同じ種類が1件のみ" }
        default    { $st.how }
    }
    Write-Host "  (クリック[$method/$how]: $($st.label))"
}

# バッチ実行の入力。欄をクリックして既存の値を消し、1文字ずつキー入力する。
function Invoke-BatchFill {
    param($Ws, $Action)
    $findJs = @'
new Promise(function (resolve) {
  var sel = __SEL__, deadline = Date.now() + __TO__;
  (function check(){
    var el = null; try { el = document.querySelector(sel); } catch(e){}
    if (el) {
      Array.prototype.forEach.call(document.querySelectorAll('[data-cap-target]'), function(e){ e.removeAttribute('data-cap-target'); });
      el.setAttribute('data-cap-target', '1');
      el.scrollIntoView({ block: 'center', inline: 'center' });
      var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      var hit = document.elementFromPoint(x, y);
      var covered = !(hit && (hit === el || el.contains(hit)));
      return resolve(JSON.stringify({ status: 'found', x: x, y: y, covered: covered }));
    }
    if (Date.now() > deadline) return resolve(JSON.stringify({ status: 'notfound' }));
    setTimeout(check, 150);
  })();
})
'@
    # 欄にフォーカスして全選択し、今の値の長さを返す
    $selectAllJs = @'
(function(){ var e=document.querySelector('[data-cap-target]'); if(!e) return -1; if(document.activeElement!==e) e.focus(); try { e.select(); } catch(_){} return (e.value||'').length; })()
'@
    $valueJs = @'
(function(){ var e=document.querySelector('[data-cap-target]'); return e ? (e.value||'') : ''; })()
'@
    $clearByScriptJs = @'
(function(){ var e=document.querySelector('[data-cap-target]'); if(!e) return false; e.value=''; e.dispatchEvent(new Event('input',{bubbles:true})); return true; })()
'@
    $expr = $findJs.Replace('__SEL__', (ConvertTo-JsLiteral ([string]$Action.selector)))
    $expr = $expr.Replace('__TO__', [string]$script:ActionTimeoutMs)
    $st = (Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true) | ConvertFrom-Json
    if ($st.status -ne 'found') { throw "入力対象が見つかりません: $($Action.selector)" }

    try {
        # 人と同じく欄をクリックしてから打つ（隠れている時はフォーカスだけ）
        if (-not $st.covered) { Send-MouseClick -Ws $Ws -X ([double]$st.x) -Y ([double]$st.y) }
        $len = [int](Invoke-PageScriptSafe -Ws $Ws -Expression $selectAllJs)
        if ($len -lt 0) { throw "入力対象が見つかりません: $($Action.selector)" }
        if ($len -gt 0) {
            Send-KeyStroke -Ws $Ws -Key "Backspace" -Code "Backspace" -KeyCode 8
            if ((Invoke-PageScriptSafe -Ws $Ws -Expression $valueJs) -ne "") {
                # 全選択が効かない欄 → Ctrl+A → Backspace、それでも残れば値を直接消す
                Send-KeyStroke -Ws $Ws -Key "a" -Code "KeyA" -KeyCode 65 -Modifiers 2
                Send-KeyStroke -Ws $Ws -Key "Backspace" -Code "Backspace" -KeyCode 8
                if ((Invoke-PageScriptSafe -Ws $Ws -Expression $valueJs) -ne "") {
                    Invoke-PageScriptSafe -Ws $Ws -Expression $clearByScriptJs | Out-Null
                }
            }
        }

        $value = [string]$Action.value
        Send-KeyText -Ws $Ws -Text $value
        $actual = [string](Invoke-PageScriptSafe -Ws $Ws -Expression $valueJs)
        Write-Host "  (入力[キー入力]: $($Action.selector) = $value → 欄の値: $actual)"
        if ($actual.Trim() -ne $value.Trim()) {
            Write-Warning "入力後の欄の値が記録と違います（期待: $value / 実際: $actual）。書式を整える欄なら問題ありません。"
        }
    } finally {
        Invoke-PageScriptSafe -Ws $Ws -Expression $script:ClearTargetMarkJs | Out-Null
    }
}

# ---------------------------------------------------------------------------
# アクション実行
# ---------------------------------------------------------------------------
function Invoke-CapAction {
    param($Ws, $Action, [int]$SettleMs)

    switch ($Action.type) {
        "click" {
            # バッチ実行は本物のマウス操作＋宛名番号での照合（見つからなければその件を打ち切る）
            if ($script:BatchMode) { Invoke-BatchClick -Ws $Ws -Action $Action; break }

            # ハイブリッド特定：セレクタで当てた要素を「記録時のボタン名(text/aria-label)」で検証する。
            # 権限差などでDOMの順番が変わり、位置セレクタが“別要素”に当たった場合はラベルで探し直す。
            $sel = ConvertTo-JsLiteral $Action.selector
            $txt = ConvertTo-JsLiteral ([string]$Action.text)
            $to  = $script:ActionTimeoutMs
            $expr = @"
new Promise((resolve) => {
  const sel = $sel, text = $txt, deadline = Date.now() + $to;
  function visible(e){ return e && (e.offsetParent !== null || (e.getClientRects && e.getClientRects().length > 0)); }
  function txtOf(e){
    var s=(e.innerText||e.textContent||'').trim();
    if(!s){ try { s=((e.getAttribute('aria-label')||e.getAttribute('title'))||'').trim(); } catch(_){} }
    return s;
  }
  function matches(a,b){
    if(!a||!b) return false;
    if(a===b) return true;
    return (b.length>=2 && a.indexOf(b)>=0) || (a.length>=2 && b.indexOf(a)>=0);
  }
  function byText(){
    if (!text) return null;
    var list = Array.prototype.slice.call(document.querySelectorAll('a,button,[role=button],[role=tab],[role=menuitem],[role=link],[role=option],li,[tabindex],[onclick]')).filter(visible);
    return list.find(function(e){ return txtOf(e) === text; })
        || list.find(function(e){ return matches(txtOf(e), text); });
  }
  function go(e,how){ e.scrollIntoView({block:'center'}); e.click(); return resolve(how); }
  (function check(){
    var el = null; try { el = document.querySelector(sel); } catch(e){}
    // 1) セレクタが当たり、かつ(テキスト未記録 or ラベル一致) → それをクリック
    if (visible(el) && (!text || matches(txtOf(el), text))) return go(el, 'clicked');
    // 2) ラベル一致の要素を探す（順番が変わっても“ボタン名”で当てる）
    var c = byText();
    if (c) return go(c, 'text');
    // 3) テキスト情報が無い時（アイコン等）は位置一致のセレクタ要素をクリック
    if (visible(el) && !text) return go(el, 'clicked-notext');
    // 4) テキストはあるが一致要素が無い → まだ描画中かもしれないので待つ
    if (Date.now() > deadline) return resolve('notfound');
    setTimeout(check, 150);
  })();
})
"@
            $st = Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true
            switch ($st) {
                'notfound'       { Write-Warning "クリック対象が見つかりません(スキップ): $($Action.selector)" }
                'text'           { Write-Host "  (ボタン名一致でクリック: $($Action.text))" }
                'clicked-notext' { Write-Host "  (位置一致でクリック: $($Action.selector))" }
            }
        }
        "fill" {
            # バッチ実行は本物のキー入力（キーを離した時に検索する部品でも候補が出るように）
            if ($script:BatchMode) { Invoke-BatchFill -Ws $Ws -Action $Action; break }

            $sel = ConvertTo-JsLiteral $Action.selector
            $val = ConvertTo-JsLiteral $Action.value
            $to  = $script:ActionTimeoutMs
            $expr = @"
new Promise((resolve) => {
  const sel = $sel, val = $val, deadline = Date.now() + $to;
  (function check(){
    var el = null; try { el = document.querySelector(sel); } catch(e){}
    if (el) {
      el.focus(); el.value = val;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return resolve('ok');
    }
    if (Date.now() > deadline) return resolve('notfound');
    setTimeout(check, 150);
  })();
})
"@
            $st = Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true
            if ($st -eq 'notfound') { Write-Warning "入力対象が見つかりません(スキップ): $($Action.selector)" }
        }
        "wait" {
            $timeout = if ($Action.timeout) { [int]$Action.timeout } else { 5000 }
            if ($Action.selector) {
                $sel = ConvertTo-JsLiteral $Action.selector
                $expr = @"
new Promise((resolve, reject) => {
  const deadline = Date.now() + $timeout;
  (function check() {
    if (document.querySelector($sel)) return resolve(true);
    if (Date.now() > deadline) return reject(new Error('wait timeout: ' + $sel));
    setTimeout(check, 100);
  })();
})
"@
                Invoke-PageScript -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
            } else {
                Start-Sleep -Milliseconds $timeout
            }
        }
        "goto" {
            if ($script:SpaMode) {
                # SPA(認証あり)向け: リロードせず history.pushState でルートだけ変更し、
                # ロード済みアプリの認証状態を保ったまま画面遷移する（同一オリジンのみ）。
                $u = ConvertTo-JsLiteral $Action.url
                $expr = @"
(function(u){
  try {
    var t = new URL(u, location.href);
    if (t.origin !== location.origin) { location.href = u; return 'hard'; }
    history.pushState({}, '', t.pathname + t.search + t.hash);
    window.dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
    window.dispatchEvent(new Event('hashchange'));
    return 'soft';
  } catch (e) { location.href = u; return 'err'; }
})($u)
"@
                Invoke-PageScriptSafe -Ws $Ws -Expression $expr | Out-Null
                Wait-PageReady -Ws $Ws -SettleMs $SettleMs
            } else {
                Invoke-CdpCommand -Ws $Ws -Method "Page.navigate" -Params @{ url = $Action.url } | Out-Null
                Wait-PageReady -Ws $Ws -SettleMs $SettleMs
            }
        }
        "select" {
            $sel = ConvertTo-JsLiteral $Action.selector
            $val = ConvertTo-JsLiteral $Action.value
            $to  = $script:ActionTimeoutMs
            $expr = @"
new Promise((resolve) => {
  const sel = $sel, val = $val, deadline = Date.now() + $to;
  (function check(){
    var el = null; try { el = document.querySelector(sel); } catch(e){}
    if (el) {
      el.value = val;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return resolve('ok');
    }
    if (Date.now() > deadline) return resolve('notfound');
    setTimeout(check, 150);
  })();
})
"@
            $st = Invoke-PageScriptSafe -Ws $Ws -Expression $expr -AwaitPromise $true
            if ($st -eq 'notfound') {
                if ($script:BatchMode) { throw "選択対象が見つかりません: $($Action.selector)" }
                Write-Warning "選択対象が見つかりません(スキップ): $($Action.selector)"
            }
        }
        "keyboard" {
            $key = ConvertTo-JsLiteral $Action.key
            $expr = @"
new Promise((resolve) => {
  const el = document.activeElement || document.body;
  const opt = { key: $key, bubbles: true };
  el.dispatchEvent(new KeyboardEvent('keydown', opt));
  el.dispatchEvent(new KeyboardEvent('keypress', opt));
  el.dispatchEvent(new KeyboardEvent('keyup', opt));
  resolve(true);
})
"@
            Invoke-PageScript -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
        }
        default {
            Write-Host "  未知のアクション: $($Action.type)"
        }
    }
}

# ---------------------------------------------------------------------------
# ビューポート（デバイスメトリクス）を上書きしてウィンドウ幅に依存しない描画にする
# ---------------------------------------------------------------------------
function Set-Viewport {
    param($Ws, [int]$Width, [int]$Height, [double]$Scale)
    $params = @{
        width             = $Width
        height            = $Height
        deviceScaleFactor = $Scale
        mobile            = $false
    }
    Invoke-CdpCommand -Ws $Ws -Method "Emulation.setDeviceMetricsOverride" -Params $params | Out-Null
}

# ---------------------------------------------------------------------------
# スクリーンショット
# ---------------------------------------------------------------------------
# 本文の実スクロール高さ（内側スクロール領域も考慮）をCSSピクセルで測る。
# SPA(html,body=overflow:hidden + 内側divがスクロール)でも全高さを取得できる。
$script:MeasureHeightJs = @'
(function(){
  var d=document.documentElement, b=document.body;
  var max=Math.max(d.scrollHeight||0, d.clientHeight||0, d.offsetHeight||0,
                   b?b.scrollHeight:0, b?b.offsetHeight:0);
  var els = b ? b.getElementsByTagName('*') : [];
  for (var i=0;i<els.length;i++){
    var e=els[i];
    if (e.scrollHeight > max && e.scrollHeight > e.clientHeight + 1){
      var ov=''; try { ov=getComputedStyle(e).overflowY; } catch(_){}
      if (ov==='auto' || ov==='scroll'){ max=e.scrollHeight; }
    }
  }
  return Math.ceil(max);
})()
'@

# 同一オリジンの iframe を中身の実サイズまで一時的に拡大する（埋め込み帳票プレビュー等の見切れ対策）。
# 祖先のクリップ(overflow)も解除して、大きくなった iframe が切られないようにする。
# 戻り値: {resized:bool, cross:bool(クロスオリジンで展開不可のiframeがあったか)}
$script:PrepareIframesJs = @'
(function(){
  var changed=[], cross=false, resized=false;
  function set(el,prop,val){ changed.push([el,prop,el.style.getPropertyValue(prop),el.style.getPropertyPriority(prop)]); el.style.setProperty(prop,val,'important'); }
  var frames=document.getElementsByTagName('iframe');
  for(var i=0;i<frames.length;i++){
    var f=frames[i], r=f.getBoundingClientRect();
    if(r.width<2 && r.height<2) continue;
    var doc=null; try{ doc=f.contentDocument || (f.contentWindow && f.contentWindow.document); }catch(e){ doc=null; }
    if(!doc || !doc.documentElement){ cross=true; continue; }
    var de=doc.documentElement, bd=doc.body;
    var iw=Math.max(de.scrollWidth||0, bd?bd.scrollWidth:0);
    var ih=Math.max(de.scrollHeight||0, bd?bd.scrollHeight:0);
    if(iw<=r.width+1 && ih<=r.height+1) continue;
    resized=true;
    set(f,'flex','none'); set(f,'min-width','0px'); set(f,'min-height','0px');
    set(f,'max-width','none'); set(f,'max-height','none');
    if(iw>0) set(f,'width', iw+'px');
    if(ih>0) set(f,'height', ih+'px');
    var anc=f.parentElement;
    while(anc && anc!==document.documentElement){
      var acs=null; try{ acs=getComputedStyle(anc); }catch(_){}
      if(acs && (acs.overflowX!=='visible' || acs.overflowY!=='visible')) set(anc,'overflow','visible');
      set(anc,'max-width','none'); set(anc,'max-height','none');
      anc=anc.parentElement;
    }
  }
  window.__capIframeRestore=changed;
  return JSON.stringify({resized:resized, cross:cross});
})()
'@

# PrepareIframesJs で変更したスタイルを元に戻す
$script:IframeRestoreJs = @'
(function(){ try{ var c=window.__capIframeRestore||[]; for(var i=0;i<c.length;i++){ var it=c[i]; if(it[2]) it[0].style.setProperty(it[1],it[2],it[3]||''); else it[0].style.removeProperty(it[1]); } window.__capIframeRestore=null; }catch(e){} return true; })()
'@

# ページ全体の必要サイズ "w,h" を測る。document のスクロールサイズに加え、
# iframe（拡大後の実サイズ）と縦スクロール領域(overflowY:auto/scroll)を考慮する。
$script:MeasureSizeJs = @'
(function(){
  var d=document.documentElement, b=document.body;
  var w=Math.max(d.scrollWidth||0, b?b.scrollWidth:0, d.clientWidth||0);
  var h=Math.max(d.scrollHeight||0, b?b.scrollHeight:0, d.clientHeight||0);
  var sx=window.scrollX||d.scrollLeft||0, sy=window.scrollY||d.scrollTop||0;
  var els=b?b.getElementsByTagName('*'):[];
  for(var i=0;i<els.length;i++){
    var e=els[i], tag=(e.tagName||'').toLowerCase(), r=e.getBoundingClientRect();
    if(tag==='iframe'){
      var right=r.left+sx+(e.offsetWidth||r.width), bottom=r.top+sy+(e.offsetHeight||r.height);
      if(right>w) w=right; if(bottom>h) h=bottom;
    } else if(e.scrollHeight>e.clientHeight+1){
      var ov=''; try{ ov=getComputedStyle(e).overflowY; }catch(_){}
      if(ov==='auto'||ov==='scroll'){ var bb=r.top+sy+e.scrollHeight; if(bb>h) h=bb; }
    }
  }
  return Math.ceil(w)+","+Math.ceil(h);
})()
'@

# 表示中のモーダル/ポップアップを検出し、全体を撮れるよう一時的に整える。
#   - ダイアログを左上(0,0)へ固定し、サイズ制約(max-width/height)を解除
#   - 内部の横/縦スクロール領域の overflow を visible にして全内容を展開
#   - data-capmodal="1" を付与し、変更内容を window.__capModalRestore に退避（復元用）
# 戻り値: {found:bool, w, h}（CSSピクセルの必要サイズ）
$script:ModalPrepareJs = @'
(function(){
  function vis(e){ return e && (e.offsetParent!==null || (e.getClientRects && e.getClientRects().length>0)); }
  function area(e){ var r=e.getBoundingClientRect(); return r.width*r.height; }
  var changed=[];
  function set(el,prop,val){ changed.push([el,prop,el.style.getPropertyValue(prop),el.style.getPropertyPriority(prop)]); el.style.setProperty(prop,val,'important'); }
  // 1) マスク/オーバーレイ（全画面の背景）を探す
  var maskSel=['.p-dialog-mask','.p-component-overlay','.modal.show','.modal.in','.modal',
               '.el-overlay','.ant-modal-wrap','.ant-modal-root','.MuiModal-root',
               '.cdk-overlay-container','[aria-modal="true"]','[role=dialog]'];
  var mask=null, best=0, i, j;
  for (i=0;i<maskSel.length;i++){
    var ns; try { ns=document.querySelectorAll(maskSel[i]); } catch(e){ continue; }
    for (j=0;j<ns.length;j++){ var e2=ns[j]; if(!vis(e2)) continue; var a=area(e2); if(a>best && a>1600){ best=a; mask=e2; } }
  }
  if(!mask){
    // 汎用: 高z-indexで大きく覆う position:fixed 要素
    var vw=window.innerWidth, vh=window.innerHeight, ar=vw*vh, all=document.body?document.body.getElementsByTagName('*'):[], k;
    for (k=0;k<all.length;k++){
      var x=all[k], cs; try{ cs=getComputedStyle(x); }catch(_){ continue; }
      if(cs.position!=='fixed') continue;
      if(cs.visibility==='hidden'||cs.display==='none'||parseFloat(cs.opacity||'1')<0.1) continue;
      var z=parseInt(cs.zIndex,10); if(isNaN(z)) z=0; if(z<100) continue;
      var rr=x.getBoundingClientRect();
      if(rr.width*rr.height>ar*0.5 && rr.width>vw*0.5 && rr.height>vh*0.4){ mask=x; break; }
    }
  }
  if(!mask) return JSON.stringify({found:false});
  // 2) マスク内の実ダイアログ本体を探す（無ければマスク自身を対象）
  var dlg=null;
  try { dlg=mask.querySelector('.p-dialog,.modal-dialog,.modal-content,.el-dialog,.ant-modal,.MuiDialog-paper,.v-dialog__content,[role=dialog]'); } catch(e){}
  if(!dlg || !vis(dlg)) dlg=mask;
  // 3) 祖先の transform/overflow を一時無効化（position:fixed をビューポート基準にし、クリップを防ぐ）
  var anc=dlg.parentElement;
  while(anc && anc!==document.documentElement){
    var acs=null; try{ acs=getComputedStyle(anc); }catch(_){}
    if(acs && ((acs.transform&&acs.transform!=='none')||(acs.filter&&acs.filter!=='none'))){ set(anc,'transform','none'); set(anc,'filter','none'); }
    set(anc,'overflow','visible');
    anc=anc.parentElement;
  }
  // 4) ダイアログを左上(0,0)へ固定＋サイズ制約を解除
  set(dlg,'position','fixed'); set(dlg,'left','0px'); set(dlg,'top','0px');
  set(dlg,'right','auto'); set(dlg,'bottom','auto'); set(dlg,'margin','0px');
  set(dlg,'transform','none'); set(dlg,'max-width','none'); set(dlg,'max-height','none'); set(dlg,'overflow','visible');
  // 5) 内部要素のクリップ(overflow)を一時解除。中間コンテナ(.p-dialog-content等)が
  //    overflow:hidden/固定幅ではみ出しを切ってしまうのを防ぐ。
  //    スクロール中の要素はサイズ制約(max-width/height)も解除して全内容を展開する。
  var inner=dlg.getElementsByTagName('*');
  for (var m=0;m<inner.length;m++){
    var y=inner[m];
    var scrollable = (y.scrollWidth>y.clientWidth+1 || y.scrollHeight>y.clientHeight+1);
    var ycs=null; try{ ycs=getComputedStyle(y); }catch(_){}
    var clips = ycs && (ycs.overflowX!=='visible' || ycs.overflowY!=='visible');
    if(scrollable){ set(y,'overflow','visible'); set(y,'max-width','none'); set(y,'max-height','none'); }
    else if(clips){ set(y,'overflow','visible'); }
  }
  dlg.setAttribute('data-capmodal','1');
  window.__capModalRestore=changed;
  // overflow:visible 展開後は scrollWidth が箱サイズに戻り当てにならないので、
  // 全子孫の描画範囲(右端/下端)から実サイズを求める（dlgは0,0固定なので right=実幅）。
  var maxR=0, maxB=0, b0=dlg.getBoundingClientRect();
  if(b0.right>maxR) maxR=b0.right; if(b0.bottom>maxB) maxB=b0.bottom;
  var alld=dlg.getElementsByTagName('*');
  for(var q=0;q<alld.length;q++){ var qr=alld[q].getBoundingClientRect(); if(qr.width>0||qr.height>0){ if(qr.right>maxR)maxR=qr.right; if(qr.bottom>maxB)maxB=qr.bottom; } }
  return JSON.stringify({found:true, w:Math.ceil(maxR), h:Math.ceil(maxB)});
})()
'@

# 準備後（ビューポート拡張後）に、モーダルの必要サイズを測り直す。戻り値 "w,h"
$script:ModalMeasureJs = @'
(function(){ var e=document.querySelector('[data-capmodal="1"]'); if(!e) return "0,0"; var maxR=0,maxB=0,b=e.getBoundingClientRect(); if(b.right>maxR)maxR=b.right; if(b.bottom>maxB)maxB=b.bottom; var all=e.getElementsByTagName('*'); for(var i=0;i<all.length;i++){ var r=all[i].getBoundingClientRect(); if(r.width>0||r.height>0){ if(r.right>maxR)maxR=r.right; if(r.bottom>maxB)maxB=r.bottom; } } return Math.ceil(maxR)+","+Math.ceil(maxB); })()
'@

# ModalPrepareJs で変更したスタイルを元に戻す
$script:ModalRestoreJs = @'
(function(){ try{ var el=document.querySelector('[data-capmodal="1"]'); if(el) el.removeAttribute('data-capmodal'); var c=window.__capModalRestore||[]; for(var i=0;i<c.length;i++){ var it=c[i]; if(it[2]) it[0].style.setProperty(it[1],it[2],it[3]||''); else it[0].style.removeProperty(it[1]); } window.__capModalRestore=null; }catch(e){} return true; })()
'@

function Save-Screenshot {
    param($Ws, [string]$Path, [bool]$FullPage)

    $params = @{ format = "png" }
    $expanded = $false
    $modalPrepared = $false
    $iframePrepared = $false
    if ($FullPage) {
        $cap = 16384   # Chromiumのスクショ上限の目安
        $mi = $null
        try { $j = Invoke-PageScriptSafe -Ws $Ws -Expression $script:ModalPrepareJs; if ($j) { $mi = $j | ConvertFrom-Json } } catch {}
        if ($mi -and $mi.found) {
            # ポップアップ/モーダル: ダイアログ全体（横スクロール含む）を展開して撮る
            $modalPrepared = $true
            $mw = [int]$mi.w; $mh = [int]$mi.h
            if ($mw -lt 1) { $mw = $script:VpWidth }
            if ($mh -lt 1) { $mh = $script:VpHeight }
            if ($mw -gt $cap) { $mw = $cap }
            if ($mh -gt $cap) { $mh = $cap }
            Set-Viewport -Ws $Ws -Width ([Math]::Max($script:VpWidth,$mw)) -Height ([Math]::Max($script:VpHeight,$mh)) -Scale $script:VpScale
            $expanded = $true
            Start-Sleep -Milliseconds 400
            # 拡張後にレイアウトが変わることがあるので測り直し、必要なら更に広げる
            $mm = ("" + (Invoke-PageScriptSafe -Ws $Ws -Expression $script:ModalMeasureJs)) -split ','
            $mw2 = [int]$mm[0]; $mh2 = if ($mm.Count -gt 1) { [int]$mm[1] } else { 0 }
            if ($mw2 -gt $cap) { $mw2 = $cap }
            if ($mh2 -gt $cap) { $mh2 = $cap }
            if ($mw2 -gt $mw -or $mh2 -gt $mh) {
                if ($mw2 -gt $mw) { $mw = $mw2 }
                if ($mh2 -gt $mh) { $mh = $mh2 }
                Set-Viewport -Ws $Ws -Width ([Math]::Max($script:VpWidth,$mw)) -Height ([Math]::Max($script:VpHeight,$mh)) -Scale $script:VpScale
                Start-Sleep -Milliseconds 300
            }
            Write-Host "  (ポップアップ全体を撮影: ${mw}x${mh})"
            $params.captureBeyondViewport = $true
            $params.clip = @{ x = 0; y = 0; width = $mw; height = $mh; scale = 1 }
        } else {
            # 通常ページ: 同一originのiframe(帳票プレビュー等)を内容サイズに拡大してから、
            # 幅・高さを測り、その大きさまでビューポートを広げて撮る（縦横とも見切れ対策）
            try {
                $ifr = ("" + (Invoke-PageScriptSafe -Ws $Ws -Expression $script:PrepareIframesJs)) | ConvertFrom-Json
                if ($ifr -and $ifr.cross) { Write-Warning "別サイト(クロスオリジン)のiframeは中身を展開できません（一部見切れる場合があります）" }
            } catch {}
            $iframePrepared = $true

            $sz = ("" + (Invoke-PageScriptSafe -Ws $Ws -Expression $script:MeasureSizeJs)) -split ','
            $w = [int]$sz[0]; $full = if ($sz.Count -gt 1) { [int]$sz[1] } else { 0 }
            if ($w -lt 1) { $w = $script:VpWidth }
            if ($full -lt 1) { $full = $script:VpHeight }
            if ($w -gt $cap) { $w = $cap }
            if ($full -gt $cap) { $full = $cap }
            $dw = [Math]::Max($script:VpWidth, $w)
            Set-Viewport -Ws $Ws -Width $dw -Height $full -Scale $script:VpScale
            $expanded = $true
            Start-Sleep -Milliseconds 400
            # 遅延ロードやレイアウト変化に備えて再測定し、必要なら更に広げる
            $sz2 = ("" + (Invoke-PageScriptSafe -Ws $Ws -Expression $script:MeasureSizeJs)) -split ','
            $w2 = [int]$sz2[0]; $h2 = if ($sz2.Count -gt 1) { [int]$sz2[1] } else { 0 }
            if ($w2 -gt $cap) { $w2 = $cap }
            if ($h2 -gt $cap) { $h2 = $cap }
            if ($w2 -gt $w -or $h2 -gt $full) {
                if ($w2 -gt $w) { $w = $w2 }
                if ($h2 -gt $full) { $full = $h2 }
                $dw = [Math]::Max($script:VpWidth, $w)
                Set-Viewport -Ws $Ws -Width $dw -Height $full -Scale $script:VpScale
                Start-Sleep -Milliseconds 300
            }
            if ($dw -gt $script:VpWidth) { Write-Host "  (横方向も展開して撮影: ${dw}x${full})" }
            $params.captureBeyondViewport = $true
            $params.clip = @{ x = 0; y = 0; width = $dw; height = $full; scale = 1 }
        }
    }
    $result = Invoke-CdpCommand -Ws $Ws -Method "Page.captureScreenshot" -Params $params
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($result.data))

    if ($modalPrepared) {
        # 一時的に変更したモーダルのスタイルを元に戻す
        try { Invoke-PageScriptSafe -Ws $Ws -Expression $script:ModalRestoreJs | Out-Null } catch {}
    }
    if ($iframePrepared) {
        # 一時的に拡大した iframe のスタイルを元に戻す
        try { Invoke-PageScriptSafe -Ws $Ws -Expression $script:IframeRestoreJs | Out-Null } catch {}
    }
    if ($expanded) {
        # 広げたビューポートを元のサイズに戻す
        Set-Viewport -Ws $Ws -Width $script:VpWidth -Height $script:VpHeight -Scale $script:VpScale
    }
}

# ---------------------------------------------------------------------------
# タブ一覧表示
# ---------------------------------------------------------------------------
function Show-Tabs {
    param([string]$BaseUrl)
    $tabs = Get-CdpTabs -BaseUrl $BaseUrl
    Write-Host "接続成功。ページ数: $($tabs.Count)"
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        Write-Host "  [$i] $($tabs[$i].title)"
        Write-Host "      $($tabs[$i].url)"
    }
}

# ---------------------------------------------------------------------------
# キャプチャ本体
# ---------------------------------------------------------------------------
# 戻り値: 対象タブに接続して処理できたら $true、タブが見つからなければ $false
#   -OutDir     : 出力先フォルダ（省略時は設定の output_dir）
#   -FilePrefix : ファイル名の接頭辞（省略時は実行日時）。バッチでは「宛名番号_大分類_小分類」
function Invoke-Capture {
    param($Cfg, [string]$OutDir, [string]$FilePrefix)

    $baseUrl    = if ($Cfg.cdp_url) { $Cfg.cdp_url } else { "http://localhost:9222" }
    $keyword    = if ($Cfg.target_url_keyword) { $Cfg.target_url_keyword } else { "" }
    $outputDir  = if ($OutDir) { $OutDir } elseif ($Cfg.output_dir) { $Cfg.output_dir } else { "output" }
    $fullPage   = if ($null -ne $Cfg.full_page) { [bool]$Cfg.full_page } else { $true }
    $settleMs   = if ($null -ne $Cfg.settle_ms) { [int]$Cfg.settle_ms } else { 800 }
    $pagesCfg   = if ($Cfg.pages) { @($Cfg.pages) } else { @() }

    # ビューポート設定（未指定ならデスクトップ幅をデフォルトにして縦長化を防ぐ）
    $vpWidth  = if ($Cfg.viewport.width)  { [int]$Cfg.viewport.width }  else { 1280 }
    $vpHeight = if ($Cfg.viewport.height) { [int]$Cfg.viewport.height } else { 800 }
    $vpScale  = if ($Cfg.viewport.device_scale_factor) { [double]$Cfg.viewport.device_scale_factor } else { 1 }
    # Save-Screenshot がフルページ撮影時にビューポートを一時的に広げる際に参照する
    $script:VpWidth  = $vpWidth
    $script:VpHeight = $vpHeight
    $script:VpScale  = $vpScale

    # 待機設定（ローディング中の画面を撮らないため）
    #   stable_ms      : DOMがこの時間変化しなくなったら「描画完了」とみなす
    #   load_timeout_ms: 上記を待つ最大時間（超えたら諦めて撮影）
    #   ready_selector : 指定するとこの要素が表示されるまで待つ（最も確実）
    $script:StableMs      = if ($null -ne $Cfg.stable_ms) { [int]$Cfg.stable_ms } else { 1000 }
    $script:LoadTimeoutMs = if ($null -ne $Cfg.load_timeout_ms) { [int]$Cfg.load_timeout_ms } else { 30000 }
    $script:ReadySelector = if ($Cfg.ready_selector) { [string]$Cfg.ready_selector } else { "" }
    # 要素クリック/入力で対象を待つ最大時間（超えたらスキップして継続）
    $script:ActionTimeoutMs = if ($null -ne $Cfg.action_timeout_ms) { [int]$Cfg.action_timeout_ms } else { 5000 }

    # SPA(Vue等)の認証付きシステム向け: goto をリロードせず pushState で行う
    $script:SpaMode = if ($null -ne $Cfg.spa_mode) { [bool]$Cfg.spa_mode } else { $false }

    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $prefix = if ($FilePrefix) { $FilePrefix } else { $ts }

    # 対象タブを探す
    $tabs = Get-CdpTabs -BaseUrl $baseUrl
    $target = $tabs | Where-Object { $_.url -like "*$keyword*" } | Select-Object -First 1
    if (-not $target) {
        Write-Host "対象タブが見つかりません (keyword: $keyword)"
        Write-Host "タブ一覧:"
        foreach ($t in $tabs) { Write-Host "  $($t.url)" }
        return $false
    }

    Write-Host "Edge接続成功"
    Write-Host "対象タブ: $($target.title)"

    $ws = Connect-CdpSocket -WsUrl $target.webSocketDebuggerUrl
    try {
        Invoke-CdpCommand -Ws $ws -Method "Page.enable" | Out-Null
        Set-Viewport -Ws $ws -Width $vpWidth -Height $vpHeight -Scale $vpScale
        Wait-PageReady -Ws $ws -SettleMs $settleMs

        if ($pagesCfg.Count -eq 0) {
            # ページ設定がなければ現在の画面をキャプチャ
            $single = if ($FilePrefix) { "${FilePrefix}_capture.png" } else { "capture_$ts.png" }
            $filename = Join-Path $outputDir $single
            Save-Screenshot -Ws $ws -Path $filename -FullPage $fullPage
            Write-Host "キャプチャ保存: $filename"
        } else {
            # 複数画面を巡回キャプチャ（1ページの失敗で全体を止めない）
            for ($i = 0; $i -lt $pagesCfg.Count; $i++) {
                $pageConf = $pagesCfg[$i]
                $name = if ($pageConf.name) { $pageConf.name } else { "page_{0:D3}" -f $i }
                $actions = if ($pageConf.actions) { @($pageConf.actions) } else { @() }

                try {
                    foreach ($action in $actions) {
                        Invoke-CapAction -Ws $ws -Action $action -SettleMs $settleMs
                    }
                    Wait-PageReady -Ws $ws -SettleMs $settleMs
                } catch {
                    # バッチ実行は、ずれた画面のまま撮り続けないよう、その件をここで打ち切る
                    if ($script:BatchMode) { throw "ページ '$name'（$($i + 1)/$($pagesCfg.Count)）で打ち切り: $($_.Exception.Message)" }
                    Write-Warning "ページ '$name' の操作中にエラー(撮影は継続): $_"
                }

                $filename = Join-Path $outputDir "${prefix}_${name}.png"
                try {
                    Save-Screenshot -Ws $ws -Path $filename -FullPage $fullPage
                    Write-Host "キャプチャ保存: $filename"
                } catch {
                    if ($script:BatchMode) { throw "ページ '$name'（$($i + 1)/$($pagesCfg.Count)）の撮影に失敗: $($_.Exception.Message)" }
                    Write-Warning "ページ '$name' の撮影に失敗(スキップ): $_"
                }
            }
        }
    } finally {
        try {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done",
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        } catch {}
        $ws.Dispose()
    }
    Write-Host "完了"
    return $true
}

# ---------------------------------------------------------------------------
# 操作記録（レコーディング）
# ---------------------------------------------------------------------------
# ページに監視用JSを注入し、入力(fill/select)を localStorage に溜める。
# 画面遷移そのものはPS側がURL変化を監視して検出し、goto アクションとして再現する。
$script:RecorderJs = @'
(function(){
  // 1ドキュメントにつき1回だけロード回数を加算（SPAソフト遷移では新ドキュメントにならない＝増えない）
  if (!window.__capLoadCounted){ window.__capLoadCounted = true;
    try { sessionStorage.setItem("__capLoad", String((parseInt(sessionStorage.getItem("__capLoad")||"0",10))+1)); } catch(e){}
  }
  function uniq(sel){ try { return document.querySelectorAll(sel).length === 1; } catch(e){ return false; } }
  // 自動生成され毎回変わるID（PrimeVueのpv_id_、ReactのuseId、各UIライブラリ等）は使わない
  function volatileId(id){
    return !id
      || /^pv_id_/.test(id)
      || /^:r[0-9a-z]+:?$/i.test(id)
      || /^(headlessui|radix|mui|el-id|ember|svelte|aria-)/i.test(id)
      || /[0-9]{4,}/.test(id)
      || /_[0-9]+(_|$)/.test(id);
  }
  // ハッシュ的・状態的でない安定したクラスだけ残す
  function stableClasses(el){
    if (!el.classList) return [];
    return Array.prototype.slice.call(el.classList).filter(function(c){
      return c && c.length>1
        && !/[0-9]{3,}/.test(c)
        && !/^(ng-|v-|jsx-|css-|sc-|is-|has-|active|selected|open|show|hover|focus)/.test(c)
        && !/--[0-9a-f]{4,}/.test(c)
        && !/[0-9a-f]{6,}/.test(c);
    });
  }
  function attrSel(el){
    var tag=el.tagName.toLowerCase();
    var attrs=["data-pc-section","data-pc-name","data-testid","data-test","data-cy","name","aria-label","title","role","placeholder"];
    for (var i=0;i<attrs.length;i++){
      var a=attrs[i]; var v=el.getAttribute && el.getAttribute(a);
      if(v){ var s=tag+"["+a+"=\""+(""+v).replace(/"/g,'\\"')+"\"]"; if(uniq(s)) return s; }
    }
    return null;
  }
  function cssPath(el){
    if (!el || el.nodeType !== 1) return "";
    if (el.id && !volatileId(el.id) && uniq("#"+CSS.escape(el.id))) return "#"+CSS.escape(el.id);
    var sa=attrSel(el); if(sa) return sa;
    var parts=[]; var node=el; var depth=0;
    while(node && node.nodeType===1 && node!==document.body && node!==document.documentElement && depth<12){
      if(node.id && !volatileId(node.id)){ parts.unshift("#"+CSS.escape(node.id)); break; }
      var seg=node.tagName.toLowerCase();
      var cls=stableClasses(node);
      if(cls.length){ seg += "."+cls.map(function(c){ return CSS.escape(c); }).join("."); }
      var parent=node.parentNode;
      if(parent){
        var sibs=Array.prototype.slice.call(parent.children).filter(function(c){
          if(c.tagName!==node.tagName) return false;
          if(!cls.length) return true;
          return cls.every(function(k){ return c.classList && c.classList.contains(k); });
        });
        if(sibs.length>1){ seg += ":nth-of-type("+(Array.prototype.indexOf.call(parent.children,node)+1)+")"; }
      }
      parts.unshift(seg);
      var cand=parts.join(" > ");
      try { if(document.querySelectorAll(cand).length===1) return cand; } catch(e){}
      node=parent; depth++;
    }
    return parts.join(" > ");
  }
  function push(ev){ try{ ev.url=location.href; var k="__capRec"; var arr=JSON.parse(localStorage.getItem(k)||"[]"); arr.push(ev); localStorage.setItem(k,JSON.stringify(arr)); }catch(e){} }

  // クリック対象を決める。標準的な要素が無ければ、クリック地点から数階層さかのぼって
  // 「クリック可能そうな祖先(cursor:pointer / role / aria-label / onclick / tabindex)」を探し、
  // それも無ければ アイコン要素(svg/i/icon系class)そのものを対象にする（虫眼鏡等のアイコンボタン対策）。
  function clickTarget(t0){
    if(!t0 || t0===document.body || t0===document.documentElement) return null;
    var t=t0.closest("a,button,[role=button],[role=tab],[role=menuitem],[role=link],[role=option],li,[onclick],[tabindex]");
    if(t) return t;
    var el=t0, hops=0;
    while(el && el!==document.body && el!==document.documentElement && hops<5){
      var cur=""; try{ cur=getComputedStyle(el).cursor; }catch(_){}
      if(cur==="pointer") return el;
      if(el.getAttribute && (el.getAttribute("role")||el.getAttribute("aria-label")||el.getAttribute("onclick")||el.hasAttribute("tabindex"))) return el;
      el=el.parentElement; hops++;
    }
    var tag=(t0.tagName||"").toLowerCase();
    var cls=(t0.getAttribute && (t0.getAttribute("class")||"")) || "";
    if(tag==="svg"||tag==="i"||tag==="use"||/icon|search|magnif|glass/i.test(cls)){
      return t0.closest("button,a,[role],[onclick],[tabindex],span,i,svg") || t0;
    }
    return null;
  }
  // ラベル文字列（テキスト → 自身/祖先の aria-label / title）
  function labelOf(t){
    var s=(t.innerText||t.textContent||"").trim();
    if(s) return s.slice(0,80);
    var el=t, hops=0;
    while(el && hops<3){
      var v = el.getAttribute && (el.getAttribute("aria-label")||el.getAttribute("title"));
      if(v) return (""+v).trim().slice(0,80);
      el=el.parentElement; hops++;
    }
    return "";
  }
  // テキスト入力欄へのクリックは記録しない（入力は fill で扱う）
  function isTypingTarget(t){
    var tg=(t.tagName||"").toLowerCase();
    if(tg!=="input"&&tg!=="textarea") return false;
    var ty=(t.type||"").toLowerCase();
    return ty!=="submit"&&ty!=="button"&&ty!=="checkbox"&&ty!=="radio";
  }
  function shown(e){ return e && (e.offsetParent!==null || (e.getClientRects && e.getClientRects().length>0)); }
  // マウスを押した時点の対象を覚えておく。サジェスト候補のように「押した瞬間に選ばれて消える」部品では
  // click が候補に届かないため、押した時点の要素で記録する。
  var pressed = null;
  var downH = function(e){
    pressed = null;
    if (e.button !== undefined && e.button !== 0) return;
    var t=clickTarget(e.target);
    if(!t || isTypingTarget(t)) return;
    pressed = { el:t, selector:cssPath(t), text:labelOf(t), ts:Date.now(), used:false };
  };
  var clickH = function(e){
    if (pressed && !pressed.used && Date.now() - pressed.ts < 1500) {
      pressed.used = true;
      push({type:"click", selector:pressed.selector, text:pressed.text});
      return;
    }
    var t=clickTarget(e.target);
    if(!t || isTypingTarget(t)) return;
    push({type:"click", selector:cssPath(t), text:labelOf(t)});
  };
  var upH = function(){
    var p = pressed;
    if (!p) return;
    // click は mouseup の直後に届く。届かないまま押した要素が消えていたら、押した要素で記録する
    setTimeout(function(){
      if (!p.used && (!p.el.isConnected || !shown(p.el))) {
        p.used = true;
        push({type:"click", selector:p.selector, text:p.text});
      }
      if (pressed === p) pressed = null;
    }, 50);
  };
  // テキスト系の入力欄か（チェックボックス等はクリックで記録、パスワードは記録ファイルに残さない）
  function isTextField(el){
    var tag=(el.tagName||"").toLowerCase();
    if(tag==="textarea") return true;
    if(tag!=="input") return false;
    return !/^(checkbox|radio|file|submit|button|reset|image|range|color|password|hidden)$/i.test(el.type||"");
  }
  var changeH = function(e){
    var el=e.target; var tag=(el.tagName||"").toLowerCase();
    if(tag==="select"){ push({type:"select", selector:cssPath(el), value:el.value}); }
    else if(isTextField(el)){
      // 人がキー入力した欄の change は記録しない（値は input で記録済み）。
      // サジェスト候補を選んだ後に部品が書き戻す「番号＋氏名」などを拾わないため。
      // キー入力なしで値が変わった欄（日付選択など）の change は記録する。
      // 部品が自分で change を投げた後に、欄を離れた時の change がもう一度来ることがあるので、
      // 目印は change では消さず、欄に次にフォーカスが入った時に消す。
      if (el.__capTyped) return;
      push({type:"fill", selector:cssPath(el), value:el.value});
    }
  };
  // 欄にフォーカスが入ったら「キー入力済み」の目印を消す（新しい入力の始まり）
  var focusH = function(e){
    var el=e.target;
    if(el && isTextField(el)){ el.__capTyped = false; }
  };
  // 人のキー入力。サジェスト候補のクリックでは change がクリックより後になる／発火しないことがあり、
  // 宛名番号の入力が記録から漏れるのを防ぐ（同じ欄の連続入力は記録側で最後の値にまとめる）。
  var inputH = function(e){
    var el=e.target;
    if(isTextField(el)){ el.__capTyped = true; push({type:"fill", selector:cssPath(el), value:el.value}); }
  };

  // 古いハンドラがあれば除去して最新を付け直す。
  // これにより「ページを開いたまま録り直し」ても古いcssPath実装が残らない。
  try { if(window.__capClickH)  document.removeEventListener("click",       window.__capClickH,  true); } catch(e){}
  try { if(window.__capChangeH) document.removeEventListener("change",      window.__capChangeH, true); } catch(e){}
  try { if(window.__capInputH)  document.removeEventListener("input",       window.__capInputH,  true); } catch(e){}
  try { if(window.__capDownH)   document.removeEventListener("pointerdown", window.__capDownH,   true); } catch(e){}
  try { if(window.__capUpH)     document.removeEventListener("pointerup",   window.__capUpH,     true); } catch(e){}
  try { if(window.__capFocusH)  document.removeEventListener("focusin",     window.__capFocusH,  true); } catch(e){}
  window.__capClickH = clickH;
  window.__capChangeH = changeH;
  window.__capInputH = inputH;
  window.__capDownH = downH;
  window.__capUpH = upH;
  window.__capFocusH = focusH;
  document.addEventListener("focusin",     focusH,  true);
  document.addEventListener("pointerdown", downH,   true);
  document.addEventListener("pointerup",   upH,     true);
  document.addEventListener("click",       clickH,  true);
  document.addEventListener("change",      changeH, true);
  document.addEventListener("input",       inputH,  true);
})();
'@

# 現在のURLと、溜まった入力イベントをまとめて回収してバッファをクリアするJS
$script:DrainJs = @'
(function(){try{var k="__capRec";var arr=JSON.parse(localStorage.getItem(k)||"[]");localStorage.setItem(k,"[]");var ld=0;try{ld=parseInt(sessionStorage.getItem("__capLoad")||"0",10)}catch(e){}return JSON.stringify({url:location.href,load:ld,events:arr});}catch(e){return JSON.stringify({url:"",load:0,events:[]});}})()
'@

# 記録した複数ページを、そのまま再生できる設定ファイルとして保存する（毎回上書き）
function Save-RecordedConfig {
    param($BaseCfg, $Pages, [string]$OutPath, [bool]$SpaMode = $false, [bool]$ClickNav = $false, [string]$KojinNo = "")

    $allPages = @($Pages)

    $out = [ordered]@{
        cdp_url            = if ($BaseCfg.cdp_url) { $BaseCfg.cdp_url } else { "http://localhost:9222" }
        target_url_keyword = $BaseCfg.target_url_keyword
        output_dir         = if ($BaseCfg.output_dir) { $BaseCfg.output_dir } else { "output" }
        full_page          = if ($null -ne $BaseCfg.full_page) { [bool]$BaseCfg.full_page } else { $true }
        wait_state         = if ($BaseCfg.wait_state) { $BaseCfg.wait_state } else { "networkidle" }
        settle_ms          = if ($null -ne $BaseCfg.settle_ms) { [int]$BaseCfg.settle_ms } else { 800 }
        pages              = @($allPages)
    }
    # SPA(認証付き等)を検出していれば spa_mode を有効にして保存（再生時にリロードせず遷移）
    if ($SpaMode -or $BaseCfg.spa_mode) { $out.spa_mode = $true }
    # バッチ用の記録（宛名番号を差し替えて使い回す）
    if ($ClickNav) { $out.click_nav = $true }
    if ($KojinNo)  { $out.kojin_no = $KojinNo }
    # 待機設定を引き継ぐ（指定があれば）
    if ($null -ne $BaseCfg.stable_ms)         { $out.stable_ms = [int]$BaseCfg.stable_ms }
    if ($null -ne $BaseCfg.load_timeout_ms)   { $out.load_timeout_ms = [int]$BaseCfg.load_timeout_ms }
    if ($null -ne $BaseCfg.action_timeout_ms) { $out.action_timeout_ms = [int]$BaseCfg.action_timeout_ms }
    if ($BaseCfg.ready_selector)            { $out.ready_selector = [string]$BaseCfg.ready_selector }
    if ($BaseCfg.viewport) { $out.viewport = $BaseCfg.viewport }

    $dir = Split-Path $OutPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $jsonText = $out | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($OutPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
}

# 1撮影ポイント=1ページを確定する。直前までの入力(pending)＋指定アクションを束ねる。
function Add-RecPage {
    # $Action: click/goto の ordered ハッシュ、または $null(入力のみ確定)
    # $Inputs: このページに入れる入力。省略時は保留中の入力(RecPending)を使って空にする
    param($Action, [bool]$Verbose, $Inputs = $null)
    $acts = New-Object System.Collections.ArrayList
    if ($null -ne $Inputs) {
        foreach ($p in $Inputs) { [void]$acts.Add($p) }
    } else {
        foreach ($p in $script:RecPending) { [void]$acts.Add($p) }
        $script:RecPending.Clear()
    }
    if ($Action) { [void]$acts.Add($Action) }
    if ($acts.Count -eq 0) { return }
    $script:RecIdx++
    $name = "{0}_{1:D3}" -f $script:RecPageName, $script:RecIdx
    [void]$script:RecPages.Add([ordered]@{ name = $name; actions = $acts })

    # 確定した入力を覚えておく（入力欄の change が遅れて届いた時に二重記録しないため）
    $inputs = @()
    foreach ($a in $acts) {
        if ($a.type -eq "fill" -or $a.type -eq "select") {
            $script:RecEmittedInputs["$($a.selector)"] = [string]$a.value
            $inputs += "$($a.selector)=$($a.value)"
        }
    }

    if ($Verbose) {
        $desc = if ($Action) {
            switch ($Action.type) {
                "click" { "click $($Action.selector)" }
                "goto"  { "goto $($Action.url)" }
                default { $Action.type }
            }
        } else { "(入力のみ)" }
        if ($inputs.Count -gt 0) { $desc += "  [入力: $($inputs -join ', ')]" }
        Write-Host "  画面 $($script:RecPages.Count): $desc"
    }
}

# ドレイン結果(JSON文字列)を解釈し、クリック・入力・URL遷移を順序どおりに撮影ポイント化する
function Add-RecordSample {
    param([string]$Json, [bool]$Verbose)
    if (-not $Json) { return }
    $obj = $null
    try { $obj = $Json | ConvertFrom-Json } catch { return }
    if (-not $obj) { return }

    # 1) イベント(クリック/入力)を発生順に処理
    foreach ($e in @($obj.events)) {
        if ($e.type -eq "click") {
            # クリックはすぐページ化せず“保留”する。数ポーリング以内にURLが変われば
            #   → 遷移リンク/サジェスト等 → 宛先URLへの goto として確定（URLで確実に再現できる）
            # URLが変わらなければ
            #   → ページ内クリック(タブ/モーダル等) → click として確定（ボタン名で照合）
            if ($script:RecPendingClick) { Resolve-PendingClick -Verbose $Verbose }
            $clickAct = [ordered]@{ type = "click"; selector = $e.selector }
            if ($e.text) { $clickAct.text = [string]$e.text }
            # クリック時点までの入力をこのクリックに紐付ける（クリック後の入力と順序が混ざらないように）
            $snap = New-Object System.Collections.ArrayList
            foreach ($p in $script:RecPending) { [void]$snap.Add($p) }
            $script:RecPending.Clear()
            $script:RecPendingClick = @{ action = $clickAct; inputs = $snap }
            $script:RecClickArmed = 3
            $script:RecLastClickTime = Get-Date
        }
        elseif ($e.type -eq "fill" -or $e.type -eq "select") {
            # 入力は次の撮影ポイントまで保留（同一セレクタは最後の値で上書き）
            $act = [ordered]@{ type = $e.type; selector = $e.selector; value = $e.value }
            $prev = if ($script:RecPending.Count -gt 0) { $script:RecPending[$script:RecPending.Count - 1] } else { $null }
            if ($prev -and $prev.type -eq $act.type -and $prev.selector -eq $act.selector) {
                $script:RecPending[$script:RecPending.Count - 1] = $act
            } else {
                # 既にページ/保留クリックに入った入力と同じ値が遅れて届いた（change の後着など）→ 二重記録しない
                $key = "$($act.selector)"
                $dupe = $script:RecEmittedInputs.ContainsKey($key) -and $script:RecEmittedInputs[$key] -eq [string]$act.value
                if (-not $dupe -and $script:RecPendingClick) {
                    foreach ($p in $script:RecPendingClick.inputs) {
                        if ($p.selector -eq $act.selector -and [string]$p.value -eq [string]$act.value) { $dupe = $true; break }
                    }
                }
                if ($dupe) { continue }
                [void]$script:RecPending.Add($act)
            }
        }
    }

    # 2) URL変化の処理（イベント処理の後）
    $url = $obj.url
    if ($url -and $url -ne $script:RecLastUrl) {
        # SPA判定: 同一オリジンでURLが変わったのにロード回数が増えていない＝ソフト遷移
        if ($script:RecLastUrl) {
            $sameOrigin = $false
            try { $sameOrigin = (([Uri]$url).GetLeftPart([System.UriPartial]::Authority) -eq ([Uri]$script:RecLastUrl).GetLeftPart([System.UriPartial]::Authority)) } catch {}
            if ($sameOrigin -and [int]$obj.load -le $script:RecLastLoad) { $script:RecSawSpa = $true }
        }
        if ($script:RecClickNav) {
            # バッチ用記録(-ClickNav): URL での移動(goto)は一切記録しない。
            # URL には宛名番号以外の番号（世帯番号など）が入り、別の人の画面を開いてしまうことがあるため。
            if ($script:RecPendingClick) {
                # 遷移を起こしたクリックを click のまま残す（入力した宛名番号に応じて遷移先が変わる）
                Resolve-PendingClick -Verbose $Verbose
            } elseif ($script:RecLastUrl) {
                # 直前にクリックが無いのに画面が変わった（戻る・アドレス入力など）。
                # 候補選択の後にサーバ応答を待って遅れて遷移する場合もあるので、直近のクリックから10秒以内は対象外。
                $recent = $script:RecLastClickTime -and ((Get-Date) - $script:RecLastClickTime).TotalSeconds -lt 10
                if (-not $recent) {
                    $script:RecNavWarnings++
                    Write-Warning "クリックを伴わない画面遷移がありました（戻る・アドレス入力など）。バッチでは再生できないため記録しません。画面内のボタンやメニューで操作してください。"
                }
            }
        } else {
            # 遷移が起きた → 宛先URLへの goto を撮影ポイントに。
            # （保留クリックがあればそれが起こした遷移なので、click は破棄し goto で確実に再現する。
            #   クリックに紐付けていた入力は goto の前に入れる）
            $pre = if ($script:RecPendingClick) { $script:RecPendingClick.inputs } else { $null }
            if ($null -ne $pre) {
                foreach ($p in $script:RecPending) { [void]$pre.Add($p) }
                $script:RecPending.Clear()
            }
            Add-RecPage -Action ([ordered]@{ type = "goto"; url = $url }) -Verbose $Verbose -Inputs $pre
        }
        $script:RecPendingClick = $null
        $script:RecClickArmed = 0
        $script:RecLastUrl = $url
    }
    if ($null -ne $obj.load) { $script:RecLastLoad = [int]$obj.load }
    # 猶予を1ポーリング分ずつ減衰。0になっても保留クリックが残っていれば
    # 「URLを変えないページ内クリック(タブ/モーダル等)」として確定する。
    if ($script:RecClickArmed -gt 0) {
        $script:RecClickArmed--
        if ($script:RecClickArmed -eq 0 -and $script:RecPendingClick) {
            Resolve-PendingClick -Verbose $Verbose
        }
    }
}

# 保留中のクリックを、紐付けた入力と一緒に click ページとして確定する
function Resolve-PendingClick {
    param([bool]$Verbose)
    if (-not $script:RecPendingClick) { return }
    $pc = $script:RecPendingClick
    $script:RecPendingClick = $null
    Add-RecPage -Action $pc.action -Inputs $pc.inputs -Verbose $Verbose
}

# 記録の状態を初期化する
function Initialize-RecordingState {
    param([string]$PageName, [bool]$ClickNav = $false)
    $script:RecPages         = New-Object System.Collections.ArrayList  # 確定した撮影ページ（順序どおり）
    $script:RecPending       = New-Object System.Collections.ArrayList  # 次の撮影ポイントまで保留する入力
    $script:RecLastUrl       = $null
    $script:RecPendingClick  = $null     # 後決め用に保留中のクリック（goto か click かは後で確定）
    $script:RecClickArmed    = 0         # クリック起因の遅延遷移を紐付ける残り猶予ポーリング数
    $script:RecLastLoad      = 0         # 直近のドキュメントロード回数
    $script:RecSawSpa        = $false    # SPAソフト遷移を1度でも検出したか
    $script:RecPageName      = $PageName
    $script:RecIdx           = 0
    $script:RecClickNav      = $ClickNav # バッチ用記録: URLが変わるクリックも click のまま残し、goto は作らない
    $script:RecEmittedInputs = @{}       # ページに確定済みの入力（セレクタ → 値）。後着 change の二重記録防止
    $script:RecLastClickTime = $null     # 直近のクリック時刻（クリックを伴わない遷移の判定用）
    $script:RecNavWarnings   = 0         # クリックを伴わない遷移の回数（バッチ用記録では再生できない）
}

# 記録を締めくくって保存する（保留中のクリック/入力の確定・バッチ用記録の点検・保存）
function Complete-Recording {
    param($Cfg, [string]$OutPath, [bool]$ClickNav = $false, [string]$KojinNo = "")

    # 未解決の保留クリックはページ内クリックとして確定し、残った入力も最後のページとして確定
    Resolve-PendingClick -Verbose $false
    Add-RecPage -Action $null -Verbose $false

    $pages = $script:RecPages

    Write-Host ""
    Write-Host "記録した画面数: $($pages.Count)"
    if ($script:RecSawSpa) {
        Write-Host "SPA(クライアントサイド遷移)を検出 → spa_mode=true で保存します（再生時はリロードせず遷移）。"
    }
    if ($pages.Count -eq 0) {
        Write-Host "画面が記録されませんでした。保存はスキップします。"
        return
    }

    if ($ClickNav) {
        $clickCount = 0
        foreach ($pg in $pages) { foreach ($a in $pg.actions) { if ($a.type -eq "click") { $clickCount++ } } }
        if ($clickCount -eq 0) {
            Write-Warning "クリックが1つも記録されませんでした。バッチの手順として成立しないため保存を中止します。"
            Write-Warning "  メニューのクリックから始めて、確認したい画面まで通しで操作してから Enter を押してください。"
            return
        }
        if ($pages[0].actions[0].type -ne "click") {
            Write-Warning "記録の最初の操作がクリックではありません。バッチでは件ごとに手順の先頭からやり直すため、"
            Write-Warning "  どの画面からでも押せるメニュー（検索画面を開くリンク等）のクリックから記録し直してください。"
        }
        if ($script:RecNavWarnings -gt 0) {
            Write-Warning "クリックを伴わない画面遷移が $($script:RecNavWarnings) 回ありました（記録していません）。バッチで同じ画面にたどり着けない可能性があります。"
        }
    }

    # バッチ用記録: 指定した宛名番号が記録されているか確認（無いとバッチで差し替えできない）
    if ($KojinNo) {
        $hits = Get-KojinNoHitCount -Pages $pages -KojinNo $KojinNo
        if ($hits -eq 0) {
            Write-Warning "記録内に宛名番号 '$KojinNo' の入力が見つかりません。このままではバッチで宛名番号を差し替えできません。"
            Write-Warning "検索欄に宛名番号 '$KojinNo' をそのまま入力して記録し直してください。"
        } else {
            Write-Host "宛名番号 '$KojinNo' を記録内で $hits 箇所確認しました（バッチ実行時に差し替えます）。"
        }
    } elseif ($ClickNav) {
        Write-Warning "-KojinNo が未指定です。バッチで使うには記録時の宛名番号を指定してください。"
    }

    Save-RecordedConfig -BaseCfg $Cfg -Pages $pages -OutPath $OutPath -SpaMode $script:RecSawSpa -ClickNav $ClickNav -KojinNo $KojinNo
    Write-Host "保存先: $OutPath"
    Write-Host "再生(全画面キャプチャ): .\powershell\cdp_capture.ps1 -Config `"$OutPath`""
}

function Start-Recording {
    param($Cfg, [string]$PageName, [string]$OutPath, [bool]$ClickNav = $false, [string]$KojinNo = "")

    $baseUrl = if ($Cfg.cdp_url) { $Cfg.cdp_url } else { "http://localhost:9222" }
    $keyword = if ($Cfg.target_url_keyword) { $Cfg.target_url_keyword } else { "" }

    $tabs = Get-CdpTabs -BaseUrl $baseUrl
    $target = $tabs | Where-Object { $_.url -like "*$keyword*" } | Select-Object -First 1
    if (-not $target) {
        Write-Host "対象タブが見つかりません (keyword: $keyword)"
        Write-Host "タブ一覧:"
        foreach ($t in $tabs) { Write-Host "  $($t.url)" }
        exit 1
    }

    Write-Host "Edge接続成功"
    Write-Host "記録対象タブ: $($target.title)"

    $ws = Connect-CdpSocket -WsUrl $target.webSocketDebuggerUrl
    Initialize-RecordingState -PageName $PageName -ClickNav $ClickNav
    try {
        Invoke-CdpCommand -Ws $ws -Method "Page.enable" | Out-Null
        Invoke-CdpCommand -Ws $ws -Method "Runtime.enable" | Out-Null

        # 以降に開く（遷移後の）ページにも自動で注入されるよう登録
        Invoke-CdpCommand -Ws $ws -Method "Page.addScriptToEvaluateOnNewDocument" `
            -Params @{ source = $script:RecorderJs } | Out-Null
        # 現在表示中のページにも即時注入し、バッファを初期化
        Invoke-PageScript -Ws $ws -Expression $script:RecorderJs | Out-Null
        Invoke-PageScript -Ws $ws -Expression "try{localStorage.setItem('__capRec','[]')}catch(e){}" | Out-Null

        Write-Host ""
        Write-Host "=== 操作記録を開始しました ==="
        Write-Host "ブラウザを操作してください。クリック（ページ内タブ切替を含む）・画面遷移・入力を順に記録します。"
        Write-Host "各クリック／遷移ごとに1枚キャプチャする設定になります。"
        if ($ClickNav) {
            Write-Host "[バッチ用記録]"
            Write-Host "  1. まず、どの画面からでも押せるメニュー（検索画面を開くリンク等）をクリックする"
            Write-Host "  2. 検索欄に宛名番号 $KojinNo をキーボードで入力し、サジェスト候補をクリックする"
            Write-Host "  3. 確認したい画面まで、画面内のボタンやタブで操作する（ブラウザの戻る・アドレス入力は使わない）"
        }
        Write-Host "記録を終了するには、このウィンドウで Enter キーを押してください。"
        Write-Host ""

        while ($true) {
            $json = $null
            try { $json = Invoke-PageScript -Ws $ws -Expression $script:DrainJs } catch { $json = $null }
            Add-RecordSample -Json $json -Verbose $true

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq "Enter") { break }
            }
            Start-Sleep -Milliseconds 400
        }

        # 終了直前の状態を回収し、保留中の入力があれば最後のページとして確定
        $json = $null
        try { $json = Invoke-PageScript -Ws $ws -Expression $script:DrainJs } catch { $json = $null }
        Add-RecordSample -Json $json -Verbose $false
    } finally {
        try {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done",
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        } catch {}
        $ws.Dispose()
    }

    Complete-Recording -Cfg $Cfg -OutPath $OutPath -ClickNav $ClickNav -KojinNo $KojinNo
}

# ---------------------------------------------------------------------------
# バッチ実行（別ツール出力の CSV × 対応表 → 宛名番号を差し替えて全件キャプチャ）
# ---------------------------------------------------------------------------

# テキストファイルを文字コード自動判定で読む（UTF-8(BOM有/無) → 不正なら Shift_JIS(CP932)）
# 別ツールが出力する CSV は Shift_JIS のことが多いため。
function Read-TextAuto {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)  # 不正なバイト列で例外
        return $strictUtf8.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
    }
}

# CSV を読み、チェック項目と宛名番号の組の一覧を返す。
# 形式: ヘッダなし・囲み文字なし・1行 = 「チェック項目,宛名番号」。空行は無視。
# 戻り値: Pairs（Line, Title, KojinNo の一覧）と Invalid（列が2つでない行の理由一覧）
function Read-CsvPairs {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "CSVファイルが見つかりません: $Path" }

    $pairs   = New-Object System.Collections.ArrayList
    $invalid = New-Object System.Collections.Generic.List[string]
    $lineNo = 0
    foreach ($line in ((Read-TextAuto -Path $Path) -split "`r?`n")) {
        $lineNo++
        if ($line.Trim() -eq '') { continue }
        $cols = $line -split ','
        if ($cols.Count -ne 2) {
            # 取り違え防止: 列数が合わない行は推測で読まず、その行だけ飛ばす
            $invalid.Add("${lineNo}行目: 列が2つではありません（$($cols.Count)列）: $line")
            continue
        }
        [void]$pairs.Add([pscustomobject]@{ Line = $lineNo; Title = $cols[0].Trim(); KojinNo = $cols[1].Trim() })
    }
    if ($pairs.Count -eq 0 -and $invalid.Count -eq 0) { throw "CSV に対象が1件もありません: $Path" }
    return [pscustomobject]@{ Pairs = $pairs; Invalid = $invalid }
}

# 対応表を読む
function Read-BatchMapping {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "対応表が見つかりません: $Path" }
    try { $map = (Read-TextAuto -Path $Path) | ConvertFrom-Json }
    catch { throw "対応表のJSONを読めません: $Path ($($_.Exception.Message))" }
    if (-not $map.records) { throw "対応表に records（記録の論理名 → 記録ファイル）がありません: $Path" }
    if (-not $map.items)   { throw "対応表に items（チェック項目 → 記録の論理名）がありません: $Path" }
    return $map
}

# 対応表に書かれた記録ファイルのパスを解決する（作業フォルダ基準 → 対応表の場所基準の順）
function Resolve-MappedPath {
    param([string]$Path, [string]$MappingPath)
    if (-not $Path) { return $null }
    if (Test-Path -LiteralPath $Path) { return $Path }
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $mapDir = Split-Path -Parent $MappingPath
        if ($mapDir) {
            $alt = Join-Path $mapDir $Path
            if (Test-Path -LiteralPath $alt) { return $alt }
        }
    }
    return $null
}

# 宛名番号を「前後が英数字でない位置」でだけ一致させる正規表現（11111 が 111112 の一部に当たらないように）
function Get-KojinNoPattern {
    param([string]$KojinNo)
    return '(?<![0-9A-Za-z])' + [regex]::Escape($KojinNo) + '(?![0-9A-Za-z])'
}

# 記録内（入力値・クリックのボタン名/セレクタ）に宛名番号が何箇所あるか。
# URL は数えない（URL には宛名番号以外の番号も入るため、バッチでは URL を使わない）。
function Get-KojinNoHitCount {
    param($Pages, [string]$KojinNo)
    $pattern = Get-KojinNoPattern -KojinNo $KojinNo
    $n = 0
    foreach ($page in @($Pages)) {
        foreach ($a in @($page.actions)) {
            if ($a.type -eq "fill" -and $null -ne $a.value -and [regex]::IsMatch([string]$a.value, $pattern)) { $n++ }
            elseif ($a.type -eq "click") {
                if ($a.text -and [regex]::IsMatch([string]$a.text, $pattern)) { $n++ }
                if ($a.selector -and [regex]::IsMatch([string]$a.selector, $pattern)) { $n++ }
            }
        }
    }
    return $n
}

# 記録内の宛名番号を差し替える。差し替えた箇所数を返す。
#   入力値 … 宛名番号の部分を置き換える
#   クリック … ボタン名に宛名番号が入っていたら、再生時は「新しい宛名番号を含む要素」だけで探すよう
#              match_kojin_no を付ける（氏名は人ごとに違うので照合に使わない）。セレクタ内の番号も置き換える
function Update-KojinNo {
    param($Cfg, [string]$From, [string]$To)
    $pattern = Get-KojinNoPattern -KojinNo $From
    $replacement = $To.Replace('$', '$$')   # 置換文字列中の $ を文字として扱う
    $n = 0
    foreach ($page in @($Cfg.pages)) {
        foreach ($a in @($page.actions)) {
            if ($a.type -eq "fill" -and $null -ne $a.value -and [regex]::IsMatch([string]$a.value, $pattern)) {
                $a.value = [regex]::Replace([string]$a.value, $pattern, $replacement); $n++
            }
            elseif ($a.type -eq "click") {
                if ($a.text -and [regex]::IsMatch([string]$a.text, $pattern)) {
                    $a.text = $To
                    $a | Add-Member -NotePropertyName match_kojin_no -NotePropertyValue $To -Force
                    $n++
                }
                if ($a.selector -and [regex]::IsMatch([string]$a.selector, $pattern)) {
                    $a.selector = [regex]::Replace([string]$a.selector, $pattern, $replacement); $n++
                }
            }
        }
    }
    return $n
}

# フォルダ名・ファイル名に使えない文字を _ に置き換える
function ConvertTo-SafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString().Trim()
}

# バッチ本体。全件成功なら $true、スキップ/失敗が1件でもあれば $false
function Invoke-Batch {
    param([string]$CsvFile, [string]$MappingPath, [string]$CdpUrl)

    $csv   = Read-CsvPairs -Path $CsvFile
    $pairs = $csv.Pairs
    $map   = Read-BatchMapping -Path $MappingPath

    $runTs   = Get-Date -Format "yyyyMMdd_HHmmss"
    $outRoot = if ($map.output_dir) { [string]$map.output_dir } else { "output" }
    $runDir  = Join-Path $outRoot "batch_$runTs"
    # 連続失敗がこの数に達した記録は中断する（ログアウトやシステム異常で全件失敗し続けるのを防ぐ）
    $maxFail  = if ($null -ne $map.max_consecutive_fail) { [int]$map.max_consecutive_fail } else { 5 }
    # 件と件の間の待ち(ms)
    $interval = if ($null -ne $map.interval_ms) { [int]$map.interval_ms } else { 1000 }

    Write-Host "=== バッチ実行 ==="
    Write-Host "CSV    : $CsvFile"
    Write-Host "対応表 : $MappingPath"
    Write-Host "件数   : $($pairs.Count) 件"
    Write-Host "出力先 : $runDir"

    $done    = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $failed  = New-Object System.Collections.Generic.List[string]
    $consecutiveFail = @{}   # 記録の論理名 → 連続失敗数
    $abortedRecords  = @{}   # 連続失敗で中断した記録の論理名

    # 列数が合わず読み飛ばした行
    foreach ($bad in $csv.Invalid) {
        Write-Warning "スキップ: $bad"
        $skipped.Add($bad)
    }

    $idx = 0
    foreach ($p in $pairs) {
        $idx++
        $label = "[$idx/$($pairs.Count)] $($p.Line)行目 $($p.Title) / 宛名番号 $($p.KojinNo)"
        Write-Host ""
        Write-Host "---- $label ----"

        # 宛名番号・チェック項目の形式チェック
        if (-not $p.KojinNo) { Write-Warning "スキップ: 宛名番号が空です"; $skipped.Add("$label : 宛名番号が空"); continue }
        $seg = $p.Title -split '_'
        if ($seg.Count -lt 2 -or -not $seg[0] -or -not $seg[1]) {
            Write-Warning "スキップ: チェック項目が「大分類_小分類_…」の形式ではありません"
            $skipped.Add("$label : チェック項目の形式不正"); continue
        }
        $dai = $seg[0]; $sho = $seg[1]

        # 対応表: チェック項目 → 記録の論理名 → 記録ファイル
        $itemProp = $map.items.PSObject.Properties[$p.Title]
        if (-not $itemProp) {
            Write-Warning "スキップ: 対応表の items にチェック項目が登録されていません"
            $skipped.Add("$label : 対応表(items)に未登録"); continue
        }
        $recName = [string]$itemProp.Value
        if ($abortedRecords.ContainsKey($recName)) {
            Write-Warning "スキップ: 記録 '$recName' は連続 $maxFail 件失敗したため中断しています"
            $skipped.Add("$label : 記録 '$recName' は連続失敗で中断中"); continue
        }
        $recProp = $map.records.PSObject.Properties[$recName]
        if (-not $recProp) {
            Write-Warning "スキップ: 対応表の records に記録名 '$recName' が登録されていません"
            $skipped.Add("$label : 対応表(records)に '$recName' が未登録"); continue
        }
        $recPath = Resolve-MappedPath -Path ([string]$recProp.Value) -MappingPath $MappingPath
        if (-not $recPath) {
            Write-Warning "スキップ: 記録ファイルが見つかりません: $($recProp.Value)"
            $skipped.Add("$label : 記録ファイルなし ($($recProp.Value))"); continue
        }

        # 記録を件ごとに読み直す（前の件の差し替えが残らないように）
        try { $cfg = (Read-TextAuto -Path $recPath) | ConvertFrom-Json }
        catch {
            Write-Warning "スキップ: 記録ファイルを読めません: $recPath"
            $skipped.Add("$label : 記録ファイルを読めない"); continue
        }
        if ($cfg.click_nav -ne $true) {
            Write-Warning "スキップ: 記録 '$recName' はバッチ用の記録ではありません。-ClickNav（GUIは「バッチ用に記録」）で記録し直してください"
            $skipped.Add("$label : バッチ用の記録ではない"); continue
        }
        if (-not $cfg.kojin_no) {
            Write-Warning "スキップ: 記録 '$recName' に kojin_no（記録時の宛名番号）がありません。-KojinNo を付けて記録し直してください"
            $skipped.Add("$label : 記録に kojin_no がない"); continue
        }
        # URL での移動(goto)を含む記録は使わない（URLに世帯番号などが入り、別の人の画面を開くことがある）
        $gotoCount = 0
        foreach ($pg in @($cfg.pages)) { foreach ($a in @($pg.actions)) { if ($a.type -eq "goto") { $gotoCount++ } } }
        if ($gotoCount -gt 0) {
            Write-Warning "スキップ: 記録 '$recName' に URL での移動(goto)が $gotoCount 箇所あります。別の人の画面を開くおそれがあるため、バッチ用に記録し直してください"
            $skipped.Add("$label : 記録に URL での移動(goto)を含む"); continue
        }

        # 宛名番号の差し替え。1箇所も無ければ記録時の人を撮ってしまうのでスキップ
        $n = Update-KojinNo -Cfg $cfg -From ([string]$cfg.kojin_no) -To $p.KojinNo
        if ($n -eq 0) {
            Write-Warning "スキップ: 記録 '$recName' の中に記録時の宛名番号 '$($cfg.kojin_no)' が見つからず、差し替えできません"
            $skipped.Add("$label : 記録内に記録時の宛名番号なし"); continue
        }
        Write-Host "記録 '$recName' を使用（宛名番号 $($cfg.kojin_no) → $($p.KojinNo) を $n 箇所差し替え）"
        if ($CdpUrl) { $cfg | Add-Member -NotePropertyName cdp_url -NotePropertyValue $CdpUrl -Force }

        # 出力: {論理名}_{大分類} フォルダに {宛名番号}_{大分類}_{小分類}_{ページ名}.png
        $folder = Join-Path $runDir (ConvertTo-SafeFileName "${recName}_${dai}")
        $prefix = ConvertTo-SafeFileName "$($p.KojinNo)_${dai}_${sho}"

        # バッチ実行中は本物のマウス・キー入力で操作し、合わなければその件を打ち切る
        $script:BatchMode = $true
        $itemOk = $false
        try {
            $ok = @(Invoke-Capture -Cfg $cfg -OutDir $folder -FilePrefix $prefix)[-1]
            if ($ok -eq $true) { $done.Add($label); $itemOk = $true }
            else { $failed.Add("$label : 対象タブが見つからない") }
        } catch {
            Write-Warning "失敗（この件を打ち切り）: $($_.Exception.Message)"
            $failed.Add("$label : $($_.Exception.Message)")
        } finally {
            $script:BatchMode = $false
        }

        if ($itemOk) {
            $consecutiveFail[$recName] = 0
        } else {
            $consecutiveFail[$recName] = [int]$consecutiveFail[$recName] + 1
            if ($consecutiveFail[$recName] -ge $maxFail) {
                # 連続で失敗する＝システム側の異常か記録の陳腐化。この記録を使う残りの行は飛ばす
                $abortedRecords[$recName] = $true
                Write-Warning "記録 '$recName' が連続 $($consecutiveFail[$recName]) 件失敗したため、この記録を使う残りの行は中断します。"
            }
        }
        if ($interval -gt 0) { Start-Sleep -Milliseconds $interval }
    }

    Write-Host ""
    Write-Host "=== バッチ結果 ==="
    Write-Host "成功   : $($done.Count) 件"
    Write-Host "スキップ: $($skipped.Count) 件"
    foreach ($s in $skipped) { Write-Host "  - $s" }
    Write-Host "失敗   : $($failed.Count) 件"
    foreach ($f in $failed) { Write-Host "  - $f" }
    Write-Host "出力先 : $runDir"

    return ($skipped.Count -eq 0 -and $failed.Count -eq 0)
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------
if ($List) {
    $baseUrl = if ($CdpUrl) { $CdpUrl } else { "http://localhost:9222" }
    Show-Tabs -BaseUrl $baseUrl
} elseif ($Batch) {
    if (-not $CsvFile) {
        Write-Host "-CsvFile で CSV ファイルを指定してください" -ForegroundColor Red
        exit 1
    }
    $allOk = $false
    try {
        $allOk = @(Invoke-Batch -CsvFile $CsvFile -MappingPath $Mapping -CdpUrl $CdpUrl)[-1]
    } catch {
        Write-Host "バッチを実行できません: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    # スキップ/失敗があれば非0で終了（GUIから起動した場合は結果を読めるようウィンドウが残る）
    if ($allOk -ne $true) { exit 1 }
} elseif ($Record) {
    $cfg = Get-CapConfig -Path $Config
    if ($CdpUrl) { $cfg.cdp_url = $CdpUrl }
    Start-Recording -Cfg $cfg -PageName $Name -OutPath $OutConfig -ClickNav $ClickNav.IsPresent -KojinNo $KojinNo
} else {
    $cfg = Get-CapConfig -Path $Config
    if ($CdpUrl) { $cfg.cdp_url = $CdpUrl }
    $ok = @(Invoke-Capture -Cfg $cfg)[-1]
    if ($ok -ne $true) { exit 1 }
}
