<#
  프로그램 관리 탭

  관리 폴더 아래의 각 하위 폴더를 "프로그램 하나"로 보고 다음을 보여 줍니다.
    - 실행 중인 프로세스 (폴더 안의 exe, 또는 python/powershell 등이 폴더의 스크립트를 실행 중인 것)
    - 자동 실행 등록 (시작 프로그램 폴더, 레지스트리 Run, 작업 스케줄러)
    - 크기, 마지막 수정일
  선택한 프로그램을 실행 / 재시작 / 중지 / 자동 실행 해제 / 삭제(휴지통)할 수 있습니다.
  기본 관리 폴더는 UtilMonster 폴더의 상위 폴더이며, [폴더 변경]으로 바꿀 수 있습니다.
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

function Get-UtilTabInfo { @{ Title = '프로그램 관리'; Order = 10; Eager = $false } }

$script:Form = $null
$script:SelfDir = ''
$script:CfgPath = ''
$script:Root = ''
# 프로그램별 실행 설정: apps[폴더이름] = @{ command = '...'; hidden = $true/$false }
$script:Cfg = @{ apps = @{} }

# 경로가 명령줄로 실행될 때 "스크립트를 실행 중"이라고 볼 인터프리터들
$script:Interp = '^(python[\d.]*|pythonw[\d.]*|py|pyw|pwsh|powershell|node|cmd|wscript|cscript|java|javaw)\.exe$'

function Save-Config {
    try {
        [ordered]@{ root = $script:Root; apps = $script:Cfg.apps } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
    }
    catch { }
}

function Read-Config {
    $script:Root = Split-Path $script:SelfDir -Parent
    $script:Cfg = @{ apps = @{} }
    if (Test-Path -LiteralPath $script:CfgPath) {
        try {
            $c = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.root -and (Test-Path -LiteralPath $c.root -PathType Container)) { $script:Root = [string]$c.root }
            if ($c.apps) {
                foreach ($p in $c.apps.PSObject.Properties) {
                    $script:Cfg.apps[$p.Name] = @{ command = [string]$p.Value.command; hidden = [bool]$p.Value.hidden }
                }
            }
        }
        catch { }
    }
}

function New-PathRegex([string]$path) {
    New-Object System.Text.RegularExpressions.Regex(([regex]::Escape($path) + '(?=[\\/"''\s]|$)'), 'IgnoreCase')
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    else { '{0:N0} KB' -f ($b / 1KB) }
}

function Get-AutostartEntries {
    $list = New-Object System.Collections.Generic.List[object]

    $sh = New-Object -ComObject WScript.Shell
    Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')) -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
        $s = $sh.CreateShortcut($_.FullName)
        $list.Add([pscustomobject]@{ Kind = '시작폴더'; Name = $_.BaseName; Id = $_.FullName; Text = "$($s.TargetPath) $($s.Arguments) $($s.WorkingDirectory)" })
    }

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $k = Get-Item -LiteralPath $runKey -ErrorAction SilentlyContinue
    if ($k) {
        foreach ($n in $k.GetValueNames()) {
            $list.Add([pscustomobject]@{ Kind = '레지스트리'; Name = $n; Id = $runKey; Text = [string]$k.GetValue($n) })
        }
    }

    try {
        Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
            $t = $_
            $txt = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments) $($_.WorkingDirectory)" }) -join ' '
            $list.Add([pscustomobject]@{ Kind = '작업스케줄러'; Name = $t.TaskName; Id = $t.TaskPath; Text = $txt })
        }
    }
    catch { }

    $list.ToArray()
}

function Get-AppInfo {
    $procs = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID })
    $auto = @(Get-AutostartEntries)

    Get-ChildItem -LiteralPath $script:Root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Hidden) -and $_.Name -notlike '.*' } |
        Sort-Object Name | ForEach-Object {
            $dir = $_
            $re = New-PathRegex $dir.FullName

            $myProcs = @($procs | Where-Object {
                    ($_.ExecutablePath -and $re.IsMatch($_.ExecutablePath)) -or
                    ($_.Name -match $script:Interp -and $_.CommandLine -and $re.IsMatch($_.CommandLine))
                })
            $myAuto = @($auto | Where-Object { $re.IsMatch($_.Text) })

            $size = [long]0
            $latest = $dir.LastWriteTime
            try {
                foreach ($f in $dir.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
                    $size += $f.Length
                    if ($f.LastWriteTime -gt $latest) { $latest = $f.LastWriteTime }
                }
            }
            catch { }

            $isPy = (@(Get-ChildItem -LiteralPath $dir.FullName -Filter *.py -File -ErrorAction SilentlyContinue).Count -gt 0) -or
                    (Test-Path -LiteralPath (Join-Path $dir.FullName 'requirements.txt'))

            [pscustomobject]@{
                Name = $dir.Name
                Path = $dir.FullName
                Kind = $(if ($isPy) { 'Python' } else { '기타' })
                Procs = $myProcs
                Auto = $myAuto
                SizeBytes = $size
                Latest = $latest
                IsSelf = ($script:SelfDir -eq $dir.FullName) -or
                         $script:SelfDir.StartsWith($dir.FullName.TrimEnd('\') + '\', 'OrdinalIgnoreCase')
            }
        }
}

# ---- 동작 ----
# 해당 프로그램의 프로세스와 그 자식 프로세스까지 종료
function Stop-App($a) {
    $all = @(Get-CimInstance Win32_Process)
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }

    $ids = New-Object System.Collections.Generic.HashSet[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    foreach ($p in $a.Procs) { if ($ids.Add([int]$p.ProcessId)) { $queue.Enqueue([int]$p.ProcessId) } }
    while ($queue.Count) {
        $parent = $byId[$queue.Dequeue()]
        foreach ($c in $all) {
            # 부모보다 늦게 생성된 자식만 (PID 재사용으로 인한 오인 방지)
            if ($parent -and $c.ParentProcessId -eq $parent.ProcessId -and $c.ProcessId -ne $PID -and
                $c.CreationDate -ge $parent.CreationDate -and $ids.Add([int]$c.ProcessId)) {
                $queue.Enqueue([int]$c.ProcessId)
            }
        }
    }
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

# 실행 명령 자동 감지: 가상환경 python + main.py 등, 없으면 bat / ps1 / exe
function Get-AutoCommand($a) {
    $dir = $a.Path
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)

    function Select-Entry([string[]]$preferred, [string]$pattern) {
        foreach ($n in $preferred) {
            $f = $files | Where-Object { $_.Name -ieq $n } | Select-Object -First 1
            if ($f) { return $f }
        }
        $cand = @($files | Where-Object { $_.Name -like $pattern -and $_.Name -notmatch '^(install|uninstall|setup)' })
        if ($cand.Count -eq 1) { return $cand[0] }
    }

    $f = Select-Entry @('main.py', 'app.py', 'run.py', 'start.py', 'server.py', '__main__.py') '*.py'
    if ($f) {
        $py = $null
        foreach ($v in '.venv', 'venv', 'env') {
            $c = Join-Path $dir "$v\Scripts\python.exe"
            if (Test-Path -LiteralPath $c) { $py = $c; break }
        }
        if (-not $py) {
            if (Get-Command python.exe -ErrorAction SilentlyContinue) { $py = 'python' }
            elseif (Get-Command py.exe -ErrorAction SilentlyContinue) { $py = 'py' }
        }
        if ($py) { return "`"$py`" `"$($f.FullName)`"" }
    }
    $f = Select-Entry @('start.bat', 'run.bat', 'main.bat', 'start.cmd', 'run.cmd') '*.bat'
    if (-not $f) { $f = Select-Entry @() '*.cmd' }
    if ($f) { return "call `"$($f.FullName)`"" }
    $f = Select-Entry @('start.ps1', 'run.ps1', 'main.ps1') '*.ps1'
    if ($f) { return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($f.FullName)`"" }
    $f = Select-Entry @("$($a.Name).exe", 'main.exe', 'app.exe') '*.exe'
    if ($f) { return "`"$($f.FullName)`"" }
    return $null
}

function Get-LaunchSpec($a) {
    $cfg = $script:Cfg.apps[$a.Name]
    $manual = [bool]($cfg -and $cfg.command)
    [pscustomobject]@{
        Command = $(if ($manual) { $cfg.command } else { Get-AutoCommand $a })
        Manual = $manual
        Hidden = [bool]($cfg -and $cfg.hidden)
    }
}

# 폴더를 작업 폴더로 cmd를 통해 실행. 실패(종료 코드 != 0)하면 창을 남겨 오류를 볼 수 있게 함
# 성공 시 null, 실패 시 오류 문자열을 반환
function Start-App($a) {
    $spec = Get-LaunchSpec $a
    if (-not $spec.Command) {
        return "$($a.Name): 실행할 파일을 찾지 못했습니다. [실행 설정]에서 명령을 지정하세요."
    }
    $tail = if ($spec.Hidden) { '' } else { ' || pause' }
    $arg = "/d /s /c `"cd /d `"$($a.Path)`" && $($spec.Command)$tail`""
    try {
        Start-Process -FilePath cmd.exe -ArgumentList $arg -WorkingDirectory $a.Path `
            -WindowStyle $(if ($spec.Hidden) { 'Hidden' } else { 'Normal' })
    }
    catch { return "$($a.Name): $($_.Exception.Message)" }
}

function Remove-Autostart($a) {
    foreach ($e in $a.Auto) {
        try {
            switch ($e.Kind) {
                '시작폴더' { Remove-Item -LiteralPath $e.Id -Force -ErrorAction Stop }
                '레지스트리' { Remove-ItemProperty -LiteralPath $e.Id -Name $e.Name -ErrorAction Stop }
                '작업스케줄러' { Unregister-ScheduledTask -TaskName $e.Name -TaskPath $e.Id -Confirm:$false -ErrorAction Stop }
            }
        }
        catch { "$($a.Name) / $($e.Kind) $($e.Name): $($_.Exception.Message)" }
    }
}

function Show-Info([string]$m) {
    [void][System.Windows.Forms.MessageBox]::Show($m, '프로그램 관리', 'OK', 'Information')
}

function New-Button([string]$text, [int]$w = 100) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true                      # 화면 배율(DPI)이 커져도 글자가 잘리지 않게
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size($w, 30)
    $b
}

function Show-Detail {
    if ($script:grid.SelectedRows.Count -ne 1) { $script:txt.Text = ''; return }
    $a = $script:grid.SelectedRows[0].Tag
    if (-not $a) { return }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("경로: $($a.Path)")
    $spec = Get-LaunchSpec $a
    $src = if ($spec.Manual) { '사용자 지정' } else { '자동 감지' }
    $lines.Add("실행 명령($src): $(if ($spec.Command) { $spec.Command } else { '찾지 못함 - [실행 설정]에서 지정' })")
    $lines.Add("실행 방식: $(if ($spec.Hidden) { '창 숨김' } else { '콘솔 창 표시' })")
    $lines.Add('')
    $lines.Add('[실행 중인 프로세스]')
    if ($a.Procs.Count) {
        foreach ($p in $a.Procs) {
            $cmd = if ($p.CommandLine) { $p.CommandLine } else { $p.ExecutablePath }
            if ($cmd.Length -gt 220) { $cmd = $cmd.Substring(0, 220) + '...' }
            $lines.Add("  PID $($p.ProcessId)  $cmd")
        }
    }
    else { $lines.Add('  없음') }
    $lines.Add('')
    $lines.Add('[자동 실행 등록]')
    if ($a.Auto.Count) {
        foreach ($e in $a.Auto) { $lines.Add("  $($e.Kind): $($e.Name)") }
    }
    else { $lines.Add('  없음') }
    $script:txt.Text = $lines -join "`r`n"
}

function Update-Grid {
    $script:Form.Cursor = 'WaitCursor'
    try {
        $script:lblRoot.Text = "관리 폴더: $($script:Root)"
        $keep = @($script:grid.SelectedRows | ForEach-Object { $_.Tag.Name })
        $script:grid.Rows.Clear()
        foreach ($a in @(Get-AppInfo)) {
            $status = if ($a.IsSelf) { 'UtilMonster(자신)' } elseif ($a.Procs.Count) { "실행 중 ($($a.Procs.Count))" } else { '중지' }
            $auto = if ($a.Auto.Count) { (($a.Auto | ForEach-Object Kind | Select-Object -Unique) -join ', ') } else { '-' }
            $i = $script:grid.Rows.Add($a.Name, $a.Kind, $status, $auto, (Format-Size $a.SizeBytes), $a.Latest.ToString('yyyy-MM-dd HH:mm'))
            $script:grid.Rows[$i].Tag = $a
            if ($a.Procs.Count) { $script:grid.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(228, 245, 228) }
        }
        # 새로고침 전에 선택돼 있던 프로그램을 다시 선택
        $script:grid.ClearSelection()
        foreach ($row in $script:grid.Rows) { if ($keep -contains $row.Tag.Name) { $row.Selected = $true } }
        Show-Detail
    }
    finally { $script:Form.Cursor = 'Default' }
}

# 선택된 프로그램 (UtilMonster가 들어 있는 폴더는 제외)
function Get-SelectedApps {
    $sel = @($script:grid.SelectedRows | ForEach-Object { $_.Tag })
    if (-not $sel.Count) { Show-Info '목록에서 프로그램을 먼저 선택하세요.'; return @() }
    $ok = @($sel | Where-Object { -not $_.IsSelf })
    if ($ok.Count -lt $sel.Count) { Show-Info 'UtilMonster가 들어 있는 폴더는 제외했습니다.' }
    $ok
}

function Edit-LaunchSettings($a) {
    $spec = Get-LaunchSpec $a
    $auto = Get-AutoCommand $a

    $d = New-Object System.Windows.Forms.Form
    $d.Text = "실행 설정 - $($a.Name)"
    $d.Font = $script:Form.Font
    $d.ClientSize = New-Object System.Drawing.Size(640, 215)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = '실행 명령 (비워 두면 자동 감지값 사용)'
    $l1.SetBounds(12, 12, 616, 22)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.SetBounds(12, 36, 616, 26)
    $tb.Text = $(if ($spec.Manual) { $spec.Command } else { '' })

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = "자동 감지: $(if ($auto) { $auto } else { '찾지 못함' })"
    $l2.ForeColor = [System.Drawing.Color]::DimGray
    $l2.AutoEllipsis = $true
    $l2.SetBounds(12, 68, 616, 22)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = "이 폴더를 작업 폴더로 실행합니다. 예) python main.py --port 8000"
    $l3.ForeColor = [System.Drawing.Color]::DimGray
    $l3.SetBounds(12, 92, 616, 22)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = '창 숨김 실행 (콘솔 창을 띄우지 않음 · 오류가 나도 창이 남지 않음)'
    $chk.Checked = $spec.Hidden
    $chk.SetBounds(12, 124, 616, 24)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '저장'
    $ok.DialogResult = 'OK'
    $ok.SetBounds(448, 170, 86, 32)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '취소'
    $cancel.DialogResult = 'Cancel'
    $cancel.SetBounds(542, 170, 86, 32)
    $d.AcceptButton = $ok
    $d.CancelButton = $cancel
    $d.Controls.AddRange(@($l1, $tb, $l2, $l3, $chk, $ok, $cancel))

    if ($d.ShowDialog($script:Form) -eq 'OK') {
        $cmd = $tb.Text.Trim()
        if ($cmd -or $chk.Checked) { $script:Cfg.apps[$a.Name] = @{ command = $cmd; hidden = $chk.Checked } }
        else { $script:Cfg.apps.Remove($a.Name) }
        Save-Config
    }
    $d.Dispose()
}

function New-UtilTab {
    param([System.Windows.Forms.TabPage]$Page, $Ctx)

    $script:Form = $Ctx.Form
    $script:SelfDir = $Ctx.AppDir.TrimEnd('\')
    $script:CfgPath = Join-Path $Ctx.ConfigDir 'AppManager.json'
    Read-Config

    $grid = New-Object System.Windows.Forms.DataGridView
    $script:grid = $grid
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.AutoSizeColumnsMode = 'Fill'
    foreach ($col in @(
            @('이름', 22), @('종류', 8), @('상태', 14), @('자동 실행', 18), @('크기', 10), @('수정일', 16))) {
        $i = $grid.Columns.Add($col[0], $col[0])
        $grid.Columns[$i].FillWeight = $col[1]
    }

    $txt = New-Object System.Windows.Forms.TextBox
    $script:txt = $txt
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = 'Vertical'
    $txt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $txt.Dock = 'Bottom'
    $txt.Height = 170

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'
    $top.AutoSize = $true
    $top.Padding = New-Object System.Windows.Forms.Padding(6)
    $lblRoot = New-Object System.Windows.Forms.Label
    $script:lblRoot = $lblRoot
    $lblRoot.AutoSize = $false
    $lblRoot.Width = 560
    $lblRoot.Height = 28
    $lblRoot.TextAlign = 'MiddleLeft'
    $lblRoot.AutoEllipsis = $true

    $btnRoot = New-Button '폴더 변경'
    $btnRefresh = New-Button '새로고침'
    $btnRun = New-Button '실행'
    $btnRestart = New-Button '재시작'
    $btnStop = New-Button '중지'
    $btnSettings = New-Button '실행 설정'
    $btnUnauto = New-Button '자동 실행 해제' 120
    $btnDelete = New-Button '삭제'
    $btnOpen = New-Button '폴더 열기'
    $btnRun.ForeColor = [System.Drawing.Color]::ForestGreen
    $btnDelete.ForeColor = [System.Drawing.Color]::Firebrick
    $btnUnauto.Margin = New-Object System.Windows.Forms.Padding(30, 3, 3, 3)
    $top.Controls.AddRange(@($lblRoot, $btnRoot, $btnRefresh, $btnRun, $btnRestart, $btnStop, $btnSettings, $btnUnauto, $btnDelete, $btnOpen))
    $top.SetFlowBreak($btnRefresh, $true)

    # Fill 컨트롤을 먼저 추가해야 Top/Bottom 도킹 후 남은 영역을 차지함
    $Page.Controls.Add($grid)
    $Page.Controls.Add($txt)
    $Page.Controls.Add($top)

    $grid.Add_SelectionChanged({ Show-Detail })

    $btnRefresh.Add_Click({ Update-Grid })

    $btnRoot.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = '프로그램들이 들어 있는 상위 폴더를 선택하세요'
            $d.SelectedPath = $script:Root
            if ($d.ShowDialog() -eq 'OK') {
                $script:Root = $d.SelectedPath
                Save-Config
                Update-Grid
            }
        })

    $btnRun.Add_Click({
            $apps = @(Get-SelectedApps)
            if (-not $apps.Count) { return }
            $errs = @()
            $started = 0
            foreach ($a in $apps) {
                if ($a.Procs.Count) { continue }
                $e = Start-App $a
                if ($e) { $errs += $e } else { $started++ }
            }
            if (-not $started -and -not $errs.Count) { Show-Info '선택한 프로그램이 이미 실행 중입니다.'; return }
            Start-Sleep -Milliseconds 1200
            Update-Grid
            if ($errs.Count) { Show-Info ($errs -join "`n") }
        })

    $btnRestart.Add_Click({
            $apps = @(Get-SelectedApps)
            if (-not $apps.Count) { return }
            $errs = @()
            foreach ($a in $apps) {
                if ($a.Procs.Count) { Stop-App $a; Start-Sleep -Milliseconds 800 }
                $e = Start-App $a
                if ($e) { $errs += $e }
            }
            Start-Sleep -Milliseconds 1200
            Update-Grid
            if ($errs.Count) { Show-Info ($errs -join "`n") }
        })

    $btnSettings.Add_Click({
            $apps = @(Get-SelectedApps)
            if ($apps.Count -ne 1) { if ($apps.Count) { Show-Info '실행 설정은 프로그램 하나만 선택해서 변경하세요.' }; return }
            Edit-LaunchSettings $apps[0]
            Update-Grid
        })

    $btnOpen.Add_Click({
            foreach ($r in $script:grid.SelectedRows) { Start-Process explorer.exe -ArgumentList "`"$($r.Tag.Path)`"" }
        })

    $btnStop.Add_Click({
            $apps = @(Get-SelectedApps | Where-Object { $_.Procs.Count })
            if (-not $apps.Count) { Show-Info '선택한 항목 중 실행 중인 프로세스가 없습니다.'; return }
            foreach ($a in $apps) { Stop-App $a }
            Start-Sleep -Milliseconds 700
            Update-Grid
        })

    $btnUnauto.Add_Click({
            $apps = @(Get-SelectedApps | Where-Object { $_.Auto.Count })
            if (-not $apps.Count) { Show-Info '선택한 항목 중 자동 실행 등록이 없습니다.'; return }
            $names = ($apps | ForEach-Object { "  - $($_.Name)" }) -join "`n"
            $r = [System.Windows.Forms.MessageBox]::Show("다음 프로그램의 자동 실행 등록을 해제합니다.`n`n$names", '자동 실행 해제', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            $errs = @($apps | ForEach-Object { Remove-Autostart $_ })
            Update-Grid
            if ($errs.Count) { Show-Info ("일부 항목을 해제하지 못했습니다.`n`n" + ($errs -join "`n")) }
        })

    $btnDelete.Add_Click({
            $apps = @(Get-SelectedApps)
            if (-not $apps.Count) { return }
            $names = ($apps | ForEach-Object { "  - $($_.Name)  ($(Format-Size $_.SizeBytes))" }) -join "`n"
            $msg = "다음 프로그램을 삭제합니다.`n`n$names`n`n" +
                   "실행 중이면 먼저 중지하고, 자동 실행 등록을 해제한 뒤 폴더를 휴지통으로 보냅니다.`n(휴지통에서 복구할 수 있습니다)"
            $r = [System.Windows.Forms.MessageBox]::Show($msg, '삭제 확인', 'YesNo', 'Warning', 'Button2')
            if ($r -ne 'Yes') { return }

            $errs = @()
            foreach ($a in $apps) {
                Stop-App $a
                Start-Sleep -Milliseconds 700
                $errs += @(Remove-Autostart $a)
                try {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($a.Path, 'AllDialogs', 'SendToRecycleBin')
                }
                catch { $errs += "$($a.Name): $($_.Exception.Message)" }
            }
            Update-Grid
            if ($errs.Count) { Show-Info ("일부 작업이 완료되지 않았습니다.`n`n" + ($errs -join "`n")) }
        })

    $lblRoot.Text = "관리 폴더: $($script:Root)  (스캔 중...)"
    $Page.Update()
    Update-Grid
}

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab
