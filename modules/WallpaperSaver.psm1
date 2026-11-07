<#
  배경화면 저장 탭

  - 현재 바탕화면 배경 이미지를 저장
  - Windows 스포트라이트(잠금화면) 사진 중 가로형 고해상도만 썸네일로 보여 주고, 골라서(또는 전부) 저장
  - 내용이 같은 파일(SHA-256)은 건너뛰므로 여러 번 저장해도 중복되지 않음
  저장 위치 기본값: 내 사진\WallpaperSaver (Desktop / Spotlight 하위 폴더). 설정은 config\WallpaperSaver.json
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Get-UtilTabInfo { @{ Title = '배경화면 저장'; Order = 30; Eager = $false } }

$script:Ctx = $null
$script:CfgPath = ''
$script:OutDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'WallpaperSaver'
$script:MinWidth = 1000
$script:ThumbW = 256
$script:ThumbH = 144
$script:Assets = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Assets'
$script:Cards = @()
$script:Candidates = @()

function Save-Config {
    try { [ordered]@{ outDir = $script:OutDir } | ConvertTo-Json | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8 } catch { }
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:CfgPath)) { return }
    try {
        $c = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.outDir) { $script:OutDir = [string]$c.outDir }
    }
    catch { }
}

function Get-BytesHash([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
}

# 파일 SHA-256. Get-FileHash 는 PowerShell 7 환경에서 실행했을 때 못 찾는 경우가 있어 .NET 으로 직접 계산한다.
function Get-FileSha256([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') } finally { $fs.Dispose() }
    }
    finally { $sha.Dispose() }
}

# 저장 폴더에 이미 있는 파일의 해시 (중복 방지)
function Get-SavedHashes([string]$dir) {
    $set = @{}
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $set[(Get-FileSha256 $_.FullName)] = $true } catch { }
        }
    }
    $set
}

# Assets 폴더에서 가로형 사진 목록 + 썸네일 만들기 (원본 파일은 잠그지 않음)
function Read-Candidates {
    if (-not (Test-Path -LiteralPath $script:Assets)) { return @() }
    $result = @()
    foreach ($f in (Get-ChildItem -LiteralPath $script:Assets -File | Where-Object { $_.Length -gt 100KB } | Sort-Object LastWriteTime -Descending)) {
        try {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $ms = New-Object IO.MemoryStream(, $bytes)
            $img = [Drawing.Image]::FromStream($ms)
            try {
                if ($img.Width -lt $script:MinWidth -or $img.Width -le $img.Height) { continue }   # 세로형/작은 이미지 제외
                $thumb = New-Object Drawing.Bitmap($script:ThumbW, $script:ThumbH)
                $g = [Drawing.Graphics]::FromImage($thumb)
                $g.InterpolationMode = 'HighQualityBicubic'
                $g.DrawImage($img, 0, 0, $script:ThumbW, $script:ThumbH)
                $g.Dispose()
                $result += [pscustomobject]@{
                    Path = $f.FullName; Date = $f.LastWriteTime; W = $img.Width; H = $img.Height
                    Hash = Get-BytesHash $bytes; Thumb = $thumb
                }
            }
            finally { $img.Dispose(); $ms.Dispose() }
        }
        catch { }   # 이미지가 아닌 파일은 무시
    }
    $result
}

function Set-Status([string]$text) { $script:lblStatus.Text = $text }

function Update-Status {
    $n = @($script:Cards | Where-Object { $_.Check.Checked }).Count
    Set-Status ('스포트라이트 가로형 사진 {0}장 · 선택 {1}장 · 저장 위치: {2}' -f $script:Cards.Count, $n, $script:OutDir)
}

function Clear-Cards {
    $script:flow.Controls.Clear()
    foreach ($c in $script:Candidates) { $c.Thumb.Dispose() }
    $script:Candidates = @()
    $script:Cards = @()
}

# 스포트라이트 사진을 다시 읽어서 썸네일 목록을 새로 그린다
function Update-Cards {
    $script:Ctx.Form.Cursor = 'WaitCursor'
    try {
        Clear-Cards
        $script:Candidates = @(Read-Candidates)
        $saved = Get-SavedHashes $script:OutDir

        $script:flow.SuspendLayout()
        foreach ($c in $script:Candidates) {
            $panel = New-Object Windows.Forms.Panel
            $panel.Size = New-Object Drawing.Size(($script:ThumbW + 12), ($script:ThumbH + 40))

            $pb = New-Object Windows.Forms.PictureBox
            $pb.Image = $c.Thumb
            $pb.SizeMode = 'Zoom'
            $pb.Location = New-Object Drawing.Point(4, 2)
            $pb.Size = New-Object Drawing.Size($script:ThumbW, $script:ThumbH)
            $pb.Cursor = 'Hand'

            $cb = New-Object Windows.Forms.CheckBox
            $cb.AutoSize = $true
            $cb.Location = New-Object Drawing.Point(4, ($script:ThumbH + 8))
            $cb.Text = '{0}x{1}  {2:yyyy-MM-dd}' -f $c.W, $c.H, $c.Date
            if ($saved.ContainsKey($c.Hash)) { $cb.Text += '  (이미 저장됨)'; $cb.Enabled = $false }

            $pb.Tag = $cb
            $pb.Add_Click({ if ($this.Tag.Enabled) { $this.Tag.Checked = -not $this.Tag.Checked } })
            $cb.Add_CheckedChanged({ Update-Status })

            $panel.Controls.AddRange(@($pb, $cb))
            $script:flow.Controls.Add($panel)
            $script:Cards += [pscustomobject]@{ Item = $c; Check = $cb }
        }
        $script:flow.ResumeLayout()

        if ($script:Cards.Count -eq 0) { Set-Status '저장할 수 있는 가로형 스포트라이트 사진을 찾지 못했습니다.' }
        else { Update-Status }
    }
    finally { $script:Ctx.Form.Cursor = 'Default' }
}

# 카드의 사진을 저장하고 화면 표시를 "저장됨"으로 바꾼다. 새로 저장한 장수를 반환
function Save-Cards($cards) {
    $dest = Join-Path $script:OutDir 'Spotlight'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $existing = Get-SavedHashes $script:OutDir
    $n = 0
    foreach ($k in $cards) {
        $c = $k.Item
        if (-not $existing.ContainsKey($c.Hash)) {
            $name = 'spotlight_{0:yyyyMMdd}_{1}.jpg' -f $c.Date, $c.Hash.Substring(0, 8)
            Copy-Item -LiteralPath $c.Path -Destination (Join-Path $dest $name)
            $existing[$c.Hash] = $true
            $n++
        }
        if ($k.Check.Enabled) {
            $k.Check.Checked = $false
            $k.Check.Text += '  (이미 저장됨)'
            $k.Check.Enabled = $false
        }
    }
    $n
}

# 현재 바탕화면 배경 저장
function Save-Desktop {
    $wall = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper
    $transcoded = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
    $src = if ($wall -and (Test-Path -LiteralPath $wall)) { $wall } elseif (Test-Path -LiteralPath $transcoded) { $transcoded } else { $null }
    if (-not $src) { return '배경 이미지 파일을 찾지 못했습니다 (단색 배경이거나 슬라이드쇼일 수 있음).' }

    $dir = Join-Path $script:OutDir 'Desktop'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $known = Get-SavedHashes $script:OutDir
    $h = Get-FileSha256 $src
    if ($known.ContainsKey($h)) { return '현재 배경화면은 이미 저장돼 있습니다.' }

    $ext = [IO.Path]::GetExtension($src)
    if (-not $ext -or $src -eq $transcoded) { $ext = '.jpg' }
    $stamp = (Get-Item -LiteralPath $src).LastWriteTime.ToString('yyyyMMdd')
    $dest = Join-Path $dir ('wallpaper_{0}_{1}{2}' -f $stamp, $h.Substring(0, 8), $ext)
    Copy-Item -LiteralPath $src -Destination $dest
    return "현재 배경화면을 저장했습니다: $dest"
}

function New-Button([string]$text, [int]$w = 110) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true                      # 화면 배율(DPI)이 커져도 글자가 잘리지 않게
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size($w, 30)
    $b
}

function New-UtilTab {
    param([System.Windows.Forms.TabPage]$Page, $Ctx)

    $script:Ctx = $Ctx
    $script:CfgPath = Join-Path $Ctx.ConfigDir 'WallpaperSaver.json'
    Read-Config

    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'
    $bar.AutoSize = $true
    $bar.Padding = New-Object Windows.Forms.Padding(6)

    $btnDesktop = New-Button '현재 배경화면 저장' 150
    $btnAll = New-Button '스포트라이트 전부 저장' 170
    $btnSel = New-Button '선택 저장'
    $btnSel.Font = New-Object Drawing.Font($btnSel.Font, 'Bold')
    $btnCheckAll = New-Button '전체 선택'
    $btnCheckNone = New-Button '전체 해제'
    $btnRefresh = New-Button '새로고침'
    $btnDir = New-Button '저장 폴더...'
    $btnOpen = New-Button '폴더 열기'
    $btnCheckAll.Margin = New-Object Windows.Forms.Padding(12, 3, 3, 3)
    $btnDir.Margin = New-Object Windows.Forms.Padding(12, 3, 3, 3)
    $bar.Controls.AddRange(@($btnDesktop, $btnAll, $btnSel, $btnCheckAll, $btnCheckNone, $btnRefresh, $btnDir, $btnOpen))

    $script:lblStatus = New-Object Windows.Forms.Label
    $script:lblStatus.Dock = 'Bottom'
    $script:lblStatus.Height = 28
    $script:lblStatus.TextAlign = 'MiddleLeft'
    $script:lblStatus.Padding = New-Object Windows.Forms.Padding(8, 0, 0, 0)

    $script:flow = New-Object Windows.Forms.FlowLayoutPanel
    $script:flow.Dock = 'Fill'
    $script:flow.AutoScroll = $true
    $script:flow.Padding = New-Object Windows.Forms.Padding(8)

    # Fill 컨트롤을 먼저 추가해야 Top/Bottom 뒤로 가지 않음
    $Page.Controls.AddRange(@($script:flow, $bar, $script:lblStatus))

    $btnCheckAll.Add_Click({ foreach ($k in $script:Cards) { if ($k.Check.Enabled) { $k.Check.Checked = $true } } })
    $btnCheckNone.Add_Click({ foreach ($k in $script:Cards) { $k.Check.Checked = $false } })
    $btnRefresh.Add_Click({ Update-Cards })

    $btnOpen.Add_Click({
            if (Test-Path -LiteralPath $script:OutDir) { Invoke-Item -LiteralPath $script:OutDir }
            else { Set-Status "저장 폴더가 아직 없습니다: $($script:OutDir)" }
        })

    $btnDir.Add_Click({
            $d = New-Object Windows.Forms.FolderBrowserDialog
            $d.SelectedPath = $script:OutDir
            if ($d.ShowDialog() -eq 'OK') {
                $script:OutDir = $d.SelectedPath
                Save-Config
                Update-Cards   # 저장 폴더가 바뀌면 "이미 저장됨" 표시도 달라지므로 다시 읽는다
            }
        })

    $btnDesktop.Add_Click({
            try { Set-Status (Save-Desktop) }
            catch { [void][Windows.Forms.MessageBox]::Show("저장하지 못했습니다.`n$($_.Exception.Message)", '배경화면 저장', 'OK', 'Error') }
        })

    $btnSel.Add_Click({
            $targets = @($script:Cards | Where-Object { $_.Check.Checked -and $_.Check.Enabled })
            if ($targets.Count -eq 0) {
                [void][Windows.Forms.MessageBox]::Show('저장할 사진을 먼저 체크하세요.', '알림'); return
            }
            try {
                $n = Save-Cards $targets
                Update-Status
                Set-Status ("{0}장을 저장했습니다 → {1}" -f $n, (Join-Path $script:OutDir 'Spotlight'))
            }
            catch { [void][Windows.Forms.MessageBox]::Show("저장하지 못했습니다.`n$($_.Exception.Message)", '배경화면 저장', 'OK', 'Error') }
        })

    $btnAll.Add_Click({
            $targets = @($script:Cards | Where-Object { $_.Check.Enabled })
            if ($targets.Count -eq 0) { Set-Status '새로 저장할 스포트라이트 사진이 없습니다 (모두 저장돼 있거나 사진을 찾지 못함).'; return }
            try {
                $n = Save-Cards $targets
                Set-Status ("스포트라이트 {0}장을 저장했습니다 → {1}" -f $n, (Join-Path $script:OutDir 'Spotlight'))
            }
            catch { [void][Windows.Forms.MessageBox]::Show("저장하지 못했습니다.`n$($_.Exception.Message)", '배경화면 저장', 'OK', 'Error') }
        })

    Set-Status '스포트라이트 사진을 읽는 중...'
    $Page.Update()
    Update-Cards
}

function Stop-UtilTab { Clear-Cards }

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab, Stop-UtilTab
