<#
  MD → HTML 탭

  Markdown(.md) 문서를 디자인이 입혀진 HTML(왼쪽 목차·검색·인쇄 버튼 포함)로 변환합니다.
  원래 MDtoHTML 프로젝트를 탭으로 옮긴 것으로, 변환은 modules\MdToHtml\build_docs.py 가 그대로 합니다.
  - Python 3 이 필요합니다. 변환에 필요한 부품(markdown)은 처음 변환할 때 modules\MdToHtml\_lib 에만
    설치됩니다 (PC 전체에 영향 없음).
  - HTML 은 같은 폴더에 같은 이름으로 만들어집니다 (문서.md → 문서.html, 있으면 덮어씀).
  - 자동 변환을 켜면 MD 를 저장할 때마다 다시 변환하고, 열어 둔 브라우저도 저절로 새로고침됩니다.
    켜져 있는 동안에는 창을 닫아도 트레이에서 계속 동작합니다.
  - 변환기는 따로 실행되므로 변환 중에도 창이 멈추지 않습니다.
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Get-UtilTabInfo { @{ Title = 'MD → HTML'; Order = 50; Eager = $false } }

$script:Ctx = $null
$script:ToolDir = Join-Path $PSScriptRoot 'MdToHtml'
$script:Converter = Join-Path $script:ToolDir 'build_docs.py'
$script:CfgPath = $null
$script:Fmt = 'yyyy-MM-dd HH:mm:ss'
$script:SkipNames = @('claude.md', 'agents.md', 'readme.md')   # 폴더째 추가할 때 제외 (원래 변환기와 같음)
$script:MaxOpen = 3                                             # 한 번에 브라우저로 여는 최대 개수
$script:Paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:Python = $null          # 찾은 Python: @{ Exe; Version }
$script:PythonWarned = $false
$script:Job = $null             # 실행 중인 변환: @{ Proc; Out; Err; Files; Started }
$script:Queue = New-Object 'System.Collections.Generic.List[string]'
$script:OpenAfter = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:Watching = $false
$script:Seen = @{}              # 자동 변환: 파일 -> 마지막으로 본 수정 시각
$script:Changed = @{}           # 자동 변환: 바뀐 것 같은 파일 -> 그때 수정 시각 (저장이 끝날 때까지 한 번 더 확인)
$script:Timer = $null
$script:Loading = $false

$script:Rules = @'
MD 작성 형식 (변환기가 디자인을 입히는 규칙)

•  # 문서 제목  →  맨 위 큰 제목
     바로 아래 > 인용문은 둥근 정보 칩, 첫 문단은 설명으로 표시됩니다.
•  ## 01 · 장 제목  →  장 제목 (왼쪽 목차에 자동으로 들어감)
     장 사이에는 --- 를 넣습니다.
•  장 제목 바로 다음 줄에 *부제 한 줄*  →  장 부제
•  하위 목록은 2칸 들여쓰기
•  인용문(>) 박스
     - 장의 첫 내용이 인용문이면 강조 박스
     - > [!WARNING] 또는 > **주의:** … (주의·경고·위험·미확정·금지·정정)  →  노란 주의 박스
     - > [!NOTE] 이거나 그 외 인용문  →  초록 메모 박스,  > [!IMPORTANT]  →  강조 박스
•  표 칸에 높음·중상·중간·중하·낮음, P0·P1·P2, 고위험, 별도 검증 등을
   단독으로 쓰면 색상 태그로 표시됩니다.
•  코드는 ```언어 블록으로 씁니다.
•  MD 안에 HTML 태그를 직접 쓰지 않습니다.

HTML 은 자동으로 만들어지는 파일입니다. 내용은 항상 .md 에서 고치세요.
'@

# ---------------------------------------------------------------- 작은 도우미
function Set-Status([string]$text) { $script:lblStatus.Text = $text }

function Write-Out([string]$text) {
    $box = $script:txtLog
    if ($box.TextLength -gt 60000) { $box.Text = $box.Text.Substring($box.TextLength - 30000) }
    $box.AppendText(($text -replace "`r?`n", "`r`n") + "`r`n")
}

function Get-HtmlPath([string]$md) { [IO.Path]::ChangeExtension($md, '.html') }
function Get-ReloadPath([string]$md) { [IO.Path]::ChangeExtension($md, '.reload.js') }

function New-Button([string]$text, [int]$w = 100) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size($w, 30)
    $b
}

function Find-Python {
    if ($script:Python) { return $script:Python }
    foreach ($name in 'py', 'python') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        try {
            # Microsoft Store 의 가짜 python.exe(설치 안내용)는 버전 대신 안내문을 내므로 걸러진다
            $v = (& $cmd.Source --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $v -match '^Python 3') {
                $script:Python = @{ Exe = $cmd.Source; Version = $v }
                return $script:Python
            }
        }
        catch { }
    }
    $null
}

# ---------------------------------------------------------------- 설정
function Save-Config {
    if ($script:Loading -or -not $script:CfgPath) { return }
    try {
        @{
            files      = @($script:list.Items | ForEach-Object { [string]$_.Tag })
            openAfter  = $script:chkOpen.Checked
            includeSub = $script:chkSub.Checked
        } | ConvertTo-Json | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
    }
    catch { }
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:CfgPath)) { return $null }
    try { Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

# ---------------------------------------------------------------- 목록
# 행 하나의 상태 표시를 실제 파일에 맞게 새로 고침
function Update-Row($it) {
    $md = [string]$it.Tag
    $html = Get-HtmlPath $md
    if (-not [IO.File]::Exists($md)) {
        $it.SubItems[1].Text = 'MD 파일 없음'
        $it.SubItems[2].Text = ''
        $it.ForeColor = [System.Drawing.Color]::Firebrick
    }
    elseif (-not [IO.File]::Exists($html)) {
        $it.SubItems[1].Text = 'HTML 없음'
        $it.SubItems[2].Text = ''
        $it.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $h = [IO.File]::GetLastWriteTime($html)
        if ($h -lt [IO.File]::GetLastWriteTime($md)) {
            $it.SubItems[1].Text = 'MD가 더 새로움'
            $it.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        else {
            $it.SubItems[1].Text = '최신'
            $it.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
        $it.SubItems[2].Text = $h.ToString($script:Fmt)
    }
}

function Update-AllRows { foreach ($it in $script:list.Items) { Update-Row $it } }

function Find-Row([string]$md) {
    foreach ($it in $script:list.Items) { if ([string]$it.Tag -ieq $md) { return $it } }
    $null
}

# .md 하나 추가. 새로 추가됐으면 $true
function Add-Md([string]$path) {
    try { $full = [IO.Path]::GetFullPath($path) } catch { return $false }
    if ([IO.Path]::GetExtension($full) -ine '.md' -or -not [IO.File]::Exists($full)) { return $false }
    if (-not $script:Paths.Add($full)) { return $false }
    $it = New-Object System.Windows.Forms.ListViewItem($full)
    [void]$it.SubItems.Add('')
    [void]$it.SubItems.Add('')
    $it.Tag = $full
    Update-Row $it
    [void]$script:list.Items.Add($it)
    $true
}

# 파일/폴더 여러 개 추가. 폴더는 안의 .md 를 (includeSub 면 하위 폴더까지) 추가
function Add-Many([string[]]$items, [bool]$includeSub) {
    $added = 0
    $others = 0
    $script:Ctx.Form.Cursor = 'WaitCursor'
    $script:list.BeginUpdate()
    try {
        foreach ($p in $items) {
            if ([IO.Directory]::Exists($p)) {
                $found = Get-ChildItem -LiteralPath $p -Filter *.md -File -Recurse:$includeSub -ErrorAction SilentlyContinue |
                    Where-Object { $script:SkipNames -notcontains $_.Name.ToLowerInvariant() -and $_.FullName -notmatch '\\_lib\\' } |
                    Sort-Object FullName
                foreach ($f in $found) { if (Add-Md $f.FullName) { $added++ } }
            }
            elseif ([IO.Path]::GetExtension($p) -ieq '.md') { if (Add-Md $p) { $added++ } }
            else { $others++ }
        }
    }
    finally {
        $script:list.EndUpdate()
        $script:Ctx.Form.Cursor = 'Default'
    }
    $msg = '{0}개 문서 (이번에 {1}개 추가)' -f $script:Paths.Count, $added
    if ($others) { $msg += " · .md 가 아닌 파일 $others 개는 건너뜀" }
    Set-Status $msg
    Save-Config
    $added
}

function Remove-Rows($items) {
    foreach ($it in @($items)) {
        $p = [string]$it.Tag
        [void]$script:Paths.Remove($p)
        $script:Seen.Remove($p)
        $script:Changed.Remove($p)
        Remove-ReloadFile $p
        $script:list.Items.Remove($it)
    }
    Set-Status ('{0}개 문서' -f $script:Paths.Count)
    Save-Config
}

# ---------------------------------------------------------------- 변환 (Python 을 따로 실행)
function Add-ToQueue([string[]]$files, [bool]$open) {
    foreach ($f in $files) {
        if (-not $script:Queue.Contains($f)) { $script:Queue.Add($f) }
        if ($open) { [void]$script:OpenAfter.Add($f) }
    }
    Start-NextJob
}

function Start-NextJob {
    if ($script:Job -or $script:Queue.Count -eq 0) { return }

    $py = Find-Python
    if (-not $py) {
        $script:Queue.Clear()
        $script:OpenAfter.Clear()
        Write-Out '[오류] Python 3 을 찾지 못했습니다. https://www.python.org/downloads/ 에서 설치해 주세요.'
        Set-Status 'Python 3 이 필요합니다.'
        if (-not $script:PythonWarned) {
            $script:PythonWarned = $true
            [void][System.Windows.Forms.MessageBox]::Show(
                "MD → HTML 변환에는 Python 3 이 필요합니다.`n`nhttps://www.python.org/downloads/ 에서 설치한 뒤`n(설치 화면의 'Add python.exe to PATH' 체크) UtilMonster 를 다시 실행해 주세요.",
                'MD → HTML', 'OK', 'Information')
        }
        return
    }

    # 명령줄 길이 제한이 있으므로 너무 많으면 나눠서 실행
    $files = @()
    $len = 0
    while ($script:Queue.Count -and ($files.Count -eq 0 -or $len -lt 20000)) {
        $f = $script:Queue[0]
        $script:Queue.RemoveAt(0)
        $files += $f
        $len += $f.Length + 3
    }

    $argList = @('"' + $script:Converter + '"', '--no-open')
    if ($script:Watching) { $argList += '--live' }
    $argList += @($files | ForEach-Object { '"' + $_ + '"' })

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $py.Exe
    $psi.Arguments = $argList -join ' '
    $psi.WorkingDirectory = $script:ToolDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

    $started = Get-Date
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        Write-Out "[오류] 변환기를 실행하지 못했습니다: $($_.Exception.Message)"
        Set-Status '변환기를 실행하지 못했습니다.'
        foreach ($f in $files) { [void]$script:OpenAfter.Remove($f) }
        return
    }
    # 출력은 비동기로 끝까지 읽어 둔다 (버퍼가 차서 멈추는 일 방지). 끝났는지는 타이머가 확인
    $script:Job = @{
        Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync()
        Files = $files; Started = $started
    }

    $mode = if ($script:Watching) { ' (자동 새로고침)' } else { '' }
    Write-Out ('── {0:HH:mm:ss} 변환 시작: {1}개{2}' -f $started, $files.Count, $mode)
    $msg = '변환 중... ({0}개)' -f $files.Count
    if (-not (Test-Path -LiteralPath (Join-Path $script:ToolDir '_lib\markdown'))) {
        $msg += ' 처음 실행이라 필요한 부품을 설치하고 있습니다 (10초 정도).'
    }
    Set-Status $msg
}

function Complete-Job {
    $job = $script:Job
    $script:Job = $null
    $out = ''
    $err = ''
    try { $out = $job.Out.Result } catch { }
    try { $err = $job.Err.Result } catch { }
    $code = $job.Proc.ExitCode
    $job.Proc.Dispose()

    foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Write-Out $line } }
    foreach ($line in ($err -split "`r?`n")) { if ($line.Trim()) { Write-Out "  ! $line" } }

    $ok = 0
    $toOpen = @()
    foreach ($f in $job.Files) {
        $html = Get-HtmlPath $f
        $fresh = [IO.File]::Exists($html) -and [IO.File]::GetLastWriteTime($html) -ge $job.Started.AddSeconds(-2)
        if ($fresh) { $ok++ }
        if ($script:OpenAfter.Remove($f) -and $fresh) { $toOpen += $html }
        if (-not $script:Watching) { Remove-ReloadFile $f }   # 감시를 끈 뒤 끝난 변환의 흔적 정리
        $row = Find-Row $f
        if ($row) { Update-Row $row }
    }

    if ($toOpen.Count) {
        foreach ($h in ($toOpen | Select-Object -First $script:MaxOpen)) {
            try { Start-Process -FilePath $h } catch { Write-Out "  ! 브라우저로 열지 못함: $h" }
        }
        if ($toOpen.Count -gt $script:MaxOpen) { Write-Out ("  (브라우저는 처음 {0}개만 열었습니다)" -f $script:MaxOpen) }
    }

    $fail = $job.Files.Count - $ok
    if ($fail -or $code -ne 0) { Set-Status ('{0:HH:mm:ss} 변환 끝: 성공 {1}개, 실패 {2}개 — 아래 기록을 확인하세요.' -f (Get-Date), $ok, $fail) }
    elseif ($script:Watching) { Set-Status ('{0:HH:mm:ss} 변환 완료 ({1}개). 자동 변환 중 — MD 를 저장하면 바로 다시 변환합니다.' -f (Get-Date), $ok) }
    else { Set-Status ('{0:HH:mm:ss} 변환 완료: {1}개' -f (Get-Date), $ok) }
}

# ---------------------------------------------------------------- 자동 변환 (저장 감시)
function Remove-ReloadFile([string]$md) {
    try { [IO.File]::Delete((Get-ReloadPath $md)) } catch { }
}

function Get-Stamp([string]$p) {
    if ([IO.File]::Exists($p)) { [IO.File]::GetLastWriteTimeUtc($p).Ticks } else { 0 }
}

# 저장된 파일 찾기. 한 번 더 확인해서 수정 시각이 그대로면(저장이 끝났으면) 변환 대기열에 넣는다
function Test-Changes {
    foreach ($it in $script:list.Items) {
        $p = [string]$it.Tag
        $t = Get-Stamp $p
        if (-not $script:Seen.ContainsKey($p)) { $script:Seen[$p] = $t; continue }
        if ($t -eq 0 -or $t -eq $script:Seen[$p]) { $script:Changed.Remove($p); continue }
        if ($script:Changed.ContainsKey($p) -and $script:Changed[$p] -eq $t) {
            $script:Seen[$p] = $t
            $script:Changed.Remove($p)
            Write-Out ('{0:HH:mm:ss} 변경 감지: {1}' -f (Get-Date), [IO.Path]::GetFileName($p))
            Add-ToQueue @($p) $false
        }
        else { $script:Changed[$p] = $t }
    }
}

function Start-Watch {
    $files = @($script:list.Items | ForEach-Object { [string]$_.Tag })
    if (-not $files.Count) {
        [void][System.Windows.Forms.MessageBox]::Show('먼저 변환할 .md 파일을 추가해 주세요.', 'MD → HTML', 'OK', 'Information')
        return $false
    }
    $script:Watching = $true
    $script:Ctx.KeepAlive['MdToHtml'] = $true
    $script:Seen = @{}
    $script:Changed = @{}
    foreach ($f in $files) { $script:Seen[$f] = Get-Stamp $f }
    Write-Out ('── {0:HH:mm:ss} 자동 변환 켬: 문서 {1}개 감시' -f (Get-Date), $files.Count)
    # 처음 한 번 전부 자동 새로고침 방식으로 변환 (열어 둔 브라우저가 이후 저절로 새로고침되도록)
    Add-ToQueue $files $script:chkOpen.Checked
    $true
}

function Stop-Watch {
    if (-not $script:Watching) { return }
    $script:Watching = $false
    $script:Ctx.KeepAlive['MdToHtml'] = $false
    $script:Seen = @{}
    $script:Changed = @{}
    foreach ($it in $script:list.Items) { Remove-ReloadFile ([string]$it.Tag) }
    Write-Out ('── {0:HH:mm:ss} 자동 변환 끔' -f (Get-Date))
    if (-not $script:Job) { Set-Status '자동 변환을 껐습니다.' }
}

function Invoke-Tick {
    try {
        if ($script:Job -and $script:Job.Proc.HasExited) { Complete-Job }
        if ($script:Watching) { Test-Changes }
        Start-NextJob
    }
    catch { try { Write-Out "[오류] $($_.Exception.Message)" } catch { } }
}

# ---------------------------------------------------------------- 끌어놓기
function Enable-Drop($ctl) {
    $ctl.AllowDrop = $true
    $ctl.Add_DragEnter({
            param($s, $e)
            $e.Effect = if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }
        })
    $ctl.Add_DragDrop({
            param($s, $e)
            $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            if ($files) { [void](Add-Many @($files) $script:chkSub.Checked) }
        })
    foreach ($c in $ctl.Controls) { Enable-Drop $c }
}

# ---------------------------------------------------------------- 화면
function New-UtilTab {
    param([System.Windows.Forms.TabPage]$Page, $Ctx)

    $script:Ctx = $Ctx
    $script:CfgPath = Join-Path $Ctx.ConfigDir 'MdToHtml.json'
    $pad = New-Object System.Windows.Forms.Padding(10)

    # ---- ① 문서 고르기
    $g1 = New-Object System.Windows.Forms.GroupBox
    $g1.Text = '① 변환할 MD 문서'
    $g1.Dock = 'Fill'
    $g1.Padding = $pad

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '.md 파일이나 폴더를 이 창 안으로 끌어다 놓으세요. HTML 은 MD 와 같은 폴더에 같은 이름으로 만들어집니다.'
    $hint.Dock = 'Top'
    $hint.Height = 36
    $hint.TextAlign = 'MiddleCenter'
    $hint.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(26, 79, 160)

    $btnBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $btnBar.Dock = 'Top'
    $btnBar.AutoSize = $true
    $btnBar.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 4)
    $btnAddFile = New-Button '파일 추가'
    $btnAddDir = New-Button '폴더 추가'
    $btnRemove = New-Button '선택 항목 빼기' 120
    $btnClear = New-Button '전체 비우기'
    $btnRules = New-Button 'MD 작성 규칙' 110
    $script:chkSub = New-Object System.Windows.Forms.CheckBox
    $script:chkSub.Text = '폴더를 추가할 때 하위 폴더도 포함'
    $script:chkSub.AutoSize = $true
    $script:chkSub.Margin = New-Object System.Windows.Forms.Padding(20, 7, 3, 3)
    $btnBar.Controls.AddRange(@($btnAddFile, $btnAddDir, $btnRemove, $btnClear, $btnRules, $script:chkSub))

    $script:list = New-Object System.Windows.Forms.ListView
    $script:list.Dock = 'Fill'
    $script:list.View = 'Details'
    $script:list.FullRowSelect = $true
    $script:list.MultiSelect = $true
    $script:list.HideSelection = $false
    $script:list.GridLines = $true
    [void]$script:list.Columns.Add('MD 파일', 560)
    [void]$script:list.Columns.Add('HTML 상태', 130)
    [void]$script:list.Columns.Add('HTML 만든 시각', 160)

    $g1.Controls.Add($script:list)
    $g1.Controls.Add($btnBar)
    $g1.Controls.Add($hint)

    # ---- ② 옵션
    $g2 = New-Object System.Windows.Forms.GroupBox
    $g2.Text = '② 변환 방법'
    $g2.Dock = 'Bottom'
    $g2.Height = 64
    $script:chkOpen = New-Object System.Windows.Forms.CheckBox
    $script:chkOpen.Text = '변환 후 브라우저로 열기'
    $script:chkOpen.Checked = $true
    $script:chkOpen.SetBounds(16, 26, 200, 26)
    $script:chkWatch = New-Object System.Windows.Forms.CheckBox
    $script:chkWatch.Text = '자동 변환 — MD 를 저장하면 바로 다시 변환하고, 열어 둔 브라우저도 저절로 새로고침'
    $script:chkWatch.AutoSize = $true
    $script:chkWatch.Location = New-Object System.Drawing.Point(230, 28)
    $g2.Controls.AddRange(@($script:chkOpen, $script:chkWatch))

    # ---- 변환 기록
    $g3 = New-Object System.Windows.Forms.GroupBox
    $g3.Text = '변환 기록'
    $g3.Dock = 'Bottom'
    $g3.Height = 150
    $g3.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 8)
    $script:txtLog = New-Object System.Windows.Forms.TextBox
    $script:txtLog.Dock = 'Fill'
    $script:txtLog.Multiline = $true
    $script:txtLog.ReadOnly = $true
    $script:txtLog.ScrollBars = 'Vertical'
    $script:txtLog.BackColor = [System.Drawing.SystemColors]::Window
    $script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $g3.Controls.Add($script:txtLog)

    # ---- 실행 버튼
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 56
    $bottom.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
    $actions = New-Object System.Windows.Forms.FlowLayoutPanel
    $actions.Dock = 'Right'
    $actions.AutoSize = $true
    $actions.FlowDirection = 'RightToLeft'
    $actions.WrapContents = $false
    $btnAll = New-Button '전체 변환' 130
    $btnAll.Font = New-Object System.Drawing.Font('Malgun Gothic', 12, [System.Drawing.FontStyle]::Bold)
    $btnSel = New-Button '선택 변환' 100
    $btnOpen = New-Button 'HTML 열기' 100
    $btnDir = New-Button '폴더 열기' 90
    foreach ($b in $btnSel, $btnOpen, $btnDir) { $b.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3) }
    $actions.Controls.AddRange(@($btnAll, $btnSel, $btnOpen, $btnDir))
    $script:lblStatus = New-Object System.Windows.Forms.Label
    $script:lblStatus.Dock = 'Fill'
    $script:lblStatus.TextAlign = 'MiddleLeft'
    $script:lblStatus.AutoEllipsis = $true
    $bottom.Controls.Add($script:lblStatus)
    $bottom.Controls.Add($actions)

    $Page.Controls.Add($g1)
    $Page.Controls.Add($g2)
    $Page.Controls.Add($g3)
    $Page.Controls.Add($bottom)
    $Page.Padding = New-Object System.Windows.Forms.Padding(8)

    # ---- 저장된 목록 불러오기
    $script:Loading = $true
    try {
        $cfg = Read-Config
        if ($cfg) {
            if ($null -ne $cfg.openAfter) { $script:chkOpen.Checked = [bool]$cfg.openAfter }
            if ($null -ne $cfg.includeSub) { $script:chkSub.Checked = [bool]$cfg.includeSub }
            $script:list.BeginUpdate()
            foreach ($f in @($cfg.files)) { if ($f) { [void](Add-Md ([string]$f)) } }
            $script:list.EndUpdate()
        }
    }
    finally { $script:Loading = $false }
    if ($script:Paths.Count) { Set-Status ('{0}개 문서' -f $script:Paths.Count) }
    else { Set-Status '.md 파일을 추가해 주세요.' }

    $py = Find-Python
    if ($py) { Write-Out "$($py.Version) 사용 ($($py.Exe))" }
    else { Write-Out '[알림] Python 3 을 찾지 못했습니다. 변환하려면 https://www.python.org/downloads/ 에서 설치해 주세요.' }

    # ---- 이벤트
    $btnAddFile.Add_Click({
            $d = New-Object System.Windows.Forms.OpenFileDialog
            $d.Title = '변환할 MD 파일 선택'
            $d.Filter = 'Markdown (*.md)|*.md'
            $d.Multiselect = $true
            if ($d.ShowDialog() -eq 'OK') { [void](Add-Many $d.FileNames $false) }
            $d.Dispose()
        })

    $btnAddDir.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = '.md 파일이 들어 있는 폴더 선택'
            if ($d.ShowDialog() -eq 'OK') { [void](Add-Many @($d.SelectedPath) $script:chkSub.Checked) }
            $d.Dispose()
        })

    $btnRemove.Add_Click({ Remove-Rows $script:list.SelectedItems })

    $btnClear.Add_Click({
            if (-not $script:list.Items.Count) { return }
            Remove-Rows $script:list.Items
            Set-Status '.md 파일을 추가해 주세요.'
        })

    $btnRules.Add_Click({ [void][System.Windows.Forms.MessageBox]::Show($script:Rules, 'MD 작성 규칙', 'OK', 'Information') })

    $script:list.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Delete') { Remove-Rows $script:list.SelectedItems }
        })

    # 더블클릭: HTML 이 있으면 열고, 없으면 변환한 뒤 연다
    $script:list.Add_DoubleClick({
            $it = $script:list.FocusedItem
            if (-not $it) { return }
            $md = [string]$it.Tag
            $html = Get-HtmlPath $md
            if ([IO.File]::Exists($html)) { Start-Process -FilePath $html }
            elseif ([IO.File]::Exists($md)) { Add-ToQueue @($md) $true }
        })

    $btnAll.Add_Click({
            $files = @($script:list.Items | ForEach-Object { [string]$_.Tag })
            if (-not $files.Count) {
                [void][System.Windows.Forms.MessageBox]::Show('먼저 변환할 .md 파일을 추가해 주세요.', 'MD → HTML', 'OK', 'Information')
                return
            }
            Add-ToQueue $files $script:chkOpen.Checked
        })

    $btnSel.Add_Click({
            $files = @($script:list.SelectedItems | ForEach-Object { [string]$_.Tag })
            if (-not $files.Count) {
                [void][System.Windows.Forms.MessageBox]::Show('목록에서 변환할 문서를 선택해 주세요.', 'MD → HTML', 'OK', 'Information')
                return
            }
            Add-ToQueue $files $script:chkOpen.Checked
        })

    $btnOpen.Add_Click({
            $sel = @($script:list.SelectedItems)
            if (-not $sel.Count) { $sel = @($script:list.Items) }
            $html = @($sel | ForEach-Object { Get-HtmlPath ([string]$_.Tag) } | Where-Object { [IO.File]::Exists($_) })
            if (-not $html.Count) {
                [void][System.Windows.Forms.MessageBox]::Show('아직 만들어진 HTML 이 없습니다. 먼저 변환해 주세요.', 'MD → HTML', 'OK', 'Information')
                return
            }
            foreach ($h in ($html | Select-Object -First $script:MaxOpen)) { Start-Process -FilePath $h }
        })

    $btnDir.Add_Click({
            $it = $script:list.FocusedItem
            if (-not $it -and $script:list.Items.Count) { $it = $script:list.Items[0] }
            if (-not $it) { return }
            $md = [string]$it.Tag
            if ([IO.File]::Exists($md)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$md`"" }
            else { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$([IO.Path]::GetDirectoryName($md))`"" }
        })

    $script:chkOpen.Add_CheckedChanged({ Save-Config })
    $script:chkSub.Add_CheckedChanged({ Save-Config })

    $script:chkWatch.Add_CheckedChanged({
            if ($script:chkWatch.Checked) {
                if (-not (Start-Watch)) { $script:chkWatch.Checked = $false }
            }
            else { Stop-Watch }
        })

    # 변환 완료 확인 + 자동 변환 감시. 0.5초마다 (UI 스레드에서 실행되므로 안전)
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 500
    $script:Timer.Add_Tick({ Invoke-Tick })
    $script:Timer.Start()

    # 탭으로 돌아올 때마다 상태 새로 고침 (다른 곳에서 변환했을 수 있음)
    $Page.Add_Enter({ if (-not $script:Watching) { Update-AllRows } })

    Enable-Drop $Page
}

function Stop-UtilTab {
    if ($script:Timer) { $script:Timer.Stop() }
    if ($script:Job) {
        # 변환 중이면 잠깐 기다렸다가, 너무 오래 걸리면 끝낸다
        try { if (-not $script:Job.Proc.WaitForExit(5000)) { $script:Job.Proc.Kill() } } catch { }
    }
    $script:Watching = $false
    if ($script:list) { foreach ($it in $script:list.Items) { Remove-ReloadFile ([string]$it.Tag) } }
    Save-Config
}

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab, Stop-UtilTab
