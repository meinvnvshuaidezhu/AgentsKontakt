// AgentsKontakt launcher (v2.2.4): thin entry exes at the package/program
// root. Compiled twice by ops\build-package.ps1:
//   default           -> 运行邮差.exe  (start the postman minimized to tray)
//   /define:UNINSTALL -> 卸载.exe     (confirm, run --uninstall, report)
// The postman exe is resolved relative to this file: <here>\app\AgentsKontaktPost.exe
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main()
    {
        Application.EnableVisualStyles();
        string here = AppDomain.CurrentDomain.BaseDirectory;
        string exe = Path.Combine(here, "app", "AgentsKontaktPost.exe");
        if (!File.Exists(exe)) exe = Path.Combine(here, "AgentsKontaktPost.exe");
        if (!File.Exists(exe))
        {
            MessageBox.Show("未找到邮差程序 app\\AgentsKontaktPost.exe。\r\n请将本文件保持在安装目录中使用。",
                "AgentsKontakt", MessageBoxButtons.OK, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
            return 1;
        }
#if UNINSTALL
        // the postman's uninstall flow removes the program together with all
        // user data and reports the outcome itself - the launcher adds nothing
        // but the call
        using (var p = Process.Start(new ProcessStartInfo { FileName = exe, Arguments = "--uninstall", UseShellExecute = false, CreateNoWindow = true }))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
#else
        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            Arguments = "--minimized",
            WorkingDirectory = Path.GetDirectoryName(exe),
            UseShellExecute = true
        });
        return 0;
#endif
    }
}
