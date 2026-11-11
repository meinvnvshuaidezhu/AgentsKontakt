// AgentsKontakt Postman - tray shell for the mailbox post-office daemon.
//
// Roles:
//   - Hosts scripts\watch.ps1 as a supervised child process (the post office).
//   - Shows the dashboard panel (dashboard\dashboard.html) in an embedded WebView2 window.
//   - Owns installation self-registration (--install / --uninstall).
//
// Installable layout (this is what makes the app portable):
//   <installDir>\  app\AgentsKontaktPost.exe  scripts\  templates\  assets\  (read-only is fine)
//   <dataDir>\     mailboxes\ registry\ archive\ logs\ post\ templates\   (must be writable)
//
// The scripts all honour the MAILBOX_ROOT environment variable, so the daemon
// child process gets MAILBOX_ROOT=<dataDir> and every script in the tree
// resolves against the data directory even though the code lives under the
// install directory.
//
// Close (X) asks: close the program, or minimize to the tray.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace AgentsKontaktPost
{
    static class Program
    {
        const string ProductName = "AgentsKontakt Postman";
        const string MutexName = "AgentsKontaktPost.SingleInstance";
        const string ShowSignalName = "AgentsKontaktPost.ShowSignal";
        const string AppSettingsFile = "postman.config";

        [STAThread]
        static int Main(string[] args)
        {
            // --- subcommands that do not run the UI -------------------------
            string sub = ArgValue(args, "--install") ?? ArgValue(args, "/install");
            if (sub != null) return Installer.Install(sub, ArgValue(args, "--data"));
            sub = ArgValue(args, "--uninstall") ?? ArgValue(args, "/uninstall");
            if (sub != null) return Installer.Uninstall(sub, ArgValue(args, "--data"));
            sub = ArgValue(args, "--register-autostart");
            if (sub != null) return Installer.SetAutostart(true);
            sub = ArgValue(args, "--unregister-autostart");
            if (sub != null) return Installer.SetAutostart(false);
            sub = ArgValue(args, "--register-defender-exclusion");
            if (sub != null) return Installer.DefenderExclusion(true);
            sub = ArgValue(args, "--unregister-defender-exclusion");
            if (sub != null) return Installer.DefenderExclusion(false);
            sub = ArgValue(args, "--version") ?? ArgValue(args, "/version");
            if (sub != null)
            {
                Console.WriteLine(ProductName + " " + Version);
                return 0;
            }

            // --- normal run --------------------------------------------------
            bool createdNew;
            Mutex mutex = new Mutex(true, MutexName, out createdNew);
            if (!createdNew)
            {
                // The mutex object outlives a force-killed owner (abandoned
                // state) as long as anyone holds an open handle. createdNew
                // alone would then misread "second launch" forever. Take
                // ownership explicitly: success OR AbandonedMutexException
                // both mean the previous owner is really gone.
                bool abandoned = false;
                try { mutex.WaitOne(0); }
                catch (AbandonedMutexException) { abandoned = true; }
                catch (ObjectDisposedException) { }
                if (!abandoned)
                {
                    // A live instance holds it: "show me the window" instead
                    // of nagging with a message box.
                    try
                    {
                        EventWaitHandle ev = EventWaitHandle.OpenExisting(ShowSignalName);
                        ev.Set();
                    } catch { }
                    return 0;
                }
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            string installDir = Path.GetDirectoryName(exeDir);
            string dataDir = ResolveDataDir(installDir, ArgValue(args, "--data"));

            if (!Directory.Exists(Path.Combine(dataDir, "scripts")))
            {
                MessageBox.Show(
                    "找不到邮局脚本目录（data\\scripts）。\r\n\r\n" +
                    "程序目录: " + installDir + "\r\n" +
                    "数据目录: " + dataDir + "\r\n\r\n" +
                    "请确认安装完整，或用 --data 参数指定数据目录。",
                    ProductName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 2;
            }

            PostApp app = new PostApp(installDir, dataDir, args);
            Application.Run(app);
            GC.KeepAlive(mutex);
            return 0;
        }

        public static string Version
        {
            get
            {
                AssemblyName an = Assembly.GetExecutingAssembly().GetName();
                string v = an.Version == null ? "0.0.0.0" : an.Version.ToString();
                return v;
            }
        }

        static string ArgValue(string[] args, string name)
        {
            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
                {
                    if (i + 1 < args.Length && !args[i + 1].StartsWith("--") && !args[i + 1].StartsWith("/"))
                        return args[i + 1];
                    return "";
                }
            }
            return null;
        }

        /// <summary>
        /// Data directory resolution, in order:
        ///   1. explicit --data argument
        ///   2. MAILBOX_ROOT environment variable
        ///   3. the install directory itself, when it carries a full mailbox
        ///      (portable / developer layout: code and data side by side)
        ///   4. the install directory's data\ subfolder, when it carries the
        ///      scripts tree (one-folder install layout: everything under a
        ///      single AgentsKontakt folder)
        ///   5. %LOCALAPPDATA%\AgentsKontakt
        ///
        /// An explicit choice (1 or 2) is honoured unconditionally: the caller
        /// asked for that exact path, so it must not be silently replaced by
        /// the install directory just because the folder does not exist yet.
        ///
        /// Note the order of 3, 4 and 5: in the portable layout the code and
        /// the mailboxes live in the same tree, so that tree must win. A
        /// leftover empty shell under %LOCALAPPDATA% must never steal the
        /// real data.
        /// </summary>
        public static string ResolveDataDir(string installDir, string explicitData)
        {
            // An explicit request wins, always.
            if (!string.IsNullOrEmpty(explicitData))
                return Path.GetFullPath(explicitData);

            string envRoot = Environment.GetEnvironmentVariable("MAILBOX_ROOT");
            if (!string.IsNullOrEmpty(envRoot))
                return Path.GetFullPath(envRoot);

            // Portable layout: the install directory carries a complete mailbox.
            if (Directory.Exists(Path.Combine(installDir, "scripts")) &&
                Directory.Exists(Path.Combine(installDir, "mailboxes")))
                return installDir;

            // One-folder install layout (2026-11-02, owner decision): the
            // wizard puts everything under a single AgentsKontakt folder -
            // code in <install>\app, data in <install>\data. Must be checked
            // before the LOCALAPPDATA fallback so a bare launch (运行邮差.exe
            // passes no --data) finds the data next to the program.
            string oneFolder = Path.Combine(installDir, "data");
            if (Directory.Exists(Path.Combine(oneFolder, "scripts")))
                return oneFolder;

            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string candidate = Path.Combine(local, "AgentsKontakt");

            // If that directory already looks like a mailbox root, use it.
            if (Directory.Exists(Path.Combine(candidate, "scripts")) ||
                Directory.Exists(Path.Combine(candidate, "mailboxes")))
                return candidate;

            return candidate;
        }
    }

    // Shell form with a startup-visibility gate. With --minimized the panel
    // must stay hidden until ShowShell runs. WinForms has more than one path
    // that ends in SetVisibleCore(true) (the ApplicationContext main-form show
    // on Run, the 50ms showOnce timer, any external Show()); gating here makes
    // "hidden at boot" hold for all of them. 2026-10-29: the un-gated show left
    // a visible shell whose webview was never initialized (deferred init only
    // runs in ShowShell) - the boot screen was a permanent white window.
    sealed class ShellForm : Form
    {
        public bool AllowVisible;
        protected override void SetVisibleCore(bool value)
        {
            if (!AllowVisible && value) value = false;
            base.SetVisibleCore(value);
        }
    }

    public class PostApp : ApplicationContext
    {
        string installDir;
        string dataDir;
        string scriptsDir;
        string logPath;
        ShellForm shell;
        WebView2 web;
        // Raw Shell_NotifyIcon tray (26H2, 2026-10-26): this Windows build
        // silently drops WinForms NotifyIcon registrations from this app while
        // accepting identical code in minimal probes. Going direct gives us
        // the API result in the log instead of a swallowed failure.
        TrayWindow trayWin;
        System.Drawing.Icon trayIcon;
        ContextMenuStrip trayStrip;
        bool trayUp;
        const uint WM_TRAYICON = 0x8000 + 1;   // WM_APP + 1
        const uint NIM_ADD = 0, NIM_DELETE = 2;
        const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4;

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        struct NOTIFYICONDATA
        {
            public int cbSize;
            public IntPtr hWnd;
            public uint uID;
            public uint uFlags;
            public uint uCallbackMessage;
            public IntPtr hIcon;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
            public int dwState;
            public int dwStateMask;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
            public int uVersion;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
            public int dwInfoFlags;
            public Guid guidItem;
        }

        [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATA data);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern uint RegisterWindowMessage(string name);

        // --- daemon job object ------------------------------------------------
        // The daemon and every process it spawns (route/send children, headless
        // agent CLIs) go into one job with KILL_ON_JOB_CLOSE. The handle is
        // never closed explicitly: it dies with this process, and the kernel
        // then kills the whole tree. This is what stops a crashed / task-killed
        // tray app from orphaning its powershell loop (orphaned watch.ps1 loops
        // used to keep sweeping at ~13% CPU each, indefinitely).
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern System.IntPtr CreateJobObjectW(System.IntPtr lpJobAttributes, string lpName);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(System.IntPtr hJob, int jobObjectInfoClass, System.IntPtr lpJobObjectInfo, int cbJobObjectInfoLength);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(System.IntPtr hJob, System.IntPtr hProcess);

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct IO_COUNTERS
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public System.UIntPtr MinimumWorkingSetSize;
            public System.UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public System.UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public System.UIntPtr ProcessMemoryLimit;
            public System.UIntPtr JobMemoryLimit;
            public System.UIntPtr PeakProcessMemoryUsed;
            public System.UIntPtr PeakJobMemoryUsed;
        }

        const int JobObjectExtendedLimitInformation = 9;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
        System.IntPtr daemonJob;

        System.IntPtr CreateDaemonJob()
        {
            System.IntPtr job = CreateJobObjectW(System.IntPtr.Zero, null);
            if (job == System.IntPtr.Zero) return System.IntPtr.Zero;
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            System.IntPtr mem = System.Runtime.InteropServices.Marshal.AllocHGlobal(
                System.Runtime.InteropServices.Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
            try
            {
                System.Runtime.InteropServices.Marshal.StructureToPtr(info, mem, false);
                SetInformationJobObject(job, JobObjectExtendedLimitInformation, mem,
                    System.Runtime.InteropServices.Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
            }
            finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(mem); }
            return job;
        }

        sealed class TrayWindow : NativeWindow
        {
            public Action OnActivate;
            public Action OnMenu;
            public Func<bool> OnTaskbarCreated;
            public uint taskbarMsg;
            protected override void WndProc(ref Message m)
            {
                if (taskbarMsg != 0 && m.Msg == (int)taskbarMsg)
                {
                    if (OnTaskbarCreated != null) OnTaskbarCreated();
                }
                else if (m.Msg == (int)WM_TRAYICON)
                {
                    int ev = unchecked((int)(long)m.LParam);
                    if (ev == 0x0203 && OnActivate != null) OnActivate();   // WM_LBUTTONDBLCLK
                    else if (ev == 0x0205 && OnMenu != null) OnMenu();      // WM_RBUTTONUP
                }
                base.WndProc(ref m);
            }
        }

        void CreateTray()
        {
            if (trayWin == null)
            {
                trayWin = new TrayWindow();
                trayWin.taskbarMsg = RegisterWindowMessage("TaskbarCreated");
                trayWin.OnActivate = ShowShell;
                trayWin.OnMenu = ShowTrayMenu;
                trayWin.OnTaskbarCreated = delegate
                {
                    Log("explorer restarted - re-adding tray icon");
                    RemoveTray();
                    CreateTray();
                    return true;
                };
                CreateParams cp = new CreateParams();
                cp.Caption = "AgentsKontaktPost.TrayWindow";
                trayWin.CreateHandle(cp);
            }
            if (trayIcon == null) trayIcon = LoadTrayIcon();
            if (trayStrip == null) trayStrip = TrayMenu();
            NOTIFYICONDATA nid = new NOTIFYICONDATA();
            nid.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(NOTIFYICONDATA));
            nid.hWnd = trayWin.Handle;
            nid.uID = 42;   // 26H2: uID=1 registrations fail for this exe (poisoned per-(exe,uID) shell state); probes with uID>=7 all pass
            nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
            nid.uCallbackMessage = WM_TRAYICON;
            nid.hIcon = trayIcon.Handle;
            nid.szTip = ProductTitle();
            bool ok = Shell_NotifyIcon(NIM_ADD, ref nid);
            Log("tray NIM_ADD=" + ok);
            trayUp = ok;
            if (ok && trayRedDot) ApplyTrayIcon(RedDotTrayIcon());   // explorer restart re-add: replay the badge
        }

        void RemoveTray()
        {
            if (!trayUp || trayWin == null) return;
            NOTIFYICONDATA nid = new NOTIFYICONDATA();
            nid.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(NOTIFYICONDATA));
            nid.hWnd = trayWin.Handle;
            nid.uID = 42;   // 26H2: uID=1 registrations fail for this exe (poisoned per-(exe,uID) shell state); probes with uID>=7 all pass
            Shell_NotifyIcon(NIM_DELETE, ref nid);
            trayUp = false;
        }

        void ShowTrayMenu()
        {
            if (trayStrip != null) trayStrip.Show(System.Windows.Forms.Cursor.Position);
        }

        void ShowTrayBalloon(string title, string text)
        {
            if (!trayUp) return;
            if (text.Length > 255) text = text.Substring(0, 255);
            NOTIFYICONDATA nid = new NOTIFYICONDATA();
            nid.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(NOTIFYICONDATA));
            nid.hWnd = trayWin.Handle;
            nid.uID = 42;   // 26H2: uID=1 registrations fail for this exe (poisoned per-(exe,uID) shell state); probes with uID>=7 all pass
            nid.uFlags = 0x10;   // NIF_INFO
            nid.szInfo = text;
            nid.szInfoTitle = title;
            nid.dwInfoFlags = 1; // NIIF_INFO
            Shell_NotifyIcon(1, ref nid);   // NIM_MODIFY
        }

        void UpdateTrayTip(string tip)
        {
            if (!trayUp) return;
            if (tip == lastTip) return;   // unchanged tip: skip the shell round-trip on every 5s tick
            lastTip = tip;
            if (tip.Length > 127) tip = tip.Substring(0, 127);
            NOTIFYICONDATA nid = new NOTIFYICONDATA();
            nid.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(NOTIFYICONDATA));
            nid.hWnd = trayWin.Handle;
            nid.uID = 42;   // 26H2: uID=1 registrations fail for this exe (poisoned per-(exe,uID) shell state); probes with uID>=7 all pass
            nid.uFlags = NIF_TIP;
            nid.szTip = tip;
            Shell_NotifyIcon(1, ref nid);   // NIM_MODIFY
        }

        // ---- 托盘更新徽标 -------------------------------------------------------
        // 有新版本时给托盘图标叠一个红点（重绘 16x16 位图换 NIF_ICON），忽略/安装
        // 后由面板发 update-clear 摘除。explorer 重启重建托盘时按 trayRedDot 重放。
        void ApplyTrayIcon(System.Drawing.Icon icon)
        {
            if (!trayUp) return;
            NOTIFYICONDATA nid = new NOTIFYICONDATA();
            nid.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(NOTIFYICONDATA));
            nid.hWnd = trayWin.Handle;
            nid.uID = 42;   // 26H2: same poison note as above
            nid.uFlags = NIF_ICON;
            nid.hIcon = icon.Handle;
            Shell_NotifyIcon(1, ref nid);   // NIM_MODIFY
        }

        System.Drawing.Icon RedDotTrayIcon()
        {
            if (trayIconRed != null) return trayIconRed;
            try
            {
                // post.ico 的 16px 帧是 PNG 压缩帧：System.Drawing 的 ToBitmap/DrawIcon
                // 解出来是噪点（资源管理器能渲染是因为 shell 支持 PNG 帧）。改用与
                // 资源管理器同源的 shell 提取器取 32px 帧，再只叠加红点。
                IntPtr hBig, hSmall;
                string icoPath = Path.Combine(installDir, "app", "post.ico");
                if (File.Exists(icoPath) &&
                    SHDefExtractIcon(icoPath, 0, 0, out hBig, out hSmall, (uint)(32 | (16 << 16))) == 0 &&
                    hBig != IntPtr.Zero)
                {
                    using (var bmp = System.Drawing.Icon.FromHandle(hBig).ToBitmap())
                    {
                        DrawUpdateBadge(bmp);
                        trayIconRed = System.Drawing.Icon.FromHandle(bmp.GetHicon());
                    }
                    DestroyIcon(hBig);
                    DestroyIcon(hSmall);
                    return trayIconRed;
                }
            }
            catch { }
            // 兜底：无 shell 提取器时退回原路径（可能有 PNG 帧噪点，但红点仍可见）
            using (var bmp = BaseTrayIcon().ToBitmap())
            {
                DrawUpdateBadge(bmp);
                trayIconRed = System.Drawing.Icon.FromHandle(bmp.GetHicon());
            }
            return trayIconRed;
        }

        void DrawUpdateBadge(System.Drawing.Bitmap bmp)
        {
            int w = bmp.Width;
            float dot = Math.Max(3.5f, w * 0.30f);   // 红点直径约为图标宽度的 30%：不遮挡信封图形
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                var dotRect = new System.Drawing.RectangleF(w - dot - 0.75f, 0.75f, dot, dot);
                using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(9, 9, 11), 1.25f))
                    g.DrawEllipse(pen, dotRect.X + 0.625f, dotRect.Y + 0.625f, dot - 1.25f, dot - 1.25f);   // 细描边：亮暗任务栏都可见
                using (var br = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(239, 68, 68)))
                    g.FillEllipse(br, dotRect.X, dotRect.Y, dot, dot);
            }
        }

        System.Drawing.Icon BaseTrayIcon()
        {
            if (trayIcon == null) trayIcon = LoadTrayIcon();
            return trayIcon;
        }

        void SetTrayRedDot(bool on)
        {
            if (trayRedDot == on) return;
            trayRedDot = on;
            ApplyTrayIcon(on ? RedDotTrayIcon() : BaseTrayIcon());
            Log("tray update badge: " + (on ? "on" : "off"));
        }

        // ---- 系统通知工厂 -------------------------------------------------------
        // 不同 Windows 版本的通知呈现不同：Win10+ 的托盘气泡由系统渲染成操作中心
        // Toast（先声明 AppUserModelID 让 Toast 归属本应用），Win7/8 为经典气球
        // 提示。按系统版本在工厂里选择实现，调用方（面板消息/编排）只面向接口。
        interface INotifier { void NotifyUpdateAvailable(string version); }

        sealed class ToastNotifier : INotifier      // Windows 10/11：Toast
        {
            readonly PostApp app;
            public ToastNotifier(PostApp app)
            {
                this.app = app;
                try { SetCurrentProcessExplicitAppUserModelID("AgentsKontakt.Postman"); }
                catch { }
            }
            public void NotifyUpdateAvailable(string version)
            {
                app.ShowTrayBalloon("AgentsKontakt 邮差", "AgentsKontakt当前有新版本更新");
            }
        }

        sealed class BalloonNotifier : INotifier    // Windows 7/8：经典气球
        {
            readonly PostApp app;
            public BalloonNotifier(PostApp app) { this.app = app; }
            public void NotifyUpdateAvailable(string version)
            {
                app.ShowTrayBalloon("AgentsKontakt 邮差", "AgentsKontakt当前有新版本更新");
            }
        }

        static class NotifierFactory
        {
            public static INotifier Create(PostApp app)
            {
                var v = Environment.OSVersion.Version;
                return (v.Major >= 10) ? (INotifier)new ToastNotifier(app) : (INotifier)new BalloonNotifier(app);
            }
        }

        INotifier Notifier
        {
            get { if (notifier == null) notifier = NotifierFactory.Create(this); return notifier; }
        }

        [System.Runtime.InteropServices.DllImport("shellapi.dll")]
        static extern void SetCurrentProcessExplicitAppUserModelID(
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string appId);

        [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int SHDefExtractIcon(string iconPath, int index, uint flags,
            out IntPtr hiconLarge, out IntPtr hiconSmall, uint nIconSize);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr hIcon);
        Process daemon;
        System.Windows.Forms.Timer monitor;
        DateTime lastSpawnUtc;
        int restartCount;
        bool reallyQuit;
        // Set on WM_QUERYENDSESSION (logoff/shutdown): from then on the
        // watchdog must not spawn anything - a powershell started into the
        // dying session fails with 0xc0000142 and its error box stalls
        // shutdown on the logon screen (2026-10-29).
        bool shuttingDown;
        bool webReady;
        bool webStarted;
        bool webEnabled;
        // Splash cover (2026-10-29): the WebView2 browser takes 5-9s to spawn
        // cold; until then the shell is a plain white void. A dark branded
        // loading layer covers that window and reports init progress/failure.
        Panel splash;
        Label splashStatus;
        System.Windows.Forms.Timer splashAnim;
        string splashBase = "正在启动面板";
        int splashDots;
        EventWaitHandle showSignal;
        DateTime lastTrayTryUtc = DateTime.MinValue;
        int trayRetrySec = 5;
        string lastTip;
        DateTime lastOfficeAliveLogUtc = DateTime.MinValue;

        // ---- update download (panel-initiated via WebMessage, host-executed) ----
        // 退出即丢进度: the partial file is deleted on cancel / dialog close /
        // panel hide / app exit; only 暂停→继续 keeps bytes within the dialog's
        // lifetime. A completed package hands ownership to the orchestrator.
        System.Net.Http.HttpClient dlClient;
        System.Threading.CancellationTokenSource dlCts;
        System.Windows.Forms.Timer dlWatchdog;
        string dlPath;
        // 托盘更新徽标 + 系统通知
        System.Drawing.Icon trayIconRed;    // base icon + red dot composite (cached)
        bool trayRedDot;                    // badge state (re-applied when the tray re-adds)
        string trayRedFor;                  // version the badge/notification fired for
        INotifier notifier;
        string dlUrl;
        long dlReceived;
        long dlTotal = -1;
        bool dlActive;
        bool dlPaused;
        bool dlLoopAlive;    // the streaming loop runs; false while paused (loop exited)
        bool dlDiscard;      // cancel/abandon/reload: delete the partial on abort
        bool dlStall;        // 30s-no-bytes watchdog fired
        bool dlFinishing;    // done → orchestrating exit (downloads no longer accepted)
        DateTime dlLastByteUtc;
        DateTime dlLastReportUtc;

        public PostApp(string installDir, string dataDir, string[] args)
        {
            this.installDir = installDir;
            this.dataDir = dataDir;
            scriptsDir = Path.Combine(dataDir, "scripts");
            Directory.CreateDirectory(Path.Combine(dataDir, "logs"));
            logPath = Path.Combine(dataDir, "logs", "app.log");

            bool startMinimized = false;
            foreach (string a in args)
            {
                if (string.Equals(a, "--minimized", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(a, "-minimized", StringComparison.OrdinalIgnoreCase)) startMinimized = true;
            }
            Log("=== app start (bits=" + (IntPtr.Size * 8) + " version=" + Program.Version +
                " install=" + installDir + " data=" + dataDir + " minimized=" + startMinimized + ") ===");

            // TLS1.2 for the update download against github.com (in-box csc
            // targets .NET Framework where the default protocol set can lag).
            try { System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12; } catch { }
            // Update packages are transient: sweep leftovers from a previous
            // session (crash/kill mid-download would otherwise leave debris).
            // Per-file tolerance: one AV-locked file (a fresh installer is
            // briefly scanned) must not abort the rest of the sweep.
            try
            {
                string up = Path.Combine(dataDir, "updates");
                if (Directory.Exists(up))
                    foreach (string f in Directory.GetFiles(up))
                    {
                        try { File.Delete(f); }
                        catch (Exception delEx) { Log("updates sweep skipped " + Path.GetFileName(f) + ": " + delEx.Message); }
                    }
            }
            catch (Exception ex) { Log("updates sweep failed: " + ex.Message); }

            shell = new ShellForm();
            shell.AllowVisible = !startMinimized;   // --minimized: nothing may show the panel before ShowShell
            shell.Text = ProductTitle();
            shell.Width = 1380;
            shell.Height = 900;
            shell.StartPosition = FormStartPosition.CenterScreen;
            try { shell.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            shell.FormClosing += OnFormClosing;
            // Fires before the session is torn down, on a worker thread - the
            // earliest reliable "Windows is going away" signal we get.
            Microsoft.Win32.SystemEvents.SessionEnding += OnSessionEnding;
            this.MainForm = shell;
            // Second-launch "show me the window" does shell.BeginInvoke, which
            // needs a created handle (and its failure is swallowed). With
            // --minimized the form stays invisible, so force handle creation
            // here on the UI thread - invisible does not mean handleless.
            // Touching only the form's own handle creates no child handles, so
            // the WebView2 browser still stays unspawned until ShowShell inits.
            if (!shell.IsHandleCreated) System.GC.KeepAlive(shell.Handle);

            web = new WebView2();
            web.Dock = DockStyle.Fill;
            shell.Controls.Add(web);
            shell.BackColor = System.Drawing.Color.FromArgb(18, 20, 26);   // splash/dashboard dark: no white flash
            BuildSplash();

            CreateTray();

            monitor = new System.Windows.Forms.Timer();
            monitor.Interval = 5000;
            monitor.Tick += MonitorTick;
            monitor.Start();

            // 26H2 tray diagnosis: env gates let us bisect which startup
            // component breaks Shell_NotifyIcon registration (tray always
            // created; the suspects are the heavy init steps around it).
            if (Environment.GetEnvironmentVariable("AK_NODAEMON") == "1") Log("daemon spawn SKIPPED (AK_NODAEMON)");
            else StartDaemon();
            webEnabled = Environment.GetEnvironmentVariable("AK_NOWEBVIEW") != "1";
            if (!webEnabled) Log("webview init SKIPPED (AK_NOWEBVIEW)");
            else if (startMinimized) Log("webview init deferred (start minimized)");
            else InitWebAsync();

            // Recreate the tray from inside the message pump: registration from
            // the constructor (pre-pump) can be silently dropped by Explorer.
            // 26H2 diagnosis (2026-10-26): recreating at 300ms lands during the
            // WebView2/daemon startup storm and the re-ADD never sticks - the
            // icon ends up nowhere (no NotifyIconSettings entry at all). Do it
            // late instead: the constructor tray registers while the machine is
            // calm, and the late pass is now a verify-and-heal (only rebuild if
            // the shell dropped it, detected via the settings hive).
            System.Windows.Forms.Timer trayOnce = new System.Windows.Forms.Timer();
            trayOnce.Interval = 4000;
            trayOnce.Tick += delegate
            {
                trayOnce.Stop();
                trayOnce.Dispose();
                try
                {
                    if (TrayIconRegistered())
                    {
                        Log("tray verified registered in shell");
                        return;
                    }
                    RemoveTray();
                    CreateTray();
                    Log("tray re-registered (shell had dropped the early icon)");
                }
                catch (Exception ex) { Log("tray recreate failed: " + ex.Message); }
            };
            trayOnce.Start();

            // Show-signal listener: a second launch of this exe restores the
            // window (works even when the tray icon cannot register). Blocks
            // forever per wait - a 500ms polling timeout here woke the thread
            // twice a second for the whole process lifetime.
            showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowSignalNameConst);
            System.Threading.Thread sig = new System.Threading.Thread(delegate()
            {
                while (!reallyQuit)
                {
                    try { showSignal.WaitOne(System.Threading.Timeout.Infinite); }
                    catch (System.ObjectDisposedException) { break; }
                    if (reallyQuit) break;
                    try { shell.BeginInvoke(new Action(ShowShell)); } catch { }
                }
            });
            sig.IsBackground = true;
            sig.Start();

            if (!startMinimized)
            {
                // Show from inside the message loop: handles only exist once the
                // pump runs, and a pre-run Show() gets undone before first paint.
                System.Windows.Forms.Timer showOnce = new System.Windows.Forms.Timer();
                showOnce.Interval = 50;
                showOnce.Tick += delegate
                {
                    showOnce.Stop();
                    showOnce.Dispose();
                    shell.Show();
                    shell.Activate();
                    SyncSplash();   // splash covers the cold webview spawn here too
                };
                showOnce.Start();
            }
        }

        static string ShowSignalNameConst { get { return "AgentsKontaktPost.ShowSignal"; } }

        static string ProductTitle()
        {
            return "AgentsKontakt 邮差 " + Program.Version;
        }

        ContextMenuStrip TrayMenu()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("打开面板", null, delegate { ShowShell(); });
            menu.Items.Add("重启邮差", null, delegate { StopDaemon(); StartDaemon(); });
            menu.Items.Add("用浏览器打开 dashboard", null, delegate {
                try { Process.Start(Path.Combine(dataDir, "dashboard", "dashboard.html")); } catch (Exception ex) { Log("browser open failed: " + ex.Message); }
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("安装 WebView2 运行时…", null, delegate { OpenWebView2Download(); });
            menu.Items.Add("打开数据目录", null, delegate {
                try { Process.Start("explorer.exe", dataDir); } catch (Exception ex) { Log("explorer failed: " + ex.Message); }
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate { ReallyQuit(); });
            return menu;
        }

        void BuildTrayMenu() { }

        void OpenWebView2Download()
        {
            try
            {
                Process.Start("https://developer.microsoft.com/microsoft-edge/webview2/");
            }
            catch (Exception ex) { Log("webview2 download link failed: " + ex.Message); }
        }

        System.Drawing.Icon LoadTrayIcon()
        {
            string icoPath = Path.Combine(installDir, "app", "post.ico");
            try { return new System.Drawing.Icon(icoPath, new System.Drawing.Size(16, 16)); }
            catch (Exception ex) { Log("post.ico load failed (" + ex.Message + ") - falling back"); }
            try { return System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch (Exception ex) { Log("ExtractAssociatedIcon failed (" + ex.Message + ") - falling back"); }
            return System.Drawing.SystemIcons.Application;
        }

        bool TrayIconRegistered()
        {
            // Win11 24H2+ records every accepted tray icon under this hive
            // (one subkey per icon, ExecutablePath = full path). No entry means
            // the shell never took the icon.
            try
            {
                using (Microsoft.Win32.RegistryKey hive = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings"))
                {
                    if (hive == null) return false;
                    foreach (string name in hive.GetSubKeyNames())
                    {
                        using (Microsoft.Win32.RegistryKey k = hive.OpenSubKey(name))
                        {
                            string exe = Convert.ToString(k.GetValue("ExecutablePath"));
                            if (string.Equals(exe, Application.ExecutablePath, StringComparison.OrdinalIgnoreCase)) return true;
                        }
                    }
                }
            }
            catch (Exception ex) { Log("tray registry check failed: " + ex.Message); }
            return false;
        }

        void ShowShell()
        {
            shell.AllowVisible = true;   // un-gate the --minimized startup visibility gate
            shell.Show();
            shell.WindowState = FormWindowState.Normal;
            shell.Activate();
            SyncSplash();   // cover the cold WebView2 spawn with the loading splash
            // Init AFTER the form is on screen: EnsureCoreWebView2Async waits on
            // the control handle, and initializing before the first Show has been
            // observed to stall forever (white panel, no ready/failed log line).
            if (webEnabled && !webStarted) InitWebAsync();   // deferred webview: load the panel on first show
            ResumeWeb();
        }

        bool webSuspended;
        bool suspendBroken;
        DateTime lastSuspendTryUtc = DateTime.MinValue;

        async void SuspendWebAsync()
        {
            // Disposed control: nothing to suspend, and the ready flag is stale
            // (kept the monitor retrying into "members cannot be accessed"
            // errors every tick after a logoff/close race).
            if (web == null || web.IsDisposed) { webReady = false; return; }
            if (suspendBroken) return;   // latched off by a prior failure; ResumeWeb re-arms
            // 退出即丢进度: hiding the panel ends the download's lifetime - the
            // progress view no longer exists to host it.
            DiscardDownload();
            // Resident tray mode: freeze the hidden panel (renderer + gpu +
            // timers) until the next Show. TrySuspendAsync refuses while the
            // WebView is still visible, so the caller must hide the shell
            // FIRST - and even then visibility propagation takes a beat, so
            // retry. The monitor tick also re-tries while the shell stays
            // hidden and the web is unsuspended (self-heal if any single
            // attempt races a window-state transition).
            lastSuspendTryUtc = DateTime.UtcNow;
            for (int attempt = 1; attempt <= 3 && !webSuspended; attempt++)
            {
                try
                {
                    if (web != null && !web.IsDisposed && web.CoreWebView2 != null)
                    {
                        webSuspended = await web.CoreWebView2.TrySuspendAsync();
                        Log("webview suspend attempt " + attempt + " -> " + webSuspended);
                        if (webSuspended) return;
                    }
                    else return;   // no web to suspend; nothing to retry
                }
                catch (Exception ex)
                {
                    // 26H2 observed: on a hidden shell this throws the
                    // "disposed" message even with the browser fully alive
                    // (09:37:59 today: throw while msedgewebview2 processes
                    // lived), so true browser death is the ProcessFailed
                    // handler's job (it clears the flags). Here: latch suspend
                    // off - clearing flags on this throw would tear down a
                    // working browser on every hide, and unlatched it spammed
                    // the log on every monitor tick.
                    suspendBroken = true;
                    Log("webview suspend unavailable (" + ex.Message + ") - panel keeps running, re-armed on next show");
                    return;
                }
                await System.Threading.Tasks.Task.Delay(700);
            }
        }

        void ResumeWeb()
        {
            // Visibility alone usually resumes a suspended WebView, but the
            // tray paths (second-launch signal, double-click) race that - resume
            // explicitly; it is a no-op when the browser is already running.
            webSuspended = false;
            suspendBroken = false;   // a fresh show re-arms suspend
            try
            {
                if (web != null && !web.IsDisposed && web.CoreWebView2 != null) web.CoreWebView2.Resume();
            }
            catch { }
        }

        void RebuildWebView()
        {
            // A crashed browser poisons its WebView2 control: EnsureCoreWebView2Async
            // on the same control fails forever with "instance no longer valid".
            // Drop the old control and host a fresh browser in a new one.
            try
            {
                if (web != null && !web.IsDisposed)
                {
                    shell.Controls.Remove(web);
                    web.Dispose();
                }
            }
            catch (Exception ex) { Log("webview dispose during rebuild failed: " + ex.Message); }
            web = new WebView2();
            web.Dock = DockStyle.Fill;
            shell.Controls.Add(web);
            splash.BringToFront();   // keep the loading layer above the fresh browser
        }

        void ReallyQuit()
        {
            reallyQuit = true;
            try { if (showSignal != null) showSignal.Set(); } catch { }   // wake the signal thread so it exits its blocking wait
            DiscardDownload();   // 退出即丢进度 (a completed package is dlFinishing-protected)
            StopDaemon();
            RemoveTray();
            shell.Close();
        }

        void OnSessionEnding(object sender, Microsoft.Win32.SessionEndingEventArgs e)
        {
            shuttingDown = true;
            // Kill the office right here: the scheduled-task loop is already
            // being torn down, and every second this process lingers is a
            // window for the watchdog to respawn powershell into the dying
            // session. Process.Kill is safe off the UI thread.
            try { DiscardDownload(); } catch { }
            try { StopDaemon(); } catch { }
        }

        void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (reallyQuit || e.CloseReason == CloseReason.ApplicationExitCall) return;
            if (shuttingDown ||
                e.CloseReason == CloseReason.WindowsShutDown ||
                e.CloseReason == CloseReason.TaskManagerClosing)
            {
                // Never argue with a shutdown: the minimize-or-close dialog
                // cannot be answered at the logon screen, and canceling the
                // close kept this process (and its watchdog) alive into
                // logoff. Quit inline - no shell.Close() re-entrancy here.
                Log("session ending - quitting (daemon stopped)");
                reallyQuit = true;
                try { if (showSignal != null) showSignal.Set(); } catch { }
                try { StopDaemon(); } catch { }
                RemoveTray();
                e.Cancel = false;
                return;
            }
            e.Cancel = true;

            Form dlg = new Form();
            dlg.Text = "AgentsKontakt 邮差";
            dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
            dlg.StartPosition = FormStartPosition.CenterParent;
            dlg.Size = new System.Drawing.Size(440, 190);
            dlg.MaximizeBox = false;
            dlg.MinimizeBox = false;
            dlg.ShowInTaskbar = false;

            Label lbl = new Label();
            lbl.Text = "要关闭邮差程序，还是最小化到右下角托盘继续投递？";
            lbl.SetBounds(22, 22, 390, 44);

            Button bClose = new Button();
            bClose.Text = "关闭程序";
            bClose.SetBounds(22, 92, 124, 36);
            bClose.FlatStyle = FlatStyle.Flat;
            bClose.BackColor = System.Drawing.Color.FromArgb(220, 38, 38);
            bClose.ForeColor = System.Drawing.Color.White;

            Button bMin = new Button();
            bMin.Text = "最小化到托盘";
            bMin.SetBounds(154, 92, 150, 36);
            bMin.FlatStyle = FlatStyle.Flat;
            bMin.BackColor = System.Drawing.Color.FromArgb(79, 70, 229);
            bMin.ForeColor = System.Drawing.Color.White;

            Button bCancel = new Button();
            bCancel.Text = "取消";
            bCancel.SetBounds(312, 92, 100, 36);
            bCancel.FlatStyle = FlatStyle.Flat;

            bool quit = false;
            string minTag = "min";
            bClose.Click += delegate { quit = true; dlg.Close(); };
            bMin.Click += delegate { dlg.Tag = minTag; dlg.Close(); };
            bCancel.Click += delegate { dlg.Tag = null; dlg.Close(); };
            dlg.Controls.Add(lbl);
            dlg.Controls.Add(bClose);
            dlg.Controls.Add(bMin);
            dlg.Controls.Add(bCancel);
            dlg.ShowDialog(shell);

            if (quit)
            {
                ReallyQuit();
                e.Cancel = false;
            }
            else if (minTag.Equals(dlg.Tag))
            {
                e.Cancel = true;
                shell.Hide();        // hide FIRST: TrySuspendAsync refuses while the WebView is visible
                SuspendWebAsync();   // then freeze the hidden panel until the next show
                ShowTrayBalloon("AgentsKontakt 邮差", "已最小化到托盘，邮差继续在后台投递。");
            }
        }

        void StartDaemon()
        {
            try
            {
                if (shuttingDown || Environment.HasShutdownStarted) return;
                if (daemon != null && !daemon.HasExited) return;

                string ps = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = ps;
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" +
                                Path.Combine(scriptsDir, "watch.ps1") + "\" -Root \"" + dataDir + "\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = dataDir;
                // Every script resolves its root from MAILBOX_ROOT first, so the
                // child must carry it even though -Root is passed explicitly
                // (nested calls without -Root would otherwise fall back to the
                // install directory).
                psi.EnvironmentVariables["MAILBOX_ROOT"] = dataDir;
                daemon = Process.Start(psi);
                if (daemonJob == System.IntPtr.Zero) daemonJob = CreateDaemonJob();
                if (daemonJob != System.IntPtr.Zero)
                    AssignProcessToJobObject(daemonJob, daemon.Handle);
                else
                    Log("daemon job create failed - tree will survive a crash (orphan risk)");
                lastSpawnUtc = DateTime.UtcNow;
                Log("daemon spawned pid=" + daemon.Id + " data=" + dataDir);
            }
            catch (Exception ex)
            {
                Log("daemon spawn failed: " + ex.Message);
            }
        }

        void StopDaemon()
        {
            try
            {
                if (daemon != null && !daemon.HasExited)
                {
                    daemon.Kill();
                }
                Log("daemon stopped by user");
            }
            catch (Exception ex)
            {
                Log("daemon stop failed: " + ex.Message);
            }
        }

        // ---- update download (dashboard ⇄ host bridge) ------------------------
        // The dashboard posts {action:"download-update"|...} via
        // chrome.webview.postMessage; progress/errors travel back as JSON
        // messages the panel renders into its progress UI. 退出即丢进度: the
        // partial file only survives a 暂停→继续 inside one dialog lifetime;
        // cancel / dialog close / panel hide / reload / app exit all delete it.
        // On completion the host owns the package: balloon → detached
        // orchestrator (wizard → delete-on-success → relaunch) → app exits.

        System.Net.Http.HttpResponseMessage dlResp;
        System.IO.Stream dlStream;

        void OnWebMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            Dictionary<string, object> msg = null;
            try
            {
                msg = new System.Web.Script.Serialization.JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(e.WebMessageAsJson);
            }
            catch (Exception ex)
            {
                Log("web message parse failed: " + ex.Message);
                return;
            }
            if (msg == null) return;
            string action = Convert.ToString(msg.ContainsKey("action") ? msg["action"] : "");
            try
            {
                switch (action)
                {
                    case "download-update":
                        StartDownload(Convert.ToString(msg.ContainsKey("url") ? msg["url"] : ""),
                                      Convert.ToString(msg.ContainsKey("name") ? msg["name"] : ""));
                        break;
                    case "dl-pause": PauseDownload(); break;
                    case "dl-resume": ResumeDownload(); break;
                    case "dl-cancel":
                    case "dl-abandon": CancelDownload(); break;
                    case "update-available":
                        SetTrayRedDot(true);
                        string uv = Convert.ToString(msg.ContainsKey("version") ? msg["version"] : "");
                        if (trayRedFor != uv)
                        {
                            trayRedFor = uv;
                            Log("update available v" + uv + " - tray badge + notify");
                            Notifier.NotifyUpdateAvailable(uv);
                        }
                        break;
                    case "update-clear":
                        trayRedFor = null;
                        SetTrayRedDot(false);
                        break;
                    case "dl-state":
                        DlPostJson(new Dictionary<string, object>
                        {
                            { "type", "dl-state" },
                            { "active", dlActive },
                            { "paused", dlPaused },
                            { "received", dlReceived },
                            { "total", dlTotal < 0 ? (object)null : (object)dlTotal }
                        });
                        break;
                    default: break;
                }
            }
            catch (Exception ex)
            {
                Log("web message handling failed (" + action + "): " + ex.Message);
            }
        }

        void StartDownload(string url, string name)
        {
            if (dlActive || dlFinishing) return;   // one download at a time
            if (string.IsNullOrEmpty(url)) return;
            if (string.IsNullOrEmpty(name)) name = "AgentsKontakt-Setup.exe";
            foreach (char c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
            try
            {
                string dir = Path.Combine(dataDir, "updates");
                Directory.CreateDirectory(dir);
                // a fresh start always wipes any stale partial (退出即丢进度)
                string p = Path.Combine(dir, name);
                try { if (File.Exists(p)) File.Delete(p); } catch { }
                dlPath = p; dlUrl = url;
                dlReceived = 0; dlTotal = -1;
                dlPaused = false; dlDiscard = false; dlStall = false; dlActive = true;
                dlLastByteUtc = DateTime.UtcNow; dlLastReportUtc = DateTime.MinValue;
                if (dlClient == null)
                {
                    dlClient = new System.Net.Http.HttpClient();
                    dlClient.Timeout = System.Threading.Timeout.InfiniteTimeSpan;   // the stall watchdog governs
                }
                dlCts = new System.Threading.CancellationTokenSource();
                Log("update download start: " + url + " -> " + p);
                System.Threading.Tasks.Task.Run((Action)delegate { DownloadLoop(false); });
                StartDlWatchdog();
            }
            catch (Exception ex)
            {
                Log("download start failed: " + ex.Message);
                DlFail("start failed: " + ex.Message);
            }
        }

        void DownloadLoop(bool resume)
        {
            dlLoopAlive = true;
            try
            {
                using (var req = new System.Net.Http.HttpRequestMessage(System.Net.Http.HttpMethod.Get, dlUrl))
                {
                    if (resume && dlReceived > 0)
                        req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(dlReceived, null);
                    dlResp = dlClient.SendAsync(req, System.Net.Http.HttpCompletionOption.ResponseHeadersRead,
                                                dlCts.Token).GetAwaiter().GetResult();
                    int code = (int)dlResp.StatusCode;
                    if (code != 200 && code != 206) { DlFail("HTTP " + code); return; }

                    // 断点续传自适应: 206 with the exact requested offset → append;
                    // 200 (server ignored Range) or mismatched Content-Range → discard
                    // the old bytes and restart from zero.
                    bool append = false;
                    if (code == 206 && resume && dlReceived > 0)
                    {
                        var cr = dlResp.Content.Headers.ContentRange;
                        if (cr != null && cr.From.HasValue && cr.From.Value == dlReceived) append = true;
                        else dlReceived = 0;
                    }
                    else if (resume && dlReceived > 0)
                    {
                        dlReceived = 0;
                    }
                    long? len = dlResp.Content.Headers.ContentLength;
                    dlTotal = append ? dlReceived + (len ?? 0) : (len.HasValue ? len.Value : -1);
                    if (dlTotal <= 0) dlTotal = -1;
                    Log("update download " + (append ? "resumed at " + dlReceived : "started") +
                        (dlTotal > 0 ? "/" + dlTotal : "") + " (HTTP " + code + ")");

                    dlStream = dlResp.Content.ReadAsStreamAsync().GetAwaiter().GetResult();
                    using (FileStream fs = new FileStream(dlPath,
                        append && dlReceived > 0 ? FileMode.Append : FileMode.Create,
                        FileAccess.Write, FileShare.None, 8192))
                    {
                        byte[] buf = new byte[81920];
                        while (true)
                        {
                            dlCts.Token.ThrowIfCancellationRequested();
                            int n = dlStream.Read(buf, 0, buf.Length);
                            if (n <= 0) break;
                            fs.Write(buf, 0, n);
                            dlReceived += n;
                            dlLastByteUtc = DateTime.UtcNow;
                            MaybeReportProgress();
                        }
                    }
                    dlStream = null; dlResp = null;

                    if (dlDiscard) { DiscardPartial(); DlPostCancelled(); return; }
                    if (dlPaused) { DlPostPaused(); return; }
                    if (dlTotal >= 0 && dlReceived < dlTotal)
                    {
                        DlFail("connection closed early (" + dlReceived + "/" + dlTotal + ")");
                        return;
                    }
                    DlDone();
                }
            }
            catch (Exception ex)
            {
                dlStream = null; dlResp = null;
                // Cancels surface as OperationCanceledException OR as stream
                // I/O errors (a blocked Read is broken by disposing the stream
                // on the UI thread - see PauseDownload/CancelDownload).
                if (dlDiscard) { DiscardPartial(); DlPostCancelled(); return; }
                if (dlPaused) { DlPostPaused(); return; }
                if (dlStall) { DlFail("30 秒无响应"); return; }
                DlFail(ex.Message);
            }
            finally
            {
                dlLoopAlive = false;
            }
        }

        void PauseDownload()
        {
            if (!dlActive || dlPaused || dlFinishing) return;
            dlPaused = true;
            BreakConnection();
            Log("update download paused at " + dlReceived);
        }

        void ResumeDownload()
        {
            // Paused keeps dlActive=true with the loop exited: resume must pass
            // exactly for that state.
            if (dlFinishing || (dlActive && !dlPaused)) return;
            if (dlPath == null || !File.Exists(dlPath))
            {
                Log("update resume failed: partial gone");
                DlPostJson(new Dictionary<string, object> { { "type", "dl-error" } });
                return;
            }
            dlActive = true; dlPaused = false; dlDiscard = false; dlStall = false;
            dlLastByteUtc = DateTime.UtcNow; dlLastReportUtc = DateTime.MinValue;
            dlCts = new System.Threading.CancellationTokenSource();
            Log("update download resume from " + dlReceived);
            System.Threading.Tasks.Task.Run((Action)delegate { DownloadLoop(true); });
            StartDlWatchdog();
        }

        void CancelDownload()
        {
            if (dlFinishing) return;
            if (dlLoopAlive)
            {
                // streaming loop alive: signal it, the catch discards + replies
                dlDiscard = true; dlActive = false; dlPaused = false;
                BreakConnection();
                return;
            }
            // paused (loop exited) or stale: discard inline (退出即丢进度)
            dlActive = false; dlPaused = false;
            Log("update download cancelled while paused - discarding partial");
            DiscardPartial();
            DlPostCancelled();
        }

        void DiscardDownload()
        {
            // Panel hide / reload / app exit: the progress view is gone, so the
            // partial goes with it. A completed package (dlFinishing) belongs
            // to the orchestrator and must survive.
            if (dlFinishing) return;
            if (dlLoopAlive)
            {
                dlDiscard = true; dlActive = false; dlPaused = false;
                BreakConnection();
                StopDlWatchdog();
                return;
            }
            dlActive = false; dlPaused = false;
            DiscardPartial();
            StopDlWatchdog();
        }

        void BreakConnection()
        {
            try { if (dlCts != null) dlCts.Cancel(); } catch { }
            try { if (dlStream != null) dlStream.Dispose(); } catch { }
        }

        void DiscardPartial()
        {
            try { if (dlPath != null && File.Exists(dlPath)) File.Delete(dlPath); } catch { }
        }

        void DlFail(string why)
        {
            dlActive = false; dlPaused = false;
            StopDlWatchdog();
            DiscardPartial();
            Log("update download failed: " + why);
            DlPostJson(new Dictionary<string, object> { { "type", "dl-error" } });
        }

        void DlPostPaused()
        {
            DlPostJson(new Dictionary<string, object>
            {
                { "type", "dl-paused" },
                { "received", dlReceived },
                { "total", dlTotal < 0 ? (object)null : (object)dlTotal }
            });
        }

        void DlPostCancelled()
        {
            StopDlWatchdog();
            DlPostJson(new Dictionary<string, object> { { "type", "dl-cancelled" } });
        }

        void MaybeReportProgress()
        {
            DateTime now = DateTime.UtcNow;
            if ((now - dlLastReportUtc).TotalMilliseconds < 250) return;
            dlLastReportUtc = now;
            DlPostJson(new Dictionary<string, object>
            {
                { "type", "dl-progress" },
                { "received", dlReceived },
                { "total", dlTotal < 0 ? (object)null : (object)dlTotal }
            });
        }

        void StartDlWatchdog()
        {
            if (dlWatchdog == null)
            {
                dlWatchdog = new System.Windows.Forms.Timer();
                dlWatchdog.Interval = 3000;
                dlWatchdog.Tick += delegate
                {
                    if (!dlActive || dlPaused) return;
                    if ((DateTime.UtcNow - dlLastByteUtc).TotalSeconds >= 30)
                    {
                        Log("update download stalled: 30s without bytes");
                        dlStall = true;
                        BreakConnection();
                    }
                };
            }
            dlWatchdog.Start();
        }

        void StopDlWatchdog()
        {
            try { if (dlWatchdog != null) dlWatchdog.Stop(); } catch { }
        }

        void DlPost(string json)
        {
            try
            {
                if (!shell.IsHandleCreated) return;
                shell.BeginInvoke(new Action(delegate
                {
                    try
                    {
                        if (webReady && web != null && !web.IsDisposed && web.CoreWebView2 != null)
                            web.CoreWebView2.PostWebMessageAsJson(json);
                    }
                    catch { }
                }));
            }
            catch { }
        }

        void DlPostJson(Dictionary<string, object> o)
        {
            string json;
            try { json = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(o); }
            catch { return; }
            DlPost(json);
        }

        void DlDone()
        {
            dlActive = false; dlPaused = false;
            StopDlWatchdog();
            Log("update download complete: " + dlPath + " (" + dlReceived + " bytes)");
            if (dlFinishing) return;
            dlFinishing = true;
            DlPostJson(new Dictionary<string, object>
            {
                { "type", "dl-done" },
                { "path", dlPath }
            });
            try
            {
                ShowTrayBalloon("AgentsKontakt 邮差", "更新包下载完成，即将退出应用并打开安装程序。");
                StartUpdateOrchestrator();
            }
            catch (Exception ex)
            {
                Log("update orchestration failed: " + ex.Message);
            }
            // Ownership of dlPath has passed to the orchestrator: a later
            // DiscardDownload must not delete the completed package.
            dlPath = null;
            var t = new System.Windows.Forms.Timer { Interval = 1200 };
            t.Tick += delegate { t.Stop(); t.Dispose(); ReallyQuit(); };
            t.Start();
        }

        static string PsQuote(string s)
        {
            return "'" + (s ?? "").Replace("'", "''") + "'";
        }

        void StartUpdateOrchestrator()
        {
            // Detached helper that outlives this process: opens the interactive
            // Setup wizard pre-filled with this install, waits, deletes the
            // package only when the newest install log carries the "Install
            // finished" milestone, and relaunches the postman if nothing runs.
            string ps = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            string setupLit = PsQuote(dlPath);
            string installLit = PsQuote(installDir);
            string dataLit = PsQuote(dataDir);
            string exeLit = PsQuote(Path.Combine(installDir, "app", "AgentsKontaktPost.exe"));
            string cmd =
                "$p = Start-Process -FilePath " + setupLit +
                " -ArgumentList @('--install-dir'," + installLit + ",'--data-dir'," + dataLit + ") -PassThru -Wait; " +
                "$ok = $false; " +
                "$log = Get-ChildItem -Path (Join-Path " + dataLit + " 'logs') -Filter 'install-*.log' -ErrorAction SilentlyContinue | " +
                "Sort-Object LastWriteTime -Descending | Select-Object -First 1; " +
                "if ($log) { $hit = Select-String -Path $log.FullName -Pattern 'Install finished' -Quiet -ErrorAction SilentlyContinue; if ($hit) { $ok = $true; } }; " +
                "if ($ok) { Remove-Item -LiteralPath " + setupLit + " -Force -ErrorAction SilentlyContinue; }; " +
                "Start-Sleep -Milliseconds 800; " +
                "if (-not (Get-Process -Name 'AgentsKontaktPost' -ErrorAction SilentlyContinue)) { " +
                "Start-Process -FilePath " + exeLit + " -ArgumentList '--minimized' }";
            var psi = new ProcessStartInfo
            {
                FileName = ps,
                Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -Command " + cmd,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = dataDir
            };
            Process.Start(psi);
            Log("update orchestrator launched");
        }

        void MonitorTick(object sender, EventArgs e)
        {
            try
            {
                if (reallyQuit || shuttingDown || Environment.HasShutdownStarted) return;
                // Heal a shell that became visible without going through
                // ShowShell (observed at --minimized boot on 2026-10-29: the
                // window showed white for a long time because the deferred
                // webview was never initialized by whatever showed it).
                if (webEnabled && !webStarted && shell.Visible)
                {
                    Log("shell visible without webview init - initializing (self-heal)");
                    SyncSplash();   // cover the re-init with the loading layer
                    InitWebAsync();
                }
                // Disposed panel (logoff/close race): drop the ready flag so
                // the suspend self-heal below stops erroring every 10s.
                if (webReady && web != null && web.IsDisposed) webReady = false;
                // Self-heal the panel freeze: if the shell sits hidden (tray
                // mode) while the web is running, the minimize-time suspend
                // lost a race somewhere - re-try at most every 10s. A running
                // panel hidden this way burns a render core all night.
                if (webReady && !shell.Visible && !webSuspended &&
                    (DateTime.UtcNow - lastSuspendTryUtc).TotalSeconds >= 10)
                {
                    SuspendWebAsync();
                }
                // Tray self-heal with backoff: this used to re-add every 5s tick,
                // hammering Shell_NotifyIcon forever when the shell kept refusing
                // the registration (2026-10-26: NIM_ADD=False every 5s for minutes).
                if (!trayUp && (DateTime.UtcNow - lastTrayTryUtc).TotalSeconds >= trayRetrySec)
                {
                    lastTrayTryUtc = DateTime.UtcNow;
                    CreateTray();
                    trayRetrySec = trayUp ? 5 : 60;   // failing registration: retry at most once a minute
                }
                if (daemon == null || daemon.HasExited)
                {
                    // Exponential backoff: 15s, 30s, 60s, 120s, 240s cap. A
                    // crash-looping daemon used to respawn every 15s forever,
                    // each spawn a full powershell + WMI adoption sweep.
                    int wait = (int)Math.Min(15.0 * Math.Pow(2, Math.Min(restartCount, 4)), 240.0);
                    if ((DateTime.UtcNow - lastSpawnUtc).TotalSeconds < wait) return;
                    // Office-alive gate: a fresh watch.heartbeat means SOME loop
                    // is actively sweeping this root (e.g. a manually started
                    // office). Respawning over it caused kill/respawn ping-pong
                    // storms - wait until the external office goes quiet.
                    try
                    {
                        string hb = Path.Combine(dataDir, "logs", "watch.heartbeat");
                        if (File.Exists(hb) && (DateTime.Now - File.GetLastWriteTime(hb)).TotalSeconds < 30)
                        {
                            lastSpawnUtc = DateTime.UtcNow;
                            // With an external office resident (scheduled task)
                            // this fired on every monitor tick - log at most
                            // once every 5 minutes.
                            if ((DateTime.UtcNow - lastOfficeAliveLogUtc).TotalMinutes >= 5)
                            {
                                lastOfficeAliveLogUtc = DateTime.UtcNow;
                                Log("office alive elsewhere (fresh heartbeat) - not respawning");
                            }
                            return;
                        }
                    }
                    catch { }
                    restartCount++;
                    Log("daemon not running - respawn (count=" + restartCount + ")");
                    StartDaemon();
                }
                else
                {
                    // Only a daemon that stayed up a while counts as healthy;
                    // resetting on every live tick made a crash-looper never
                    // accumulate backoff.
                    if ((DateTime.UtcNow - lastSpawnUtc).TotalMinutes >= 5) restartCount = 0;
                    UpdateTrayTip("AgentsKontakt 邮差 - 投递中 (pid " + daemon.Id + ")");
                }
            }
            catch (Exception ex)
            {
                Log("monitor error: " + ex.Message);
            }
        }

        // --- splash ------------------------------------------------------------
        // Dark loading cover shown while the WebView2 browser initializes (5-9s
        // cold at first show). Reports progress; on failure/timeout it carries
        // the reason instead of leaving a white void.
        void BuildSplash()
        {
            splash = new Panel();
            splash.Dock = DockStyle.Fill;
            splash.BackColor = System.Drawing.Color.FromArgb(18, 20, 26);
            splash.Visible = false;

            TableLayoutPanel tl = new TableLayoutPanel();
            tl.Dock = DockStyle.Fill;
            tl.BackColor = splash.BackColor;
            tl.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            tl.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            tl.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            tl.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            tl.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));

            PictureBox pic = new PictureBox();
            try { pic.Image = new System.Drawing.Icon(Path.Combine(installDir, "app", "post.ico"), 32, 32).ToBitmap(); }
            catch { try { pic.Image = new System.Drawing.Icon(Path.Combine(installDir, "app", "post.ico"), 16, 16).ToBitmap(); } catch { } }
            pic.SizeMode = PictureBoxSizeMode.CenterImage;
            pic.Size = new System.Drawing.Size(64, 64);
            pic.Margin = new System.Windows.Forms.Padding(0, 0, 0, 18);
            pic.Visible = pic.Image != null;

            Label title = new Label();
            title.Text = "AgentsKontakt 邮差";
            title.Font = new System.Drawing.Font("Segoe UI", 20F, System.Drawing.FontStyle.Bold);
            title.ForeColor = System.Drawing.Color.FromArgb(235, 238, 245);
            title.AutoSize = true;
            title.Margin = new System.Windows.Forms.Padding(0, 0, 0, 10);

            splashStatus = new Label();
            splashStatus.Text = "";
            splashStatus.Font = new System.Drawing.Font("Segoe UI", 10F);
            splashStatus.ForeColor = System.Drawing.Color.FromArgb(148, 158, 170);
            splashStatus.AutoSize = true;
            splashStatus.Margin = new System.Windows.Forms.Padding(0, 0, 0, 6);

            Label ver = new Label();
            ver.Text = "v" + Program.Version;
            ver.Font = new System.Drawing.Font("Segoe UI", 8F);
            ver.ForeColor = System.Drawing.Color.FromArgb(96, 104, 116);
            ver.AutoSize = true;
            ver.Margin = new System.Windows.Forms.Padding(0);

            tl.Controls.Add(pic, 0, 1);
            tl.Controls.Add(title, 0, 2);
            tl.Controls.Add(splashStatus, 0, 3);
            tl.Controls.Add(ver, 0, 4);
            foreach (Control c in tl.Controls) c.Anchor = AnchorStyles.None;   // center in cell
            splash.Controls.Add(tl);

            splashAnim = new System.Windows.Forms.Timer();
            splashAnim.Interval = 450;
            splashAnim.Tick += delegate
            {
                splashDots = (splashDots + 1) % 4;
                splashStatus.Text = splashBase + new string('.', splashDots);
            };

            shell.Controls.Add(splash);   // added after web: sits on top when visible
            splash.BringToFront();
        }

        void SetSplashStatus(string text, bool animate)
        {
            splashBase = text;
            splashDots = 0;
            splashStatus.Text = text;
            if (animate) { if (!splashAnim.Enabled) splashAnim.Start(); }
            else splashAnim.Stop();
        }

        void SyncSplash()
        {
            bool need = webEnabled && !webReady;
            splash.Visible = need;
            if (need)
            {
                splash.BringToFront();
                if (!splashAnim.Enabled) splashAnim.Start();
            }
            else splashAnim.Stop();
        }

        async void InitWebAsync()
        {
            webStarted = true;
            SetSplashStatus("正在启动面板", true);
            // Watchdog: a stalled EnsureCoreWebView2Async (hidden-panel init,
            // boot-time races) used to leave a permanently white panel with no
            // ready/failed log. 20s without "webview ready" -> open the
            // dashboard in the browser so the user is never stuck on white.
            System.Windows.Forms.Timer watchdog = new System.Windows.Forms.Timer();
            watchdog.Interval = 20000;
            watchdog.Tick += delegate
            {
                watchdog.Stop();
                watchdog.Dispose();
                if (webReady) return;
                Log("webview init watchdog: no 'ready' after 20s - opening dashboard in browser");
                SetSplashStatus("面板加载超时，已改用浏览器打开看板", false);
                try { Process.Start(Path.Combine(dataDir, "dashboard", "dashboard.html")); } catch { }
                ShowTrayBalloon("AgentsKontakt 邮差",
                    "面板加载超时，已改用浏览器打开看板。邮差仍在后台投递。");
            };
            watchdog.Start();
            try
            {
                string userData = Path.Combine(dataDir, "app", "userdata");
                Directory.CreateDirectory(userData);
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, userData);
                await web.EnsureCoreWebView2Async(env);
                web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                web.CoreWebView2.Settings.IsStatusBarEnabled = false;
                // Popups (the panel's 立即更新 button, any future external
                // link) belong in the user's real browser, not in a tray
                // panel: route NewWindowRequested to the system default
                // browser instead of spawning a WebView2 popup window.
                web.CoreWebView2.NewWindowRequested += delegate (object ns, CoreWebView2NewWindowRequestedEventArgs nw)
                {
                    nw.Handled = true;
                    try { Process.Start(new ProcessStartInfo(nw.Uri) { UseShellExecute = true }); }
                    catch (Exception openEx) { Log("open external link failed: " + openEx.Message); }
                };
                // Panel ⇄ host bridge: the dashboard posts update-download
                // actions; progress/errors travel back as JSON messages.
                web.CoreWebView2.WebMessageReceived += OnWebMessage;
                // A panel reload (F5 / navigation) removes the progress view:
                // the discard rule (退出即丢进度) then applies host-side without
                // needing a page message.
                web.CoreWebView2.ContentLoading += delegate
                {
                    Log("panel reloading - discarding any update download");
                    try { shell.BeginInvoke(new Action(DiscardDownload)); } catch { }
                };
                // Browser death while the control lives: without this the only
                // symptom was suspend failing into the log every 10s forever.
                // Renderer failures recover in place; only browser exit is fatal.
                web.CoreWebView2.ProcessFailed += delegate (object ps, CoreWebView2ProcessFailedEventArgs pf)
                {
                    if (pf.ProcessFailedKind != CoreWebView2ProcessFailedKind.BrowserProcessExited) return;
                    webReady = false;
                    webStarted = false;
                    Log("webview browser process exited - control will be rebuilt");
                    // Rebuild off the event call: disposing a control from
                    // inside its own event is unsafe. The self-heal tick (or
                    // the next show) then initializes the fresh control.
                    try { shell.BeginInvoke(new Action(RebuildWebView)); } catch { }
                };
                string url = "file:///" + dataDir.Replace('\\', '/') + "/dashboard/dashboard.html";
                web.CoreWebView2.Navigate(url);
                webReady = true;
                watchdog.Stop();
                watchdog.Dispose();
                SyncSplash();   // webReady now: splash hides itself, dashboard shows
                Log("webview ready -> " + url);
            }
            catch (Exception ex)
            {
                watchdog.Stop();
                watchdog.Dispose();
                Log("webview init failed: " + ex.Message);
                webReady = false;
                if (ex.Message.IndexOf("browser process", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    // A crashed browser poisons its control (EnsureCoreWebView2Async
                    // then fails forever with "instance no longer valid"): only a
                    // rebuilt control hosts a fresh browser. Hand the retry back
                    // to the self-heal tick / next show instead of falling back.
                    RebuildWebView();
                    webStarted = false;
                    return;
                }
                SetSplashStatus("面板初始化失败，已改用浏览器打开看板", false);
                // Graceful degradation: no WebView2 runtime on this machine.
                // Open the dashboard in the default browser instead of blocking
                // the user with a modal dialog - the postman keeps delivering.
                try { Process.Start(Path.Combine(dataDir, "dashboard", "dashboard.html")); } catch { }
                ShowTrayBalloon("AgentsKontakt 邮差",
                    "WebView2 面板不可用，已改用浏览器打开看板。邮差仍在后台投递。\r\n" + ex.Message);
            }
        }

        void Log(string line)
        {
            try
            {
                File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " | " + line + "\r\n");
            }
            catch { }
        }
    }
}
