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
    // 3) テキスト情報が無い時のみ、位置一致のセレクタ要素をクリック（アイコン等）
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
            if ($st -eq 'notfound') { Write-Warning "選択対象が見つかりません(スキップ): $($Action.selector)" }
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
  var r2=dlg.getBoundingClientRect();
  var w=Math.max(dlg.scrollWidth, Math.ceil(r2.right));
  var h=Math.max(dlg.scrollHeight, Math.ceil(r2.bottom));
  return JSON.stringify({found:true, w:Math.ceil(w), h:Math.ceil(h)});
})()
'@

# 準備後（ビューポート拡張後）に、モーダルの必要サイズを測り直す。戻り値 "w,h"
$script:ModalMeasureJs = @'
(function(){ var e=document.querySelector('[data-capmodal="1"]'); if(!e) return "0,0"; var r=e.getBoundingClientRect(); var w=Math.max(e.scrollWidth,Math.ceil(r.right)); var h=Math.max(e.scrollHeight,Math.ceil(r.bottom)); return Math.ceil(w)+","+Math.ceil(h); })()
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
            # 通常ページ: 実コンテンツ高さを測り、その高さまでビューポートを広げて縦長で撮る
            $full = [int](Invoke-PageScriptSafe -Ws $Ws -Expression $script:MeasureHeightJs)
            if ($full -lt 1) { $full = $script:VpHeight }
            if ($full -gt $cap) { $full = $cap }
            Set-Viewport -Ws $Ws -Width $script:VpWidth -Height $full -Scale $script:VpScale
            $expanded = $true
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
    }
    $result = Invoke-CdpCommand -Ws $Ws -Method "Page.captureScreenshot" -Params $params
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($result.data))

    if ($modalPrepared) {
        # 一時的に変更したモーダルのスタイルを元に戻す
        try { Invoke-PageScriptSafe -Ws $Ws -Expression $script:ModalRestoreJs | Out-Null } catch {}
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
    # 要素クリック/入力で対象を待つ最大時間（超えたらスキップして継続）
    $script:ActionTimeoutMs = if ($null -ne $Cfg.action_timeout_ms) { [int]$Cfg.action_timeout_ms } else { 5000 }

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
                    Write-Warning "ページ '$name' の操作中にエラー(撮影は継続): $_"
                }

                $filename = Join-Path $outputDir "${ts}_${name}.png"
                try {
                    Save-Screenshot -Ws $ws -Path $filename -FullPage $fullPage
                    Write-Host "キャプチャ保存: $filename"
                } catch {
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
  var clickH = function(e){
    var t=clickTarget(e.target);
    if(!t) return;
    var tg=(t.tagName||"").toLowerCase();
    if(tg==="input"||tg==="textarea"){
      var ty=(t.type||"").toLowerCase();
      if(ty!=="submit"&&ty!=="button"&&ty!=="checkbox"&&ty!=="radio") return; // テキスト入力はfillで扱う
    }
    push({type:"click", selector:cssPath(t), text:labelOf(t)});
  };
  var changeH = function(e){
    var el=e.target; var tag=(el.tagName||"").toLowerCase();
    if(tag==="select"){ push({type:"select", selector:cssPath(el), value:el.value}); }
    else if(el.type==="checkbox"||el.type==="radio"){ /* クリックで記録済み */ }
    else if(tag==="input"||tag==="textarea"){ push({type:"fill", selector:cssPath(el), value:el.value}); }
  };

  // 古いハンドラがあれば除去して最新を付け直す。
  // これにより「ページを開いたまま録り直し」ても古いcssPath実装が残らない。
  try { if(window.__capClickH)  document.removeEventListener("click",  window.__capClickH,  true); } catch(e){}
  try { if(window.__capChangeH) document.removeEventListener("change", window.__capChangeH, true); } catch(e){}
  window.__capClickH = clickH;
  window.__capChangeH = changeH;
  document.addEventListener("click",  clickH,  true);
  document.addEventListener("change", changeH, true);
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

# 1撮影ポイント=1ページを確定する。直前までの入力(pending)＋指定アクションを束ねる。
function Add-RecPage {
    param($Action, [bool]$Verbose)   # $Action: click/goto の ordered ハッシュ、または $null(入力のみ確定)
    $acts = New-Object System.Collections.ArrayList
    foreach ($p in $script:RecPending) { [void]$acts.Add($p) }
    $script:RecPending.Clear()
    if ($Action) { [void]$acts.Add($Action) }
    if ($acts.Count -eq 0) { return }
    $script:RecIdx++
    $name = "{0}_{1:D3}" -f $script:RecPageName, $script:RecIdx
    [void]$script:RecPages.Add([ordered]@{ name = $name; actions = $acts })
    if ($Verbose) {
        $desc = if ($Action) {
            switch ($Action.type) {
                "click" { "click $($Action.selector)" }
                "goto"  { "goto $($Action.url)" }
                default { $Action.type }
            }
        } else { "(入力のみ)" }
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
            if ($script:RecPendingClick) { Add-RecPage -Action $script:RecPendingClick -Verbose $Verbose }
            $clickAct = [ordered]@{ type = "click"; selector = $e.selector }
            if ($e.text) { $clickAct.text = [string]$e.text }
            $script:RecPendingClick = $clickAct
            $script:RecClickArmed = 3
        }
        elseif ($e.type -eq "fill" -or $e.type -eq "select") {
            # 入力は次の撮影ポイントまで保留（同一セレクタは最後の値で上書き）
            $act = [ordered]@{ type = $e.type; selector = $e.selector; value = $e.value }
            $prev = if ($script:RecPending.Count -gt 0) { $script:RecPending[$script:RecPending.Count - 1] } else { $null }
            if ($prev -and $prev.type -eq $act.type -and $prev.selector -eq $act.selector) {
                $script:RecPending[$script:RecPending.Count - 1] = $act
            } else {
                [void]$script:RecPending.Add($act)
            }
            if ($Verbose) { Write-Host "    + 入力 $($act.selector) = $($act.value)" }
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
        # 遷移が起きた → 宛先URLへの goto を撮影ポイントに。
        # （保留クリックがあればそれが起こした遷移なので、click は破棄し goto で確実に再現する）
        Add-RecPage -Action ([ordered]@{ type = "goto"; url = $url }) -Verbose $Verbose
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
            Add-RecPage -Action $script:RecPendingClick -Verbose $Verbose
            $script:RecPendingClick = $null
        }
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
    $script:RecPages       = New-Object System.Collections.ArrayList  # 確定した撮影ページ（順序どおり）
    $script:RecPending     = New-Object System.Collections.ArrayList  # 次の撮影ポイントまで保留する入力
    $script:RecLastUrl     = $null
    $script:RecPendingClick = $null  # 後決め用に保留中のクリック（goto か click かは後で確定）
    $script:RecClickArmed  = 0       # クリック起因の遅延遷移を紐付ける残り猶予ポーリング数
    $script:RecLastLoad    = 0       # 直近のドキュメントロード回数
    $script:RecSawSpa      = $false  # SPAソフト遷移を1度でも検出したか
    $script:RecPageName    = $PageName
    $script:RecIdx         = 0
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
        # 未解決の保留クリックはページ内クリックとして確定
        if ($script:RecPendingClick) { Add-RecPage -Action $script:RecPendingClick -Verbose $false; $script:RecPendingClick = $null }
        Add-RecPage -Action $null -Verbose $false
    } finally {
        try {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done",
                [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        } catch {}
        $ws.Dispose()
    }

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
