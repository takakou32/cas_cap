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

.EXAMPLE
    .\powershell\cdp_capture.ps1 --list
.EXAMPLE
    .\powershell\cdp_capture.ps1 -Config config/my_config.json
#>

[CmdletBinding()]
param(
    [Alias("c")]
    [string]$Config = "config/config.json",
    [switch]$List,
    [string]$CdpUrl,
    [switch]$Record,
    [string]$Name = "recorded",
    [string]$OutConfig = "config/recorded.json"
)

$ErrorActionPreference = "Stop"
$script:CdpId = 0

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
# アクション実行
# ---------------------------------------------------------------------------
function Invoke-CapAction {
    param($Ws, $Action, [int]$SettleMs)

    switch ($Action.type) {
        "click" {
            $sel = ConvertTo-JsLiteral $Action.selector
            $expr = @"
new Promise((resolve, reject) => {
  const el = document.querySelector($sel);
  if (!el) return reject(new Error('要素が見つかりません: ' + $sel));
  el.scrollIntoView({block:'center'});
  el.click();
  resolve(true);
})
"@
            Invoke-PageScript -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
        }
        "fill" {
            $sel = ConvertTo-JsLiteral $Action.selector
            $val = ConvertTo-JsLiteral $Action.value
            $expr = @"
new Promise((resolve, reject) => {
  const el = document.querySelector($sel);
  if (!el) return reject(new Error('要素が見つかりません: ' + $sel));
  el.focus();
  el.value = $val;
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  resolve(true);
})
"@
            Invoke-PageScript -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
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
            $expr = @"
new Promise((resolve, reject) => {
  const el = document.querySelector($sel);
  if (!el) return reject(new Error('要素が見つかりません: ' + $sel));
  el.value = $val;
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  resolve(true);
})
"@
            Invoke-PageScript -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
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

function Save-Screenshot {
    param($Ws, [string]$Path, [bool]$FullPage)

    $params = @{ format = "png" }
    if ($FullPage) {
        $cap = 16384   # Chromiumのスクショ高さ上限の目安
        # 実コンテンツ高さを測り、その高さまでビューポートを広げてレイアウトを展開させる
        $full = [int](Invoke-PageScriptSafe -Ws $Ws -Expression $script:MeasureHeightJs)
        if ($full -lt 1) { $full = $script:VpHeight }
        if ($full -gt $cap) { $full = $cap }
        Set-Viewport -Ws $Ws -Width $script:VpWidth -Height $full -Scale $script:VpScale
        Start-Sleep -Milliseconds 400
        # 遅延ロードで伸びる場合に備えて再測定し、必要なら更に広げる
        $full2 = [int](Invoke-PageScriptSafe -Ws $Ws -Expression $script:MeasureHeightJs)
        if ($full2 -gt $cap) { $full2 = $cap }
        if ($full2 -gt $full) {
            Set-Viewport -Ws $Ws -Width $script:VpWidth -Height $full2 -Scale $script:VpScale
            Start-Sleep -Milliseconds 400
            $full = $full2
        }
        $params.captureBeyondViewport = $true
        $params.clip = @{ x = 0; y = 0; width = $script:VpWidth; height = $full; scale = 1 }
    }
    $result = Invoke-CdpCommand -Ws $Ws -Method "Page.captureScreenshot" -Params $params
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($result.data))

    if ($FullPage) {
        # ビューポートを元のサイズに戻す
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
function Invoke-Capture {
    param($Cfg)

    $baseUrl    = if ($Cfg.cdp_url) { $Cfg.cdp_url } else { "http://localhost:9222" }
    $keyword    = if ($Cfg.target_url_keyword) { $Cfg.target_url_keyword } else { "" }
    $outputDir  = if ($Cfg.output_dir) { $Cfg.output_dir } else { "output" }
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

    # SPA(Vue等)の認証付きシステム向け: goto をリロードせず pushState で行う
    $script:SpaMode = if ($null -ne $Cfg.spa_mode) { [bool]$Cfg.spa_mode } else { $false }

    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    # 対象タブを探す
    $tabs = Get-CdpTabs -BaseUrl $baseUrl
    $target = $tabs | Where-Object { $_.url -like "*$keyword*" } | Select-Object -First 1
    if (-not $target) {
        Write-Host "対象タブが見つかりません (keyword: $keyword)"
        Write-Host "タブ一覧:"
        foreach ($t in $tabs) { Write-Host "  $($t.url)" }
        exit 1
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
            $filename = Join-Path $outputDir "capture_$ts.png"
            Save-Screenshot -Ws $ws -Path $filename -FullPage $fullPage
            Write-Host "キャプチャ保存: $filename"
        } else {
            # 複数画面を巡回キャプチャ
            for ($i = 0; $i -lt $pagesCfg.Count; $i++) {
                $pageConf = $pagesCfg[$i]
                $name = if ($pageConf.name) { $pageConf.name } else { "page_{0:D3}" -f $i }
                $actions = if ($pageConf.actions) { @($pageConf.actions) } else { @() }

                foreach ($action in $actions) {
                    Invoke-CapAction -Ws $ws -Action $action -SettleMs $settleMs
                }

                Wait-PageReady -Ws $ws -SettleMs $settleMs

                $filename = Join-Path $outputDir "${ts}_${name}.png"
                Save-Screenshot -Ws $ws -Path $filename -FullPage $fullPage
                Write-Host "キャプチャ保存: $filename"
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
}

# ---------------------------------------------------------------------------
# 操作記録（レコーディング）
# ---------------------------------------------------------------------------
# ページに監視用JSを注入し、入力(fill/select)を localStorage に溜める。
# 画面遷移そのものはPS側がURL変化を監視して検出し、goto アクションとして再現する。
$script:RecorderJs = @'
(function(){
  if (window.__capRecInstalled) return;
  window.__capRecInstalled = true;
  // 実ドキュメントのロード回数を数える（SPAのソフト遷移ではこの注入が走らない＝増えない）
  try { sessionStorage.setItem("__capLoad", String((parseInt(sessionStorage.getItem("__capLoad")||"0",10))+1)); } catch(e){}
  function uniq(sel){ try { return document.querySelectorAll(sel).length === 1; } catch(e){ return false; } }
  function cssPath(el){
    if (!el || el.nodeType !== 1) return "";
    if (el.id && uniq("#"+CSS.escape(el.id))) return "#"+CSS.escape(el.id);
    var attrs = ["data-testid","name","aria-label","placeholder"];
    for (var i=0;i<attrs.length;i++){
      var a=attrs[i]; var v=el.getAttribute && el.getAttribute(a);
      if(v){ var s=el.tagName.toLowerCase()+"["+a+"=\""+v.replace(/"/g,'\\"')+"\"]"; if(uniq(s)) return s; }
    }
    var parts=[]; var node=el;
    while(node && node.nodeType===1 && node!==document.body && node!==document.documentElement){
      if(node.id){ parts.unshift("#"+CSS.escape(node.id)); break; }
      var part=node.tagName.toLowerCase();
      var parent=node.parentNode;
      if(parent){
        var same=[]; for(var j=0;j<parent.children.length;j++){ if(parent.children[j].tagName===node.tagName) same.push(parent.children[j]); }
        if(same.length>1){ part+=":nth-of-type("+(same.indexOf(node)+1)+")"; }
      }
      parts.unshift(part); node=parent;
    }
    return parts.join(" > ");
  }
  function push(ev){ try{ ev.url=location.href; var k="__capRec"; var arr=JSON.parse(localStorage.getItem(k)||"[]"); arr.push(ev); localStorage.setItem(k,JSON.stringify(arr)); }catch(e){} }
  document.addEventListener("change", function(e){
    var el=e.target; var tag=(el.tagName||"").toLowerCase();
    if(tag==="select"){ push({type:"select", selector:cssPath(el), value:el.value}); }
    else if(el.type==="checkbox"||el.type==="radio"){ /* 遷移はgotoで再現するため記録しない */ }
    else if(tag==="input"||tag==="textarea"){ push({type:"fill", selector:cssPath(el), value:el.value}); }
  }, true);
})();
'@

# 現在のURLと、溜まった入力イベントをまとめて回収してバッファをクリアするJS
$script:DrainJs = @'
(function(){try{var k="__capRec";var arr=JSON.parse(localStorage.getItem(k)||"[]");localStorage.setItem(k,"[]");var ld=0;try{ld=parseInt(sessionStorage.getItem("__capLoad")||"0",10)}catch(e){}return JSON.stringify({url:location.href,load:ld,events:arr});}catch(e){return JSON.stringify({url:"",load:0,events:[]});}})()
'@

# 記録した複数ページを、そのまま再生できる設定ファイルとして保存する（毎回上書き）
function Save-RecordedConfig {
    param($BaseCfg, $Pages, [string]$OutPath, [bool]$SpaMode = $false)

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
    # 待機設定を引き継ぐ（指定があれば）
    if ($null -ne $BaseCfg.stable_ms)       { $out.stable_ms = [int]$BaseCfg.stable_ms }
    if ($null -ne $BaseCfg.load_timeout_ms) { $out.load_timeout_ms = [int]$BaseCfg.load_timeout_ms }
    if ($BaseCfg.ready_selector)            { $out.ready_selector = [string]$BaseCfg.ready_selector }
    if ($BaseCfg.viewport) { $out.viewport = $BaseCfg.viewport }

    $dir = Split-Path $OutPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $jsonText = $out | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($OutPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
}

# ドレイン結果(JSON文字列)を解釈し、URL遷移と入力イベントを記録に反映する
function Add-RecordSample {
    param([string]$Json, $Visited, [hashtable]$FillsByUrl, [ref]$LastUrl, [bool]$Verbose)
    if (-not $Json) { return }
    $obj = $null
    try { $obj = $Json | ConvertFrom-Json } catch { return }
    if (-not $obj) { return }

    # 画面遷移の検出（直前と異なるURLになったら1画面として記録）
    if ($obj.url -and $obj.url -ne $LastUrl.Value) {
        # SPA判定: 同一オリジンでURLが変わったのにロード回数が増えていない＝ソフト遷移
        if ($LastUrl.Value) {
            $sameOrigin = $false
            try { $sameOrigin = (([Uri]$obj.url).GetLeftPart([System.UriPartial]::Authority) -eq ([Uri]$LastUrl.Value).GetLeftPart([System.UriPartial]::Authority)) } catch {}
            $load = [int]$obj.load
            if ($sameOrigin -and $load -le $script:RecLastLoad) { $script:RecSawSpa = $true }
        }
        [void]$Visited.Add($obj.url)
        $LastUrl.Value = $obj.url
        if ($Verbose) { Write-Host "  画面 $($Visited.Count): $($obj.url)" }
    }
    if ($null -ne $obj.load) { $script:RecLastLoad = [int]$obj.load }

    # 入力(fill/select)をその画面のURLに紐付けて蓄積（同一セレクタは最後の値で上書き）
    foreach ($e in @($obj.events)) {
        if ($e.type -ne "fill" -and $e.type -ne "select") { continue }
        $eu = if ($e.url) { $e.url } else { $LastUrl.Value }
        if (-not $eu) { continue }
        if (-not $FillsByUrl.ContainsKey($eu)) { $FillsByUrl[$eu] = New-Object System.Collections.ArrayList }
        $lst = $FillsByUrl[$eu]
        $act = [ordered]@{ type = $e.type; selector = $e.selector; value = $e.value }
        $prev = if ($lst.Count -gt 0) { $lst[$lst.Count - 1] } else { $null }
        if ($prev -and $prev.type -eq $act.type -and $prev.selector -eq $act.selector) {
            $lst[$lst.Count - 1] = $act
        } else {
            [void]$lst.Add($act)
        }
        if ($Verbose) { Write-Host "    + 入力 $($act.selector) = $($act.value)" }
    }
}

function Start-Recording {
    param($Cfg, [string]$PageName, [string]$OutPath)

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
    $visited    = New-Object System.Collections.ArrayList   # 遷移した順のURL（連続重複は除く）
    $fillsByUrl = @{}                                        # URL -> その画面で行った入力(fill/select)
    $lastUrl    = $null
    $script:RecLastLoad = 0       # 直近のドキュメントロード回数
    $script:RecSawSpa   = $false  # SPAソフト遷移を1度でも検出したか
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
        Write-Host "ブラウザで画面を遷移してください。遷移した画面を順にキャプチャ対象として記録します。"
        Write-Host "（入力(fill)・選択(select)も記録します。クリック等の遷移は goto で再現します）"
        Write-Host "記録を終了するには、このウィンドウで Enter キーを押してください。"
        Write-Host ""

        while ($true) {
            $json = $null
            try { $json = Invoke-PageScript -Ws $ws -Expression $script:DrainJs } catch { $json = $null }
            $ref = [ref]$lastUrl
            Add-RecordSample -Json $json -Visited $visited -FillsByUrl $fillsByUrl -LastUrl $ref -Verbose $true
            $lastUrl = $ref.Value

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq "Enter") { break }
            }
            Start-Sleep -Milliseconds 400
        }

        # 終了直前の状態を回収
        $json = $null
        try { $json = Invoke-PageScript -Ws $ws -Expression $script:DrainJs } catch { $json = $null }
        $ref = [ref]$lastUrl
        Add-RecordSample -Json $json -Visited $visited -FillsByUrl $fillsByUrl -LastUrl $ref -Verbose $false
        $lastUrl = $ref.Value
    } finally {
        try {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done",
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        } catch {}
        $ws.Dispose()
    }

    # 訪れた画面ごとに「goto + その画面での入力」= 1ページ（再生時に各画面を1枚ずつ撮影）
    $pages = New-Object System.Collections.ArrayList
    $idx = 0
    foreach ($u in $visited) {
        $idx++
        $acts = New-Object System.Collections.ArrayList
        [void]$acts.Add([ordered]@{ type = "goto"; url = $u })
        if ($fillsByUrl.ContainsKey($u)) {
            foreach ($a in $fillsByUrl[$u]) { [void]$acts.Add($a) }
        }
        $pname = "{0}_{1:D3}" -f $PageName, $idx
        [void]$pages.Add([ordered]@{ name = $pname; actions = @($acts) })
    }

    Write-Host ""
    Write-Host "記録した画面数: $($pages.Count)"
    if ($script:RecSawSpa) {
        Write-Host "SPA(クライアントサイド遷移)を検出 → spa_mode=true で保存します（再生時はリロードせず遷移）。"
    }
    if ($pages.Count -eq 0) {
        Write-Host "画面が記録されませんでした。保存はスキップします。"
        return
    }

    Save-RecordedConfig -BaseCfg $Cfg -Pages $pages -OutPath $OutPath -SpaMode $script:RecSawSpa
    Write-Host "保存先: $OutPath"
    Write-Host "再生(全画面キャプチャ): .\powershell\cdp_capture.ps1 -Config `"$OutPath`""
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------
if ($List) {
    $baseUrl = if ($CdpUrl) { $CdpUrl } else { "http://localhost:9222" }
    Show-Tabs -BaseUrl $baseUrl
} elseif ($Record) {
    $cfg = Get-CapConfig -Path $Config
    if ($CdpUrl) { $cfg.cdp_url = $CdpUrl }
    Start-Recording -Cfg $cfg -PageName $Name -OutPath $OutConfig
} else {
    $cfg = Get-CapConfig -Path $Config
    if ($CdpUrl) { $cfg.cdp_url = $CdpUrl }
    Invoke-Capture -Cfg $cfg
}
