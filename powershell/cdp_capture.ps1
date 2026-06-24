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
    [string]$CdpUrl
)

$ErrorActionPreference = "Stop"
$script:CdpId = 0

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
    $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
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

# 文字列を安全なJSリテラルに変換（JSON文字列はJS文字列としても妥当）
function ConvertTo-JsLiteral {
    param([string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------------------
# 待機処理（networkidle相当はreadyState完了＋settle待ちで近似）
# ---------------------------------------------------------------------------
function Wait-PageReady {
    param($Ws, [int]$SettleMs = 800, [int]$TimeoutMs = 30000)
    $expr = @"
new Promise((resolve, reject) => {
  const deadline = Date.now() + $TimeoutMs;
  (function check() {
    if (document.readyState === 'complete') return resolve(true);
    if (Date.now() > deadline) return reject(new Error('readyState timeout'));
    setTimeout(check, 100);
  })();
})
"@
    Invoke-PageScript -Ws $Ws -Expression $expr -AwaitPromise $true | Out-Null
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
            Invoke-CdpCommand -Ws $Ws -Method "Page.navigate" -Params @{ url = $Action.url } | Out-Null
            Wait-PageReady -Ws $Ws -SettleMs $SettleMs
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
# スクリーンショット
# ---------------------------------------------------------------------------
function Save-Screenshot {
    param($Ws, [string]$Path, [bool]$FullPage)

    $params = @{ format = "png" }
    if ($FullPage) {
        $metrics = Invoke-CdpCommand -Ws $Ws -Method "Page.getLayoutMetrics"
        $size = if ($metrics.cssContentSize) { $metrics.cssContentSize } else { $metrics.contentSize }
        $w = [Math]::Ceiling([double]$size.width)
        $h = [Math]::Ceiling([double]$size.height)
        $params.captureBeyondViewport = $true
        $params.clip = @{ x = 0; y = 0; width = $w; height = $h; scale = 1 }
    }
    $result = Invoke-CdpCommand -Ws $Ws -Method "Page.captureScreenshot" -Params $params
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($result.data))
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
# エントリポイント
# ---------------------------------------------------------------------------
if ($List) {
    $baseUrl = if ($CdpUrl) { $CdpUrl } else { "http://localhost:9222" }
    Show-Tabs -BaseUrl $baseUrl
} else {
    $cfg = Get-CapConfig -Path $Config
    if ($CdpUrl) { $cfg.cdp_url = $CdpUrl }
    Invoke-Capture -Cfg $cfg
}
