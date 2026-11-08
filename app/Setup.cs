// AgentsKontakt Setup (v2.3.0): wizard-style installer with live progress UI.
//
// Three pages, mainstream Windows installer style:
//   1. options   - install path (prefilled from previous install), browse
//   2. progress  - progress bar + current step + detailed log (streamed from
//                  the staged install.ps1; milestones advance the bar)
//   3. done      - autostart / launch choices (owner decides AFTER install)
//
// The payload zip travels embedded as resource "payload.zip". All install
// work is still done by the staged scripts\ops\install.ps1 - the single
// implementation every path shares.
//
// Command line (all optional, for unattended runs):
//   AgentsKontakt-Setup.exe [--install-dir <dir>] [--data-dir <dir>]
//                           [--no-autostart] [--no-defender] [--silent]
//   Silent mode: no UI, exit code 0/1. Interactive installs always run the
//   pipeline WITHOUT autostart; the done page applies the user's choice via
//   --register-autostart.
//
// Exit codes: 0 installed (or user aborted), 1 install failed.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace AgentsKontaktSetup
{
    static class Setup
    {
        const string ResourceName = "payload.zip";

        // milestones printed by scripts\ops\install.ps1, in order of appearance
        static readonly string[][] Milestones = new string[][] {
            new string[] { "copied app",                    "复制程序文件" },
            new string[] { "data tree ready",               "建立数据目录" },
            new string[] { "scripts staged into data dir",  "部署脚本到数据目录" },
            new string[] { "doc layer staged",              "部署文档与技能层" },
            new string[] { "registry cards staged",         "登记通讯录" },
            new string[] { "standard uninstall entry",      "标准安装注册（设置→应用可见）" },
            new string[] { "mailbox tree initialised",      "初始化信箱目录树" },
            new string[] { "Install finished",              "收尾" }
        };

        static WizardForm wizard;
        static string LogPath;
        static int exitCode = 0;

        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            bool silent = Has(args, "--silent");
            bool defender = !Has(args, "--no-defender");
            string installDir = Value(args, "--install-dir");
            string dataDir = Value(args, "--data-dir");

            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(installDir)) installDir = Path.Combine(local, "Programs", "AgentsKontakt");
            // data dir default (2026-11-03 owner decision): the INSTALL DIR
            // ITSELF is the mailbox root (flat portable layout - code and
            // data side by side, agent docs at the folder root). Reinstalling
            // into the remembered dir keeps everything in one folder. An
            // explicit --data-dir still wins (separated layouts keep working).
            if (string.IsNullOrEmpty(dataDir)) dataDir = installDir;

            if (silent)
            {
                LogPath = Path.Combine(dataDir, "logs", "install-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
                try { Directory.CreateDirectory(Path.GetDirectoryName(LogPath)); } catch { }
                ILog("AgentsKontakt 安装开始（静默模式）");
                ILog("安装路径: " + installDir);
                ILog("数据目录: " + dataDir);
                string err;
                bool shortcutsArg = !Has(args, "--no-shortcuts");
                int rc = RunInstall(installDir, dataDir, defender, shortcutsArg, false, delegate(string l) { ILog(l); }, null, out err);
                ILog("安装结束 rc=" + rc);
                return rc;
            }

            LogPath = Path.Combine(dataDir, "logs", "install-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
            try { Directory.CreateDirectory(Path.GetDirectoryName(LogPath)); } catch { }
            ILog("AgentsKontakt 安装开始（向导模式）");
            string previous = GetPreviousInstallDir();
            // remembered paths must also end with \AgentsKontakt (owner requirement)
            if (!string.IsNullOrEmpty(previous) &&
                !previous.EndsWith("\\AgentsKontakt", StringComparison.OrdinalIgnoreCase))
            {
                previous = previous.TrimEnd('\\') + "\\AgentsKontakt";
            }
            wizard = new WizardForm(previous != null ? previous : installDir, installDir, defender);
            wizard.LogFilePath = LogPath;
            wizard.ShowDialog();
            return exitCode;
        }

        // ---------------- install pipeline (UI callbacks may be null) --------

        internal static int RunInstall(string installDir, string dataDir, bool defender, bool shortcuts, bool interactive,
                              Action<string> uiLog, Action<int, string> uiStep, out string error)
        {
            error = null;
            try
            {
                // 1. unpack the embedded payload (step 1 of the bar)
                Report(uiStep, 1, "解压安装载荷");
                string extract = Path.Combine(Path.GetTempPath(), "AKSetup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
                Directory.CreateDirectory(extract);
                using (Stream src = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
                {
                    if (src == null) throw new InvalidOperationException("payload resource missing: " + ResourceName);
                    using (var zip = new ZipArchive(src))
                    {
                        int i = 0; int total = zip.Entries.Count;
                        foreach (var e in zip.Entries)
                        {
                            if (string.IsNullOrEmpty(e.Name)) continue;
                            string target = Path.Combine(extract, e.FullName);
                            string td = Path.GetDirectoryName(target);
                            if (!Directory.Exists(td)) Directory.CreateDirectory(td);
                            using (var es = e.Open())
                            using (var fs = File.Create(target)) { es.CopyTo(fs); }
                            i++;
                            if (i % 12 == 0 || i == total) Report(uiStep, 1, "解压安装载荷 (" + i + "/" + total + ")");
                        }
                    }
                }

                // 2. run the staged installer - milestones stream to the UI
                string ps = Path.Combine(extract, "scripts", "ops", "install.ps1");
                if (!File.Exists(ps)) throw new InvalidOperationException("staged install.ps1 missing");
                var psi = new ProcessStartInfo
                {
                    FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                            "WindowsPowerShell", "v1.0", "powershell.exe"),
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps + "\""
                                + " -InstallDir \"" + installDir + "\""
                                + " -DataDir \"" + dataDir + "\""
                                + " -SourceRoot \"" + extract + "\""
                                + " -NoAutostart"                       // done page applies the choice
                                + (shortcuts ? "" : " -NoShortcuts")
                                + (defender ? "" : " -NoDefenderExclusion"),
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };
                using (var p = Process.Start(psi))
                {
                    p.OutputDataReceived += (s, e) =>
                    {
                        if (e.Data == null) return;
                        Report(uiLog, e.Data);
                        for (int i = 0; i < Milestones.Length; i++)
                        {
                            if (e.Data.IndexOf(Milestones[i][0], StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                Report(uiStep, i + 2, Milestones[i][1]);   // +2: step 1 = extraction
                                break;
                            }
                        }
                    };
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) Report(uiLog, e.Data); };
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    p.WaitForExit();
                    int rc = p.ExitCode;
                    try { Directory.Delete(extract, true); } catch { }
                    if (rc != 0)
                    {
                        error = "安装脚本返回 " + rc;
                        return rc;
                    }
                }
                Report(uiStep, Milestones.Length + 1, "安装完成");
                return 0;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                if (interactive) MessageBox.Show("安装失败: " + ex.Message, "AgentsKontakt 安装程序",
                    MessageBoxButtons.OK, MessageBoxIcon.Error, MessageBoxDefaultButton.Button1,
                    MessageBoxOptions.DefaultDesktopOnly);
                return 1;
            }
        }

        static void Report(Action<string> log, string line) { if (log != null) log(line); }
        static void Report(Action<int, string> step, int idx, string text) { if (step != null) step(idx, text); }

        internal static void ILog(string line)
        {
            try
            {
                if (LogPath != null)
                    File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " | " + line + Environment.NewLine);
            }
            catch { }
        }

        // ---------------- registry: remember previous install path ------------

        // reject paths under %TEMP% — they are test installs, not real deployments
        static bool IsTestPath(string p)
        {
            if (string.IsNullOrEmpty(p)) return true;
            string temp = Path.GetTempPath();
            return p.StartsWith(temp, StringComparison.OrdinalIgnoreCase);
        }

        static string GetPreviousInstallDir()
        {
            // v2.2.9: the standard Uninstall key's InstallLocation (written by
            // install.ps1 4b on every install) is the previous chosen path.
            try
            {
                Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\AgentsKontaktPost");
                if (k != null)
                {
                    string loc = k.GetValue("InstallLocation") as string;
                    k.Close();
                    if (!string.IsNullOrWhiteSpace(loc) && loc.Trim().Length > 2 && !IsTestPath(loc)) return loc.Trim();
                }
                Microsoft.Win32.RegistryKey k2 = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    "Software\\AgentsKontakt");
                if (k2 != null)
                {
                    string loc2 = k2.GetValue("LastInstallDir") as string;
                    k2.Close();
                    if (!string.IsNullOrWhiteSpace(loc2) && loc2.Trim().Length > 2 && !IsTestPath(loc2)) return loc2.Trim();
                }
            }
            catch { }
            return null;
        }

        static bool Has(string[] args, string name)
        {
            foreach (string a in args) { if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true; }
            return false;
        }

        static string Value(string[] args, string name)
        {
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            }
            return null;
        }
    }

    // ------------------------------------------------------------------ wizard

    class WizardForm : Form
    {
        const string bs = "\\";
        Panel banner; Label bannerTitle, bannerSub;
        Panel pageOptions, pageProgress, pageDone;
        TextBox pathBox; Label dataLabel;
        ProgressBar bar; Label stepLabel; TextBox logBox; Label doneSummary;
        CheckBox autoStartCheck, launchCheck;
        Button startBtn, cancelBtn, doneBtn, browse;
        Label lbl1, lblTip, doneTitle, agentTip;
        string dataDir; bool defender;
        bool installing;
        string chosenInstallDir; string initialPath; public string LogFilePath; public CheckBox shortcutsCheck;

        public WizardForm(string previousDir, string defaultDir, bool defenderArg)
        {
            defender = defenderArg;
            initialPath = previousDir != null ? previousDir : defaultDir;
            // flat one-folder layout (2026-11-03): the install dir IS the
            // mailbox root - agent docs at the folder root, mailboxes\ and
            // scripts\ beside app\. The wizard ignores any --data-dir
            // default; silent mode honours it.
            dataDir = initialPath;
            Text = "AgentsKontakt 安装程序";
            ClientSize = new System.Drawing.Size(660, 560);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MaximizeBox = false; MinimizeBox = false;
            TopMost = true;

            banner = new Panel { Dock = DockStyle.Top, Height = 64, BackColor = Color.FromArgb(28, 60, 106) };
            bannerTitle = new Label { Text = "安装 AgentsKontakt 邮差", ForeColor = Color.White,
                Font = new Font("Microsoft YaHei", 14, FontStyle.Bold), Left = 20, Top = 8, AutoSize = true };
            bannerSub = new Label { Text = "跨应用 AI 信箱 · 邮局常驻 · agent 自助接入", ForeColor = Color.FromArgb(200, 214, 235),
                Font = new Font("Microsoft YaHei", 9), Left = 22, Top = 36, AutoSize = true };
            banner.Controls.Add(bannerTitle); banner.Controls.Add(bannerSub);

            // ---- page 1: options
            pageOptions = new Panel { Dock = DockStyle.Fill };
            lbl1 = new Label { Text = "安装路径：", Left = 24, Top = 24, Width = 80 };
            pathBox = new TextBox { Left = 106, Top = 21, Width = 440, TabStop = false };
            pathBox.SelectionStart = 0;   // show the drive letter (leftmost), not the tail
            var browse = new Button { Text = "浏览...", Left = 514, Top = 19, Width = 90 };
            this.browse = browse;
            browse.Click += (s, e) =>
            {
                using (var d = new FolderBrowserDialog
                {
                    Description = "选择安装位置（将自动创建 AgentsKontakt 子目录）",
                    ShowNewFolderButton = true,
                    SelectedPath = Directory.Exists(pathBox.Text) ? pathBox.Text : ""
                })
                {
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    // TextChanged keeps the data dir + label in sync
                    pathBox.Text = NormalizeInstallDir(d.SelectedPath);
                    pathBox.SelectionStart = 0;
                }
                }
            };
            dataLabel = new Label { Text = "程序与数据同装一个文件夹：信件（mailboxes\\）、归档（archive\\）、通讯录（registry\\）都在安装文件夹内。", Left = 106, Top = 54, Width = 500 };
            lblTip = new Label
            {
                Text = "接入 AI agent：装好后让它读安装文件夹下的 AGENTS.md，按指引自助注册。\r\n开机自启与立即启动在安装完成后由您选择。",
                Left = 106, Top = 82, Width = 500, Height = 44
            };
            startBtn = new Button { Text = "开始安装", Left = 372, Top = 336, Width = 116, Height = 32  };
            cancelBtn = new Button { Text = "取消", Left = 500, Top = 336, Width = 104, Height = 32, DialogResult = DialogResult.Cancel  };
            startBtn.Click += (s, e) => StartInstall();
            shortcutsCheck = new CheckBox { Text = "创建开始菜单和桌面快捷方式", Left = 106, Top = 132, Width = 500, Checked = true };
            pageOptions.Controls.AddRange(new Control[] { lbl1, pathBox, browse, dataLabel, lblTip, shortcutsCheck, startBtn, cancelBtn });

            // ---- page 2: progress
            pageProgress = new Panel { Dock = DockStyle.Fill };
            stepLabel = new Label { Text = "准备安装...", Left = 24, Top = 24, Width = 590, Font = new Font("Microsoft YaHei", 10) };
            bar = new ProgressBar { Left = 24, Top = 58, Width = 596, Height = 22 };
            logBox = new TextBox
            {
                Left = 24, Top = 94, Width = 596, Height = 250,
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                Font = new Font("Consolas", 8.5f), BackColor = Color.White
            };
            pageProgress.Controls.AddRange(new Control[] { stepLabel, bar, logBox });

            // ---- page 3: done
            pageDone = new Panel { Dock = DockStyle.Fill };
            doneTitle = new Label { Text = "安装完成！", Left = 24, Top = 30, Width = 440,
                Font = new Font("Microsoft YaHei", 15, FontStyle.Bold) };
            doneSummary = new Label { Text = "", Left = 26, Top = 74, Width = 560, Height = 92 };
            autoStartCheck = new CheckBox { Text = "开机自动启动邮差（登录后托盘常驻）", Left = 30, Top = 150, Width = 500, Checked = true };
            launchCheck = new CheckBox { Text = "立即启动邮差", Left = 30, Top = 180, Width = 500, Checked = true };
            agentTip = new Label { Text = "接入 AI agent：让它读安装文件夹下的 AGENTS.md，按指引自助注册。", Left = 26, Top = 220, Width = 560 };
            doneBtn = new Button { Text = "完成", Left = 478, Top = 336, Width = 126, Height = 32  };
            doneBtn.Click += (s, e) => FinishUp();
            pageDone.Controls.AddRange(new Control[] { doneTitle, doneSummary, autoStartCheck, launchCheck, agentTip, doneBtn });

            Controls.Add(pageOptions);
            Controls.Add(pageProgress); pageProgress.Visible = false;
            Controls.Add(pageDone); pageDone.Visible = false;
            Controls.Add(banner);
            AcceptButton = startBtn; CancelButton = cancelBtn;
            // mainstream-installer behavior: fill the path AFTER show so the box
            // (unfocused, caret at home) displays from the LEFT — drive letter visible.
            Shown += delegate(object s, EventArgs e)
            {
                pathBox.Text = initialPath;
                ActiveControl = startBtn;
                // defer the caret reset until after ALL pending messages (focus,
                // layout) settle — a synchronous reset gets overwritten by them
                BeginInvoke(new Action(delegate()
                {
                    pathBox.SelectionStart = 0;
                    pathBox.SelectionLength = 0;
                    pathBox.ScrollToCaret();
                    HomeCaret();
                }));
                // belt and braces: one more pass after the message loop drains
                var caretTimer = new System.Windows.Forms.Timer { Interval = 300 };
                caretTimer.Tick += delegate(object t, EventArgs te)
                {
                    caretTimer.Stop();
                    HomeCaret();
                };
                caretTimer.Start();
            };
            Load += delegate(object s, EventArgs e)
            {
                LayoutControls();
            };
        }

        // Win32: force the single-line Edit to show char 0 (WinForms SelectionStart
        // alone loses the battle against the automatic end-of-text scroll at 150% DPI)
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
        const uint EM_SETSEL = 0x00B1;
        const uint EM_SCROLLCARET = 0x00B7;

        void HomeCaret()
        {
            try
            {
                if (pathBox.IsHandleCreated)
                {
                    SendMessage(pathBox.Handle, EM_SETSEL, System.IntPtr.Zero, System.IntPtr.Zero);
                    SendMessage(pathBox.Handle, EM_SCROLLCARET, System.IntPtr.Zero, System.IntPtr.Zero);
                }
            }
            catch { }
        }

        // proportional layout: positions as % of actual ClientSize
        // called on Load — DPI-proof, font-scale-proof, resolution-proof
        void LayoutControls()
        {
            int cw = ClientSize.Width;
            int ch = ClientSize.Height - banner.Height;   // usable area below banner

            // page 1: options - pathBox sits AFTER the label's real right edge.
            // At high DPI the label's autosized text is wider than any fixed Left,
            // and the box slides UNDER it hiding the drive letter (the missing
            // "C:" bug). Align content to the label's actual edge.
            lbl1.AutoSize = true;
            int contentLeft = lbl1.Right + 12;
            int contentWidth = cw - contentLeft - cw * 3 / 100;
            lbl1.Left = cw * 3 / 100; lbl1.Top = ch * 5 / 100;
            pathBox.Left = contentLeft; pathBox.Top = lbl1.Top - 3; pathBox.Width = contentWidth - browse.Width - 12;
            browse.Left = pathBox.Right + 12; browse.Top = pathBox.Top - 2;
            dataLabel.Left = contentLeft; dataLabel.Top = ch * 11 / 100; dataLabel.Width = contentWidth;
            lblTip.Left = contentLeft; lblTip.Top = ch * 17 / 100; lblTip.Width = contentWidth;
            shortcutsCheck.Left = contentLeft; shortcutsCheck.Top = ch * 27 / 100; shortcutsCheck.Width = contentWidth;
            startBtn.Left = cw * 55 / 100; startBtn.Top = ch * 80 / 100;
            cancelBtn.Left = cw * 74 / 100; cancelBtn.Top = ch * 80 / 100;

            // page 2: progress
            stepLabel.Left = cw * 3 / 100; stepLabel.Top = ch * 5 / 100; stepLabel.Width = cw * 92 / 100;
            bar.Left = cw * 3 / 100; bar.Top = ch * 12 / 100; bar.Width = cw * 92 / 100;
            logBox.Left = cw * 3 / 100; logBox.Top = ch * 18 / 100; logBox.Width = cw * 92 / 100; logBox.Height = ch * 55 / 100;

            // page 3: done
            doneTitle.Left = cw * 3 / 100; doneTitle.Top = ch * 6 / 100;
            doneSummary.Left = cw * 4 / 100; doneSummary.Top = ch * 14 / 100; doneSummary.Width = cw * 88 / 100;
            autoStartCheck.Left = cw * 4 / 100; autoStartCheck.Top = ch * 32 / 100;
            launchCheck.Left = cw * 4 / 100; launchCheck.Top = ch * 38 / 100;
            agentTip.Left = cw * 4 / 100; agentTip.Top = ch * 44 / 100;
            doneBtn.Left = cw * 70 / 100; doneBtn.Top = ch * 80 / 100;
        }

        static string NormalizeInstallDir(string p)
        {
            p = (p ?? "").Trim().TrimEnd(Convert.ToChar(92));
            if (p.Length == 0) return p;
            string suffix = bs + "AgentsKontakt";
            if (p.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return p;
            return p + suffix;
        }

        void StartInstall()
        {
            chosenInstallDir = NormalizeInstallDir(pathBox.Text);
            if (chosenInstallDir.Length == 0) chosenInstallDir = pathBox.Text;
            // flat layout: the mailbox root IS the install dir
            dataDir = chosenInstallDir.Length > 0 ? chosenInstallDir : initialPath;
            // overlay guard (2026-11-04 owner requirement): a running postman
            // locks app\AgentsKontaktPost.exe and install.ps1 copies with
            // -ErrorAction SilentlyContinue, so an overlay update would
            // half-install silently. Detect before any file moves, judge the
            // version, ask. Cancel = leave the app running, exit installer.
            if (!StopRunningPostman()) { Close(); return; }
            installing = true;
            startBtn.Enabled = false; cancelBtn.Enabled = false; browse.Enabled = false; pathBox.Enabled = false;
            if (shortcutsCheck != null) shortcutsCheck.Enabled = false;
            pageOptions.Visible = false; pageProgress.Visible = true;
            bar.Value = 8;
            Action<string> uiLog = delegate(string line) { SafeUi(delegate { AppendLog(line); }); Setup.ILog(line); };
            Action<int, string> uiStep = delegate(int idx, string text)
            {
                SafeUi(delegate
                {
                    stepLabel.Text = "当前步骤： " + text;
                    int pct = idx * 100 / 9; if (pct > 100) pct = 100; if (pct < 0) pct = 0;
                    bar.Value = pct;
                });
            };
            var worker = new Thread(delegate()
            {
                string err;
                int rc = Setup.RunInstall(chosenInstallDir, dataDir, defender, shortcutsCheck.Checked, true, uiLog, uiStep, out err);
                SafeUi(delegate
                {
                    installing = false;
                    if (rc == 0)
                    {
                        bar.Value = 100;
                        stepLabel.Text = "全部步骤完成";
                        doneSummary.Text = "安装目录（程序与数据同在此文件夹）: " + chosenInstallDir +
                            "\r\n\r\n下方两个选项按需勾选，点「完成」生效。\r\n安装日志: " + LogFilePath;
                        pageProgress.Visible = false; pageDone.Visible = true;
                    }
                    else
                    {
                        stepLabel.Text = "安装失败";
                        MessageBox.Show("安装未完成: " + (err == null ? "" : err) +
                            "\r\n详细输出见上方日志与本机 %TEMP%\\AgentsKontakt-setup.log",
                            "AgentsKontakt 安装程序", MessageBoxButtons.OK, MessageBoxIcon.Warning,
                            MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
                        pageProgress.Visible = false; pageOptions.Visible = true;
                        startBtn.Enabled = true; cancelBtn.Enabled = true; browse.Enabled = true; pathBox.Enabled = true;
                        if (shortcutsCheck != null) shortcutsCheck.Enabled = true;
                    }
                });
            });
            worker.IsBackground = true;
            worker.Start();
        }

        // ---- running-postman guard ---------------------------------------
        // Detects a running AgentsKontaktPost anywhere on this machine (any
        // version), pauses when its version <= this installer's version, and
        // offers to stop it. The exe of a running app cannot be replaced and
        // install.ps1 copies with -ErrorAction SilentlyContinue, so without
        // this guard an overlay update would half-install silently.

        bool StopRunningPostman()
        {
            var mine = new System.Collections.Generic.List<Process>();
            foreach (var p in Process.GetProcessesByName("AgentsKontaktPost"))
            {
                if (p.Id == Process.GetCurrentProcess().Id) continue;
                mine.Add(p);
            }
            if (mine.Count == 0) return true;

            Version installerVer = ParseVer(FileVersionInfo.GetVersionInfo(Application.ExecutablePath).FileVersion);
            var roots = new System.Collections.Generic.List<string>();
            string verTxt = "";
            bool needPrompt = false;
            foreach (var p in mine)
            {
                string fv = null;
                try { fv = p.MainModule.FileVersionInfo.FileVersion; } catch { }
                try { roots.Add(Path.GetDirectoryName(p.MainModule.FileName)); } catch { }
                Version rv = ParseVer(fv);
                if (rv == null || installerVer == null || rv <= installerVer) needPrompt = true;
                verTxt += (verTxt.Length > 0 ? ", " : "") + (string.IsNullOrEmpty(fv) ? "未知" : fv);
            }
            if (!needPrompt)
            {
                // every running build is newer than this installer: installing
                // here is a downgrade - require explicit consent instead of
                // silently proceeding (2026-11-04 owner requirement).
                Setup.ILog("检测到运行中的邮差版本更新 (" + verTxt + ")，询问是否覆盖回退");
                if (!AskDowngrade(verTxt))
                {
                    Setup.ILog("用户取消覆盖回退，正在运行的邮差保持原样");
                    return false;
                }
            }
            else
            {
                Setup.ILog("检测到运行中的邮差 (版本 " + verTxt + ")，询问是否结束进程");
                if (!AskStopRunning(verTxt))
                {
                    Setup.ILog("用户取消安装更新，正在运行的邮差保持原样");
                    return false;
                }
            }

            Setup.ILog("结束运行中的邮差进程");
            foreach (var p in mine)
            {
                try { p.Kill(); p.WaitForExit(5000); } catch { }
            }
            // related services: standalone watch daemons (powershell watch.ps1)
            roots.Add(chosenInstallDir); roots.Add(dataDir);
            try
            {
                foreach (System.Management.ManagementObject o in
                    new System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'").Get())
                {
                    string cl = (o["CommandLine"] ?? "").ToString();
                    if (cl.IndexOf("watch.ps1", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    foreach (string root in roots)
                    {
                        if (string.IsNullOrEmpty(root)) continue;
                        if (cl.IndexOf(root, StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            int pid = Convert.ToInt32(o["ProcessId"]);
                            try { Process.GetProcessById(pid).Kill(); Process.GetProcessById(pid).WaitForExit(3000); } catch { }
                            Setup.ILog("  [ok] stopped daemon pid=" + pid);
                            break;
                        }
                    }
                }
            }
            catch (Exception ex) { Setup.ILog("  [--] daemon stop: " + ex.Message); }

            int left = 0;
            foreach (var p in Process.GetProcessesByName("AgentsKontaktPost"))
            {
                if (p.Id != Process.GetCurrentProcess().Id) left++;
            }
            if (left > 0)
                MessageBox.Show("仍有 " + left + " 个邮差进程未能结束（可能权限不足）。\r\n安装将继续，但程序文件可能无法被替换。",
                    "AgentsKontakt 安装程序", MessageBoxButtons.OK, MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
            return true;
        }

        bool AskStopRunning(string verTxt)
        {
            using (var dlg = new Form())
            {
                dlg.Text = "AgentsKontakt 安装程序";
                dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
                dlg.StartPosition = FormStartPosition.CenterParent;
                dlg.MinimizeBox = false; dlg.MaximizeBox = false;
                dlg.ShowInTaskbar = false;
                dlg.ClientSize = new Size(470, 152);
                dlg.Font = new Font("Microsoft YaHei", 9);
                var msg = new Label
                {
                    Text = "检测到本机正在运行 AgentsKontakt 邮差（版本 " + verTxt + "）。\r\n安装更新需要退出当前运行程序。",
                    Left = 18, Top = 16, Width = 436, Height = 56
                };
                var yes = new Button { Text = "结束进程继续", Left = 112, Top = 96, Width = 122, Height = 32 };
                var no = new Button { Text = "取消安装更新", Left = 248, Top = 96, Width = 122, Height = 32 };
                yes.DialogResult = DialogResult.Yes;
                no.DialogResult = DialogResult.No;
                dlg.Controls.Add(msg); dlg.Controls.Add(yes); dlg.Controls.Add(no);
                dlg.AcceptButton = yes; dlg.CancelButton = no;
                return dlg.ShowDialog(this) == DialogResult.Yes;
            }
        }

        // downgrade consent: every running build is newer than this installer
        bool AskDowngrade(string verTxt)
        {
            using (var dlg = new Form())
            {
                dlg.Text = "AgentsKontakt 安装程序";
                dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
                dlg.StartPosition = FormStartPosition.CenterParent;
                dlg.MinimizeBox = false; dlg.MaximizeBox = false;
                dlg.ShowInTaskbar = false;
                dlg.ClientSize = new Size(470, 152);
                dlg.Font = new Font("Microsoft YaHei", 9);
                var msg = new Label
                {
                    Text = "已检测已安装更新的版本（" + verTxt + "），是否要覆盖回退？\r\n此举可能会导致程序不兼容，影响稳定性。",
                    Left = 18, Top = 16, Width = 436, Height = 56
                };
                var yes = new Button { Text = "继续", Left = 112, Top = 96, Width = 122, Height = 32 };
                var no = new Button { Text = "取消", Left = 248, Top = 96, Width = 122, Height = 32 };
                yes.DialogResult = DialogResult.Yes;
                no.DialogResult = DialogResult.No;
                dlg.Controls.Add(msg); dlg.Controls.Add(yes); dlg.Controls.Add(no);
                dlg.AcceptButton = yes; dlg.CancelButton = no;
                return dlg.ShowDialog(this) == DialogResult.Yes;
            }
        }

        static Version ParseVer(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            Version v;
            return Version.TryParse(s.Trim(), out v) ? v : null;
        }

        void FinishUp()
        {
            if (autoStartCheck.Checked)
            {
                string exe = Path.Combine(chosenInstallDir, "app", "AgentsKontaktPost.exe");
                using (var p = Process.Start(new ProcessStartInfo
                {
                    FileName = exe, Arguments = "--register-autostart",
                    UseShellExecute = false, CreateNoWindow = true
                }))
                {
                    p.WaitForExit();
                    if (p.ExitCode != 0)
                        MessageBox.Show("自启注册返回 " + p.ExitCode + "；可稍后手动运行\r\n" + exe + " --register-autostart",
                            "AgentsKontakt 安装程序", MessageBoxButtons.OK, MessageBoxIcon.Warning,
                            MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
                }
            }
            if (launchCheck.Checked)
            {
                try
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = Path.Combine(chosenInstallDir, "app", "AgentsKontaktPost.exe"),
                        Arguments = "--minimized",
                        WorkingDirectory = Path.Combine(chosenInstallDir, "app"),
                        UseShellExecute = true
                    });
                }
                catch (Exception ex)
                {
                    MessageBox.Show("邮差启动失败: " + ex.Message, "AgentsKontakt 安装程序",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button1,
                        MessageBoxOptions.DefaultDesktopOnly);
                }
            }
            Close();
        }

        void SafeUi(Action a)
        {
            try { if (IsHandleCreated) BeginInvoke(a); } catch { }
        }

        void AppendLog(string line)
        {
            logBox.AppendText(line + Environment.NewLine);
            logBox.SelectionStart = logBox.TextLength;
            logBox.ScrollToCaret();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (installing) { e.Cancel = true; return; }   // no partial-install aborts
            base.OnFormClosing(e);
        }
    }
}
