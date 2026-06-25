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
$form.Size = New-Object System.Drawing.Size(540, 470)
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
$gbMode.Size = New-Object System.Drawing.Size(500, 110)
$form.Controls.Add($gbMode)

$rbNormal = New-Object System.Windows.Forms.RadioButton
$rbNormal.Text = "通常キャプチャ"
$rbNormal.Location = New-Object System.Drawing.Point(15, 22)
$rbNormal.Size = New-Object System.Drawing.Size(130, 22)
$rbNormal.Checked = $true
$gbMode.Controls.Add($rbNormal)

$rbList = New-Object System.Windows.Forms.RadioButton
$rbList.Text = "タブ一覧 (--list)"
$rbList.Location = New-Object System.Drawing.Point(155, 22)
$rbList.Size = New-Object System.Drawing.Size(140, 22)
$gbMode.Controls.Add($rbList)

$rbRecord = New-Object System.Windows.Forms.RadioButton
$rbRecord.Text = "操作記録 (PSのみ)"
$rbRecord.Location = New-Object System.Drawing.Point(305, 22)
$rbRecord.Size = New-Object System.Drawing.Size(160, 22)
$gbMode.Controls.Add($rbRecord)

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

$lblModeHint = New-Object System.Windows.Forms.Label
$lblModeHint.Text = "操作記録: 遷移した画面を順に記録。コンソールで Enter を押すと、各画面を撮る設定を出力先に保存。"
$lblModeHint.Location = New-Object System.Drawing.Point(15, 80)
$lblModeHint.Size = New-Object System.Drawing.Size(475, 20)
$lblModeHint.ForeColor = [System.Drawing.Color]::DimGray
$gbMode.Controls.Add($lblModeHint)

# --- 4. エンジン & 実行 ---------------------------------------------------
$gbRun = New-Object System.Windows.Forms.GroupBox
$gbRun.Text = "4. エンジン & 実行"
$gbRun.Location = New-Object System.Drawing.Point(12, 296)
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
$lblStatus.Location = New-Object System.Drawing.Point(12, 372)
$lblStatus.Size = New-Object System.Drawing.Size(500, 40)
$lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($lblStatus)

# ---------------------------------------------------------------------------
# イベント
# ---------------------------------------------------------------------------

# 記録モードのときだけ 記録名/出力先 を有効化
$updateRecordFields = {
    $txtName.Enabled = $rbRecord.Checked
    $txtOut.Enabled  = $rbRecord.Checked
}.GetNewClosure()
$rbNormal.Add_CheckedChanged($updateRecordFields)
$rbList.Add_CheckedChanged($updateRecordFields)
$rbRecord.Add_CheckedChanged($updateRecordFields)

# 設定ファイル参照
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "JSON (*.json)|*.json|すべて (*.*)|*.*"
    $dlg.InitialDirectory = Join-Path $RepoRoot "config"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtConfig.Text = $dlg.FileName
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
        if ($rbRecord.Checked) {
            [System.Windows.Forms.MessageBox]::Show("操作記録はPowerShell版のみ対応です。エンジンをPowerShellにしてください。", "未対応") | Out-Null
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
        $a = "-Config `"$cfg`""
        if ($rbList.Checked) {
            $a += " -List"
        }
        elseif ($rbRecord.Checked) {
            $nm  = $txtName.Text.Trim()
            $out = $txtOut.Text.Trim()
            if (-not $nm)  { $nm = "recorded" }
            if (-not $out) { $out = "config/recorded.json" }
            $a += " -Record -Name `"$nm`" -OutConfig `"$out`""
        }
        if ($cdp) { $a += " -CdpUrl `"$cdp`"" }
        Start-InConsole "& '.\powershell\cdp_capture.ps1' $a"
        $lblStatus.Text = "PS版を実行しました: $a"
    }
})

[void]$form.ShowDialog()
$form.Dispose()
