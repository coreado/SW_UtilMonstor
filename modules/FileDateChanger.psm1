<#
  파일 날짜 변경 탭

  파일/폴더의 생성 날짜, 수정 날짜, 액세스(마지막 열람) 날짜를 원하는 값으로 바꿉니다.
  파일/폴더는 창 안으로 끌어다 놓아도 됩니다. (원래 Python 프로그램을 PowerShell 로 옮김 - Python 설치 불필요)
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Get-UtilTabInfo { @{ Title = '파일 날짜 변경'; Order = 40; Eager = $false } }

$script:Ctx = $null
$script:Fmt = 'yyyy-MM-dd HH:mm:ss'
$script:Paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# Win32 SetFileTime 직접 호출 (원래 프로그램과 동일한 방식).
# .NET 의 File.SetCreationTime 등은 쓰기 권한으로 파일을 열기 때문에 읽기 전용 파일에서 실패한다.
# 여기서는 "속성 쓰기" 권한만 쓰고 BACKUP_SEMANTICS 로 폴더도 열 수 있다.
if (-not ('UtilMonster.FileTimeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace UtilMonster {
    public static class FileTimeNative {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileTime(SafeFileHandle h, IntPtr created, IntPtr accessed, IntPtr modified);

        // null 인 항목은 건드리지 않는다. 실패하면 Win32Exception.
        public static void Set(string path, DateTime? created, DateTime? modified, DateTime? accessed) {
            const uint FILE_WRITE_ATTRIBUTES = 0x0100, SHARE_ALL = 7, OPEN_EXISTING = 3, BACKUP_SEMANTICS = 0x02000000;
            using (SafeFileHandle h = CreateFile(path, FILE_WRITE_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, BACKUP_SEMANTICS, IntPtr.Zero)) {
                if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                IntPtr c = Alloc(created), a = Alloc(accessed), m = Alloc(modified);
                try {
                    if (!SetFileTime(h, c, a, m)) throw new Win32Exception(Marshal.GetLastWin32Error());
                } finally {
                    Free(c); Free(a); Free(m);
                }
            }
        }
        static IntPtr Alloc(DateTime? dt) {
            if (!dt.HasValue) return IntPtr.Zero;
            IntPtr p = Marshal.AllocHGlobal(8);
            Marshal.WriteInt64(p, dt.Value.ToFileTime());   // Kind 가 지정되지 않은 값은 로컬 시간으로 처리됨
            return p;
        }
        static void Free(IntPtr p) { if (p != IntPtr.Zero) Marshal.FreeHGlobal(p); }
    }
}
'@
}

function Set-Status([string]$text) { $script:lblStatus.Text = $text }

function Get-Times([string]$path) {
    # File.Get*Time 은 폴더에도 동작한다
    [pscustomobject]@{
        Created  = [IO.File]::GetCreationTime($path)
        Modified = [IO.File]::GetLastWriteTime($path)
    }
}

# 목록에 항목 하나 추가. 새로 추가됐으면 $true
function Add-Item([string]$path) {
    try { $full = [IO.Path]::GetFullPath($path) } catch { return $false }
    if (-not (Test-Path -LiteralPath $full)) { return $false }
    if ($script:Paths.Contains($full)) { return $false }
    try { $t = Get-Times $full } catch { return $false }
    [void]$script:Paths.Add($full)
    $it = New-Object System.Windows.Forms.ListViewItem($full)
    [void]$it.SubItems.Add($t.Created.ToString($script:Fmt))
    [void]$it.SubItems.Add($t.Modified.ToString($script:Fmt))
    $it.Tag = $full
    [void]$script:list.Items.Add($it)
    return $true
}

# 파일/폴더 여러 개 추가. IncludeSub 이면 폴더 안의 파일/하위 폴더도 모두 추가. 새로 추가된 개수 반환
function Add-Many([string[]]$items, [bool]$includeSub) {
    $added = 0
    $script:Ctx.Form.Cursor = 'WaitCursor'
    $script:list.BeginUpdate()
    try {
        foreach ($p in $items) {
            if (Add-Item $p) { $added++ }
            if ($includeSub -and (Test-Path -LiteralPath $p -PathType Container)) {
                foreach ($c in (Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue)) {
                    if (Add-Item $c.FullName) { $added++ }
                }
            }
        }
    }
    finally {
        $script:list.EndUpdate()
        $script:Ctx.Form.Cursor = 'Default'
    }
    Set-Status ('{0}개 항목 (이번에 {1}개 추가)' -f $script:Paths.Count, $added)
    $added
}

# 목록 표시를 현재 파일 날짜로 새로 고침
function Update-Row($it) {
    $t = Get-Times $it.Tag
    $it.SubItems[1].Text = $t.Created.ToString($script:Fmt)
    $it.SubItems[2].Text = $t.Modified.ToString($script:Fmt)
}

# 날짜 적용. 성공 수와 실패 목록을 반환
function Set-FileDates([string[]]$paths, [hashtable]$values) {
    $ok = 0
    $fail = @()
    foreach ($p in $paths) {
        try {
            [UtilMonster.FileTimeNative]::Set($p, $values['created'], $values['modified'], $values['accessed'])
            $ok++
        }
        catch { $fail += "$p`n   → $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Ok = $ok; Fail = $fail }
}

# ---- 끌어놓기: 컨트롤마다 켜 줘야 어디에 놓아도 받는다 ----
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

function New-Button([string]$text, [int]$w = 100) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size($w, 30)
    $b
}

function New-UtilTab {
    param([System.Windows.Forms.TabPage]$Page, $Ctx)

    $script:Ctx = $Ctx
    $pad = New-Object System.Windows.Forms.Padding(10)

    # ---- ① 파일 고르기
    $g1 = New-Object System.Windows.Forms.GroupBox
    $g1.Text = '① 날짜를 바꿀 파일 고르기'
    $g1.Dock = 'Fill'
    $g1.Padding = $pad

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '파일이나 폴더를 이 창 안으로 끌어다 놓거나, 아래 버튼을 누르세요'
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
    $script:chkSub = New-Object System.Windows.Forms.CheckBox
    $script:chkSub.Text = '폴더를 추가할 때 안의 파일도 포함'
    $script:chkSub.Checked = $true
    $script:chkSub.AutoSize = $true
    $script:chkSub.Margin = New-Object System.Windows.Forms.Padding(20, 7, 3, 3)
    $btnBar.Controls.AddRange(@($btnAddFile, $btnAddDir, $btnRemove, $btnClear, $script:chkSub))

    $script:list = New-Object System.Windows.Forms.ListView
    $script:list.Dock = 'Fill'
    $script:list.View = 'Details'
    $script:list.FullRowSelect = $true
    $script:list.MultiSelect = $true
    $script:list.HideSelection = $false
    $script:list.GridLines = $true
    [void]$script:list.Columns.Add('파일 / 폴더', 420)
    [void]$script:list.Columns.Add('현재 생성 날짜', 160)
    [void]$script:list.Columns.Add('현재 수정 날짜', 160)

    # Fill 컨트롤을 먼저 추가해야 Top 도킹 후 남은 영역을 차지함
    $g1.Controls.Add($script:list)
    $g1.Controls.Add($btnBar)
    $g1.Controls.Add($hint)

    # ---- ② 날짜
    $g2 = New-Object System.Windows.Forms.GroupBox
    $g2.Text = '② 바꿀 날짜와 시간'
    $g2.Dock = 'Bottom'
    $g2.Height = 72
    $script:dtp = New-Object System.Windows.Forms.DateTimePicker
    $script:dtp.Format = 'Custom'
    $script:dtp.CustomFormat = $script:Fmt
    $script:dtp.SetBounds(16, 28, 260, 28)
    $now = Get-Date
    $script:dtp.Value = $now.AddTicks( - ($now.Ticks % 10000000))   # 밀리초 제거
    $btnNow = New-Button '지금 시각'
    $btnNow.Location = New-Object System.Drawing.Point(290, 26)
    $lblFmt = New-Object System.Windows.Forms.Label
    $lblFmt.Text = '(년-월-일 시:분:초 — 칸을 클릭하고 숫자를 입력하거나 ▼ 로 달력을 열 수 있어요)'
    $lblFmt.ForeColor = [System.Drawing.Color]::DimGray
    $lblFmt.AutoSize = $true
    $lblFmt.Location = New-Object System.Drawing.Point(410, 33)
    $g2.Controls.AddRange(@($script:dtp, $btnNow, $lblFmt))

    # ---- ③ 항목
    $g3 = New-Object System.Windows.Forms.GroupBox
    $g3.Text = '③ 어떤 날짜를 바꿀까요?'
    $g3.Dock = 'Bottom'
    $g3.Height = 64
    $script:chkCreated = New-Object System.Windows.Forms.CheckBox
    $script:chkCreated.Text = '생성 날짜'
    $script:chkCreated.Checked = $true
    $script:chkCreated.SetBounds(16, 26, 110, 26)
    $script:chkModified = New-Object System.Windows.Forms.CheckBox
    $script:chkModified.Text = '수정 날짜'
    $script:chkModified.Checked = $true
    $script:chkModified.SetBounds(140, 26, 110, 26)
    $script:chkAccessed = New-Object System.Windows.Forms.CheckBox
    $script:chkAccessed.Text = '액세스(마지막 열람) 날짜'
    $script:chkAccessed.SetBounds(264, 26, 240, 26)
    $g3.Controls.AddRange(@($script:chkCreated, $script:chkModified, $script:chkAccessed))

    # ---- 실행
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 56
    $bottom.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
    $btnApply = New-Button '날짜 바꾸기' 160
    $btnApply.Dock = 'Right'
    $btnApply.Font = New-Object System.Drawing.Font('Malgun Gothic', 12, [System.Drawing.FontStyle]::Bold)
    $script:lblStatus = New-Object System.Windows.Forms.Label
    $script:lblStatus.Dock = 'Fill'
    $script:lblStatus.TextAlign = 'MiddleLeft'
    $script:lblStatus.Text = '파일을 추가해 주세요.'
    $bottom.Controls.Add($script:lblStatus)
    $bottom.Controls.Add($btnApply)

    # Fill 먼저, 그다음 아래쪽 패널들(마지막에 추가한 것이 가장 아래에 놓임)
    $Page.Controls.Add($g1)
    $Page.Controls.Add($g2)
    $Page.Controls.Add($g3)
    $Page.Controls.Add($bottom)
    $Page.Padding = New-Object System.Windows.Forms.Padding(8)

    # ---- 이벤트
    $btnAddFile.Add_Click({
            $d = New-Object System.Windows.Forms.OpenFileDialog
            $d.Title = '날짜를 바꿀 파일 선택'
            $d.Multiselect = $true
            if ($d.ShowDialog() -eq 'OK') { [void](Add-Many $d.FileNames $false) }
            $d.Dispose()
        })

    $btnAddDir.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = '폴더 선택'
            if ($d.ShowDialog() -eq 'OK') { [void](Add-Many @($d.SelectedPath) $script:chkSub.Checked) }
            $d.Dispose()
        })

    $btnRemove.Add_Click({
            foreach ($it in @($script:list.SelectedItems)) {
                [void]$script:Paths.Remove([string]$it.Tag)
                $script:list.Items.Remove($it)
            }
            Set-Status ('{0}개 항목' -f $script:Paths.Count)
        })

    $btnClear.Add_Click({
            $script:list.Items.Clear()
            $script:Paths.Clear()
            Set-Status '파일을 추가해 주세요.'
        })

    $script:btnRemove = $btnRemove
    $script:list.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Delete') { $script:btnRemove.PerformClick() }
        })

    $btnNow.Add_Click({
            $n = Get-Date
            $script:dtp.Value = $n.AddTicks( - ($n.Ticks % 10000000))
        })

    $btnApply.Add_Click({
            if ($script:Paths.Count -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show('먼저 날짜를 바꿀 파일을 추가해 주세요.', '파일 날짜 변경', 'OK', 'Information')
                return
            }
            $dt = $script:dtp.Value
            $values = @{}
            $names = @()
            if ($script:chkCreated.Checked) { $values.created = $dt; $names += '생성' }
            if ($script:chkModified.Checked) { $values.modified = $dt; $names += '수정' }
            if ($script:chkAccessed.Checked) { $values.accessed = $dt; $names += '액세스' }
            if (-not $values.Count) {
                [void][System.Windows.Forms.MessageBox]::Show('③ 에서 바꿀 날짜를 하나 이상 체크해 주세요.', '파일 날짜 변경', 'OK', 'Information')
                return
            }
            $msg = "{0}개 항목의 [{1}] 날짜를`n{2:yyyy년 MM월 dd일 HH:mm:ss} 로 바꿉니다.`n`n계속할까요?" -f $script:Paths.Count, ($names -join ', '), $dt
            if ([System.Windows.Forms.MessageBox]::Show($msg, '확인', 'YesNo', 'Question') -ne 'Yes') { return }

            $r = Set-FileDates @($script:list.Items | ForEach-Object { [string]$_.Tag }) $values
            foreach ($it in $script:list.Items) { try { Update-Row $it } catch { } }
            Set-Status ('완료! 성공 {0}개, 실패 {1}개' -f $r.Ok, $r.Fail.Count)
            if ($r.Fail.Count) {
                [void][System.Windows.Forms.MessageBox]::Show("$($r.Fail.Count)개를 바꾸지 못했습니다:`n`n" + (($r.Fail | Select-Object -First 8) -join "`n"), '일부 실패', 'OK', 'Error')
            }
            else {
                [void][System.Windows.Forms.MessageBox]::Show("$($r.Ok)개 항목의 날짜를 바꿨습니다.", '완료', 'OK', 'Information')
            }
        })

    Enable-Drop $Page
}

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab
