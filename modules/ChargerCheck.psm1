<#
  충전기 체크 탭

  - 충전기가 빠지는 순간 즉시 알림 (소리 + 화면 맨 위 경고창)
  - 감시를 켤 때 충전기가 연결돼 있지 않으면 알림
  - 배터리 사용 중 잔량이 기준 이하이면 주기적으로 재알림
  - (선택) 충전기 미연결 + 잔량이 기준 이하이면 텔레그램으로도 알림

  감시를 켜 두면(KeepAlive) UtilMonster 창을 닫아도 트레이에서 계속 감시합니다.
  설정은 config\ChargerCheck.json 에 저장됩니다.
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-UtilTabInfo { @{ Title = '충전기 체크'; Order = 20; Eager = $true } }

$script:Ctx = $null
$script:CfgPath = ''
$script:Cfg = @{
    enabled                  = $false   # 감시 사용
    lowBatteryPercent        = 30       # 미연결 + 이 값 이하이면 화면 재알림
    remindMinutes            = 5        # 화면 재알림 간격(분)
    pollSeconds              = 3        # 상태 확인 주기(초)
    telegramToken            = ''
    telegramChatId           = ''
    telegramThresholdPercent = 90
    telegramRemindMinutes    = 5
}

$script:Loading = $true
$script:Monitoring = $false
$script:Mutex = $null
$script:AlertForm = $null
$script:prev = $null
$script:lastRemind = [datetime]::MinValue
$script:lastTg = [datetime]::MinValue
$script:tgSent = $false

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:CfgPath)) { return }
    try {
        $c = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($script:Cfg.Keys)) {
            $v = $c.$k
            if ($null -eq $v) { continue }
            $cur = $script:Cfg[$k]
            $script:Cfg[$k] = if ($cur -is [bool]) { [bool]$v } elseif ($cur -is [int]) { [int]$v } else { [string]$v }
        }
    }
    catch { }
}

function Save-Config {
    try { $script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8 } catch { }
}

# 화면의 값을 설정에 반영하고 저장
function Save-FromUi {
    if ($script:Loading) { return }
    $script:Cfg.lowBatteryPercent = [int]$script:numLow.Value
    $script:Cfg.remindMinutes = [int]$script:numRemind.Value
    $script:Cfg.telegramToken = $script:tbToken.Text.Trim()
    $script:Cfg.telegramChatId = $script:tbChat.Text.Trim()
    $script:Cfg.telegramThresholdPercent = [int]$script:numTgThr.Value
    $script:Cfg.telegramRemindMinutes = [int]$script:numTgRemind.Value
    Save-Config
}

function Test-TgEnabled { [bool]($script:Cfg.telegramToken -and $script:Cfg.telegramChatId) }

function Add-Log([string]$msg) {
    if (-not $script:tbLog) { return }
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $msg
    $lines = @($script:tbLog.Lines) + $line
    if ($lines.Count -gt 200) { $lines = $lines[($lines.Count - 200)..($lines.Count - 1)] }
    $script:tbLog.Lines = $lines
    $script:tbLog.SelectionStart = $script:tbLog.TextLength
    $script:tbLog.ScrollToCaret()
}

function Get-PowerInfo {
    $p = [System.Windows.Forms.SystemInformation]::PowerStatus
    [pscustomobject]@{
        Line = [string]$p.PowerLineStatus   # Online / Offline / Unknown
        Percent = [int][math]::Round($p.BatteryLifePercent * 100)
        HasBattery = ($p.BatteryChargeStatus -notmatch 'NoSystemBattery')
    }
}

function Send-Telegram([string]$text) {
    if (-not (Test-TgEnabled)) { return }
    try {
        # 비동기 전송: 인터넷이 없어도 프로그램이 멈추지 않음
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $body = New-Object System.Collections.Specialized.NameValueCollection
        $body.Add('chat_id', $script:Cfg.telegramChatId)
        $body.Add('text', $text)
        $wc.UploadValuesAsync([uri]"https://api.telegram.org/bot$($script:Cfg.telegramToken)/sendMessage", 'POST', $body)
    }
    catch { }
}

function Show-Alert([string]$text) {
    [System.Media.SystemSounds]::Exclamation.Play()

    if ($script:AlertForm -and -not $script:AlertForm.IsDisposed) { $script:AlertForm.Close() }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '충전기 체크'
    $f.TopMost = $true
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size(440, 140)
    $f.BackColor = [System.Drawing.Color]::FromArgb(255, 232, 232)

    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = New-Object System.Drawing.Font('Malgun Gothic', 14, [System.Drawing.FontStyle]::Bold)
    $l.Dock = 'Fill'
    $l.TextAlign = 'MiddleCenter'
    $f.Controls.Add($l)

    # 15초 뒤 자동으로 닫힘
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 15000
    $t.Add_Tick({ $t.Stop(); $f.Close() }.GetNewClosure())
    $f.Add_FormClosed({ $t.Stop(); $t.Dispose() }.GetNewClosure())
    $t.Start()

    $script:AlertForm = $f
    $f.Show()
    $f.Activate()
}

# ---- 감시 시작/중지 ----
# 기존 ChargerCheck 와 같은 뮤텍스를 써서, 둘이 동시에 떠서 알림이 두 번 나오는 것을 막는다.
function Start-Monitor {
    if ($script:Monitoring) { return $true }
    try {
        $mx = New-Object System.Threading.Mutex($false, 'Local\ChargerCheck')
        $got = $false
        try { $got = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { $mx.Dispose(); return $false }
        $script:Mutex = $mx
    }
    catch { return $false }

    $script:prev = $null
    $script:lastRemind = [datetime]::MinValue
    $script:lastTg = [datetime]::MinValue
    $script:tgSent = $false
    $script:Monitoring = $true
    $script:Ctx.KeepAlive['ChargerCheck'] = $true
    Add-Log '감시 시작'
    return $true
}

function Stop-Monitor {
    if (-not $script:Monitoring) { return }
    $script:Monitoring = $false
    $script:Ctx.KeepAlive['ChargerCheck'] = $false
    if ($script:AlertForm -and -not $script:AlertForm.IsDisposed) { $script:AlertForm.Close() }
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:Mutex.Dispose()
        $script:Mutex = $null
    }
    Add-Log '감시 중지'
}

# ---- 상태 표시 ----
function Update-StatusView($p) {
    if (-not $script:lblPower) { return }
    $mon = if ($script:Monitoring) { '감시 중' } else { '감시 꺼짐' }
    if (-not $p.HasBattery) {
        $script:lblPower.Text = '배터리가 없는 PC입니다'
        $script:lblPower.ForeColor = [System.Drawing.Color]::DimGray
        $script:lblSub.Text = "충전기 감시를 사용할 수 없습니다.  ($mon)"
        return
    }
    switch ($p.Line) {
        'Online' { $script:lblPower.Text = '충전기 연결됨'; $script:lblPower.ForeColor = [System.Drawing.Color]::SeaGreen }
        'Offline' { $script:lblPower.Text = '충전기 분리됨 (배터리 사용 중)'; $script:lblPower.ForeColor = [System.Drawing.Color]::Firebrick }
        default { $script:lblPower.Text = '전원 상태를 알 수 없음'; $script:lblPower.ForeColor = [System.Drawing.Color]::DimGray }
    }
    $script:lblSub.Text = "배터리 $($p.Percent)%   ·   $mon"
}

# 알림 규칙 (원래 ChargerCheck 와 동일)
function Invoke-Rules($p) {
    if (-not $p.HasBattery) { return }

    # 화면 알림
    if ($p.Line -eq 'Offline') {
        if ($script:prev -ne 'Offline') {
            # 방금 빠졌거나, 감시를 켠 시점에 이미 미연결
            Add-Log "충전기 미연결 감지 (배터리 $($p.Percent)%)"
            Show-Alert "충전기가 연결되어 있지 않습니다!`n(배터리 $($p.Percent)%)"
            $script:lastRemind = Get-Date
        }
        elseif ($p.Percent -le $script:Cfg.lowBatteryPercent -and
                ((Get-Date) - $script:lastRemind).TotalMinutes -ge $script:Cfg.remindMinutes) {
            Add-Log "재알림 (배터리 $($p.Percent)%)"
            Show-Alert "배터리 $($p.Percent)% - 충전기를 연결하세요!"
            $script:lastRemind = Get-Date
        }
    }
    elseif ($p.Line -eq 'Online' -and $script:prev -eq 'Offline') {
        Add-Log "충전기 연결됨 (배터리 $($p.Percent)%)"
    }

    # 텔레그램 알림: 미연결 + 잔량이 기준 이하일 때, 간격을 두고 반복
    if (Test-TgEnabled) {
        if ($p.Line -eq 'Offline') {
            if ($p.Percent -le $script:Cfg.telegramThresholdPercent -and
                ((Get-Date) - $script:lastTg).TotalMinutes -ge $script:Cfg.telegramRemindMinutes) {
                Send-Telegram "⚠️ [$env:COMPUTERNAME] 충전기 미연결 - 배터리 $($p.Percent)%"
                Add-Log '텔레그램 전송'
                $script:lastTg = Get-Date
                $script:tgSent = $true
            }
        }
        elseif ($p.Line -eq 'Online' -and $script:tgSent) {
            Send-Telegram "🔌 [$env:COMPUTERNAME] 충전기 연결됨 - 배터리 $($p.Percent)%"
            Add-Log '텔레그램 전송 (연결됨)'
            $script:tgSent = $false
            $script:lastTg = [datetime]::MinValue
        }
    }

    $script:prev = $p.Line
}

function Invoke-Tick {
    try {
        $p = Get-PowerInfo
        if ($script:Monitoring) { Invoke-Rules $p }
        Update-StatusView $p
    }
    catch { }
}

# ---- 자동 실행 (시작 프로그램 폴더 바로가기) ----
function Get-StartupLink([string]$name) { Join-Path ([Environment]::GetFolderPath('Startup')) $name }

function Set-Autostart([bool]$on) {
    $lnk = Get-StartupLink 'UtilMonster.lnk'
    if ($on) {
        $ps1 = Join-Path $script:Ctx.AppDir 'UtilMonster.ps1'
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`" -Minimized"
        $sc.WorkingDirectory = $script:Ctx.AppDir
        $ico = Join-Path $script:Ctx.AppDir 'UtilMonster.ico'
        if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico }
        $sc.Save()
    }
    else { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
}

# 이 탭의 전신인 단독 실행형 ChargerCheck(ChargerCheck.ps1 + 시작 프로그램 바로가기)가 남아 있는 경우
function Get-LegacyProcs {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ChargerCheck.ps1*' -and $_.ProcessId -ne $PID })
}
function Test-Legacy {
    (Test-Path -LiteralPath (Get-StartupLink 'ChargerCheck.lnk')) -or ((Get-LegacyProcs).Count -gt 0)
}

function New-Label([string]$text, [int]$x, [int]$y, [int]$w = 200, [int]$h = 24) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.SetBounds($x, $y, $w, $h)
    $l.TextAlign = 'MiddleLeft'
    $l
}

function New-Num([int]$x, [int]$y, [int]$min, [int]$max, [int]$val) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $min
    $n.Maximum = $max
    $n.Value = [math]::Min([math]::Max($val, $min), $max)
    $n.SetBounds($x, $y, 64, 26)
    $n.Add_ValueChanged({ Save-FromUi })
    $n
}

function New-Group([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $text
    $g.SetBounds($x, $y, $w, $h)
    $g
}

function New-UtilTab {
    param([System.Windows.Forms.TabPage]$Page, $Ctx)

    $script:Ctx = $Ctx
    $script:CfgPath = Join-Path $Ctx.ConfigDir 'ChargerCheck.json'
    Read-Config
    $script:Loading = $true

    # -- 현재 상태
    $gStatus = New-Group '현재 상태' 12 10 640 90
    $script:lblPower = New-Label '' 16 24 600 34
    $script:lblPower.Font = New-Object System.Drawing.Font('Malgun Gothic', 15, [System.Drawing.FontStyle]::Bold)
    $script:lblSub = New-Label '' 16 58 600 24
    $gStatus.Controls.AddRange(@($script:lblPower, $script:lblSub))

    # -- 화면 알림
    $gScreen = New-Group '화면 알림' 12 108 640 212
    $script:chkEnable = New-Object System.Windows.Forms.CheckBox
    $script:chkEnable.Text = '충전기 감시 사용  (창을 닫아도 트레이에서 계속 감시)'
    $script:chkEnable.SetBounds(16, 26, 600, 26)
    $script:chkAuto = New-Object System.Windows.Forms.CheckBox
    $script:chkAuto.Text = 'Windows 시작 시 자동 실행  (트레이로 시작)'
    $script:chkAuto.SetBounds(16, 54, 600, 26)

    $l1 = New-Label '충전기 미연결 + 잔량이' 16 92 190
    $script:numLow = New-Num 210 90 1 100 $script:Cfg.lowBatteryPercent
    $l2 = New-Label '% 이하이면' 282 92 90
    $script:numRemind = New-Num 374 90 1 120 $script:Cfg.remindMinutes
    $l3 = New-Label '분마다 화면 재알림' 446 92 180

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '알림 테스트'
    $btnTest.SetBounds(16, 130, 120, 30)

    $script:lblLegacy = New-Label '예전 ChargerCheck 의 자동 실행/프로세스가 남아 있습니다. 감시가 겹치면 이쪽이 켜지지 않을 수 있습니다.' 16 168 480 36
    $script:lblLegacy.ForeColor = [System.Drawing.Color]::Chocolate
    $script:btnLegacy = New-Object System.Windows.Forms.Button
    $script:btnLegacy.Text = '기존 항목 정리'
    $script:btnLegacy.SetBounds(504, 170, 120, 30)
    $gScreen.Controls.AddRange(@($script:chkEnable, $script:chkAuto, $l1, $script:numLow, $l2, $script:numRemind, $l3, $btnTest, $script:lblLegacy, $script:btnLegacy))

    # -- 텔레그램
    $gTg = New-Group '텔레그램 알림 (선택)' 12 328 640 168
    $l4 = New-Label '봇 토큰' 16 30 90
    $script:tbToken = New-Object System.Windows.Forms.TextBox
    $script:tbToken.SetBounds(110, 28, 510, 26)
    $script:tbToken.UseSystemPasswordChar = $true
    $l5 = New-Label 'Chat ID' 16 62 90
    $script:tbChat = New-Object System.Windows.Forms.TextBox
    $script:tbChat.SetBounds(110, 60, 200, 26)
    $l6 = New-Label '미연결 + 잔량이' 16 96 150
    $script:numTgThr = New-Num 170 94 1 100 $script:Cfg.telegramThresholdPercent
    $l7 = New-Label '% 이하이면' 242 96 90
    $script:numTgRemind = New-Num 334 94 1 240 $script:Cfg.telegramRemindMinutes
    $l8 = New-Label '분마다 전송' 406 96 140
    $btnTg = New-Object System.Windows.Forms.Button
    $btnTg.Text = '테스트 전송'
    $btnTg.SetBounds(16, 128, 120, 30)
    $script:lblTg = New-Label '' 146 130 474
    $gTg.Controls.AddRange(@($l4, $script:tbToken, $l5, $script:tbChat, $l6, $script:numTgThr, $l7, $script:numTgRemind, $l8, $btnTg, $script:lblTg))

    # -- 이벤트 로그
    $gLog = New-Group '최근 이벤트' 664 10 400 486
    $gLog.Anchor = 'Top, Bottom, Left, Right'
    $script:tbLog = New-Object System.Windows.Forms.TextBox
    $script:tbLog.Multiline = $true
    $script:tbLog.ReadOnly = $true
    $script:tbLog.ScrollBars = 'Vertical'
    $script:tbLog.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $script:tbLog.Dock = 'Fill'
    $gLog.Controls.Add($script:tbLog)

    $Page.Controls.AddRange(@($gStatus, $gScreen, $gTg, $gLog))

    # -- 현재 설정을 화면에 반영
    $script:tbToken.Text = $script:Cfg.telegramToken
    $script:tbChat.Text = $script:Cfg.telegramChatId
    $script:chkAuto.Checked = Test-Path -LiteralPath (Get-StartupLink 'UtilMonster.lnk')
    $legacy = Test-Legacy
    $script:lblLegacy.Visible = $legacy
    $script:btnLegacy.Visible = $legacy

    # -- 이벤트
    $script:tbToken.Add_Leave({ Save-FromUi })
    $script:tbChat.Add_Leave({ Save-FromUi })

    $script:chkEnable.Add_CheckedChanged({
            if ($script:Loading) { return }
            if ($script:chkEnable.Checked) {
                if (-not (Start-Monitor)) {
                    # 체크를 되돌릴 때 이 핸들러가 다시 돌지 않도록 잠시 막는다
                    $script:Loading = $true
                    $script:chkEnable.Checked = $false
                    $script:Loading = $false
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "다른 충전기 감시(예전 ChargerCheck 또는 다른 UtilMonster)가 이미 실행 중입니다.`n그쪽을 먼저 종료하세요.",
                        '충전기 체크', 'OK', 'Warning')
                    return
                }
                $script:Cfg.enabled = $true
                Save-Config
                Invoke-Tick
            }
            else {
                Stop-Monitor
                $script:Cfg.enabled = $false
                Save-Config
                # 감시가 꺼져 있으면 자동 실행도 의미가 없으므로 같이 해제
                if ($script:chkAuto.Checked) { $script:chkAuto.Checked = $false }
                Invoke-Tick
            }
        })

    $script:chkAuto.Add_CheckedChanged({
            if ($script:Loading) { return }
            try {
                Set-Autostart $script:chkAuto.Checked
                if ($script:chkAuto.Checked -and -not $script:chkEnable.Checked) { $script:chkEnable.Checked = $true }
            }
            catch {
                [void][System.Windows.Forms.MessageBox]::Show("자동 실행 설정 실패: $($_.Exception.Message)", '충전기 체크', 'OK', 'Error')
            }
        })

    $btnTest.Add_Click({
            $p = Get-PowerInfo
            Show-Alert "알림 테스트입니다.`n(배터리 $($p.Percent)%)"
        })

    $btnTg.Add_Click({
            Save-FromUi
            if (-not (Test-TgEnabled)) { $script:lblTg.ForeColor = [System.Drawing.Color]::Firebrick; $script:lblTg.Text = '봇 토큰과 Chat ID 를 입력하세요.'; return }
            $script:Ctx.Form.Cursor = 'WaitCursor'
            try {
                $r = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($script:Cfg.telegramToken)/sendMessage" -TimeoutSec 10 `
                    -Body @{ chat_id = $script:Cfg.telegramChatId; text = "[$env:COMPUTERNAME] 충전기 체크 테스트 메시지" }
                $script:lblTg.ForeColor = [System.Drawing.Color]::SeaGreen
                $script:lblTg.Text = "전송 성공 (ok=$($r.ok))"
            }
            catch {
                $script:lblTg.ForeColor = [System.Drawing.Color]::Firebrick
                $script:lblTg.Text = "전송 실패: $($_.Exception.Message)"
            }
            finally { $script:Ctx.Form.Cursor = 'Default' }
        })

    $script:btnLegacy.Add_Click({
            $r = [System.Windows.Forms.MessageBox]::Show(
                "예전 ChargerCheck 의 시작 프로그램 바로가기(ChargerCheck.lnk)를 지우고`n실행 중인 ChargerCheck.ps1 프로세스를 종료합니다.`n(원본 폴더의 파일은 그대로 둡니다)",
                '기존 항목 정리', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            Remove-Item -LiteralPath (Get-StartupLink 'ChargerCheck.lnk') -Force -ErrorAction SilentlyContinue
            foreach ($p in (Get-LegacyProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 500
            $has = Test-Legacy
            $script:lblLegacy.Visible = $has
            $script:btnLegacy.Visible = $has
            Add-Log '예전 ChargerCheck 항목 정리'
        })

    # -- 상태 확인 타이머 (감시가 꺼져 있어도 화면 표시는 갱신)
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = [math]::Max(1, $script:Cfg.pollSeconds) * 1000
    $script:Timer.Add_Tick({ Invoke-Tick })
    $script:Timer.Start()

    # -- 저장된 "감시 사용" 복원
    if ($script:Cfg.enabled) {
        if (Start-Monitor) { $script:chkEnable.Checked = $true }
        else { Add-Log '감시를 시작하지 못했습니다: 다른 충전기 감시가 이미 실행 중입니다.' }
    }
    $script:Loading = $false
    Invoke-Tick
}

function Stop-UtilTab {
    if ($script:Timer) { $script:Timer.Stop(); $script:Timer.Dispose(); $script:Timer = $null }
    Stop-Monitor
}

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab, Stop-UtilTab
