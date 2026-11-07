// UtilMonster.exe - 같은 폴더의 UtilMonster.ps1 을 콘솔 창 없이 실행하는 작은 런처.
// 받은 명령줄 인자(-Tab 충전기, -Minimized 등)는 그대로 넘긴다.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "UtilMonster.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("UtilMonster.ps1 을 찾을 수 없습니다.\n\nUtilMonster.exe 와 같은 폴더에 있어야 합니다.\n" + dir,
                "UtilMonster", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        StringBuilder a = new StringBuilder("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ");
        a.Append(Quote(ps1));
        foreach (string arg in args) a.Append(' ').Append(Quote(arg));

        ProcessStartInfo psi = new ProcessStartInfo(powershell, a.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        // PowerShell 7 터미널에서 실행하면 PSModulePath 에 7 전용 경로가 섞여 Windows PowerShell 5.1 의
        // 기본 명령(Get-FileHash 등)을 못 찾는 경우가 있다. 비워 두면 5.1 이 기본값으로 다시 계산한다.
        psi.EnvironmentVariables.Remove("PSModulePath");
        try { Process.Start(psi); }
        catch (Exception e)
        {
            MessageBox.Show("실행하지 못했습니다.\n\n" + e.Message, "UtilMonster", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
}
