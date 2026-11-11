<#
  폴더 크기 탭

  드라이브나 폴더를 스캔해 하위 폴더별 크기를 큰 순서로 보여 줍니다. 파일을 읽기만 하고 아무것도 바꾸지 않습니다.
  스캔은 별도 스레드에서 돌아 화면이 멈추지 않으며 언제든 취소할 수 있습니다.

  - 크기는 파일 크기의 합(탐색기 '크기'와 같은 기준), 디스크 점유는 클러스터 단위로 올림한 추정치입니다.
    압축/스파스 파일은 실제 압축 크기, 클라우드 전용(OneDrive 온라인 전용 등) 파일은 0 으로 셉니다.
  - 심볼릭 링크 / 정션 폴더는 따라가지 않습니다(같은 데이터를 두 번 세지 않도록).
  - 권한이 없어 못 읽은 폴더는 빨간색 '(접근 거부)' 로 표시하고 크기에서 빠집니다.
  - 260자가 넘는 긴 경로도 읽습니다.
#>
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Get-UtilTabInfo { @{ Title = '폴더 크기'; Order = 50; Eager = $false } }

$script:Ctx = $null
$script:Scanner = $null
$script:Timer = $null
$script:CfgPath = $null
$script:Cfg = @{ lastPath = '' }
$script:ScanStart = $null
$script:UsedBytes = 0

# 스캔 엔진 + 트리/목록 그리기. 폴더가 수십만 개라도 빠르도록 C# 으로 처리한다.
if (-not ('UtilMonster.FolderScanner' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace UtilMonster {
    public sealed class FsNode {
        public string Name;          // 루트는 전체 경로(끝에 \ 포함), 나머지는 폴더 이름
        public FsNode Parent;
        public long Bytes, Alloc, Files, Dirs;        // 하위 전체 합계
        public long OwnBytes, OwnAlloc, OwnFiles;     // 이 폴더 바로 아래 파일만
        public bool Denied;
        public List<FsNode> Kids;                     // 크기가 큰 순서
        public int KidCount { get { return Kids == null ? 0 : Kids.Count; } }
        public string FullPath {
            get {
                if (Parent == null) return Name;
                List<string> parts = new List<string>();
                FsNode n = this;
                while (n.Parent != null) { parts.Add(n.Name); n = n.Parent; }
                parts.Reverse();
                return n.Name + string.Join("\\", parts.ToArray());
            }
        }
    }

    public sealed class FolderScanner {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct FD {
            public uint Attr; public uint c1, c2, a1, a2, w1, w2; public uint SizeHigh, SizeLow; public uint Tag, R1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string Alt;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstFileExW(string p, int level, out FD d, int op, IntPtr f, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool FindNextFileW(IntPtr h, out FD d);
        [DllImport("kernel32.dll")]
        static extern bool FindClose(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetCompressedFileSizeW(string p, out uint high);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetVolumePathNameW(string p, StringBuilder buf, int len);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceW(string root, out uint spc, out uint bps, out uint freeC, out uint totalC);
        static readonly IntPtr BAD = new IntPtr(-1);

        public long Files, Dirs, Bytes, Errors, Reparse;
        public long Cluster = 4096;
        public volatile string Current = "";
        public volatile bool Cancel;
        public volatile bool Done;
        public string Error;
        public FsNode Root;
        public double Seconds;
        Thread thread;

        public static string Normalize(string path) {
            string p = Path.GetFullPath(path.Trim());
            if (!p.EndsWith("\\")) p += "\\";
            return p;
        }

        // \\?\ 접두어를 붙여 260자 제한을 피한다
        static string Long(string p) {
            if (p.StartsWith(@"\\?\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }

        public void Start(string path) {
            string root = Normalize(path);
            Root = new FsNode { Name = root };
            StringBuilder vol = new StringBuilder(1024);
            uint spc, bps, fc, tc;
            if (GetVolumePathNameW(root, vol, vol.Capacity) && GetDiskFreeSpaceW(vol.ToString(), out spc, out bps, out fc, out tc) && spc * bps > 0)
                Cluster = (long)spc * bps;
            thread = new Thread(Run, 64 * 1024 * 1024);
            thread.IsBackground = true;
            thread.Start();
        }

        public void Stop(int waitMs) {
            Cancel = true;
            if (thread != null) thread.Join(waitMs);
        }

        void Run() {
            Stopwatch sw = Stopwatch.StartNew();
            try { Walk(Root.Name, Root); }
            catch (Exception ex) { Error = ex.Message; }
            finally { Seconds = sw.Elapsed.TotalSeconds; Done = true; }
        }

        void Walk(string dir, FsNode n) {
            if (Cancel) return;
            Current = dir;
            FD d;
            IntPtr h = FindFirstFileExW(Long(dir) + "*", 1, out d, 0, IntPtr.Zero, 2);
            if (h == BAD) {
                int err = Marshal.GetLastWin32Error();
                if (err != 2 && err != 18) { n.Denied = true; Interlocked.Increment(ref Errors); }
                return;
            }
            try {
                do {
                    if (Cancel) break;
                    string name = d.Name;
                    if (name == "." || name == "..") continue;
                    bool isDir = (d.Attr & 0x10) != 0;
                    // 링크/정션 폴더는 건너뜀 (0xA000000C 심볼릭 링크, 0xA0000003 마운트 지점)
                    if ((d.Attr & 0x400) != 0 && (isDir || d.Tag == 0xA000000C || d.Tag == 0xA0000003)) { Reparse++; continue; }
                    if (isDir) {
                        Dirs++;
                        FsNode k = new FsNode { Name = name, Parent = n };
                        if (n.Kids == null) n.Kids = new List<FsNode>();
                        n.Kids.Add(k);
                        Walk(dir + name + "\\", k);
                        n.Bytes += k.Bytes; n.Alloc += k.Alloc; n.Files += k.Files; n.Dirs += k.Dirs + 1;
                    } else {
                        long size = ((long)d.SizeHigh << 32) | d.SizeLow;
                        long alloc = AllocOf(d.Attr, size, dir, name);
                        Files++; Bytes += size;
                        n.OwnBytes += size; n.OwnAlloc += alloc; n.OwnFiles++;
                        n.Bytes += size; n.Alloc += alloc; n.Files++;
                    }
                } while (FindNextFileW(h, out d));
            } finally { FindClose(h); }
            if (n.Kids != null) n.Kids.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
        }

        long AllocOf(uint attr, long size, string dir, string name) {
            const uint OFFLINE = 0x1000, RECALL_OPEN = 0x40000, RECALL_ACCESS = 0x400000, COMPRESSED = 0x800, SPARSE = 0x200;
            if ((attr & (OFFLINE | RECALL_OPEN | RECALL_ACCESS)) != 0) return 0;
            if ((attr & (COMPRESSED | SPARSE)) != 0) {
                uint hi;
                uint lo = GetCompressedFileSizeW(Long(dir + name), out hi);
                if (lo != 0xFFFFFFFF || Marshal.GetLastWin32Error() == 0) size = ((long)hi << 32) | lo;
            }
            return (size + Cluster - 1) / Cluster * Cluster;
        }

        static string Q(string s) { return "\"" + s.Replace("\"", "\"\"") + "\""; }

        // 모든 폴더를 트리 순서(큰 것 먼저)로 저장. Excel 에서 한글이 깨지지 않게 UTF-8 BOM.
        public int ExportCsv(string path, string header) {
            int rows = 0;
            CultureInfo inv = CultureInfo.InvariantCulture;
            using (StreamWriter w = new StreamWriter(path, false, new UTF8Encoding(true))) {
                w.WriteLine(header);
                Stack<FsNode> stack = new Stack<FsNode>();
                stack.Push(Root);
                while (stack.Count > 0) {
                    FsNode n = stack.Pop();
                    w.WriteLine(string.Join(",", new string[] {
                        Q(n.FullPath), n.Bytes.ToString(inv), (n.Bytes / 1048576.0).ToString("0.0", inv),
                        n.Alloc.ToString(inv), n.Files.ToString(inv), n.Dirs.ToString(inv), n.Denied ? "Y" : "" }));
                    rows++;
                    if (n.Kids != null) for (int i = n.Kids.Count - 1; i >= 0; i--) stack.Push(n.Kids[i]);
                }
            }
            return rows;
        }
    }

    public static class FsView {
        public static int SortCol = 1;
        public static bool SortDesc = true;
        static string[] baseHeaders;
        static readonly Color BarColor = Color.FromArgb(91, 141, 239);

        public static string Size(long b) {
            if (b < 1024) return b.ToString("N0") + " B";
            if (b < 1048576) return (b / 1024.0).ToString("N1") + " KB";
            if (b < 1073741824) return (b / 1048576.0).ToString("N1") + " MB";
            if (b < 1099511627776) return (b / 1073741824.0).ToString("N2") + " GB";
            return (b / 1099511627776.0).ToString("N2") + " TB";
        }

        static string Pct(long part, long whole) { return whole > 0 ? (100.0 * part / whole).ToString("N1") + "%" : ""; }

        static void DoubleBuffer(Control c) {
            PropertyInfo p = typeof(Control).GetProperty("DoubleBuffered", BindingFlags.NonPublic | BindingFlags.Instance);
            p.SetValue(c, true, null);
        }

        // ---- 트리: 펼칠 때 자식 노드를 만든다(처음엔 '…' 자리표시만) ----
        public static TreeNode MakeTreeNode(FsNode n) {
            long whole = n.Parent != null ? n.Parent.Bytes : 0;
            string text = n.Name + "   " + Size(n.Bytes) + (whole > 0 ? "  ·  " + Pct(n.Bytes, whole) : "") + (n.Denied ? "  (접근 거부)" : "");
            TreeNode t = new TreeNode(text);
            t.Tag = n;
            if (n.Denied) t.ForeColor = Color.Firebrick;
            if (n.KidCount > 0) t.Nodes.Add(new TreeNode("…"));
            return t;
        }

        public static void AttachTree(TreeView tv) {
            DoubleBuffer(tv);
            tv.BeforeExpand += (s, e) => Fill(e.Node);
            tv.NodeMouseClick += (s, e) => { if (e.Button == MouseButtons.Right) tv.SelectedNode = e.Node; };
        }

        public static void Fill(TreeNode t) {
            if (t.Nodes.Count != 1 || t.Nodes[0].Tag != null) return;
            FsNode n = (FsNode)t.Tag;
            TreeNode[] arr = new TreeNode[n.KidCount];
            for (int i = 0; i < arr.Length; i++) arr[i] = MakeTreeNode(n.Kids[i]);
            TreeView tv = t.TreeView;
            if (tv != null) tv.BeginUpdate();
            t.Nodes.Clear();
            t.Nodes.AddRange(arr);
            if (tv != null) tv.EndUpdate();
        }

        public static TreeNode SelectChild(TreeNode parent, FsNode target) {
            Fill(parent);
            parent.Expand();
            foreach (TreeNode c in parent.Nodes) {
                if (c.Tag == target) { parent.TreeView.SelectedNode = c; c.EnsureVisible(); return c; }
            }
            return null;
        }

        // ---- 목록: 선택한 폴더의 하위 폴더 + '이 폴더의 파일' 한 줄, 비율 막대 ----
        sealed class Row { public string Name; public FsNode Node; public long Bytes, Alloc, Files, Dirs; public bool IsFiles; }

        public static void AttachList(ListView lv) {
            DoubleBuffer(lv);
            baseHeaders = new string[lv.Columns.Count];
            for (int i = 0; i < baseHeaders.Length; i++) baseHeaders[i] = lv.Columns[i].Text;
            lv.OwnerDraw = true;
            lv.DrawColumnHeader += (s, e) => { e.DrawDefault = true; };
            lv.DrawItem += (s, e) => { };
            lv.DrawSubItem += DrawSub;
            ListViewItem last = null;
            lv.MouseMove += (s, e) => {
                ListViewItem it = lv.GetItemAt(e.X, e.Y);
                if (it != last) { if (last != null && last.ListView == lv) lv.Invalidate(last.Bounds); if (it != null) lv.Invalidate(it.Bounds); last = it; }
            };
            lv.ColumnClick += (s, e) => {
                if (SortCol == e.Column) SortDesc = !SortDesc; else { SortCol = e.Column; SortDesc = e.Column != 0; }
                FillList(lv, lv.Tag as FsNode);
            };
        }

        static void DrawSub(object sender, DrawListViewSubItemEventArgs e) {
            if (e.ColumnIndex != 2) { e.DrawDefault = true; return; }
            Rectangle r = e.Bounds;
            bool sel = e.Item.Selected;
            using (SolidBrush bg = new SolidBrush(sel ? SystemColors.Highlight : e.Item.ListView.BackColor)) e.Graphics.FillRectangle(bg, r);
            double frac = e.SubItem.Tag is double ? (double)e.SubItem.Tag : 0;
            const int textW = 62;
            int barMax = Math.Max(0, r.Width - textW - 12);
            Rectangle bar = new Rectangle(r.X + 4, r.Y + 4, (int)Math.Round(barMax * frac), Math.Max(1, r.Height - 8));
            if (bar.Width > 0) using (SolidBrush b = new SolidBrush(BarColor)) e.Graphics.FillRectangle(b, bar);
            Rectangle tr = new Rectangle(r.Right - textW - 2, r.Y, textW, r.Height);
            TextRenderer.DrawText(e.Graphics, e.SubItem.Text, e.Item.ListView.Font, tr,
                sel ? SystemColors.HighlightText : e.Item.ForeColor, TextFormatFlags.Right | TextFormatFlags.VerticalCenter);
        }

        public static void FillList(ListView lv, FsNode n) {
            lv.Tag = n;
            if (baseHeaders != null) {
                for (int i = 0; i < baseHeaders.Length && i < lv.Columns.Count; i++)
                    lv.Columns[i].Text = baseHeaders[i] + (i == SortCol ? (SortDesc ? " ▼" : " ▲") : "");
            }
            lv.BeginUpdate();
            lv.Items.Clear();
            if (n != null) {
                List<Row> rows = new List<Row>();
                if (n.Kids != null) foreach (FsNode k in n.Kids)
                    rows.Add(new Row { Name = k.Name, Node = k, Bytes = k.Bytes, Alloc = k.Alloc, Files = k.Files, Dirs = k.Dirs });
                if (n.OwnFiles > 0)
                    rows.Add(new Row { Name = "[이 폴더의 파일 " + n.OwnFiles.ToString("N0") + "개]", IsFiles = true, Bytes = n.OwnBytes, Alloc = n.OwnAlloc, Files = n.OwnFiles });
                Comparison<Row> cmp;
                switch (SortCol) {
                    case 0: cmp = (a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase); break;
                    case 3: cmp = (a, b) => a.Alloc.CompareTo(b.Alloc); break;
                    case 4: cmp = (a, b) => a.Files.CompareTo(b.Files); break;
                    case 5: cmp = (a, b) => a.Dirs.CompareTo(b.Dirs); break;
                    default: cmp = (a, b) => a.Bytes.CompareTo(b.Bytes); break;
                }
                rows.Sort(cmp);
                if (SortDesc) rows.Reverse();
                long whole = n.Bytes;
                ListViewItem[] items = new ListViewItem[rows.Count];
                for (int i = 0; i < rows.Count; i++) {
                    Row r = rows[i];
                    ListViewItem it = new ListViewItem(r.Name);
                    it.SubItems.Add(Size(r.Bytes));
                    ListViewItem.ListViewSubItem p = it.SubItems.Add(Pct(r.Bytes, whole));
                    p.Tag = whole > 0 ? (double)r.Bytes / whole : 0.0;
                    it.SubItems.Add(Size(r.Alloc));
                    it.SubItems.Add(r.Files.ToString("N0"));
                    it.SubItems.Add(r.IsFiles ? "" : r.Dirs.ToString("N0"));
                    it.Tag = r.Node;
                    if (r.IsFiles) it.ForeColor = Color.DimGray;
                    else if (r.Node.Denied) { it.ForeColor = Color.Firebrick; it.Text += "  (접근 거부)"; }
                    items[i] = it;
                }
                lv.Items.AddRange(items);
            }
            lv.EndUpdate();
        }
    }
}
'@
}

function Set-Status([string]$text) { $script:lblStatus.Text = $text }

function Save-Config {
    try { $script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $script:CfgPath -Encoding UTF8 } catch { }
}

function Get-DriveRoots {
    @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -in 'Fixed', 'Removable', 'Network' } | ForEach-Object { $_.Name })
}

function Test-Scanning { $script:Scanner -and -not $script:Scanner.Done }

function Start-Scan([string]$path) {
    if (Test-Scanning) { return }
    $path = "$path".Trim().Trim('"')
    if (-not $path) { return }
    if ($path -match '^[A-Za-z]:$') { $path += '\' }
    if (-not [IO.Directory]::Exists($path)) {
        [void][System.Windows.Forms.MessageBox]::Show("폴더를 찾을 수 없습니다.`n`n$path", '폴더 크기', 'OK', 'Warning')
        return
    }
    $script:cmbPath.Text = $path
    $script:Cfg.lastPath = $path
    Save-Config

    # 드라이브 전체를 스캔할 때는 사용 중인 용량 대비로 진행률을 보여 줄 수 있다
    $script:UsedBytes = 0
    try {
        $full = [UtilMonster.FolderScanner]::Normalize($path)
        $di = New-Object System.IO.DriveInfo($full)
        if ($di.RootDirectory.FullName -ieq $full) { $script:UsedBytes = $di.TotalSize - $di.TotalFreeSpace }
    }
    catch { }
    $script:progress.Style = if ($script:UsedBytes -gt 0) { 'Continuous' } else { 'Marquee' }
    $script:progress.Value = 0
    $script:progress.Visible = $true

    $script:tree.Nodes.Clear()
    [UtilMonster.FsView]::FillList($script:list, $null)
    $script:lblHint.Visible = $false
    $script:btnScan.Text = '취소'
    $script:btnCsv.Enabled = $false
    $script:btnUp.Enabled = $false

    $script:Scanner = New-Object UtilMonster.FolderScanner
    $script:ScanStart = Get-Date
    $script:Scanner.Start($path)
    Set-Status '스캔 시작…'
    $script:Timer.Start()
}

function Update-Progress {
    $s = $script:Scanner
    if (-not $s) { $script:Timer.Stop(); return }
    if ($s.Done) { $script:Timer.Stop(); Complete-Scan; return }
    if ($script:UsedBytes -gt 0) { $script:progress.Value = [int][math]::Min(99, 100.0 * $s.Bytes / $script:UsedBytes) }
    $el = (Get-Date) - $script:ScanStart
    $state = if ($s.Cancel) { '취소하는 중…' } else { '스캔 중…' }
    Set-Status ('{0}  파일 {1:N0}개 · {2} · {3:mm\:ss}    {4}' -f $state, $s.Files, [UtilMonster.FsView]::Size($s.Bytes), $el, $s.Current)
}

function Complete-Scan {
    $s = $script:Scanner
    $script:progress.Visible = $false
    $script:btnScan.Text = '스캔'
    $script:tree.BeginUpdate()
    $script:tree.Nodes.Clear()
    $rootTn = [UtilMonster.FsView]::MakeTreeNode($s.Root)
    [void]$script:tree.Nodes.Add($rootTn)
    $rootTn.Expand()
    $script:tree.EndUpdate()
    $script:tree.SelectedNode = $rootTn
    $script:btnCsv.Enabled = $true
    $script:btnUp.Enabled = $true

    $msg = '{0}   {1} (디스크 점유 약 {2}) · 파일 {3:N0}개 · 폴더 {4:N0}개 · {5:N1}초' -f $s.Root.Name,
    [UtilMonster.FsView]::Size($s.Root.Bytes), [UtilMonster.FsView]::Size($s.Root.Alloc), $s.Files, $s.Dirs, $s.Seconds
    if ($s.Cancel) { $msg = '중단됨 - 읽은 곳까지만 표시합니다.   ' + $msg }
    if ($s.Errors -gt 0) { $msg += '   · 접근 거부 {0:N0}개 폴더 제외 (관리자 권한으로 실행하면 줄어듭니다)' -f $s.Errors }
    if ($s.Error) { $msg += "   · 오류: $($s.Error)" }
    Set-Status $msg
}

# 목록에서 고른 폴더로 들어가기 (트리에서 그 폴더를 선택)
function Open-ListItem {
    $it = @($script:list.SelectedItems)[0]
    if (-not $it -or -not $it.Tag) { return }
    $p = $script:tree.SelectedNode
    if ($p) { [void][UtilMonster.FsView]::SelectChild($p, $it.Tag) }
}

# 상위 폴더로 올라가고, 방금 있던 폴더를 목록에서 선택해 둔다
function Move-Up {
    $cur = $script:tree.SelectedNode
    if (-not $cur -or -not $cur.Parent) { return }
    $script:tree.SelectedNode = $cur.Parent
    foreach ($it in $script:list.Items) {
        if ($it.Tag -eq $cur.Tag) { $it.Selected = $true; $it.Focused = $true; $it.EnsureVisible(); break }
    }
    [void]$script:list.Focus()
}

# 이름 열이 남는 폭을 채우게 해서 가로 스크롤이 생기지 않게 한다
function Update-ListColumns {
    $cols = $script:list.Columns
    if ($cols.Count -lt 2) { return }
    $rest = 0
    for ($i = 1; $i -lt $cols.Count; $i++) { $rest += $cols[$i].Width }
    $w = $script:list.ClientSize.Width - $rest - 2
    $cols[0].Width = [math]::Max(160, $w)
}

# 우클릭 메뉴 대상 폴더(FsNode)
function Get-MenuTarget {
    if ($script:menu.SourceControl -eq $script:list) {
        $it = @($script:list.SelectedItems)[0]
        if ($it -and $it.Tag) { return $it.Tag }
        return $script:list.Tag
    }
    if ($script:tree.SelectedNode) { return $script:tree.SelectedNode.Tag }
}

function Enable-Drop($ctl) {
    $ctl.AllowDrop = $true
    $ctl.Add_DragEnter({
            param($s, $e)
            $e.Effect = if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { 'Link' } else { 'None' }
        })
    $ctl.Add_DragDrop({
            param($s, $e)
            $first = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))[0]
            if (-not $first) { return }
            if (-not [IO.Directory]::Exists($first)) { $first = [IO.Path]::GetDirectoryName($first) }
            Start-Scan $first
        })
    foreach ($c in $ctl.Controls) { Enable-Drop $c }
}

function New-Button([string]$text, [int]$w = 90) {
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
    $script:CfgPath = Join-Path $Ctx.ConfigDir 'FolderSize.json'
    if (Test-Path -LiteralPath $script:CfgPath) {
        try {
            $c = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.lastPath) { $script:Cfg.lastPath = [string]$c.lastPath }
        }
        catch { }
    }

    # ---- 위: 대상 + 버튼
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'
    $bar.AutoSize = $true
    $bar.WrapContents = $false
    $bar.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '대상'
    $lbl.AutoSize = $true
    $lbl.Margin = New-Object System.Windows.Forms.Padding(3, 9, 6, 3)
    $script:cmbPath = New-Object System.Windows.Forms.ComboBox
    $script:cmbPath.Width = 420
    $script:cmbPath.Margin = New-Object System.Windows.Forms.Padding(3, 5, 6, 3)
    foreach ($d in Get-DriveRoots) { [void]$script:cmbPath.Items.Add($d) }
    $script:cmbPath.Text = if ($script:Cfg.lastPath) { $script:Cfg.lastPath } elseif ($script:cmbPath.Items.Count) { $script:cmbPath.Items[0] } else { '' }
    $btnBrowse = New-Button '폴더 선택…'
    $script:btnScan = New-Button '스캔' 100
    $script:btnScan.Font = New-Object System.Drawing.Font($Ctx.Font, [System.Drawing.FontStyle]::Bold)
    $script:btnUp = New-Button '▲ 위로'
    $script:btnUp.Margin = New-Object System.Windows.Forms.Padding(18, 3, 3, 3)
    $script:btnUp.Enabled = $false
    $script:btnCsv = New-Button 'CSV 저장'
    $script:btnCsv.Enabled = $false
    $bar.Controls.AddRange(@($lbl, $script:cmbPath, $btnBrowse, $script:btnScan, $script:btnUp, $script:btnCsv))

    # ---- 가운데: 트리 | 목록
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.FixedPanel = 'Panel1'

    $script:tree = New-Object System.Windows.Forms.TreeView
    $script:tree.Dock = 'Fill'
    $script:tree.HideSelection = $false
    $script:tree.ShowLines = $true
    [UtilMonster.FsView]::AttachTree($script:tree)
    $split.Panel1.Controls.Add($script:tree)

    $script:list = New-Object System.Windows.Forms.ListView
    $script:list.Dock = 'Fill'
    $script:list.View = 'Details'
    $script:list.FullRowSelect = $true
    $script:list.MultiSelect = $false
    $script:list.HideSelection = $false
    [void]$script:list.Columns.Add('이름', 220)
    [void]$script:list.Columns.Add('크기', 95, 'Right')
    [void]$script:list.Columns.Add('비율', 130)
    [void]$script:list.Columns.Add('디스크 점유', 125, 'Right')
    [void]$script:list.Columns.Add('파일 수', 80, 'Right')
    [void]$script:list.Columns.Add('폴더 수', 70, 'Right')
    [UtilMonster.FsView]::AttachList($script:list)

    $script:lblHint = New-Object System.Windows.Forms.Label
    $script:lblHint.Dock = 'Fill'
    $script:lblHint.TextAlign = 'MiddleCenter'
    $script:lblHint.ForeColor = [System.Drawing.Color]::FromArgb(26, 79, 160)
    $script:lblHint.BackColor = [System.Drawing.Color]::FromArgb(232, 240, 254)
    $script:lblHint.Text = "드라이브나 폴더를 고르고 [스캔]을 누르세요.`r`n폴더를 이 창으로 끌어다 놓아도 됩니다.`r`n`r`n파일을 읽기만 하고, 아무것도 바꾸거나 지우지 않습니다."
    $split.Panel2.Controls.Add($script:list)
    $split.Panel2.Controls.Add($script:lblHint)
    $script:lblHint.BringToFront()

    # ---- 아래: 상태 + 진행 막대
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 34
    $bottom.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 4)
    $script:progress = New-Object System.Windows.Forms.ProgressBar
    $script:progress.Dock = 'Right'
    $script:progress.Width = 220
    $script:progress.Visible = $false
    $script:lblStatus = New-Object System.Windows.Forms.Label
    $script:lblStatus.Dock = 'Fill'
    $script:lblStatus.TextAlign = 'MiddleLeft'
    $script:lblStatus.AutoEllipsis = $true
    $script:lblStatus.Text = '대상을 고르고 [스캔]을 누르세요.'
    $bottom.Controls.Add($script:lblStatus)
    $bottom.Controls.Add($script:progress)

    # Fill 먼저, 그다음 위/아래
    $Page.Controls.Add($split)
    $Page.Controls.Add($bar)
    $Page.Controls.Add($bottom)
    $Page.Padding = New-Object System.Windows.Forms.Padding(8)
    try { $split.SplitterDistance = 340 } catch { }

    # ---- 우클릭 메뉴
    $script:menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $script:menu.Items.Add('탐색기에서 열기')
    $miCopy = $script:menu.Items.Add('경로 복사')
    $miRescan = $script:menu.Items.Add('이 폴더만 다시 스캔')
    $script:tree.ContextMenuStrip = $script:menu
    $script:list.ContextMenuStrip = $script:menu

    $miOpen.Add_Click({
            $n = Get-MenuTarget
            if ($n) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $n.FullPath) }
        })
    $miCopy.Add_Click({
            $n = Get-MenuTarget
            if ($n) { [System.Windows.Forms.Clipboard]::SetText($n.FullPath) }
        })
    $miRescan.Add_Click({
            $n = Get-MenuTarget
            if ($n) { Start-Scan $n.FullPath }
        })

    # ---- 이벤트
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 250
    $script:Timer.Add_Tick({ Update-Progress })

    $script:btnScan.Add_Click({
            if (Test-Scanning) { $script:Scanner.Cancel = $true; Set-Status '취소하는 중…'; return }
            Start-Scan $script:cmbPath.Text
        })
    $script:cmbPath.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $script:btnScan.PerformClick() }
        })
    $btnBrowse.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = '크기를 볼 폴더 선택'
            if ([IO.Directory]::Exists($script:cmbPath.Text)) { $d.SelectedPath = $script:cmbPath.Text }
            if ($d.ShowDialog() -eq 'OK') { Start-Scan $d.SelectedPath }
            $d.Dispose()
        })
    $script:btnUp.Add_Click({ Move-Up })
    $script:btnCsv.Add_Click({
            if (-not $script:Scanner -or -not $script:Scanner.Done) { return }
            $d = New-Object System.Windows.Forms.SaveFileDialog
            $d.Filter = 'CSV 파일 (*.csv)|*.csv'
            $name = ($script:Scanner.Root.Name -replace '[\\/:*?"<>|]+', '_').Trim('_')
            $d.FileName = 'FolderSize_{0}_{1:yyyyMMdd_HHmm}.csv' -f $name, (Get-Date)
            if ($d.ShowDialog() -eq 'OK') {
                try {
                    $n = $script:Scanner.ExportCsv($d.FileName, '경로,크기(바이트),크기(MB),디스크 점유 추정(바이트),파일 수,폴더 수,접근 거부')
                    Set-Status ('CSV 저장 완료: 폴더 {0:N0}개 → {1}' -f $n, $d.FileName)
                }
                catch {
                    [void][System.Windows.Forms.MessageBox]::Show("저장하지 못했습니다.`n`n$($_.Exception.Message)", '폴더 크기', 'OK', 'Error')
                }
            }
            $d.Dispose()
        })

    $script:tree.Add_AfterSelect({
            param($s, $e)
            [UtilMonster.FsView]::FillList($script:list, $e.Node.Tag)
        })
    $script:list.Add_ClientSizeChanged({ Update-ListColumns })
    Update-ListColumns
    $script:list.Add_DoubleClick({ Open-ListItem })
    $script:list.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Open-ListItem }
            elseif ($e.KeyCode -eq 'Back') { $e.SuppressKeyPress = $true; Move-Up }
        })

    Enable-Drop $Page
}

function Stop-UtilTab {
    if ($script:Timer) { $script:Timer.Stop() }
    if ($script:Scanner) { $script:Scanner.Stop(2000) }
}

Export-ModuleMember -Function Get-UtilTabInfo, New-UtilTab, Stop-UtilTab
