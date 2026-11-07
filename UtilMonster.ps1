<#
.SYNOPSIS
  UtilMonster - 잔잔한 유틸리티들을 탭 하나에 모아 둔 도구

.DESCRIPTION
  modules\*.psm1 파일 하나가 탭 하나입니다. 파일을 추가하면 다음 실행부터 탭이 생깁니다.
  (모듈 작성법은 README.md 참고. 이름이 _ 로 시작하는 파일은 무시됩니다.)

  탭은 처음 선택할 때 만들어집니다(시작이 빠름). 모듈이 Eager 이면 시작할 때 바로 만듭니다.
  모듈이 백그라운드 동작(KeepAlive)을 요청하면, 창을 닫아도 트레이에서 계속 실행됩니다.

  -Minimized   창을 띄우지 않고 트레이로 시작 (백그라운드 동작 중인 모듈이 있을 때만)
  -Tab <이름>  시작할 탭 (탭 제목 또는 모듈 파일 이름의 일부)
  -SelfTest    모든 탭을 만들어 보고 결과를 출력한 뒤 종료 (-ShotDir 로 탭별 스크린샷 저장)
#>
param(
    [switch]$Minimized,
    [string]$Tab,
    [switch]$SelfTest,
    [string]$ShotDir
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppDir = $PSScriptRoot.TrimEnd('\')
$script:ModulesDir = Join-Path $script:AppDir 'modules'
$script:ConfigDir = Join-Path $script:AppDir 'config'
$script:LogDir = Join-Path $script:AppDir 'logs'
$script:CfgPath = Join-Path $script:ConfigDir 'UtilMonster.json'
New-Item -ItemType Directory -Force -Path $script:ConfigDir, $script:LogDir | Out-Null

function Write-Log([string]$msg) {
    try {
        $p = Join-Path $script:LogDir 'UtilMonster.log'
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 512KB) {
            Move-Item -LiteralPath $p -Destination "$p.old" -Force
        }
        Add-Content -LiteralPath $p -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg) -Encoding UTF8
    }
    catch { }
}

# ---- 중복 실행 방지: 이미 떠 있으면 그 창을 앞으로 가져오고 종료 ----
$sfx = if ($SelfTest) { '.SelfTest' } else { '' }
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, "Local\UtilMonster$sfx", [ref]$created)
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Local\UtilMonster.Show$sfx")
if (-not $created) { [void]$script:ShowEvent.Set(); return }

# ---- 셸 설정 ----
$script:Shell = @{ lastTab = '' }
if (Test-Path -LiteralPath $script:CfgPath) {
    try {
        $c = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.lastTab) { $script:Shell.lastTab = [string]$c.lastTab }
    }
    catch { }
}
function Save-ShellConfig {
    if ($SelfTest) { return }
    try { $script:Shell | ConvertTo-Json | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8 } catch { }
}

# ---- 창 / 트레이 ----
$script:Quitting = $false
$script:BalloonShown = $false

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'UtilMonster'
$script:Form.Font = New-Object System.Drawing.Font('Malgun Gothic', 9.5)
$script:Form.Size = New-Object System.Drawing.Size(1120, 720)
$script:Form.MinimumSize = New-Object System.Drawing.Size(900, 560)
$script:Form.StartPosition = 'CenterScreen'

$script:TabCtl = New-Object System.Windows.Forms.TabControl
$script:TabCtl.Dock = 'Fill'
$script:TabCtl.Padding = New-Object System.Drawing.Point(18, 6)
$script:Form.Controls.Add($script:TabCtl)

# 아이콘: UtilMonster.ico (없으면 기본 아이콘). 창은 큰 크기, 트레이는 16x16 을 쓴다.
$script:IcoPath = Join-Path $script:AppDir 'UtilMonster.ico'
$script:TrayIcon = [System.Drawing.SystemIcons]::Application
if (Test-Path -LiteralPath $script:IcoPath) {
    try {
        $script:Form.Icon = New-Object System.Drawing.Icon($script:IcoPath)
        $script:TrayIcon = New-Object System.Drawing.Icon($script:IcoPath, 16, 16)
    }
    catch { Write-Log "아이콘 로드 실패: $($_.Exception.Message)" }
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $script:TrayIcon
$script:Tray.Text = 'UtilMonster'
$script:Tray.Visible = $false
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $trayMenu.Items.Add('열기')
$miQuit = $trayMenu.Items.Add('종료')
$script:Tray.ContextMenuStrip = $trayMenu

# 모듈에 넘겨 주는 공용 정보. KeepAlive['이름'] = $true 로 두면 창을 닫아도 트레이에서 계속 실행
$script:Ctx = [pscustomobject]@{
    AppDir    = $script:AppDir
    ConfigDir = $script:ConfigDir
    Form      = $script:Form
    Font      = $script:Form.Font
    Tray      = $script:Tray
    KeepAlive = @{}
}

function Test-KeepAlive {
    foreach ($v in @($script:Ctx.KeepAlive.Values)) { if ($v) { return $true } }
    return $false
}

function Update-Tray {
    $script:Tray.Visible = (Test-KeepAlive) -or (-not $script:Form.Visible)
}

function Show-MainWindow {
    $script:Form.Show()
    if ($script:Form.WindowState -eq 'Minimized') { $script:Form.WindowState = 'Normal' }
    $script:Form.Activate()
    Update-Tray
}

function Exit-App {
    $script:Quitting = $true
    [System.Windows.Forms.Application]::ExitThread()
}

# ---- 모듈 로드 ----
$script:Tabs = @()
$mods = @()
if (Test-Path -LiteralPath $script:ModulesDir) {
    $mods = @(Get-ChildItem -LiteralPath $script:ModulesDir -Filter *.psm1 -File | Where-Object { $_.Name -notlike '_*' })
}
foreach ($f in $mods) {
    $entry = [pscustomobject]@{
        File = $f.Name; Module = $null; Title = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        Order = 1000; Eager = $false; Page = $null; Built = $false; Failed = $false; Error = $null
    }
    try {
        $m = Import-Module -Name $f.FullName -Force -PassThru -DisableNameChecking -ErrorAction Stop
        $info = & $m.ExportedCommands['Get-UtilTabInfo']
        if (-not $m.ExportedCommands['New-UtilTab']) { throw 'New-UtilTab 함수가 없습니다.' }
        $entry.Module = $m
        if ($info.Title) { $entry.Title = [string]$info.Title }
        if ($info.Order) { $entry.Order = [int]$info.Order }
        $entry.Eager = [bool]$info.Eager
    }
    catch {
        $entry.Error = $_.Exception.Message
        Write-Log "모듈 로드 실패: $($f.Name): $($_.Exception.Message)"
    }
    $script:Tabs += $entry
}
$script:Tabs = @($script:Tabs | Sort-Object Order, Title)

foreach ($t in $script:Tabs) {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $t.Title
    $page.UseVisualStyleBackColor = $true
    $t.Page = $page
    [void]$script:TabCtl.TabPages.Add($page)
}

# 탭 하나를 실제로 만든다. 실패해도 다른 탭에는 영향이 없고, 그 탭에 오류 내용을 보여 준다.
function Build-Tab($t) {
    if ($t.Built) { return }
    $t.Built = $true
    $script:Form.Cursor = 'WaitCursor'
    try {
        if ($t.Error) { throw $t.Error }
        & $t.Module.ExportedCommands['New-UtilTab'] -Page $t.Page -Ctx $script:Ctx
    }
    catch {
        $t.Failed = $true
        $t.Error = $_.Exception.Message
        Write-Log "탭 생성 실패: $($t.Title): $($_.Exception.Message)`n$($_.ScriptStackTrace)"        $t.Page.Controls.Clear()
        $l = New-Object System.Windows.Forms.Label
        $l.Dock = 'Fill'
        $l.Padding = New-Object System.Windows.Forms.Padding(16)
        $l.ForeColor = [System.Drawing.Color]::Firebrick
        $l.Text = "'$($t.Title)' 탭을 불러오지 못했습니다.`r`n`r`n$($t.Error)`r`n`r`n로그: $(Join-Path $script:LogDir 'UtilMonster.log')"
        $t.Page.Controls.Add($l)
    }
    finally { $script:Form.Cursor = 'Default' }
}

function Get-SelectedTab {
    $i = $script:TabCtl.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:Tabs.Count) { return $script:Tabs[$i] }
}

$script:TabCtl.Add_SelectedIndexChanged({
        $t = Get-SelectedTab
        if ($t) {
            Build-Tab $t
            $script:Shell.lastTab = $t.File
            Save-ShellConfig
        }
    })

# 시작 탭: -Tab 지정 > 마지막으로 쓴 탭 > 첫 탭
$want = if ($Tab) { $Tab } else { $script:Shell.lastTab }
if ($want) {
    for ($i = 0; $i -lt $script:Tabs.Count; $i++) {
        $t = $script:Tabs[$i]
        if ($t.File -ieq $want -or $t.Title -like "*$want*" -or $t.File -like "*$want*") { $script:TabCtl.SelectedIndex = $i; break }
    }
}

# 백그라운드 동작이 필요한 모듈은 미리 만든다
foreach ($t in $script:Tabs) { if ($t.Eager -and -not $t.Error) { Build-Tab $t } }

# ---- 이벤트 ----
$script:Form.Add_Shown({ $t = Get-SelectedTab; if ($t) { Build-Tab $t } })

$script:Form.Add_FormClosing({
        param($sender, $e)
        if (-not $script:Quitting -and $e.CloseReason -eq 'UserClosing' -and (Test-KeepAlive)) {
            $e.Cancel = $true
            $script:Form.Hide()
            Update-Tray
            if (-not $script:BalloonShown) {
                $script:BalloonShown = $true
                $script:Tray.ShowBalloonTip(3000, 'UtilMonster', '백그라운드 기능이 켜져 있어 트레이에서 계속 실행됩니다.', 'Info')
            }
        }
    })
$script:Form.Add_FormClosed({ Exit-App })

$script:Tray.Add_DoubleClick({ Show-MainWindow })
$miOpen.Add_Click({ Show-MainWindow })
$miQuit.Add_Click({ Exit-App })

# 다른 인스턴스가 다시 실행되면 창을 앞으로 + 트레이 아이콘 상태 갱신
$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 700
$script:PollTimer.Add_Tick({
        if ($script:ShowEvent.WaitOne(0)) { Show-MainWindow }
        Update-Tray
    })
$script:PollTimer.Start()

function Close-All {
    $script:PollTimer.Stop()
    foreach ($t in $script:Tabs) {
        if ($t.Module -and $t.Built -and -not $t.Failed -and $t.Module.ExportedCommands['Stop-UtilTab']) {
            try { & $t.Module.ExportedCommands['Stop-UtilTab'] } catch { Write-Log "정리 실패: $($t.Title): $($_.Exception.Message)" }
        }
    }
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    try { $script:Mutex.ReleaseMutex() } catch { }
}

# ---- 실행 ----
try {
    if ($SelfTest) {
        $script:Form.TopMost = $true
        $script:Form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $bad = 0
        for ($i = 0; $i -lt $script:Tabs.Count; $i++) {
            $t = $script:Tabs[$i]
            $script:TabCtl.SelectedIndex = $i
            Build-Tab $t
            for ($k = 0; $k -lt 6; $k++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            $n = $t.Page.Controls.Count
            if ($t.Failed) { $bad++ }
            Write-Host ('[{0}] {1,-14} controls={2} {3}' -f $(if ($t.Failed) { 'FAIL' } else { 'OK  ' }), $t.Title, $n, $(if ($t.Failed) { $t.Error } else { '' }))
            if ($ShotDir) {
                New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
                $b = New-Object System.Drawing.Bitmap($script:Form.Width, $script:Form.Height)
                $g = [System.Drawing.Graphics]::FromImage($b)
                $g.CopyFromScreen($script:Form.Location, [System.Drawing.Point]::Empty, $script:Form.Size)
                $g.Dispose()
                $b.Save((Join-Path $ShotDir ('{0:00}_{1}.png' -f ($i + 1), [IO.Path]::GetFileNameWithoutExtension($t.File))), [System.Drawing.Imaging.ImageFormat]::Png)
                $b.Dispose()
            }
        }
        Write-Host ("SelfTest 완료: 탭 {0}개, 실패 {1}개, KeepAlive={2}" -f $script:Tabs.Count, $bad, (Test-KeepAlive))
        $script:Form.Hide()
    }
    else {
        $startHidden = $Minimized -and (Test-KeepAlive)
        if (-not $startHidden) { Show-MainWindow }
        Update-Tray
        $appCtx = New-Object System.Windows.Forms.ApplicationContext
        [System.Windows.Forms.Application]::Run($appCtx)
    }
}
catch {
    Write-Log "치명적 오류: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    [void][System.Windows.Forms.MessageBox]::Show("UtilMonster 오류`n`n$($_.Exception.Message)", 'UtilMonster', 'OK', 'Error')
}
finally { Close-All }
