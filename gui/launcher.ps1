<#
.SYNOPSIS
    CAS Cap ランチャー GUI - start_edge / cdp_capture(PS|JS) を各オプションで起動する

.DESCRIPTION
    WinFormsベースの簡易ランチャー。各ツールを実行モード・エンジンを選んで起動する。
    実行は新しいPowerShellコンソールで行うため、出力やプロンプト（記録の停止など）を
    そのまま確認・操作できる。

.EXAMPLE
    powershell -STA -ExecutionPolicy Bypass -File gui\launcher.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# リポジトリルート（このスクリプトの1つ上）
$RepoRoot = Split-Path $PSScriptRoot -Parent

# 指定コマンドを新しいPowerShellコンソールで実行する（リポジトリルートで動作）
function Start-InConsole {
    param([string]$Command)

    # 引用符の受け渡し崩れを避けるため、内側・外側とも EncodedCommand 化する。
    # 内側: 本体を子PowerShellで実行（cdp_capture.ps1 内の exit / 例外でも終了コードを取得できる）
    $inner = "Set-Location -LiteralPath '$RepoRoot'; $Command"
    $innerEnc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))

    # 外側(親ウィンドウ): 内側を実行 → 成功なら自動で閉じる / 失敗時のみ一時停止
    $wrapper = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $innerEnc; " +
               "if (`$LASTEXITCODE -ne 0) { Write-Host ''; " +
               "Write-Host 'エラーで終了しました。内容を確認してください。' -ForegroundColor Red; " +
               "[void](Read-Host 'Enter キーで閉じます') }"
    $wrapperEnc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))

    # -WorkingDirectory で .NET/Node の相対パス基準もリポジトリルートに揃える（-NoExit は付けない）
    Start-Process powershell -WorkingDirectory $RepoRoot -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $wrapperEnc
    )
}

# ---------------------------------------------------------------------------
# フォーム
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "CAS Cap ランチャー"
$form.Size = New-Object System.Drawing.Size(540, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# --- 1. Edge起動 ----------------------------------------------------------
$gbEdge = New-Object System.Windows.Forms.GroupBox
$gbEdge.Text = "1. Edge起動 (start_edge.ps1)"
$gbEdge.Location = New-Object System.Drawing.Point(12, 12)
$gbEdge.Size = New-Object System.Drawing.Size(500, 60)
$form.Controls.Add($gbEdge)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "ポート"
$lblPort.Location = New-Object System.Drawing.Point(15, 26)
$lblPort.Size = New-Object System.Drawing.Size(40, 20)
$gbEdge.Controls.Add($lblPort)

$txtPort = New-Object System.Windows.Forms.TextBox
$txtPort.Text = "9222"
$txtPort.Location = New-Object System.Drawing.Point(60, 23)
$txtPort.Size = New-Object System.Drawing.Size(70, 22)
$gbEdge.Controls.Add($txtPort)

$btnEdge = New-Object System.Windows.Forms.Button
$btnEdge.Text = "Edge起動"
$btnEdge.Location = New-Object System.Drawing.Point(390, 21)
$btnEdge.Size = New-Object System.Drawing.Size(100, 26)
$gbEdge.Controls.Add($btnEdge)

# --- 2. 共通設定 ----------------------------------------------------------
$gbCommon = New-Object System.Windows.Forms.GroupBox
$gbCommon.Text = "2. 共通設定"
$gbCommon.Location = New-Object System.Drawing.Point(12, 80)
$gbCommon.Size = New-Object System.Drawing.Size(500, 90)
$form.Controls.Add($gbCommon)

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Text = "Config"
$lblConfig.Location = New-Object System.Drawing.Point(15, 26)
$lblConfig.Size = New-Object System.Drawing.Size(70, 20)
$gbCommon.Controls.Add($lblConfig)

$txtConfig = New-Object System.Windows.Forms.TextBox
$txtConfig.Text = "config/config.json"
$txtConfig.Location = New-Object System.Drawing.Point(85, 23)
$txtConfig.Size = New-Object System.Drawing.Size(310, 22)
$gbCommon.Controls.Add($txtConfig)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "参照..."
$btnBrowse.Location = New-Object System.Drawing.Point(405, 22)
$btnBrowse.Size = New-Object System.Drawing.Size(80, 24)
$gbCommon.Controls.Add($btnBrowse)

$lblCdp = New-Object System.Windows.Forms.Label
$lblCdp.Text = "CDP URL(任意)"
$lblCdp.Location = New-Object System.Drawing.Point(15, 57)
$lblCdp.Size = New-Object System.Drawing.Size(90, 20)
$gbCommon.Controls.Add($lblCdp)

$txtCdp = New-Object System.Windows.Forms.TextBox
$txtCdp.Text = ""
$txtCdp.Location = New-Object System.Drawing.Point(105, 54)
$txtCdp.Size = New-Object System.Drawing.Size(290, 22)
$gbCommon.Controls.Add($txtCdp)

# --- 3. 実行モード --------------------------------------------------------
$gbMode = New-Object System.Windows.Forms.GroupBox
$gbMode.Text = "3. 実行モード"
$gbMode.Location = New-Object System.Drawing.Point(12, 178)
$gbMode.Size = New-Object System.Drawing.Size(500, 218)
$form.Controls.Add($gbMode)

$rbNormal = New-Object System.Windows.Forms.RadioButton
$rbNormal.Text = "通常キャプチャ"
$rbNormal.Location = New-Object System.Drawing.Point(15, 22)
$rbNormal.Size = New-Object System.Drawing.Size(110, 22)
$rbNormal.Checked = $true
$gbMode.Controls.Add($rbNormal)

$rbList = New-Object System.Windows.Forms.RadioButton
$rbList.Text = "タブ一覧"
$rbList.Location = New-Object System.Drawing.Point(130, 22)
$rbList.Size = New-Object System.Drawing.Size(95, 22)
$gbMode.Controls.Add($rbList)

$rbRecord = New-Object System.Windows.Forms.RadioButton
$rbRecord.Text = "操作記録"
$rbRecord.Location = New-Object System.Drawing.Point(230, 22)
$rbRecord.Size = New-Object System.Drawing.Size(95, 22)
$gbMode.Controls.Add($rbRecord)

$rbBatch = New-Object System.Windows.Forms.RadioButton
$rbBatch.Text = "バッチ実行"
$rbBatch.Location = New-Object System.Drawing.Point(330, 22)
$rbBatch.Size = New-Object System.Drawing.Size(110, 22)
$gbMode.Controls.Add($rbBatch)

$lblName = New-Object System.Windows.Forms.Label
$lblName.Text = "記録名"
$lblName.Location = New-Object System.Drawing.Point(15, 54)
$lblName.Size = New-Object System.Drawing.Size(50, 20)
$gbMode.Controls.Add($lblName)

$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Text = "recorded"
$txtName.Location = New-Object System.Drawing.Point(65, 51)
$txtName.Size = New-Object System.Drawing.Size(120, 22)
$txtName.Enabled = $false
$gbMode.Controls.Add($txtName)

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = "出力先"
$lblOut.Location = New-Object System.Drawing.Point(200, 54)
$lblOut.Size = New-Object System.Drawing.Size(50, 20)
$gbMode.Controls.Add($lblOut)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Text = "config/recorded.json"
$txtOut.Location = New-Object System.Drawing.Point(250, 51)
$txtOut.Size = New-Object System.Drawing.Size(235, 22)
$txtOut.Enabled = $false
$gbMode.Controls.Add($txtOut)

# 記録オプション: バッチ用に記録（サジェスト遷移をクリックのまま残す）＋記録に使う宛名番号
$chkClickNav = New-Object System.Windows.Forms.CheckBox
$chkClickNav.Text = "バッチ用に記録"
$chkClickNav.Location = New-Object System.Drawing.Point(15, 80)
$chkClickNav.Size = New-Object System.Drawing.Size(120, 22)
$chkClickNav.Enabled = $false
$gbMode.Controls.Add($chkClickNav)

$lblKojin = New-Object System.Windows.Forms.Label
$lblKojin.Text = "記録に使う宛名番号"
$lblKojin.Location = New-Object System.Drawing.Point(140, 83)
$lblKojin.Size = New-Object System.Drawing.Size(115, 20)
$gbMode.Controls.Add($lblKojin)

$txtKojin = New-Object System.Windows.Forms.TextBox
$txtKojin.Text = ""
$txtKojin.Location = New-Object System.Drawing.Point(255, 80)
$txtKojin.Size = New-Object System.Drawing.Size(140, 22)
$txtKojin.Enabled = $false
$gbMode.Controls.Add($txtKojin)

# バッチ実行: 別ツールが出力した bat と、チェック項目→記録の対応表
$lblBat = New-Object System.Windows.Forms.Label
$lblBat.Text = "bat"
$lblBat.Location = New-Object System.Drawing.Point(15, 113)
$lblBat.Size = New-Object System.Drawing.Size(50, 20)
$gbMode.Controls.Add($lblBat)

$txtBat = New-Object System.Windows.Forms.TextBox
$txtBat.Text = ""
$txtBat.Location = New-Object System.Drawing.Point(65, 110)
$txtBat.Size = New-Object System.Drawing.Size(330, 22)
$txtBat.Enabled = $false
$gbMode.Controls.Add($txtBat)

$btnBat = New-Object System.Windows.Forms.Button
$btnBat.Text = "参照..."
$btnBat.Location = New-Object System.Drawing.Point(405, 109)
$btnBat.Size = New-Object System.Drawing.Size(80, 24)
$btnBat.Enabled = $false
$gbMode.Controls.Add($btnBat)

$lblMap = New-Object System.Windows.Forms.Label
$lblMap.Text = "対応表"
$lblMap.Location = New-Object System.Drawing.Point(15, 143)
$lblMap.Size = New-Object System.Drawing.Size(50, 20)
$gbMode.Controls.Add($lblMap)

$txtMap = New-Object System.Windows.Forms.TextBox
$txtMap.Text = "config/mapping.json"
$txtMap.Location = New-Object System.Drawing.Point(65, 140)
$txtMap.Size = New-Object System.Drawing.Size(330, 22)
$txtMap.Enabled = $false
$gbMode.Controls.Add($txtMap)

$btnMap = New-Object System.Windows.Forms.Button
$btnMap.Text = "参照..."
$btnMap.Location = New-Object System.Drawing.Point(405, 139)
$btnMap.Size = New-Object System.Drawing.Size(80, 24)
$btnMap.Enabled = $false
$gbMode.Controls.Add($btnMap)

$lblModeHint = New-Object System.Windows.Forms.Label
$lblModeHint.Text = ""
$lblModeHint.Location = New-Object System.Drawing.Point(15, 172)
$lblModeHint.Size = New-Object System.Drawing.Size(475, 38)
$lblModeHint.ForeColor = [System.Drawing.Color]::DimGray
$gbMode.Controls.Add($lblModeHint)

# --- 4. エンジン & 実行 ---------------------------------------------------
$gbRun = New-Object System.Windows.Forms.GroupBox
$gbRun.Text = "4. エンジン & 実行"
$gbRun.Location = New-Object System.Drawing.Point(12, 404)
$gbRun.Size = New-Object System.Drawing.Size(500, 70)
$form.Controls.Add($gbRun)

$rbPS = New-Object System.Windows.Forms.RadioButton
$rbPS.Text = "PowerShell"
$rbPS.Location = New-Object System.Drawing.Point(15, 28)
$rbPS.Size = New-Object System.Drawing.Size(110, 22)
$rbPS.Checked = $true
$gbRun.Controls.Add($rbPS)

$rbJS = New-Object System.Windows.Forms.RadioButton
$rbJS.Text = "JavaScript (node)"
$rbJS.Location = New-Object System.Drawing.Point(135, 28)
$rbJS.Size = New-Object System.Drawing.Size(150, 22)
$gbRun.Controls.Add($rbJS)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "実行"
$btnRun.Location = New-Object System.Drawing.Point(390, 24)
$btnRun.Size = New-Object System.Drawing.Size(100, 30)
$gbRun.Controls.Add($btnRun)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = ""
$lblStatus.Location = New-Object System.Drawing.Point(12, 480)
$lblStatus.Size = New-Object System.Drawing.Size(500, 40)
$lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($lblStatus)

# ---------------------------------------------------------------------------
# イベント
# ---------------------------------------------------------------------------

# PowerShell のコマンド文字列に埋め込む引数を単一引用符で囲む（$ や ` を展開させない）
function ConvertTo-PsArg {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# 選んだモードに応じて入力欄の有効/無効と説明を切り替える
$updateModeFields = {
    $isRec   = $rbRecord.Checked
    $isBatch = $rbBatch.Checked
    $txtName.Enabled     = $isRec
    $txtOut.Enabled      = $isRec
    $chkClickNav.Enabled = $isRec
    $txtKojin.Enabled    = $isRec -and $chkClickNav.Checked
    $txtBat.Enabled      = $isBatch
    $btnBat.Enabled      = $isBatch
    $txtMap.Enabled      = $isBatch
    $btnMap.Enabled      = $isBatch
    $lblModeHint.Text = if ($isBatch) {
        "バッチ実行: bat のチェック項目×宛名番号ごとに、対応表の記録で全件を自動撮影します。事前に Edge 起動とアプリへのログインが必要です。"
    } elseif ($isRec) {
        "操作記録: 画面を順に記録し、Enter で出力先に保存。バッチ用は「バッチ用に記録」をオンにし、ここに入れた宛名番号を検索欄に入力して記録してください。"
    } elseif ($rbList.Checked) {
        "タブ一覧: 接続中の Edge のタブを表示します。"
    } else {
        "通常キャプチャ: Config の設定どおりに画面を撮影します。"
    }
}.GetNewClosure()
$rbNormal.Add_CheckedChanged($updateModeFields)
$rbList.Add_CheckedChanged($updateModeFields)
$rbRecord.Add_CheckedChanged($updateModeFields)
$rbBatch.Add_CheckedChanged($updateModeFields)
$chkClickNav.Add_CheckedChanged($updateModeFields)
& $updateModeFields

# 設定ファイル参照
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "JSON (*.json)|*.json|すべて (*.*)|*.*"
    $dlg.InitialDirectory = Join-Path $RepoRoot "config"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtConfig.Text = $dlg.FileName
    }
})

# bat 参照
$btnBat.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "バッチファイル (*.bat;*.cmd)|*.bat;*.cmd|すべて (*.*)|*.*"
    $dlg.InitialDirectory = $RepoRoot
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtBat.Text = $dlg.FileName
    }
})

# 対応表 参照
$btnMap.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "JSON (*.json)|*.json|すべて (*.*)|*.*"
    $dlg.InitialDirectory = Join-Path $RepoRoot "config"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtMap.Text = $dlg.FileName
    }
})

# Edge起動
$btnEdge.Add_Click({
    $port = $txtPort.Text.Trim()
    if ($port -notmatch '^\d+$') {
        [System.Windows.Forms.MessageBox]::Show("ポートは数値で入力してください。", "入力エラー") | Out-Null
        return
    }
    Start-InConsole "& '.\scripts\start_edge.ps1' -Port $port"
    $lblStatus.Text = "Edgeを起動しました (port: $port)"
})

# 実行（キャプチャ / 一覧 / 記録）
$btnRun.Add_Click({
    $cfg = $txtConfig.Text.Trim()
    $cdp = $txtCdp.Text.Trim()

    if ($rbJS.Checked) {
        # --- JavaScript版 ---
        if ($rbRecord.Checked -or $rbBatch.Checked) {
            [System.Windows.Forms.MessageBox]::Show("操作記録とバッチ実行はPowerShell版のみ対応です。エンジンをPowerShellにしてください。", "未対応") | Out-Null
            return
        }
        $a = "-c `"$cfg`""
        if ($rbList.Checked) { $a += " --list" }
        if ($cdp) { $a += " --cdp-url `"$cdp`"" }
        Start-InConsole "node '.\js\cdp_capture.js' $a"
        $lblStatus.Text = "JS版を実行しました: $a"
    }
    else {
        # --- PowerShell版 ---
        if ($rbBatch.Checked) {
            $bat = $txtBat.Text.Trim()
            $map = $txtMap.Text.Trim()
            if (-not $bat) {
                [System.Windows.Forms.MessageBox]::Show("bat ファイルを指定してください。", "入力エラー") | Out-Null
                return
            }
            if (-not $map) { $map = "config/mapping.json" }
            $a = "-Batch -BatFile $(ConvertTo-PsArg $bat) -Mapping $(ConvertTo-PsArg $map)"
        }
        else {
            $a = "-Config $(ConvertTo-PsArg $cfg)"
            if ($rbList.Checked) {
                $a += " -List"
            }
            elseif ($rbRecord.Checked) {
                $nm  = $txtName.Text.Trim()
                $out = $txtOut.Text.Trim()
                if (-not $nm)  { $nm = "recorded" }
                if (-not $out) { $out = "config/recorded.json" }
                $a += " -Record -Name $(ConvertTo-PsArg $nm) -OutConfig $(ConvertTo-PsArg $out)"
                if ($chkClickNav.Checked) {
                    $kno = $txtKojin.Text.Trim()
                    if (-not $kno) {
                        [System.Windows.Forms.MessageBox]::Show("バッチ用に記録する場合は、記録に使う宛名番号を入力してください。", "入力エラー") | Out-Null
                        return
                    }
                    $a += " -ClickNav -KojinNo $(ConvertTo-PsArg $kno)"
                }
            }
        }
        if ($cdp) { $a += " -CdpUrl $(ConvertTo-PsArg $cdp)" }
        Start-InConsole "& '.\powershell\cdp_capture.ps1' $a"
        $lblStatus.Text = "PS版を実行しました: $a"
    }
})

[void]$form.ShowDialog()
$form.Dispose()
