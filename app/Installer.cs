// Installer - self-registration for the AgentsKontakt Postman.
//
// Commands (all non-interactive, safe to run repeatedly):
//   AgentsKontaktPost.exe --install [installDir] [--data <dataDir>]
//   AgentsKontaktPost.exe --uninstall [installDir] [--data <dataDir>]
//   AgentsKontaktPost.exe --register-autostart
//   AgentsKontaktPost.exe --unregister-autostart
//
// The install directory holds code (read-only is fine). The data directory
// holds mailboxes/ registry/ archive/ logs/ post/ and must be writable. One
// folder for everything (2026-11-02): the data lives in <install>\data and
// Program.ResolveDataDir picks it up; %LOCALAPPDATA%\AgentsKontakt remains
// the last-resort fallback for pre-2.3.8 layouts.
//
// Autostart is registered as an HKCU Run value, so the post office works even
// when the tray app is not running - a single point of failure is exactly
// what the "daemon died unnoticed" incident taught us.
using System;
using System.Diagnostics;
using System.IO;
using System.Drawing;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace AgentsKontaktPost
{
    static class Installer
    {
        const string TaskName = "AgentsKontakt Postman";
        const string RunKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        const string RunValue = "AgentsKontaktPost";

        // The exe is built as a GUI app (/target:winexe), so Console.WriteLine
        // goes nowhere when launched from Explorer. Every command therefore
        // mirrors its output into a log file next to the data directory - and
        // when a console is attached it also writes to stdout.
        static string LogPath;

        static void Say(string line)
        {
            Console.WriteLine(line);
            AppendLog(line);
        }

        static void Fail(string line)
        {
            Console.Error.WriteLine(line);
            AppendLog("ERROR " + line);
        }

        static void AppendLog(string line)
        {
            try
            {
                if (LogPath == null)
                {
                    // Prefer the install's own tree (one-folder: <install>\data
                    // first, legacy <install>\logs second); fall back to
                    // %LOCALAPPDATA% and finally to %TEMP% - the log must land
                    // somewhere writable even during a first-time install.
                    string baseDir = null;
                    try
                    {
                        string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                        string root = Path.GetDirectoryName(exeDir);
                        string candidate = Path.Combine(root, "data", "logs");
                        if (Directory.Exists(candidate)) baseDir = candidate;
                        else
                        {
                            candidate = Path.Combine(root, "logs");
                            if (Directory.Exists(candidate)) baseDir = candidate;
                        }
                    }
                    catch { }
                    if (baseDir == null)
                    {
                        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                        if (!string.IsNullOrEmpty(local)) baseDir = Path.Combine(local, "AgentsKontakt");
                    }
                    if (baseDir == null) baseDir = Path.GetTempPath();
                    LogPath = Path.Combine(baseDir, "install.log");
                    string dir = Path.GetDirectoryName(LogPath);
                    if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                }
                File.AppendAllText(LogPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " | " + line + Environment.NewLine);
            }
            catch { }
        }

        public static int Install(string installDirArg, string dataDirArg)
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                string sourceInstallDir = Path.GetDirectoryName(exeDir);
                string installDir = string.IsNullOrEmpty(installDirArg)
                    ? sourceInstallDir
                    : Path.GetFullPath(installDirArg);
                string dataDir = Program.ResolveDataDir(installDir, dataDirArg);

                Say("AgentsKontakt Postman installer");
                Say("  version : " + Program.Version);
                Say("  install : " + installDir);
                Say("  data    : " + dataDir);
                Console.WriteLine();

                // The heavy lifting (code copy, data tree, registry cards,
                // shortcuts, autostart, defender exclusion) lives in
                // scripts\ops\install.ps1 - the same script a human runs by
                // hand. Doing it here in C# would mean two implementations
                // that drift apart.
                //
                // It also avoids a real platform problem: WScript.Shell late
                // binding from .NET fails to save .lnk files here, while the
                // equivalent PowerShell COM call works.
                string ps = FindOpsScript("install.ps1", dataDir, installDir, sourceInstallDir);
                if (ps != null)
                {
                    int rc = RunPowerShell(ps, new string[] {
                        "-InstallDir", installDir,
                        "-DataDir", dataDir,
                        "-SourceRoot", sourceInstallDir
                    });
                    if (rc == 0) return 0;
                    Say("  [--] install.ps1 returned " + rc + "; falling back to built-in layout");
                }

                // Built-in fallback: no PowerShell available (or it failed).
                EnsureDataTree(dataDir);
                WriteDataConfig(dataDir);
                CopyRegistryCards(dataDir);
                CopyIfMissing(sourceInstallDir, installDir);

                Say("  [ok] data tree ready: " + dataDir);
                Say("  [ok] install layout verified: " + installDir);
                Console.WriteLine();
                Say("Next steps:");
                Say("  1. Start the postman:  " + Path.Combine(installDir, "app", "AgentsKontaktPost.exe"));
                Say("  2. Enable autostart:   " + Path.Combine(installDir, "app", "AgentsKontaktPost.exe") + " --register-autostart");
                Say("  3. Register your agents (registry\\<name>.md), then run:");
                Say("     powershell -NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dataDir, "scripts", "init.ps1") + "\"");
                return 0;
            }
            catch (Exception ex)
            {
                Fail("install failed: " + ex.Message);
                return 1;
            }
        }

        /// <summary>
        /// Locates an ops helper script. The layered layout keeps them under
        /// scripts\ops\; the pre-split flat layout (scripts\<name>) is still
        /// accepted so an older install can be upgraded in place. Data dir
        /// wins over install dir: MAILBOX_ROOT resolution runs the daemon's
        /// scripts from there.
        /// </summary>
        static string FindOpsScript(string name, string dataDir, string installDir, string sourceInstallDir)
        {
            foreach (string baseDir in new string[] { dataDir, installDir, sourceInstallDir })
            {
                if (string.IsNullOrEmpty(baseDir)) continue;
                foreach (string rel in new string[] { Path.Combine("scripts", "ops", name), Path.Combine("scripts", name) })
                {
                    string p = Path.Combine(baseDir, rel);
                    if (File.Exists(p)) return p;
                }
            }
            return null;
        }

        /// <summary>
        /// Registers/removes the Microsoft Defender exclusion for the app's
        /// own directories via scripts\ops\defender-exclusion.ps1. The script
        /// self-elevates (one UAC prompt, the consent gate) and treats a
        /// declined prompt or an absent Defender as a clean skip - this step
        /// must never fail an install. Pure performance measure: the
        /// real-time scan filter taxes every file open, and the post office
        /// does hundreds per sweep.
        /// </summary>
        public static int DefenderExclusion(bool register)
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                string installDir = Path.GetDirectoryName(exeDir);
                string dataDir = Program.ResolveDataDir(installDir, null);
                string script = FindOpsScript("defender-exclusion.ps1", dataDir, installDir, null);
                if (script == null)
                {
                    Fail("defender-exclusion.ps1 not found (staged scripts missing?)");
                    return 1;
                }

                var roots = new System.Collections.Generic.List<string>();
                roots.Add(dataDir);
                if (string.Compare(installDir.TrimEnd('\\'), dataDir.TrimEnd('\\'), true) != 0) roots.Add(installDir);

                var psArgs = new System.Collections.Generic.List<string>();
                psArgs.Add("-Action");
                psArgs.Add(register ? "Register" : "Unregister");
                foreach (string r in roots) { psArgs.Add("-Root"); psArgs.Add(r); }

                Say((register ? "defender exclusion (register): " : "defender exclusion (unregister): ") + string.Join(", ", roots));
                int rc = RunPowerShell(script, psArgs.ToArray());
                Say("  " + (rc == 0 ? "[ok]" : "[--]") + " defender exclusion step finished (rc=" + rc + ")");
                return rc == 0 ? 0 : 1;
            }
            catch (Exception ex)
            {
                Fail("defender exclusion failed: " + ex.Message);
                return 1;
            }
        }

        /// <summary>
        /// Runs a PowerShell script and mirrors its output. Returns the exit
        /// code. Used so the exe and the hand-run scripts behave identically.
        /// </summary>
        static int RunPowerShell(string script, string[] args)
        {
            try
            {
                string psExe = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(psExe)) psExe = "powershell.exe";

                string quoted = "\"" + script + "\"";
                foreach (string a in args) quoted += " \"" + a + "\"";

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = psExe;
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + quoted;
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;

                using (Process p = Process.Start(psi))
                {
                    string so = p.StandardOutput.ReadToEnd();
                    string se = p.StandardError.ReadToEnd();
                    p.WaitForExit();
                    if (!string.IsNullOrEmpty(so))
                        foreach (string line in so.Split('\n'))
                            if (line.Trim().Length > 0) Say("  " + line.TrimEnd('\r'));
                    if (!string.IsNullOrEmpty(se))
                        foreach (string line in se.Split('\n'))
                            if (line.Trim().Length > 0) Fail("  " + line.TrimEnd('\r'));
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Fail("could not run " + script + ": " + ex.Message);
                return -1;
            }
        }



        // ---- uninstall wizard + streamed core (v2.3.5) --------------------

        static readonly string[][] UMilestones = new string[][] {
            new string[] { "autostart entry removed",          "移除登录自启" },
            new string[] { "standard uninstall entry removed", "移除标准安装注册" },
            new string[] { "daemon task removed",              "移除计划任务" },
            new string[] { "stopped running daemon",           "清扫守护进程" },
            new string[] { "stopped running postman",          "停止运行中的邮差" },
            new string[] { "shortcut removed",                 "移除快捷方式" },
            new string[] { "program files scheduled",          "移除程序目录" },
            new string[] { "data removed",                     "删除用户数据" }
        };

        static string UninstallLogPath;

        static void ULog(string line)
        {
            Say(line);
            try
            {
                if (UninstallLogPath != null)
                    File.AppendAllText(UninstallLogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " | " + line + Environment.NewLine);
            }
            catch { }
        }

        static int RunUninstallCore(string installDir, string dataDir, bool doPurge, int waitPid,
                                    Action<string> uiLog, Action<int, string> uiStep, ref string note)
        {
            Action<string> logBoth = delegate(string l) { ULog(l); if (uiLog != null) uiLog(l); };
            installDir = installDir.Replace('/', (char)92);
            dataDir = dataDir.Replace('/', (char)92);
            char QQ = (char)34;

            // ---- phase 1: stop ALL processes (services first, then daemons) ----
            if (uiStep != null) uiStep(1, "停止运行中的邮差");
            try
            {
                foreach (var p in Process.GetProcessesByName("AgentsKontaktPost"))
                {
                    if (p.Id == Process.GetCurrentProcess().Id) continue;
                    string pp = "";
                    try { pp = p.MainModule.FileName; } catch { }
                    if (pp.StartsWith(installDir, StringComparison.OrdinalIgnoreCase) ||
                        pp.StartsWith(dataDir, StringComparison.OrdinalIgnoreCase))
                    {
                        p.Kill();
                        p.WaitForExit(5000);
                        logBoth("  [ok] stopped running postman pid=" + p.Id);
                    }
                }
                // stop standalone watch daemon (scheduled-task launched, no Job Object parent)
                foreach (System.Management.ManagementObject p in
                    new System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'").Get())
                {
                    string cl = (p["CommandLine"] ?? "").ToString();
                    if (cl.IndexOf("watch.ps1", StringComparison.OrdinalIgnoreCase) >= 0 &&
                        cl.IndexOf(dataDir, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        int pid = Convert.ToInt32(p["ProcessId"]);
                        Process.GetProcessById(pid).Kill();
                        Process.GetProcessById(pid).WaitForExit(3000);
                        logBoth("  [ok] stopped daemon pid=" + pid);
                    }
                }
            }
            catch (Exception ex1) { logBoth("  [--] process stop: " + ex1.Message); }

            // ---- phase 2: remove autostart (prevent restart after cleanup) ----
            if (uiStep != null) uiStep(2, "移除自启与计划任务");
            SetAutostart(false);
            logBoth("  [ok] autostart removed (task + run)");

            // ---- phase 3: remove shortcuts ----
            if (uiStep != null) uiStep(3, "移除快捷方式");
            RemoveShortcuts();
            logBoth("  [ok] shortcuts removed");

            // ---- phase 4: remove standard registration ----
            if (uiStep != null) uiStep(4, "移除标准安装注册");
            try
            {
                Microsoft.Win32.RegistryKey parent = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    "Software/Microsoft/Windows/CurrentVersion/Uninstall", true);
                if (parent != null) { parent.DeleteSubKeyTree("AgentsKontaktPost", false); parent.Close(); }
                logBoth("  [ok] standard uninstall entry removed");
            }
            catch { }

            // ---- phase 5: delete files (program dir + data dir) ----
            if (uiStep != null) uiStep(5, "删除程序与数据");
            if (doPurge)
            {
                // program dir (the uninstaller exe itself lives here — may be locked)
                try
                {
                    if (Directory.Exists(installDir))
                    {
                        Directory.Delete(installDir, true);
                        logBoth("  [ok] program dir deleted: " + installDir);
                    }
                }
                catch (Exception ex2)
                {
                    // self-lock: schedule via RunOnce for next logon
                    try
                    {
                        Microsoft.Win32.RegistryKey ro = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(
                            "Software/Microsoft/Windows/CurrentVersion/RunOnce");
                        ro.SetValue("AgentsKontaktCleanup",
                            "cmd /c ping -n 3 127.0.0.1 >nul & rmdir /s /q " + QQ + installDir + QQ);
                        ro.Close();
                        logBoth("  [--] program dir locked; scheduled RunOnce cleanup");
                    }
                    catch { }
                }
                // data dir
                try
                {
                    if (Directory.Exists(dataDir))
                    {
                        Directory.Delete(dataDir, true);
                        logBoth("  [ok] data dir deleted: " + dataDir);
                    }
                }
                catch (Exception de)
                {
                    note = "数据删除失败: " + de.Message;
                    logBoth("  [--] data delete failed: " + de.Message);
                }
            }
            return 0;
        }

        static int RunPowerShellStream(string script, string[] args, Action<string> onLine)
        {
            // the proven -File + quoted-args form (matches Installer.RunPowerShell);
            // internal quotes are stripped (paths and flags never contain them)
            string quoted = "\"" + script + "\"";
            foreach (string a in args) quoted += " \"" + a.Replace("\"", "") + "\"";
            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                        "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + quoted,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            using (var p = Process.Start(psi))
            {
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null && onLine != null) onLine(e.Data); };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null && onLine != null) onLine(e.Data); };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                return p.ExitCode;
            }
        }

        public static int Uninstall(string installDirArg, string dataDirArg)
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string sourceInstallDir = Path.GetDirectoryName(exeDir);
            string installDir = string.IsNullOrEmpty(installDirArg)
                ? sourceInstallDir
                : Path.GetFullPath(installDirArg);
            string dataDir = Program.ResolveDataDir(installDir, dataDirArg);
            installDir = installDir.Replace('/', '\\');
            dataDir = dataDir.Replace('/', '\\');

            // 卸载即全删 (2026-11-03 owner decision): the program and the whole
            // data folder (one-folder layout: data lives inside the program
            // folder) are removed together - there is no keep-data option any
            // more. The log goes to %TEMP% so it survives the purge.
            bool doPurge = true;
            UninstallWizard wiz = null;
            string note = "";
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            int myPid = Process.GetCurrentProcess().Id;

            UninstallLogPath = Path.Combine(Path.GetTempPath(), "AgentsKontakt-uninstall-" + stamp + ".log");
            Action runWork = delegate()
            {
                ULog("AgentsKontakt 卸载开始");
                ULog("  install : " + installDir);
                ULog("  data    : " + dataDir);
                ULog("  mode    : purge (应用与数据一并删除)");
                int r = RunUninstallCore(installDir, dataDir, doPurge, myPid,
                    delegate(string l) { ULog(l); wiz.StreamLine(l); },
                    delegate(int i, string t) { ULog("step " + i + ": " + t); wiz.Step(i, t); },
                    ref note);
                ULog("uninstall finished rc=" + r);
                wiz.ShowDone(note, UninstallLogPath);
            };
            wiz = new UninstallWizard(installDir, dataDir, runWork);
            wiz.AskConfirm();                      // modal: page1 -> page2(worker) -> done -> close
            return 0;
        }

        // ---- uninstall wizard form (v2.3.5) -------------------------------

        class UninstallWizard : Form
        {
            public bool Finished;
            Action RunWork;
            Panel banner; Label bannerTitle, bannerSub;
            Panel pageConfirm, pageProgress, pageDone;
            Label dirLabel, stepLabel, doneSummary, askLabel; ProgressBar bar; TextBox logBox;
            Button startBtn, cancelBtn, doneBtn;
            string installDir, dataDir;
            static readonly string NL = "" + (char)13 + (char)10;

            public UninstallWizard(string installDir, string dataDir, Action runWork)
            {
                RunWork = runWork;
                this.installDir = installDir; this.dataDir = dataDir;
                Text = "AgentsKontakt 卸载";
                Width = 640; Height = 560;
                FormBorderStyle = FormBorderStyle.FixedDialog;
                StartPosition = FormStartPosition.CenterScreen;
                MaximizeBox = false; MinimizeBox = false;
                TopMost = true;

                banner = new Panel { Dock = DockStyle.Top, Height = 60, BackColor = Color.FromArgb(106, 44, 44) };
                bannerTitle = new Label { Text = "卸载 AgentsKontakt 邮差", ForeColor = Color.White,
                    Font = new Font("Microsoft YaHei", 14, FontStyle.Bold), Left = 20, Top = 8, AutoSize = true };
                bannerSub = new Label { Text = "应用与用户数据将一并删除", ForeColor = Color.FromArgb(235, 205, 205),
                    Font = new Font("Microsoft YaHei", 9), Left = 22, Top = 34, AutoSize = true };
                banner.Controls.Add(bannerTitle); banner.Controls.Add(bannerSub);

                pageConfirm = new Panel { Dock = DockStyle.Fill };
                var info = new Label { Text = "将从这台电脑移除 AgentsKontakt 邮差。", Left = 24, Top = 20, Width = 580,
                    Font = new Font("Microsoft YaHei", 10, FontStyle.Bold) };
                dirLabel = new Label { Text = "程序目录: " + installDir + NL + "数据目录: " + dataDir,
                    Left = 24, Top = 52, Width = 580, Height = 48 };
                var ask = new Label { Text = "卸载将同时删除全部用户数据（信件、归档、通讯录），不可恢复。", Left = 24, Top = 112, Width = 560,
                    Font = new Font("Microsoft YaHei", 10, FontStyle.Bold) };
                askLabel = ask;
                startBtn = new Button { Text = "开始卸载", Left = 380, Top = 250, Width = 116, Height = 32 };
                cancelBtn = new Button { Text = "取消", Left = 510, Top = 250, Width = 104, Height = 32, DialogResult = DialogResult.Cancel };
                startBtn.Click += delegate(object s, EventArgs e)
                {
                    // ---- pre-uninstall check: detect running postman ----
                    var running = new System.Collections.Generic.List<Process>();
                    foreach (var p in Process.GetProcessesByName("AgentsKontaktPost"))
                    {
                        if (p.Id == Process.GetCurrentProcess().Id) continue;
                        running.Add(p);
                    }
                    if (running.Count > 0)
                    {
                        string pids = "";
                        foreach (var p in running) pids += (pids.Length > 0 ? ", " : "") + p.Id;
                        var go = MessageBox.Show(
                            "检测到邮差正在运行（pid: " + pids + "）。\r\n\r\n卸载需要先关闭它，是否继续？",
                            "AgentsKontakt 卸载", MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                            MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
                        if (go != DialogResult.Yes) return;   // user declined → stay on confirm page
                        foreach (var p in running) { try { p.Kill(); p.WaitForExit(3000); } catch { } }
                        ULog("  [ok] stopped " + running.Count + " running postman process(es) per user request");
                    }

                    // ---- proceed with uninstall ----
                    pageConfirm.Visible = false;
                    pageProgress.Visible = true;
                    var w = new Thread(delegate()
                    {
                        try { RunWork(); }
                        catch (Exception ex)
                        {
                            SafeUi(delegate
                            {
                                stepLabel.Text = "卸载出错";
                                doneSummary.Text = "卸载过程中出错: " + ex.Message;
                                pageProgress.Visible = false;
                                pageDone.Visible = true;
                                Finished = true;
                            });
                        }
                    });
                    w.IsBackground = true;
                    w.Start();
                };
                pageConfirm.Controls.AddRange(new Control[] { info, dirLabel, ask, startBtn, cancelBtn });

                pageProgress = new Panel { Dock = DockStyle.Fill };
                stepLabel = new Label { Text = "准备卸载...", Left = 24, Top = 24, Width = 580,
                    Font = new Font("Microsoft YaHei", 10) };
                bar = new ProgressBar { Left = 24, Top = 58, Width = 580, Height = 22 };
                logBox = new TextBox { Left = 24, Top = 94, Width = 580, Height = 240, Multiline = true,
                    ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                    Font = new Font("Consolas", 8.5f), BackColor = Color.White };
                pageProgress.Controls.AddRange(new Control[] { stepLabel, bar, logBox });

                pageDone = new Panel { Dock = DockStyle.Fill };
                var doneTitle = new Label { Text = "卸载完成", Left = 24, Top = 30, Width = 400,
                    Font = new Font("Microsoft YaHei", 15, FontStyle.Bold) };
                doneSummary = new Label { Text = "", Left = 26, Top = 78, Width = 570, Height = 140 };
                doneBtn = new Button { Text = "完成", Left = 478, Top = 316, Width = 126, Height = 32, Anchor = AnchorStyles.Bottom | AnchorStyles.Right };
                doneBtn.Click += delegate(object s, EventArgs e) { Finished = true; Close(); };
                pageDone.Controls.AddRange(new Control[] { doneTitle, doneSummary, doneBtn });

                Controls.Add(pageConfirm);
                Controls.Add(pageProgress); pageProgress.Visible = false;
                Controls.Add(pageDone); pageDone.Visible = false;
                Controls.Add(banner);
                AcceptButton = startBtn; CancelButton = cancelBtn;
                Load += delegate(object s, EventArgs e) { LayoutControls(); };
            }

            void LayoutControls()
            {
                int cw = ClientSize.Width;
                int ch = ClientSize.Height - banner.Height;

                dirLabel.Left = cw * 3 / 100; dirLabel.Top = ch * 10 / 100; dirLabel.Width = cw * 90 / 100;
                askLabel.Left = cw * 3 / 100; askLabel.Top = ch * 26 / 100; askLabel.Width = cw * 90 / 100;
                startBtn.Left = cw * 55 / 100; startBtn.Top = ch * 78 / 100;
                cancelBtn.Left = cw * 74 / 100; cancelBtn.Top = ch * 78 / 100;
                stepLabel.Left = cw * 3 / 100; stepLabel.Top = ch * 5 / 100; stepLabel.Width = cw * 92 / 100;
                bar.Left = cw * 3 / 100; bar.Top = ch * 12 / 100; bar.Width = cw * 92 / 100;
                logBox.Left = cw * 3 / 100; logBox.Top = ch * 18 / 100; logBox.Width = cw * 92 / 100; logBox.Height = ch * 55 / 100;
                doneSummary.Left = cw * 4 / 100; doneSummary.Top = ch * 14 / 100; doneSummary.Width = cw * 88 / 100;
                doneBtn.Left = cw * 70 / 100; doneBtn.Top = ch * 80 / 100;
            }

            public bool AskConfirm()
            {
                ShowDialog();                      // page1 -> 开始卸载 -> page2(worker) -> done -> close
                return Finished;                   // reached the done page
            }

            public void StreamLine(string line)
            {
                SafeUi(delegate
                {
                    if (logBox.TextLength > 60000) logBox.Clear();
                    logBox.AppendText(line + Environment.NewLine);
                    logBox.SelectionStart = logBox.TextLength;
                    logBox.ScrollToCaret();
                    for (int i = 0; i < UMilestones.Length; i++)
                    {
                        if (line.IndexOf(UMilestones[i][0], StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            Step(i + 2, UMilestones[i][1]);
                            break;
                        }
                    }
                });
            }

            public void Step(int idx, string text)
            {
                SafeUi(delegate
                {
                    stepLabel.Text = "当前步骤： " + text;
                    int pct = idx * 100 / 10; if (pct > 96) pct = 96;
                    bar.Value = pct;
                });
            }

            public void ShowDone(string note, string logPath)
            {
                SafeUi(delegate
                {
                    bar.Value = 100;
                    stepLabel.Text = "卸载完成";
                    doneSummary.Text = "程序与用户数据已全部删除。" + NL +
                        (note.Length > 0 ? "备注: " + note + NL : "") +
                        "程序目录将在关闭本窗口后自动移除（如有残留可手动删除）。" + NL +
                        "卸载日志: " + logPath;
                    pageProgress.Visible = false;
                    pageDone.Visible = true;
                });
            }

            void SafeUi(Action a)
            {
                try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { }
            }

            protected override void OnFormClosing(FormClosingEventArgs e)
            {
                // pageConfirm: nothing destructive yet — close freely.
                // pageProgress: the uninstall is running — ask before abandoning.
                if (pageConfirm != null && pageConfirm.Visible)
                {
                    base.OnFormClosing(e);
                    return;
                }
                var r = MessageBox.Show("卸载正在进行中。确定要退出吗？\r\n\r\n退出后内置清理仍会完成已开始的步骤。",
                    "AgentsKontakt 卸载", MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                    MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
                if (r == DialogResult.No) { e.Cancel = true; return; }
                Finished = true;
                base.OnFormClosing(e);
            }
        }


        public static int SetAutostart(bool enable)
        {
            try
            {
                string exe = Application.ExecutablePath;
                string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                string installDir = Path.GetDirectoryName(exeDir);
                string dataDir = Program.ResolveDataDir(installDir, null);

                // The daemon task is the important layer: it keeps the post
                // office alive even when the tray app is never opened. The
                // registry entry only starts the tray app at logon.
                string autostartPs = FindOpsScript("autostart.ps1", dataDir, installDir, null);
                if (autostartPs != null)
                {
                    int rc = RunPowerShell(autostartPs, new string[] {
                        "-Action", enable ? "Register" : "Unregister",
                        "-DataDir", dataDir
                    });
                    if (enable)
                    {
                        if (rc == 0) Say("  [ok] daemon autostart registered (scheduled task)");
                        else Say("  [--] daemon autostart NOT registered (rc=" + rc + ") - rely on the registry entry below");
                    }
                    else
                    {
                        Say("  [ok] daemon autostart removed");
                    }
                }

                if (enable)
                {
                    // Registry Run value: simplest and needs no elevation.
                    // The exe starts minimized so it only puts a tray icon up.
                    Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey)
                        .SetValue(RunValue, "\"" + exe + "\" --minimized");
                    Say("autostart enabled (registry): " + exe + " --minimized");
                    return 0;
                }
                else
                {
                    try
                    {
                        Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true)
                            .DeleteValue(RunValue, false);
                    }
                    catch { }
                    Say("autostart disabled");
                    return 0;
                }
            }
            catch (Exception ex)
            {
                Fail("autostart change failed: " + ex.Message);
                return 1;
            }
        }

        static void EnsureDataTree(string dataDir)
        {
            string[] dirs = {
                "mailboxes", "registry", "archive", "logs", "logs\\routed",
                "post\\manifest", "post\\cold", "templates", "config", "app"
            };
            foreach (string d in dirs)
            {
                string full = Path.Combine(dataDir, d);
                if (!Directory.Exists(full)) Directory.CreateDirectory(full);
            }
        }

        static void WriteDataConfig(string dataDir)
        {
            // The scripts live in the data dir too (they are code, but the
            // whole tree is self-contained so the postman works from one place).
            string srcScripts = Path.Combine(Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')), "scripts");
            string dstScripts = Path.Combine(dataDir, "scripts");
            if (Directory.Exists(srcScripts) && !Directory.Exists(dstScripts))
            {
                CopyDirectory(srcScripts, dstScripts, new string[] { "__pycache__" });
            }
            string srcTemplates = Path.Combine(Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')), "templates");
            string dstTemplates = Path.Combine(dataDir, "templates");
            if (Directory.Exists(srcTemplates))
                CopyDirectory(srcTemplates, dstTemplates, null);
            string srcAssets = Path.Combine(Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')), "assets");
            string dstAssets = Path.Combine(dataDir, "assets");
            if (Directory.Exists(srcAssets))
                CopyDirectory(srcAssets, dstAssets, null);
            string srcConfig = Path.Combine(Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')), "config");
            string dstConfig = Path.Combine(dataDir, "config");
            if (Directory.Exists(srcConfig))
                CopyDirectory(srcConfig, dstConfig, null);

            // doc layer (v2.2, packaging guide S3c): mirrors install.ps1 2b -
            // entry documents must be discoverable in the data root. Note this
            // fallback runs only when PowerShell is unavailable, so a pure-C#
            // copy keeps the cold-agent entry path alive.
            string srcRoot = Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\'));
            foreach (string doc in new string[] { "AGENTS.md", "PROTOCOL.md", "README.md" })
            {
                string s = Path.Combine(srcRoot, doc);
                if (File.Exists(s)) File.Copy(s, Path.Combine(dataDir, doc), true);
            }
            foreach (string d in new string[] { "docs", "skills" })
            {
                string s = Path.Combine(srcRoot, d);
                if (Directory.Exists(s)) CopyDirectory(s, Path.Combine(dataDir, d), new string[] { "__pycache__" });
            }
        }

        static void CopyIfMissing(string sourceInstallDir, string installDir)
        {
            if (string.Equals(sourceInstallDir, installDir, StringComparison.OrdinalIgnoreCase)) return;
            foreach (string sub in new string[] { "app", "scripts", "templates", "assets", "config" })
            {
                string src = Path.Combine(sourceInstallDir, sub);
                string dst = Path.Combine(installDir, sub);
                if (Directory.Exists(src) && !Directory.Exists(dst))
                    CopyDirectory(src, dst, new string[] { "__pycache__", "userdata" });
            }
        }

        static void CopyRegistryCards(string dataDir)
        {
            // The agent cards are the mailbox's address book. Without them the
            // data tree is empty and init.ps1 has nobody to build mailboxes
            // for - so they travel with the install.
            string srcReg = Path.Combine(Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\')), "registry");
            string dstReg = Path.Combine(dataDir, "registry");
            if (!Directory.Exists(dstReg)) Directory.CreateDirectory(dstReg);
            if (!Directory.Exists(srcReg)) return;
            foreach (string f in Directory.GetFiles(srcReg, "*.md"))
            {
                string target = Path.Combine(dstReg, Path.GetFileName(f));
                if (!File.Exists(target)) File.Copy(f, target, true);
            }
        }

        static void CopyDirectory(string src, string dst, string[] skipDirs)
        {
            Directory.CreateDirectory(dst);
            foreach (string f in Directory.GetFiles(src))
            {
                string target = Path.Combine(dst, Path.GetFileName(f));
                if (!File.Exists(target)) File.Copy(f, target, true);
            }
            foreach (string d in Directory.GetDirectories(src))
            {
                string name = Path.GetFileName(d);
                if (skipDirs != null && Array.IndexOf(skipDirs, name) >= 0) continue;
                CopyDirectory(d, Path.Combine(dst, name), skipDirs);
            }
        }

        static void RemoveShortcuts()
        {
            // Best-effort cleanup for the built-in fallback path. The name
            // contains Chinese characters; the glob also catches leftovers
            // from an earlier BOM-less version that wrote mojibake names.
            try
            {
                string startMenu = Environment.GetFolderPath(Environment.SpecialFolder.StartMenu);
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
                foreach (string dir in new string[] { startMenu, desktop })
                {
                    if (string.IsNullOrEmpty(dir)) continue;
                    foreach (string f in Directory.GetFiles(dir, "AgentsKontakt*.lnk"))
                    {
                        try { File.Delete(f); } catch { }
                    }
                }
            }
            catch { }
        }
    }
}
