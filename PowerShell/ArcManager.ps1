# ArcManager.ps1 (v2) - multi-account helper for the official Arc client
# Works on Windows 7 (PowerShell 2.0+). No install needed.
#
# Flow per row: SIGN IN -> starts a fresh Arc.exe -> types the username and password into
#   Arc's login window and presses Enter -> YOU click Play in Arc -> manager sees Arc start
#   launcher.exe -> closes that Arc right away.
#
# Accounts are saved in PLAIN TEXT in %AppData%\ArcManager\accounts.txt (username<TAB>password).

# ---------- settings ----------
# All settings are stored in %AppData%\ArcManager\ArcManager.ini (the same file the C++ version uses).
# Change them with the gear button in the program. To edit the file by hand, save it and restart the program.
# A copy of ArcManager.ini placed next to this script is used instead of that one (portable mode).
# Program version, shown in the log and in the settings window. >>> Change it here when you release a new version. <<<
$AppVersion = 'v6.NOV.2026'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:APPDATA 'ArcManager'
$IniFile   = Join-Path $ConfigDir 'ArcManager.ini'
if (Test-Path (Join-Path $ScriptDir 'ArcManager.ini')) { $IniFile = Join-Path $ScriptDir 'ArcManager.ini' }

# RunElevated (PowerShell version only) is read first, because it decides whether this copy restarts as administrator
$RunElevated = $true
if (Test-Path $IniFile) {
    try {
        $m = [regex]::Match([System.IO.File]::ReadAllText($IniFile), '(?im)^\s*RunElevated\s*=\s*(\S+)')
        if ($m.Success -and @('0', 'false', 'no', 'off') -contains $m.Groups[1].Value.ToLower()) { $RunElevated = $false }
    } catch { }
}
# -----------------------------------------------

# Arc may run elevated; Windows blocks keystrokes/closing from a non-elevated program,
# so the manager restarts itself as administrator once.
$nowAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($RunElevated -and -not $nowAdmin) {
    $self = $MyInvocation.MyCommand.Path
    $relaunched = $false
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "' + $self + '"')
        $relaunched = $true
    } catch { }
    if ($relaunched) { exit }
}

# only one manager at a time (the C++ version uses the same name, so the two never run together)
$createdNew = $false
$script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Local\ArcManager_SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    [void][System.Windows.Forms.MessageBox]::Show('ArcManager is already running.', 'ArcManager', 'OK', 'Information')
    exit
}


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinHelper {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr hAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);

    // Hidden Arc Mode: moves every top-level window of the given processes off-screen (moved, not hidden or minimized, so it
    // still counts as visible and keeps its real size for the Start click). Windows that are already off-screen are skipped.
    public static void MoveOffScreen(int[] pids) {
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, (int)pid) < 0) return true;
            RECT r;
            if (GetWindowRect(h, out r) && r.L <= -30000) return true;
            SetWindowPos(h, IntPtr.Zero, -32000, -32000, 0, 0, 0x0001 | 0x0004 | 0x0010);   // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
            return true;
        }, IntPtr.Zero);
    }
    // largest visible top-level window belonging to any of the given process ids
    public static IntPtr FindVisibleWindow(int[] pids) {
        IntPtr best = IntPtr.Zero;
        int bestArea = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, (int)pid) < 0) return true;
            if (!IsWindowVisible(h)) return true;
            RECT r;
            GetWindowRect(h, out r);
            int w = r.R - r.L;
            int ht = r.B - r.T;
            if (w < 200 || ht < 150) return true;
            int area = w * ht;
            if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
    // the launcher/patcher window briefly exists at an undersized / not-yet-laid-out size right after it is created
    // (the same kind of early-placeholder issue Arc's own main window had); only once its client area looks like
    // the real, fully loaded window should it be clicked (Start was confirmed at (853, 557) on a 984 x 744 client).
    public static bool ClientAtLeast(IntPtr h, int minW, int minH) {
        RECT r;
        if (!GetClientRect(h, out r)) return false;
        return (r.R - r.L) >= minW && (r.B - r.T) >= minH;
    }
    // text description of every top-level window of the given processes (for the debug log)
    public static string DescribeWindows(int[] pids) {
        StringBuilder sb = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, (int)pid) < 0) return true;
            RECT r;
            GetWindowRect(h, out r);
            StringBuilder t = new StringBuilder(256);
            StringBuilder c = new StringBuilder(256);
            GetWindowText(h, t, 256);
            GetClassName(h, c, 256);
            sb.Append("[hwnd=" + h.ToInt64() + " pid=" + pid + " vis=" + IsWindowVisible(h) + " " + (r.R - r.L) + "x" + (r.B - r.T) + " class='" + c + "' title='" + t + "'] ");
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr rgn, uint flags);
    // paints a window and all its children right now (INVALIDATE | ERASE | ALLCHILDREN | UPDATENOW): used while a dragged row scrolls the list
    public static void RedrawNow(IntPtr h) { RedrawWindow(h, IntPtr.Zero, IntPtr.Zero, 0x0001u | 0x0004u | 0x0080u | 0x0100u); }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, string lp);
    // grey placeholder text inside an empty text box (EM_SETCUEBANNER)
    public static void SetCue(IntPtr h, string text) { SendMessage(h, 0x1501, (IntPtr)1, text); }
    public static int GetForegroundPid() {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return (int)pid;
    }
}
public class IniFile {
    // reads / writes the [Settings] section; WritePrivateProfileString keeps comments and unknown lines in the file
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetPrivateProfileString(string sec, string key, string def, StringBuilder buf, int size, string file);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool WritePrivateProfileString(string sec, string key, string val, string file);
    public static string Get(string file, string key, string def) {
        StringBuilder sb = new StringBuilder(1024);
        GetPrivateProfileString("Settings", key, def, sb, 1024, file);
        return sb.ToString();
    }
    public static bool Put(string file, string key, string val) { return WritePrivateProfileString("Settings", key, val, file); }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool MoveFileEx(string src, string dst, uint flags);
    // moves src over dst in one step (MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH), so a half-written file can never be left behind
    // removes a setting from the settings file (a null value deletes the line)
    public static bool Remove(string file, string key) { return WritePrivateProfileString("Settings", key, null, file); }
    public static bool ReplaceFile(string src, string dst) { return MoveFileEx(src, dst, 0x1 | 0x8); }
    public static int LastError() { return Marshal.GetLastWin32Error(); }
}
public class WinTitle {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")] static extern IntPtr SendMessageTimeoutSet(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")] static extern IntPtr SendMessageTimeoutGet(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    public static string ClassOf(IntPtr hWnd) {
        StringBuilder sb = new StringBuilder(64);
        GetClassName(hWnd, sb, 64);
        return sb.ToString();
    }
    // Gives every large visible top-level window of the process the title (WM_SETTEXT with SMTO_ABORTIFHUNG: a frozen
    // window can never freeze the manager). Returns "found;renamed;class".
    public static string Rename(int pid, string title) {
        int found = 0;
        int renamed = 0;
        string cls = "";
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p != (uint)pid || !IsWindowVisible(h)) return true;
            RECT r;
            GetWindowRect(h, out r);
            if (r.Right - r.Left < 200 || r.Bottom - r.Top < 150) return true;
            found++;
            StringBuilder sb = new StringBuilder(512);
            UIntPtr res;
            if (SendMessageTimeoutGet(h, 0x000D, (IntPtr)512, sb, 2, 500, out res) == IntPtr.Zero) return true;
            if (sb.ToString() == title) return true;
            if (SendMessageTimeoutSet(h, 0x000C, UIntPtr.Zero, title, 2, 1000, out res) != IntPtr.Zero) {
                if (renamed == 0) cls = ClassOf(h);
                renamed++;
            }
            return true;
        }, IntPtr.Zero);
        return found + ";" + renamed + ";" + cls;
    }
}
// ---- Hidden Login: runs the REAL, official Arc sign-in flow (launch, type credentials, click Play) while
// every Arc window stays hidden. This never bypasses Arc's own authentication - it only keeps Arc's own
// windows off-screen while Arc does its normal, legitimate sign-in. The whole thing runs on its own
// background thread so PowerShell 2's GUI thread is never blocked; the GUI side polls HiddenLoginState.
public class HiddenLoginSettings {
    public string ArcPath;
    public string Username;
    public string Password;
    public int KeyDelayMs;
    public int CharDelayMs;
    public int PostTabDelayMs;
    public int PostFieldDelayMs;
    public int HideSettleDelayMs;
    public int SignInTimeoutSec;
    public int SignInPollIntervalMs;
    public int MainWindowInitialDelayMs;
    public int MainWindowTimeoutSec;
    public int MainWindowPollIntervalMs;
    public int PatcherWaitTimeoutSec;
    public int PatcherWaitPollIntervalMs;
    public bool ClickPatcherStart;
    public int PatcherStartPollIntervalMs;
    public int PatcherStartTimeoutSec;
}
// Cross-thread status, polled (never pushed) from the GUI's 1-second timer tick - the safe pattern on PS2,
// where a background .NET thread cannot reliably call back into a PowerShell script block.
public class HiddenLoginState {
    public volatile bool Cancel;
    public volatile bool Done;
    public volatile int Result;   // 0=Success 1=ArcLaunchFailed 2=SignInWindowNotFound 3=MainWindowNotFound 4=Cancelled
}
public class HiddenLogin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr hAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr PostMessage(IntPtr h, uint msg, UIntPtr wp, IntPtr lp);

    const uint WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_CHAR = 0x0102;
    const uint WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
    const int SW_HIDE = 0;
    const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
    const int VK_TAB = 0x09, VK_RETURN = 0x0D, VK_END = 0x23, VK_BACK = 0x08;

    static volatile bool hiderRunning;
    static volatile bool hiderPaused;

    static List<IntPtr> FindArcWindows() {
        List<IntPtr> list = new List<IntPtr>();
        List<int> pids = new List<int>();
        foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName("Arc")) pids.Add(p.Id);
        if (pids.Count == 0) return list;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pids.Contains((int)pid)) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }
    static string GetTitle(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        return sb.ToString();
    }
    static IntPtr FindWindowByTitle(string title) {
        foreach (IntPtr h in FindArcWindows()) if (GetTitle(h) == title) return h;
        return IntPtr.Zero;
    }
    // the largest window titled exactly "Arc" (its real main window), at least 800x500
    static IntPtr FindLargestArcWindow() {
        IntPtr best = IntPtr.Zero;
        int bestArea = 0;
        foreach (IntPtr h in FindArcWindows()) {
            if (GetTitle(h) != "Arc") continue;
            RECT r;
            GetWindowRect(h, out r);
            int w = r.R - r.L, ht = r.B - r.T;
            if (w < 800 || ht < 500) continue;
            int area = w * ht;
            if (area > bestArea) { bestArea = area; best = h; }
        }
        return best;
    }
    static void HideAllArcWindows() {
        foreach (IntPtr h in FindArcWindows()) {
            ShowWindow(h, SW_HIDE);
            SetWindowPos(h, IntPtr.Zero, -32000, -32000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }
    static void KillAllArc() {
        foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName("Arc")) {
            try { p.Kill(); } catch { }
        }
    }
    static void SendKeyPress(IntPtr h, int vk, int delayMs) {
        PostMessage(h, WM_KEYDOWN, (UIntPtr)(uint)vk, IntPtr.Zero);
        System.Threading.Thread.Sleep(delayMs);
        PostMessage(h, WM_KEYUP, (UIntPtr)(uint)vk, IntPtr.Zero);
    }
    static void SendCharText(IntPtr h, string text, int delayMs) {
        if (text == null) return;
        foreach (char c in text) {
            PostMessage(h, WM_CHAR, (UIntPtr)(uint)c, IntPtr.Zero);
            System.Threading.Thread.Sleep(delayMs);
        }
    }
    static void ClearTextField(IntPtr h, int delayMs) {
        SendKeyPress(h, VK_END, delayMs);
        for (int i = 0; i < 40; i++) SendKeyPress(h, VK_BACK, delayMs);
    }
    static void SendClickAt(IntPtr h, int x, int y) {
        IntPtr lp = (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF));
        PostMessage(h, WM_MOUSEMOVE, UIntPtr.Zero, lp);
        PostMessage(h, WM_LBUTTONDOWN, (UIntPtr)1, lp);
        System.Threading.Thread.Sleep(30);
        PostMessage(h, WM_LBUTTONUP, UIntPtr.Zero, lp);
    }
    static void Log(string msg) {
        try {
            string dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData) + "\\ArcManager";
            if (!System.IO.Directory.Exists(dir)) System.IO.Directory.CreateDirectory(dir);
            System.IO.File.AppendAllText(dir + "\\hidden_debug.log", DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg + "\r\n");
        } catch { }
    }
    static void HiderLoop() {
        while (hiderRunning) {
            if (!hiderPaused) HideAllArcWindows();
            System.Threading.Thread.Sleep(1000);   // a tight loop fights Arc for its own message queue; once a second is plenty
        }
    }
    // spawns the background thread and returns immediately; state is polled by the GUI thread afterwards
    public static void Start(HiddenLoginSettings settings, HiddenLoginState state) {
        System.Threading.Thread t = new System.Threading.Thread(delegate() { Run(settings, state); });
        t.IsBackground = true;
        t.Start();
    }
    // exposes the message-based click used throughout this class, for Show Arc Mode's GUI-thread auto-click-Start loop
    public static void ClickAt(IntPtr h, int x, int y) { SendClickAt(h, x, y); }
    // exposes the "real main/library window" finder for Show Arc Mode's GUI-thread auto-click-Play phase (ClickArcPlay)
    public static IntPtr FindArcMainWindow() { return FindLargestArcWindow(); }
    // Result codes (match the C++ HiddenLoginResult enum exactly): 0=Success 1=ArcLaunchFailed 2=SignInWindowNotFound
    // 3=MainWindowNotFound 4=PatcherNotDetected 5=Cancelled
    static void Run(HiddenLoginSettings s, HiddenLoginState state) {
        try {
            KillAllArc();   // always start clean: Arc cannot be launched again while an instance of it is already running
            System.Threading.Thread.Sleep(500);

            hiderRunning = true;
            hiderPaused = false;
            System.Threading.Thread hider = new System.Threading.Thread(new System.Threading.ThreadStart(HiderLoop));
            hider.IsBackground = true;
            hider.Start();
            System.Threading.Thread.Sleep(50);

            if (state.Cancel) { hiderRunning = false; KillAllArc(); state.Result = 5; state.Done = true; return; }

            try {
                System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo(s.ArcPath);
                psi.WorkingDirectory = System.IO.Path.GetDirectoryName(s.ArcPath);
                System.Diagnostics.Process.Start(psi);
            } catch (Exception ex) {
                Log("ArcLaunchFailed: " + ex.Message);
                hiderRunning = false;
                state.Result = 1; state.Done = true;
                return;
            }
            Log("hidden login: started Arc.exe (invisibly)");

            IntPtr signIn = IntPtr.Zero;
            int waited = 0;
            int timeoutMs = s.SignInTimeoutSec * 1000;
            while (waited < timeoutMs) {
                signIn = FindWindowByTitle("Sign In");
                if (signIn != IntPtr.Zero || state.Cancel) break;
                System.Threading.Thread.Sleep(s.SignInPollIntervalMs);
                waited += s.SignInPollIntervalMs;
            }
            if (state.Cancel) { hiderRunning = false; KillAllArc(); state.Result = 5; state.Done = true; return; }
            if (signIn == IntPtr.Zero) {
                Log("hidden login: the Sign In window never appeared");
                hiderRunning = false; KillAllArc();
                state.Result = 2; state.Done = true;
                return;
            }

            hiderPaused = true;
            ShowWindow(signIn, SW_HIDE);
            System.Threading.Thread.Sleep(s.HideSettleDelayMs);

            SendKeyPress(signIn, VK_TAB, s.KeyDelayMs);
            System.Threading.Thread.Sleep(s.PostTabDelayMs);
            ClearTextField(signIn, s.KeyDelayMs);
            SendCharText(signIn, s.Username, s.CharDelayMs);
            System.Threading.Thread.Sleep(s.PostFieldDelayMs);

            SendKeyPress(signIn, VK_TAB, s.KeyDelayMs);
            System.Threading.Thread.Sleep(s.PostTabDelayMs);
            ClearTextField(signIn, s.KeyDelayMs);
            SendCharText(signIn, s.Password, s.CharDelayMs);
            System.Threading.Thread.Sleep(s.PostFieldDelayMs);

            SendKeyPress(signIn, VK_RETURN, s.KeyDelayMs);
            Log("hidden login: submitted username and password (hidden)");
            hiderPaused = false;

            if (state.Cancel) { hiderRunning = false; KillAllArc(); state.Result = 5; state.Done = true; return; }
            System.Threading.Thread.Sleep(s.MainWindowInitialDelayMs);   // the real window needs a moment to exist; too soon finds an unfinished placeholder instead

            IntPtr main = IntPtr.Zero;
            waited = 0;
            timeoutMs = s.MainWindowTimeoutSec * 1000;
            while (waited < timeoutMs) {
                main = FindLargestArcWindow();
                if (main != IntPtr.Zero || state.Cancel) break;
                System.Threading.Thread.Sleep(s.MainWindowPollIntervalMs);
                waited += s.MainWindowPollIntervalMs;
            }
            if (state.Cancel) { hiderRunning = false; KillAllArc(); state.Result = 5; state.Done = true; return; }
            if (main == IntPtr.Zero) {
                Log("hidden login: signed in, but Arc's main window never appeared");
                hiderRunning = false; KillAllArc();
                state.Result = 3; state.Done = true;
                return;
            }

            SendClickAt(main, 288, 405);   // Arc's Play button (confirmed coordinate); Arc is killed right after this anyway
            Log("hidden login: clicked Play");
            System.Threading.Thread.Sleep(500);
            hiderRunning = false;

            // waits for the real launch to begin, then ALWAYS kills Arc - patcher seen, not seen, or cancelled makes no
            // difference (this is the step that was missing before: Arc used to just sit there after Play was clicked)
            bool patcherSeen = false;
            int pwaited = 0;
            int ptimeout = s.PatcherWaitTimeoutSec * 1000;
            while (pwaited < ptimeout) {
                if (System.Diagnostics.Process.GetProcessesByName("launcher").Length > 0 ||
                    System.Diagnostics.Process.GetProcessesByName("patcher").Length > 0) { patcherSeen = true; break; }
                if (state.Cancel) break;
                System.Threading.Thread.Sleep(s.PatcherWaitPollIntervalMs);
                pwaited += s.PatcherWaitPollIntervalMs;
            }
            bool cancelledHere = !patcherSeen && state.Cancel;
            KillAllArc();   // ALWAYS kill Arc at the end
            if (cancelledHere) { state.Result = 5; state.Done = true; return; }
            Log(patcherSeen ? "hidden login: launcher/patcher detected - done" : "hidden login: the launcher/patcher never appeared");
            // returns right away so the "Obtaining ARC / PWI TOKEN Now" popup closes the instant the launcher/patcher
            // is detected; auto-clicking Start (if on) is handled afterwards by the same tick-based logic Show Arc
            // Mode uses (see Update-State), with its own "Starting Game" popup - the same behavior either way
            state.Result = patcherSeen ? 0 : 4;
            state.Done = true;
        } catch (Exception ex) {
            Log("unexpected error: " + ex);
            hiderRunning = false;
            try { KillAllArc(); } catch { }
            state.Result = 3;
            state.Done = true;
        }
    }
}
'@

$AccountsFile = Join-Path $ConfigDir 'accounts.txt'
$LogFile      = Join-Path $ConfigDir 'debug.log'
$PrevLogFile  = Join-Path $ConfigDir 'debug.previous.log'
$SessionFile  = Join-Path $ConfigDir 'session.txt'
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }

# ---------- settings file ----------
$DefaultIniText = @'
; ArcManager settings.
; The easiest way to change them is the gear button in the program. If you edit this file by hand,
; save it and restart the program. 1 = on, 0 = off.
; (A copy of this file placed next to the program is used instead of this one.)
[Settings]
; Full path to Arc.exe (the file must be named Arc.exe)
ArcPath=C:\Program Files (x86)\Arc\Arc.exe
; Window size. The window can also be resized by hand; RememberWindowSize=1 saves the size when you close the program.
WindowWidth=1280
WindowHeight=720
RememberWindowSize=1
AutoFill=1
; Tab presses before the username box / between username and password
UsernameFocusTabs=1
FieldSeparatorTabs=1
LoginDelayMs=3000
MinWaitSeconds=6
WindowTimeoutSeconds=40
; Login pop-up and typing. The official game needs none of this right now (the defaults do nothing); it is here in case Arc ever shows a
; message before its login page. PopupKey: enter or escape, pressed EntersBefore times (0 = none), then a pause in milliseconds
PopupKey=enter
EntersBefore=0
PauseAfterPopupMs=1500
; Backspaces pressed before typing a box, to remove old text (0 = none), and whether Enter is pressed after the password (1 = yes)
ClearBackspaces=0
EnterAfterPassword=1
TimeoutSeconds=300
PendingTimeoutSeconds=600
ConfirmStop=0
KillArcOnStart=1
DebugLog=1
; Show a note at the bottom of the window that accounts are saved as plain text: 1 = yes, 0 = no
ShowStorageHint=0
; Rename each game client window to the Notes text of its row: 1 = yes
RenameGameWindows=1
; Windows are re-checked every second for this many seconds after a game client starts (the game opens and closes windows while loading)
RenameDurationSeconds=180
; Messages such as Stopped / Cancelled / Timed out go back to Idle after this many seconds (0 = never)
StatusResetSeconds=30
; Background image. Leave BackgroundImage blank to use background.png/jpg/jpeg/bmp/gif found next to the program or in %AppData%\ArcManager;
; if none is found, the built-in image is used.
BackgroundImage=
; BackgroundMode: fill (cover, cropped) | fit (whole image, bars) | stretch | tile | center
BackgroundMode=fill
; BackgroundDim: 0 = image as-is ... 1 = black (keeps the text readable)
BackgroundDim=0.5
; ---- Private servers (used while the switch at the top of the main window is on PRIVATE; Arc is not used then) ----
PrivateMode=0
; the program to start (the game client or a launcher; it starts in its own folder) and its command-line flags
PrivateClientPath=
PrivateFlags=game:cpw nocheck startbypatcher console:1
; show a warning every time you switch to Private Servers: 1 = yes, 0 = no
PrivateShowWarning=1
; process name(s) of the real game client, separated by commas
PrivateProcessNames=elementclient.exe,elementclient_64.exe
; give up if the game client / its window does not appear within this many seconds, then wait this long before the first key
PrivateWindowWaitSeconds=90
PrivateFirstKeyDelaySeconds=6
; the typing sequence: Enter or Escape (start-up pop-up) x N, pause, username, Tab x N, password, Enter. Pauses are in milliseconds
; PrivatePopupKey: the key that clears the start-up pop-up of the client: enter or escape
PrivatePopupKey=enter
PrivateEntersBefore=1
PrivatePauseAfterPopupMs=1500
PrivatePauseStepMs=400
PrivateTabs=1
; Backspaces pressed before typing a box, to remove old text (0 = none)
PrivateClearBackspaces=0
PrivateEnterAfterPassword=1
; Advanced (not shown in the settings window). PowerShell version only (this program always asks for administrator rights): 1 = restart as administrator
RunElevated=1
; ---- Hidden Login: runs the real, official Arc sign-in while every Arc window stays off-screen ----
; (shared with the C++ version - same keys, same ArcManager.ini). 1 = use it, 0 = fall back to the old visible pop-up method.
UseHiddenLogin=1
HiddenKeyDelayMs=20
HiddenCharDelayMs=20
HiddenPostTabDelayMs=20
HiddenPostFieldDelayMs=20
HiddenHideSettleDelayMs=20
HiddenSignInTimeoutSeconds=300
HiddenSignInPollIntervalMs=500
HiddenMainWindowInitialDelayMs=1600
HiddenMainWindowTimeoutSeconds=60
HiddenMainWindowPollIntervalMs=500
HiddenPatcherWaitTimeoutSeconds=120
HiddenPatcherWaitPollIntervalMs=500
; automatically click Start on the launcher/patcher once it appears, so sign-in truly finishes the job.
; applies to both Launcher Modes (Hidden Arc Mode and Show Arc Mode)
ClickPatcherStart=1
PatcherStartPollIntervalMs=2000
PatcherStartTimeoutSeconds=180
; Show Arc Mode only: once auto-fill submits the username and password, automatically click Arc's own Play
; button too, instead of requiring you to click it yourself. Hidden Arc Mode always does this on its own.
ClickArcPlay=1
'@

# The settings file is stored as UTF-16 so that folder names with accented / non-Latin letters survive.
function Write-UnicodeFile([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::Unicode)
}
# converts an older ANSI / UTF-8 settings file to UTF-16 (leaves UTF-16 files alone)
function Ensure-UnicodeIni([string]$path) {
    try {
        $b = [System.IO.File]::ReadAllBytes($path)
        if ($b.Length -eq 0) { return }
        if ($b.Length -ge 2 -and $b[0] -eq 255 -and $b[1] -eq 254) { return }
        if ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) {
            $text = [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3)
        } else {
            $text = [System.Text.Encoding]::Default.GetString($b)
        }
        Write-UnicodeFile $path $text
    } catch { }
}

# the built-in defaults (keep in step with the default file text above)
function Get-DefaultValues {
    return @{
        ArcPath = 'C:\Program Files (x86)\Arc\Arc.exe'
        WindowWidth = 1280; WindowHeight = 720; RememberWindowSize = $true
        AutoFill = $true; UsernameFocusTabs = 1; FieldSeparatorTabs = 1
        LoginDelayMs = 3000; MinWaitSeconds = 6; WindowTimeoutSeconds = 40
        TimeoutSeconds = 300; PendingTimeoutSeconds = 600
        ConfirmStop = $false; KillArcOnStart = $true; DebugLog = $true; RenameGameWindows = $true; RenameDurationSeconds = 180; StatusResetSeconds = 30
        PrivateMode = $false; PrivateShowWarning = $true; PrivateEnterAfterPassword = $true
        PrivateProcessNames = 'elementclient.exe,elementclient_64.exe'
        PrivatePopupKey = 'enter'
        PopupKey = 'enter'; EntersBefore = 0; PauseAfterPopupMs = 1500; ClearBackspaces = 0; EnterAfterPassword = $true
        PrivateWindowWaitSeconds = 90; PrivateFirstKeyDelaySeconds = 6; PrivateEntersBefore = 1
        PrivatePauseAfterPopupMs = 1500; PrivatePauseStepMs = 400; PrivateTabs = 1; PrivateClearBackspaces = 0
        BackgroundImage = ''; BackgroundMode = 'fill'; BackgroundDim = 0.5
        ShowStorageHint = $false
        PrivateFlags = 'game:cpw nocheck startbypatcher console:1'
        UseHiddenLogin = $true
        HiddenKeyDelayMs = 20; HiddenCharDelayMs = 20; HiddenPostTabDelayMs = 20; HiddenPostFieldDelayMs = 20; HiddenHideSettleDelayMs = 20
        HiddenSignInTimeoutSeconds = 300; HiddenSignInPollIntervalMs = 500
        HiddenMainWindowInitialDelayMs = 1600; HiddenMainWindowTimeoutSeconds = 60; HiddenMainWindowPollIntervalMs = 500
        HiddenPatcherWaitTimeoutSeconds = 120; HiddenPatcherWaitPollIntervalMs = 500
        ClickPatcherStart = $true; PatcherStartPollIntervalMs = 2000; PatcherStartTimeoutSeconds = 180
        ClickArcPlay = $true
    }
}
function Get-IniText([string]$key, [string]$def) { return [IniFile]::Get($IniFile, $key, $def) }
function Get-IniInt([string]$key, [int]$def) {
    $v = 0
    if ([int]::TryParse((Get-IniText $key ([string]$def)).Trim(), [ref]$v)) { return $v }
    return $def
}
function Get-IniBool([string]$key, [bool]$def) {
    $d = '0'
    if ($def) { $d = '1' }
    $t = (Get-IniText $key $d).Trim().ToLower()
    return ($t -ne '' -and $t -ne '0' -and $t -ne 'false' -and $t -ne 'no' -and $t -ne 'off')
}
function Load-Settings {
    $d = Get-DefaultValues
    $script:ArcPath = (Get-IniText 'ArcPath' $d.ArcPath).Trim()
    $script:WindowWidth = [math]::Max(1040, (Get-IniInt 'WindowWidth' $d.WindowWidth))
    $script:WindowHeight = [math]::Max(420, (Get-IniInt 'WindowHeight' $d.WindowHeight))
    $script:RememberWindowSize = Get-IniBool 'RememberWindowSize' $d.RememberWindowSize
    $script:AutoFill = Get-IniBool 'AutoFill' $d.AutoFill
    $script:UsernameFocusTabs = [math]::Max(0, (Get-IniInt 'UsernameFocusTabs' $d.UsernameFocusTabs))
    $script:FieldSeparatorTabs = [math]::Max(0, (Get-IniInt 'FieldSeparatorTabs' $d.FieldSeparatorTabs))
    $script:UsernameFocusKeys = '{TAB}' * $script:UsernameFocusTabs     # keys sent first, to move focus onto the username field
    $script:FieldSeparatorKeys = '{TAB}' * $script:FieldSeparatorTabs   # keys sent between the username and password fields
    $script:LoginDelayMs = Get-IniInt 'LoginDelayMs' $d.LoginDelayMs
    $script:MinWaitSeconds = Get-IniInt 'MinWaitSeconds' $d.MinWaitSeconds
    $script:WindowTimeoutSeconds = Get-IniInt 'WindowTimeoutSeconds' $d.WindowTimeoutSeconds
    $script:TimeoutSeconds = Get-IniInt 'TimeoutSeconds' $d.TimeoutSeconds
    $script:PendingTimeoutSeconds = Get-IniInt 'PendingTimeoutSeconds' $d.PendingTimeoutSeconds
    $script:ConfirmStop = Get-IniBool 'ConfirmStop' $d.ConfirmStop
    $script:KillArcOnStart = Get-IniBool 'KillArcOnStart' $d.KillArcOnStart
    $script:ShowStorageHint = Get-IniBool 'ShowStorageHint' $d.ShowStorageHint
    $script:RenameGameWindows = Get-IniBool 'RenameGameWindows' $d.RenameGameWindows
    $script:RenameDurationSeconds = Get-IniInt 'RenameDurationSeconds' $d.RenameDurationSeconds
    $script:StatusResetSeconds = Get-IniInt 'StatusResetSeconds' $d.StatusResetSeconds
    $script:PrivateMode = Get-IniBool 'PrivateMode' $d.PrivateMode
    $script:PrivateShowWarning = Get-IniBool 'PrivateShowWarning' $d.PrivateShowWarning
    $script:PrivateClientPath = (Get-IniText 'PrivateClientPath' '').Trim()
    $script:PrivateFlags = (Get-IniText 'PrivateFlags' $d.PrivateFlags).Trim()
    $script:PrivateProcessNames = (Get-IniText 'PrivateProcessNames' $d.PrivateProcessNames).Trim()
    if ($script:PrivateProcessNames -eq '') { $script:PrivateProcessNames = $d.PrivateProcessNames }
    $script:PopupKey = (Get-IniText 'PopupKey' 'enter').Trim().ToLower()
    if ($script:PopupKey -ne 'escape') { $script:PopupKey = 'enter' }
    $script:EntersBefore = Get-IniInt 'EntersBefore' $d.EntersBefore
    $script:PauseAfterPopupMs = Get-IniInt 'PauseAfterPopupMs' $d.PauseAfterPopupMs
    $script:ClearBackspaces = Get-IniInt 'ClearBackspaces' $d.ClearBackspaces
    $script:EnterAfterPassword = Get-IniBool 'EnterAfterPassword' $d.EnterAfterPassword
    $script:PrivatePopupKey = (Get-IniText 'PrivatePopupKey' 'enter').Trim().ToLower()
    if ($script:PrivatePopupKey -ne 'escape') { $script:PrivatePopupKey = 'enter' }
    $script:PrivateWindowWaitSeconds = Get-IniInt 'PrivateWindowWaitSeconds' $d.PrivateWindowWaitSeconds
    $script:PrivateFirstKeyDelaySeconds = Get-IniInt 'PrivateFirstKeyDelaySeconds' $d.PrivateFirstKeyDelaySeconds
    $script:PrivateEntersBefore = Get-IniInt 'PrivateEntersBefore' $d.PrivateEntersBefore
    $script:PrivatePauseAfterPopupMs = Get-IniInt 'PrivatePauseAfterPopupMs' $d.PrivatePauseAfterPopupMs
    $script:PrivatePauseStepMs = Get-IniInt 'PrivatePauseStepMs' $d.PrivatePauseStepMs
    $script:PrivateTabs = Get-IniInt 'PrivateTabs' $d.PrivateTabs
    $script:PrivateClearBackspaces = Get-IniInt 'PrivateClearBackspaces' $d.PrivateClearBackspaces
    $script:PrivateEnterAfterPassword = Get-IniBool 'PrivateEnterAfterPassword' $d.PrivateEnterAfterPassword
    $script:UseHiddenLogin = Get-IniBool 'UseHiddenLogin' $d.UseHiddenLogin
    $script:HiddenKeyDelayMs = Get-IniInt 'HiddenKeyDelayMs' $d.HiddenKeyDelayMs
    $script:HiddenCharDelayMs = Get-IniInt 'HiddenCharDelayMs' $d.HiddenCharDelayMs
    $script:HiddenPostTabDelayMs = Get-IniInt 'HiddenPostTabDelayMs' $d.HiddenPostTabDelayMs
    $script:HiddenPostFieldDelayMs = Get-IniInt 'HiddenPostFieldDelayMs' $d.HiddenPostFieldDelayMs
    $script:HiddenHideSettleDelayMs = Get-IniInt 'HiddenHideSettleDelayMs' $d.HiddenHideSettleDelayMs
    $script:HiddenSignInTimeoutSeconds = Get-IniInt 'HiddenSignInTimeoutSeconds' $d.HiddenSignInTimeoutSeconds
    $script:HiddenSignInPollIntervalMs = Get-IniInt 'HiddenSignInPollIntervalMs' $d.HiddenSignInPollIntervalMs
    $script:HiddenMainWindowInitialDelayMs = Get-IniInt 'HiddenMainWindowInitialDelayMs' $d.HiddenMainWindowInitialDelayMs
    $script:HiddenMainWindowTimeoutSeconds = Get-IniInt 'HiddenMainWindowTimeoutSeconds' $d.HiddenMainWindowTimeoutSeconds
    $script:HiddenMainWindowPollIntervalMs = Get-IniInt 'HiddenMainWindowPollIntervalMs' $d.HiddenMainWindowPollIntervalMs
    $script:HiddenPatcherWaitTimeoutSeconds = Get-IniInt 'HiddenPatcherWaitTimeoutSeconds' $d.HiddenPatcherWaitTimeoutSeconds
    $script:HiddenPatcherWaitPollIntervalMs = Get-IniInt 'HiddenPatcherWaitPollIntervalMs' $d.HiddenPatcherWaitPollIntervalMs
    $script:ClickPatcherStart = Get-IniBool 'ClickPatcherStart' $d.ClickPatcherStart
    $script:PatcherStartPollIntervalMs = Get-IniInt 'PatcherStartPollIntervalMs' $d.PatcherStartPollIntervalMs
    $script:PatcherStartTimeoutSeconds = Get-IniInt 'PatcherStartTimeoutSeconds' $d.PatcherStartTimeoutSeconds
    $script:ClickArcPlay = Get-IniBool 'ClickArcPlay' $d.ClickArcPlay
    $script:DebugLog = Get-IniBool 'DebugLog' $d.DebugLog
    $script:BackgroundImage = (Get-IniText 'BackgroundImage' '').Trim()
    $script:BackgroundMode = (Get-IniText 'BackgroundMode' 'fill').Trim().ToLower()
    $dimText = (Get-IniText 'BackgroundDim' '0.5').Trim().Replace(',', '.')
    $dim = 0.5
    if (-not [double]::TryParse($dimText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dim)) { $dim = 0.5 }
    $script:BackgroundDim = [math]::Min(1.0, [math]::Max(0.0, $dim))
    # clean-up of settings that were removed in later versions
    $none = [string][char]1
    foreach ($old in @('PrivateStartDir', 'PrivateNoticeShown', 'LauncherGraceSeconds', 'GraceSeconds', 'CloseArcAt')) {
        if ([IniFile]::Get($IniFile, $old, $none) -ne $none) { [void][IniFile]::Remove($IniFile, $old) }
    }
}
if (-not (Test-Path $IniFile)) { Write-UnicodeFile $IniFile ($DefaultIniText -replace "`r?`n", "`r`n") } else { Ensure-UnicodeIni $IniFile }
Load-Settings

# the official game and private servers each have their own accounts list and session file
function Apply-ModePaths {
    if ($PrivateMode) {
        $script:AccountsFile = Join-Path $ConfigDir 'accounts-private.txt'
        $script:SessionFile = Join-Path $ConfigDir 'session-private.txt'
    } else {
        $script:AccountsFile = Join-Path $ConfigDir 'accounts.txt'
        $script:SessionFile = Join-Path $ConfigDir 'session.txt'
    }
}
Apply-ModePaths

# For safety the manager only ever launches a program named Arc.exe (it runs with administrator rights).
function Test-ArcExeName([string]$path) { return ($path -match '(^|[\\/])Arc\.exe$') }

# where is Arc.exe? 1) a running Arc.exe knows, 2) the list of installed programs, 3) the usual folders on every fixed drive
function Find-ArcPath {
    foreach ($p in @(Get-Process -Name 'Arc' -ErrorAction SilentlyContinue)) {
        try { $f = [string]$p.Path; if ($f -ne '' -and (Test-Path -LiteralPath $f)) { return $f } } catch { }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $key)) { continue }
        foreach ($k in @(Get-ChildItem $key -ErrorAction SilentlyContinue)) {
            try {
                if ([string]$k.GetValue('DisplayName') -ne 'Arc') { continue }
                $loc = ([string]$k.GetValue('InstallLocation')).Trim().Trim('"').TrimEnd('\')
                if ($loc -ne '' -and (Test-Path -LiteralPath ($loc + '\Arc.exe'))) { return ($loc + '\Arc.exe') }
            } catch { }
        }
    }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed') { continue }
        foreach ($sub in @('Program Files (x86)\Arc\Arc.exe', 'Program Files\Arc\Arc.exe')) {
            $f = Join-Path $d.Name $sub
            if (Test-Path -LiteralPath $f) { return $f }
        }
    }
    return ''
}
# when the configured Arc.exe does not exist: look for it and (if found) save the new location to the settings file
function Initialize-ArcPath {
    if (Test-Path -LiteralPath $ArcPath) { return }
    $f = Find-ArcPath
    if ($f -eq '') { Write-Log 'Arc.exe was not found at the configured location and could not be detected'; return }
    $script:ArcPath = $f
    [void][IniFile]::Put($IniFile, 'ArcPath', $f)
    Write-Log 'Arc.exe detected automatically; ArcPath updated'
}

# load saved accounts (older name-only files still work)
$accounts = New-Object System.Collections.ArrayList
# reads the accounts file of the current mode (or its backup)
function Load-AccountList {
    $list = New-Object System.Collections.ArrayList
    $accFileToRead = $AccountsFile
    if ((-not (Test-Path $AccountsFile)) -and (Test-Path ($AccountsFile + '.bak'))) { $accFileToRead = $AccountsFile + '.bak' }   # the main file is missing: use the backup
    if (Test-Path $accFileToRead) {
        foreach ($line in [System.IO.File]::ReadAllLines($accFileToRead, [System.Text.Encoding]::UTF8)) {
            if ($line.Trim() -eq '') { continue }
            $parts = $line.Split([char[]]@([char]9), 3)
            $p = ''
            $nt = ''
            if ($parts.Length -gt 1) { $p = $parts[1] }
            if ($parts.Length -gt 2) { $nt = $parts[2] }
            [void]$list.Add(@{ User = $parts[0].Trim(); Pass = $p; Notes = $nt })
        }
    }
    if ($list.Count -eq 0) {
        [void]$list.Add(@{ User = ''; Pass = ''; Notes = '' })   # first start: one empty row
    }
    return ,$list
}
$accounts = Load-AccountList

# colors
$cBg    = [System.Drawing.Color]::FromArgb(24, 24, 28)
$cBox   = [System.Drawing.Color]::FromArgb(38, 38, 44)
$cWhite = [System.Drawing.Color]::FromArgb(235, 235, 235)
$cGray  = [System.Drawing.Color]::FromArgb(140, 140, 150)
$cRed   = [System.Drawing.Color]::FromArgb(230, 30, 60)
$cGreen = [System.Drawing.Color]::FromArgb(80, 200, 120)
$cAmber = [System.Drawing.Color]::FromArgb(240, 170, 60)

$script:Rows   = New-Object System.Collections.ArrayList
$script:Active = $null
$script:LastDesc = ''
$script:HiddenState = $null
$script:HiddenPopup = $null
$script:StartingPopup = $null
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-GamePids {
    if ($PrivateMode) {   # private servers: the process names from the settings
        $names = @($PrivateProcessNames.Split(',') | ForEach-Object { ($_.Trim() -replace '\.exe$', '') } | Where-Object { $_ -ne '' })
        if ($names.Count -gt 0) { @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
    } else {
        @(Get-Process -Name 'elementclient', 'elementclient_64' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    }
}
function Get-ArcPids {
    @(Get-Process -Name 'Arc' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}
function Reset-Log {
    if ($DebugLog) { Set-Content -Path $LogFile -Value ('ArcManager (PowerShell) ' + $AppVersion + ' debug log - started ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) }
}
# a new log for this run; the log of the run before it is kept as debug.previous.log
function Start-NewLog {
    if (-not $DebugLog) { return }
    if (Test-Path $LogFile) { Copy-Item -Path $LogFile -Destination $PrevLogFile -Force }
    Reset-Log
}
function Write-Log([string]$msg) {
    if ($DebugLog) { Add-Content -Path $LogFile -Value ((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $msg) }
}
function Stop-ProcessLogged([int]$id) {
    try { Stop-Process -Id $id -Force -ErrorAction Stop; Write-Log ('closed pid ' + $id) }
    catch { Write-Log ('FAILED to close pid ' + $id + ': ' + $_.Exception.Message) }
}
# launcher.exe / patcher.exe processes that were started directly by one of the given Arc pids
function Get-ArcLauncherPids($arcPids) {
    $out = @()
    try {
        foreach ($w in @(Get-WmiObject Win32_Process -Filter "Name='launcher.exe' OR Name='patcher.exe'" -ErrorAction Stop)) {
            if ($arcPids -contains [int]$w.ParentProcessId) { $out += [int]$w.ProcessId }
        }
    } catch { }
    $out
}
function Get-ClaimedPids {
    @($script:Rows | Where-Object { $_.GamePid } | ForEach-Object { $_.GamePid })
}
function Set-Status($row, [string]$text, $color, [bool]$transient = $false) {
    if (($row.Label.Text -ceq $text) -and ($row.Label.ForeColor.ToArgb() -eq $color.ToArgb())) { return }   # nothing changed
    $row.Label.Text = $text
    $row.Label.ForeColor = $color
    $row.StatusSince = Get-Date
    $row.StatusTransient = $transient   # transient messages (Stopped, Cancelled...) return to Idle after a while
}
# CANCEL: closes Arc.exe plus the launcher.exe / patcher.exe that appeared since the sign-in began (game clients are never touched)
function Get-LaunchToolPids {
    @(Get-Process -Name 'launcher', 'patcher' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}
# true if any other row is still signing in or waiting for its own game client (its launcher / patcher must be left alone)
function Test-OtherSignInsBusy($row) {
    if ($script:Active -ne $null -and $script:Active.Row -ne $row) { return $true }
    foreach ($r in $script:Rows) { if ($r -ne $row -and $r.Pending -ne $null) { return $true } }
    return $false
}
# the game client just started: force-close the launcher.exe / patcher.exe that this sign-in started (the patcher can
# take a long time to close by itself). Skipped if another sign-in is under way, so its launcher is never hit.
function Stop-LaunchTools($launchBase, $row) {
    if (Test-OtherSignInsBusy $row) { Write-Log 'game client detected - another sign-in is under way, leaving launcher/patcher alone'; return }
    $closed = 0
    foreach ($p in (Get-LaunchToolPids | Where-Object { $launchBase -notcontains $_ })) { Stop-ProcessLogged $p; $closed++ }
    if ($closed -gt 0) { Write-Log ('game client detected - force-closed ' + $closed + ' launcher/patcher process(es)') }
}
function Close-LaunchLeftovers($launchBase) {
    $arc = @(Get-ArcPids)
    foreach ($p in $arc) { Stop-ProcessLogged $p }
    $closed = 0
    foreach ($p in (Get-LaunchToolPids)) {
        if (@($launchBase) -notcontains $p) { Stop-ProcessLogged $p; $closed++ }
    }
    Write-Log ('cancel: closed ' + $arc.Count + ' Arc process(es) and ' + $closed + ' launcher/patcher process(es)')
}
# Writes accounts.txt.tmp first and swaps it in afterwards, so a crash or power loss can never leave a half-written file.
# The previous version of the file (when it was not empty) is kept as accounts.txt.bak.
function Save-Accounts {
    $lines = @()
    foreach ($r in $script:Rows) {
        # last line of defence (typing and pasting are already blocked): tabs and line breaks would corrupt the file
        $u = ($r.Box.Text.Trim() -replace '[\x00-\x1F]', ' ')
        $pw = ($r.Pass.Text -replace '[\x00-\x1F]', ' ')
        $n = ($r.Notes.Text.Trim() -replace '[\x00-\x1F]', ' ')
        if ($u -ne '') { $lines += ($u + [string][char]9 + $pw + [string][char]9 + $n) }
    }
    $tmp = $AccountsFile + '.tmp'
    try {
        [System.IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        if ((Test-Path $AccountsFile) -and ((Get-Item $AccountsFile).Length -gt 0)) { [System.IO.File]::Copy($AccountsFile, ($AccountsFile + '.bak'), $true) }
        if (-not [IniFile]::ReplaceFile($tmp, $AccountsFile)) { throw ('Windows error ' + [IniFile]::LastError()) }
    } catch {
        Write-Log ('could not save the accounts file: ' + $_.Exception.Message)
        try { if (Test-Path $tmp) { Remove-Item -Path $tmp -Force } } catch { }
    }
}
function Finish-Active([string]$text, $color, [bool]$transient = $false) {
    $a = $script:Active
    if ($a -ne $null) {
        $a.Row.Button.Text = 'SIGN IN'
        Set-Status $a.Row $text $color $transient
        $script:Active = $null
    }
}
# small always-on-top notice shown during a long async wait so the user doesn't think the program froze.
# Shared by both status popups ("Obtaining ARC / PWI TOKEN Now" and "Starting Game") - same size and font either way.
function New-StatusPopup([string]$text) {
    $p = New-Object System.Windows.Forms.Form
    $p.Text = 'ArcManager'
    $p.FormBorderStyle = 'FixedDialog'
    $p.ControlBox = $false
    $p.MinimizeBox = $false
    $p.MaximizeBox = $false
    $p.ShowInTaskbar = $false
    $p.StartPosition = 'CenterScreen'
    $p.TopMost = $true
    $p.ClientSize = New-Object System.Drawing.Size(500, 300)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.Dock = 'Fill'
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 14)
    $p.Controls.Add($lbl)
    try { $p.Show($form) } catch { $p.Show() }
    $p
}
function Close-StatusPopup([ref]$popupVar) {
    if ($popupVar.Value -ne $null) {
        try { $popupVar.Value.Close() } catch { }
        try { $popupVar.Value.Dispose() } catch { }
        $popupVar.Value = $null
    }
}
function Show-HiddenPopup {
    if ($script:HiddenPopup -ne $null) { return }
    $script:HiddenPopup = New-StatusPopup 'Obtaining ARC / PWI TOKEN Now'
}
function Close-HiddenPopup {
    Close-StatusPopup ([ref]$script:HiddenPopup)
}
# shown while the manager is auto-clicking Start on the launcher/patcher (either Launcher Mode); closed the
# instant the real game client (elementclient.exe / elementclient_64.exe) is detected.
function Show-StartingPopup {
    if ($script:StartingPopup -ne $null) { return }
    $script:StartingPopup = New-StatusPopup 'Starting Game'
}
function Close-StartingPopup {
    Close-StatusPopup ([ref]$script:StartingPopup)
}
# polled once a second from Update-State while $script:Active.Phase is 'hidden'. Result codes match the C++
# HiddenLoginResult enum: 0=Success 1=ArcLaunchFailed 2=SignInWindowNotFound 3=MainWindowNotFound 4=PatcherNotDetected 5=Cancelled.
# The hidden-login thread always kills Arc itself before reporting back (success, failure or cancel alike), so none
# of these branches need to touch Arc - they only update the row.
function Update-HiddenLogin {
    $a = $script:Active
    $hs = $script:HiddenState
    if ($hs -eq $null -or -not $hs.Done) { return }
    $result = [int]$hs.Result
    $script:HiddenState = $null
    Close-HiddenPopup
    switch ($result) {
        0 {
            $a.Row.Pending = @{ Since = Get-Date; Base = $a.GameBase; LaunchBase = $a.LaunchBase; LastStartClickAt = $null; SawTool = $false; ToolFirstSeenAt = $null; HideTools = $true }   # Hidden Arc Mode: keep the launcher/patcher off-screen too
            Finish-Active 'Launcher started - waiting for the game client (CANCEL to stop)' $cWhite
            $a.Row.Button.Text = 'CANCEL'
        }
        1 { Finish-Active 'Could not start Arc.exe' $cAmber $true }
        2 { Finish-Active "Timed out waiting for Arc's Sign In window" $cAmber $true }
        3 { Finish-Active "Signed in, but Arc's main window never appeared" $cAmber $true }
        4 { Finish-Active 'Signed in, but the launcher/patcher never started' $cAmber $true }
        5 { Finish-Active 'Cancelled - Arc was closed' $cGray $true }
        default { Finish-Active 'Hidden login failed' $cAmber $true }
    }
}
# escape characters that SendKeys treats as special
function Escape-Keys([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ('+^%~(){}[]'.IndexOf($ch) -ge 0) { [void]$sb.Append('{' + $ch + '}') }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}
function Test-ArcFocused($arcPids) {
    return ($arcPids -contains [WinHelper]::GetForegroundPid())
}
function Use-Fallback($a, [string]$why) {
    try { [System.Windows.Forms.Clipboard]::SetText($a.Row.Box.Text.Trim()) } catch { }
    Set-Status $a.Row ($why + ' - sign in manually (name copied)') $cAmber
}

# returns $true only if the username and password were both typed AND the login was actually submitted (Enter
# pressed after the password) - i.e. only when it's safe to go looking for Arc's Play button on our own (see
# ClickArcPlay / the 'clickplay' phase in Update-State). Every other outcome (no saved password, lost focus,
# Enter not sent) means the person still has to finish signing in themselves, so auto-clicking Play would be premature.
function Invoke-AutoFill($a) {
    $row  = $a.Row
    $user = $row.Box.Text.Trim()
    $pass = $row.Pass.Text
    $h    = New-Object System.IntPtr ([int64]$a.Hwnd)

    [void][WinHelper]::ShowWindow($h, 9)
    [void][WinHelper]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 400
    if (-not (Test-ArcFocused $a.ArcPids)) {
        try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$a.ArcPids[0]) } catch { }
        Start-Sleep -Milliseconds 500
    }
    Write-Log ('after focus attempt: foreground pid=' + [WinHelper]::GetForegroundPid() + ' arc pids=' + ($a.ArcPids -join ','))
    if (-not (Test-ArcFocused $a.ArcPids)) { Write-Log 'Arc not focused - fallback'; Use-Fallback $a 'Could not focus Arc'; return $false }

    for ($k = 0; $k -lt $EntersBefore; $k++) {   # a message before the login page (not needed by Arc today): Enter or Escape
        if ($PopupKey -eq 'escape') { [System.Windows.Forms.SendKeys]::SendWait('{ESC}') } else { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
        if ($k -eq ($EntersBefore - 1)) { Start-Sleep -Milliseconds $PauseAfterPopupMs } else { Start-Sleep -Milliseconds 400 }
    }
    Write-Log 'moving focus to the username field'
    if ($UsernameFocusKeys -ne '') { [System.Windows.Forms.SendKeys]::SendWait($UsernameFocusKeys) }
    Start-Sleep -Milliseconds 300
    Write-Log ('typing username (' + $user.Length + ' chars)')
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    if ($ClearBackspaces -gt 0) { [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE ' + $ClearBackspaces + '}') }
    [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $user))
    Start-Sleep -Milliseconds 200
    if ($FieldSeparatorKeys -ne '') { [System.Windows.Forms.SendKeys]::SendWait($FieldSeparatorKeys) }
    Start-Sleep -Milliseconds 200

    if ($pass -eq '') {
        Set-Status $row 'Username typed - no password saved, enter it in Arc' $cAmber
        return $false
    }
    # safety: never type the password into some other window
    if (-not (Test-ArcFocused $a.ArcPids)) {
        Set-Status $row 'Focus left Arc - password was NOT typed' $cAmber
        return $false
    }
    Write-Log ('typing password (' + $pass.Length + ' chars), foreground pid=' + [WinHelper]::GetForegroundPid())
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    if ($ClearBackspaces -gt 0) { [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE ' + $ClearBackspaces + '}') }
    [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $pass))
    Start-Sleep -Milliseconds 200
    if (-not $EnterAfterPassword) {
        Set-Status $row ("Signed in as '" + $user + "' - press Enter / click Sign In, then click Play in Arc") $cWhite
        return $false
    }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    $playMsg = "Signed in as '" + $user + "'"
    if ($ClickArcPlay) { $playMsg += ' - clicking Play...' } else { $playMsg += ' - click Play in Arc' }
    Set-Status $row $playMsg $cWhite
    return $true
}

function Stop-Client($row) {
    if (-not $row.GamePid) { return }
    $id = [int]$row.GamePid
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    # never kill a pid that is no longer the game client (pids get reused)
    if ($proc -eq $null -or $proc.Name -notlike 'elementclient*') {
        $row.GamePid = $null
        Set-Status $row 'Stopped' $cGray $true
        return
    }
    if ($ConfirmStop) {
        $who = $row.Box.Text.Trim()
        $ans = [System.Windows.Forms.MessageBox]::Show("Force close the game client for '" + $who + "' (PID " + $id + ")?" + "`n`n" + 'This ends it immediately, like Task Manager. Anything unsaved in the game is lost.', 'Stop client', 'YesNo')
        if ($ans -ne 'Yes') { return }
    }
    try {
        Stop-Process -Id $id -Force -ErrorAction Stop
        Write-Log ('STOP button: closed game client pid ' + $id)
        $row.GamePid = $null
        Set-Status $row 'Stopped (closed by manager)' $cGray $true
    } catch {
        Write-Log ('STOP button: FAILED for pid ' + $id + ': ' + $_.Exception.Message)
        Set-Status $row ('Could not close it: ' + $_.Exception.Message) $cAmber $true
    }
}

# ---------- private servers ----------
# SIGN IN in private mode: start the configured program, wait for the game client and its window, then type the login
# (Enter x N for the start-up pop-up, username, Tab x N, password, Enter). It never touches Arc.
$script:Priv = $null
$script:PrivTimer = $null
function Test-ProcAlive([int]$id) { return [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
function End-Private([string]$text, $color, [bool]$transient = $false) {
    if ($script:PrivTimer -ne $null) { $script:PrivTimer.Stop() }
    $script:Priv = $null
    Finish-Active $text $color $transient
}
function Cancel-Private {
    $p = $script:Priv
    if ($p -eq $null) { return }
    $row = $p.Row
    if ($p.LaunchedPid -and (Test-ProcAlive $p.LaunchedPid)) { Stop-ProcessLogged $p.LaunchedPid }   # the program this sign-in started
    if ($row.GamePid -and $row.GamePid -eq $p.LaunchedPid) { $row.GamePid = $null }
    Write-Log 'private sign-in cancelled by user'
    if ($row.GamePid -and (Test-ProcAlive $row.GamePid)) { End-Private ('Running (PID ' + $row.GamePid + ')') $cGreen }   # a client started by a launcher stays open
    else { $row.GamePid = $null; End-Private 'Cancelled - the program that was started was closed' $cGray $true }
}
function Build-PrivateSteps {
    $steps = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $PrivateEntersBefore; $k++) {
        $pause = $PrivatePauseStepMs
        if ($k -eq ($PrivateEntersBefore - 1)) { $pause = $PrivatePauseAfterPopupMs }
        [void]$steps.Add(@{ Kind = 'popup'; Pause = $pause })
    }
    [void]$steps.Add(@{ Kind = 'user'; Pause = $PrivatePauseStepMs })
    for ($k = 0; $k -lt $PrivateTabs; $k++) { [void]$steps.Add(@{ Kind = 'tab'; Pause = $PrivatePauseStepMs }) }
    [void]$steps.Add(@{ Kind = 'pass'; Pause = $PrivatePauseStepMs })
    if ($PrivateEnterAfterPassword) { [void]$steps.Add(@{ Kind = 'enter'; Pause = 0 }) }
    return ,$steps
}
function Clear-PrivateBox {
    if ($PrivateClearBackspaces -gt 0) { [System.Windows.Forms.SendKeys]::SendWait('{END}{BACKSPACE ' + $PrivateClearBackspaces + '}') }
}
function Private-Tick {
    $p = $script:Priv
    if ($p -eq $null) { return }
    $row = $p.Row
    $now = Get-Date
    $elapsed = ($now - $p.Start).TotalSeconds

    if ($p.Phase -eq 'client') {   # wait for the game client process
        if (($now - $p.LastCheck).TotalMilliseconds -lt 1000) { return }
        $p.LastCheck = $now
        $claimed = @(Get-ClaimedPids)
        $fresh = @(Get-GamePids | Where-Object { $p.Base -notcontains $_ -and $claimed -notcontains $_ })
        if ($fresh.Count -gt 0) {
            $row.GamePid = [int]$fresh[0]
            Write-Log ('game client found (pid ' + $row.GamePid + ')')
            if (-not $AutoFill) { End-Private ('Running (PID ' + $row.GamePid + ')') $cGreen; return }
            $p.Phase = 'window'
            $p.WindowSeen = $null
            Set-Status $row ('Game client started (PID ' + $row.GamePid + ') - waiting for its window') $cWhite
        } elseif ($elapsed -gt $PrivateWindowWaitSeconds) {
            Write-Log 'timed out waiting for the game client'
            End-Private 'Timed out waiting for the game client' $cAmber $true
        }
        return
    }
    if ($p.Phase -eq 'window') {   # wait for its window, then a few more seconds
        if (($now - $p.LastCheck).TotalMilliseconds -lt 500) { return }
        $p.LastCheck = $now
        if (-not (Test-ProcAlive $row.GamePid)) { $row.GamePid = $null; End-Private 'The game client closed before the login' $cAmber $true; return }
        $h = [WinHelper]::FindVisibleWindow([int[]]@($row.GamePid))
        if ($h -eq [IntPtr]::Zero) {
            $p.WindowSeen = $null
            if ($elapsed -gt $PrivateWindowWaitSeconds) { Write-Log 'timed out waiting for the game window'; End-Private 'Timed out waiting for the game window' $cAmber $true }
            return
        }
        if ($p.WindowSeen -eq $null) { $p.WindowSeen = $now }
        if (($now - $p.WindowSeen).TotalSeconds -lt $PrivateFirstKeyDelaySeconds) { return }
        $p.Hwnd = $h
        $p.Steps = Build-PrivateSteps
        $p.Idx = 0
        $p.Refocus = 0
        $p.NextAt = $now
        $p.Phase = 'typing'
        Write-Log 'game window found - typing the login'
        Set-Status $row 'Typing the login...' $cWhite
        return
    }

    # typing: one step at a time, so the manager never freezes and CANCEL works at any moment
    if ($now -lt $p.NextAt) { return }
    if ($p.Idx -ge $p.Steps.Count) {
        Write-Log 'login typed'
        End-Private ('Running (PID ' + $row.GamePid + ')') $cGreen
        return
    }
    if (-not (Test-ProcAlive $row.GamePid)) { $row.GamePid = $null; End-Private 'The game client closed during the login' $cAmber $true; return }
    if ([WinHelper]::GetForegroundPid() -ne $row.GamePid) {   # the game window must have the keyboard
        $p.Refocus = $p.Refocus + 1
        if ($p.Refocus -gt 10) { Write-Log 'could not focus the game window'; End-Private 'Could not focus the game window - the login was NOT typed' $cAmber $true; return }
        $h = [WinHelper]::FindVisibleWindow([int[]]@($row.GamePid))
        if ($h -ne [IntPtr]::Zero) {
            [void][WinHelper]::ShowWindow($h, 9)
            [void][WinHelper]::SetForegroundWindow($h)
        }
        if ([WinHelper]::GetForegroundPid() -ne $row.GamePid) { try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$row.GamePid) } catch { } }
        $p.NextAt = $now.AddMilliseconds(300)
        return
    }
    $p.Refocus = 0
    $st = $p.Steps[$p.Idx]
    $p.Idx = $p.Idx + 1
    switch ($st.Kind) {
        'enter' { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
        'popup' { if ($PrivatePopupKey -eq 'escape') { [System.Windows.Forms.SendKeys]::SendWait('{ESC}') } else { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') } }
        'tab' { [System.Windows.Forms.SendKeys]::SendWait('{TAB}') }
        'user' {
            $user = $row.Box.Text.Trim()
            Write-Log ('typing username (' + $user.Length + ' chars)')
            Clear-PrivateBox
            [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $user))
        }
        'pass' {
            $pass = $row.Pass.Text
            if ($pass -eq '') {
                Write-Log 'no password saved - stopping after the username'
                End-Private 'Username typed - no password saved, enter it in the game' $cAmber
                return
            }
            Write-Log ('typing password (' + $pass.Length + ' chars)')
            Clear-PrivateBox
            [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $pass))
        }
    }
    $p.NextAt = (Get-Date).AddMilliseconds([double]$st.Pause)
}
function Start-PrivatePlay($row) {
    if ($script:Active -ne $null) {
        if (($script:Active.Row -eq $row) -and $script:Active.Priv) { Cancel-Private }   # the button reads CANCEL while it works
        else { [void][System.Windows.Forms.MessageBox]::Show('Another account is still launching. Wait for it to finish, or cancel it first.', 'Busy') }
        return
    }
    if ($row.GamePid) { [void][System.Windows.Forms.MessageBox]::Show('That account already has a game client running.', 'Already running'); return }
    if (($row.Box.Text -match '[\x00-\x1F]') -or ($row.Pass.Text -match '[\x00-\x1F]') -or ($row.Notes.Text -match '[\x00-\x1F]')) {
        [void][System.Windows.Forms.MessageBox]::Show(($script:BadCharsText + ' Remove them and try again.'), 'Characters not allowed', 'OK', 'Warning')
        return
    }
    if ($row.Box.Text.Trim() -eq '') { [void][System.Windows.Forms.MessageBox]::Show('Type an account name in the box first.', 'No name'); return }
    if ($PrivateClientPath -eq '' -or -not (Test-Path -LiteralPath $PrivateClientPath)) {
        [void][System.Windows.Forms.MessageBox]::Show('Set the client or launcher location first: gear icon > Private Servers.', 'Private servers')
        return
    }
    Save-Accounts
    $base = @(Get-GamePids)   # clients that are already running do not count
    $dir = Split-Path -Parent $PrivateClientPath   # the program starts in its own folder
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PrivateClientPath
    $psi.Arguments = $PrivateFlags   # the flags are passed exactly as typed
    $psi.WorkingDirectory = $dir
    $psi.UseShellExecute = $false
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch {
        [void][System.Windows.Forms.MessageBox]::Show(("The program could not be started:`n" + $_.Exception.Message + "`n`nCheck the location on the Private Servers page."), 'Private servers')
        return
    }
    $script:Active = @{ Row = $row; Priv = $true; Phase = 'private'; Start = Get-Date; LaunchBase = @() }
    $script:Priv = @{ Row = $row; Phase = 'client'; Start = Get-Date; LastCheck = [DateTime]::MinValue; WindowSeen = $null; NextAt = Get-Date; LaunchedPid = $proc.Id; Refocus = 0; Hwnd = [IntPtr]::Zero; Base = $base; Steps = $null; Idx = 0 }
    $row.Button.Text = 'CANCEL'
    Set-Status $row 'Program started - waiting for the game client' $cWhite
    Write-Log ('---- SIGN IN (private server), row ' + ($script:Rows.IndexOf($row) + 1) + ' ----')
    Write-Log ('started the configured program (pid ' + $proc.Id + ')')
    $script:PrivTimer.Start()
}

function Start-Play($row) {
    if ($PrivateMode) { Start-PrivatePlay $row; return }   # private servers: a separate path, the Arc code below is not involved
    # Arc was already closed and we are only waiting for the game client: CANCEL stops waiting
    if ($row.Pending) {
        $lb = $row.Pending.LaunchBase
        $row.Pending = $null
        Close-LaunchLeftovers $lb
        $row.Button.Text = 'SIGN IN'
        Set-Status $row 'Cancelled - Arc, launcher and patcher closed' $cGray $true
        Write-Log 'pending launch cancelled by user'
        return
    }
    # clicking the button of the row that is currently waiting = cancel
    if ($script:Active -ne $null) {
        if ($script:Active.Row -eq $row) {
            if ($script:Active.Phase -eq 'hidden') {
                # the hidden-login thread is still running: ask it to stop rather than touching Arc from here.
                # It checks this flag between steps, kills Arc itself, and reports back (Cancelled) via Update-HiddenLogin.
                if ($script:HiddenState -ne $null) { $script:HiddenState.Cancel = $true }
                Set-Status $row 'Cancelling - this can take a few seconds' $cWhite
                return
            }
            Close-LaunchLeftovers $script:Active.LaunchBase
            if ($row.GamePid) { Finish-Active ('Running (PID ' + $row.GamePid + ')') $cGreen }   # the game client was already up
            else { Finish-Active 'Cancelled - Arc, launcher and patcher closed' $cGray $true }
            Write-Log 'sign-in cancelled by user'
        } else {
            [void][System.Windows.Forms.MessageBox]::Show('Another account is still launching. Wait for it to finish, or cancel it first.', 'Busy')
        }
        return
    }
    if ($row.GamePid) {
        [void][System.Windows.Forms.MessageBox]::Show('That account already has a game client running.', 'Already running')
        return
    }
    if (($row.Box.Text -match '[\x00-\x1F]') -or ($row.Pass.Text -match '[\x00-\x1F]') -or ($row.Notes.Text -match '[\x00-\x1F]')) {
        [void][System.Windows.Forms.MessageBox]::Show(($script:BadCharsText + ' Remove them and try again.'), 'Characters not allowed', 'OK', 'Warning')
        return
    }
    $name = $row.Box.Text.Trim()
    if ($name -eq '') {
        [void][System.Windows.Forms.MessageBox]::Show('Type an account name in the box first.', 'No name')
        return
    }
    if (-not (Test-Path -LiteralPath $ArcPath)) { Initialize-ArcPath }   # maybe Arc was installed (or moved) after the last start
    if (-not (Test-ArcExeName $ArcPath)) {
        [void][System.Windows.Forms.MessageBox]::Show("The Arc Location must point to a file named Arc.exe.`n`nChange it with the gear button (bottom right).", 'Arc Location')
        return
    }
    if (-not (Test-Path $ArcPath)) {
        [void][System.Windows.Forms.MessageBox]::Show("Arc.exe not found at:`n$ArcPath`n`nSet the Arc Location with the gear button (bottom right).", 'Arc not found')
        return
    }

    if ($UseHiddenLogin) {
        Save-Accounts
        Write-Log ('---- SIGN IN (hidden), row ' + ($script:Rows.IndexOf($row) + 1) + ' ----')
        Write-Log ('manager elevated=' + $script:IsAdmin)
        $script:Active = @{
            Row = $row; Phase = 'hidden'; Start = Get-Date
            GameBase = (Get-GamePids); ArcBase = (Get-ArcPids); LaunchBase = (Get-LaunchToolPids)
            ArcPids = @(); Hwnd = [int64]0; HwndSince = Get-Date; SeenAt = $null; Trigger = ''
        }
        $script:HiddenState = New-Object HiddenLoginState
        $hs = New-Object HiddenLoginSettings
        $hs.ArcPath = $ArcPath
        $hs.Username = $name
        $hs.Password = $row.Pass.Text
        $hs.KeyDelayMs = $HiddenKeyDelayMs
        $hs.CharDelayMs = $HiddenCharDelayMs
        $hs.PostTabDelayMs = $HiddenPostTabDelayMs
        $hs.PostFieldDelayMs = $HiddenPostFieldDelayMs
        $hs.HideSettleDelayMs = $HiddenHideSettleDelayMs
        $hs.SignInTimeoutSec = $HiddenSignInTimeoutSeconds
        $hs.SignInPollIntervalMs = $HiddenSignInPollIntervalMs
        $hs.MainWindowInitialDelayMs = $HiddenMainWindowInitialDelayMs
        $hs.MainWindowTimeoutSec = $HiddenMainWindowTimeoutSeconds
        $hs.MainWindowPollIntervalMs = $HiddenMainWindowPollIntervalMs
        $hs.PatcherWaitTimeoutSec = $HiddenPatcherWaitTimeoutSeconds
        $hs.PatcherWaitPollIntervalMs = $HiddenPatcherWaitPollIntervalMs
        $hs.ClickPatcherStart = [bool]$ClickPatcherStart
        $hs.PatcherStartPollIntervalMs = $PatcherStartPollIntervalMs
        $hs.PatcherStartTimeoutSec = $PatcherStartTimeoutSeconds
        [HiddenLogin]::Start($hs, $script:HiddenState)
        $row.Button.Text = 'CANCEL'
        Set-Status $row 'Signing in hidden - this can take a minute (CANCEL to stop)' $cWhite
        Show-HiddenPopup
        return
    }

    # a still-running Arc would just take focus instead of starting fresh, so close it first
    $existing = @(Get-ArcPids)
    if ($existing.Count -gt 0) {
        foreach ($p in $existing) { Stop-ProcessLogged $p }
        for ($i = 0; $i -lt 8 -and @(Get-ArcPids).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }
        if (@(Get-ArcPids).Count -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show("An Arc process is still running and couldn't be closed. Close it in Task Manager and try again.", 'Arc still running')
            return
        }
    }

    Save-Accounts
    Write-Log ('---- SIGN IN, row ' + ($script:Rows.IndexOf($row) + 1) + ' ----')
    Write-Log ('manager elevated=' + $script:IsAdmin + ' autofill=' + $AutoFill)
    Write-Log ('Arc processes closed before launch: ' + $existing.Count)
    $phase = 'waiting'
    if ($AutoFill) { $phase = 'login' }
    $script:Active = @{
        Row = $row; Phase = $phase; Start = Get-Date
        GameBase = (Get-GamePids); ArcBase = (Get-ArcPids); LaunchBase = (Get-LaunchToolPids)
        ArcPids = @(); Hwnd = [int64]0; HwndSince = Get-Date; SeenAt = $null; Trigger = ''; PlayClickStart = $null
    }
    Start-Process -FilePath $ArcPath -WorkingDirectory (Split-Path $ArcPath)
    Write-Log 'started Arc.exe'
    $row.Button.Text = 'CANCEL'
    if ($AutoFill) {
        Set-Status $row "Waiting for Arc's login window - don't click elsewhere" $cWhite
    } else {
        try { [System.Windows.Forms.Clipboard]::SetText($name) } catch { }
        Set-Status $row ("Arc opened - sign in as '" + $name + "' and click Play (name copied)") $cWhite
    }
}

# Hidden Arc Mode: the game's launcher / patcher window is kept off-screen too, the same way Arc's is. Runs 10 times a
# second, only while a Hidden Arc Mode row is waiting for its game client; Show Arc Mode rows are never touched.
function Hide-LaunchToolWindows {
    $base = @()
    $any = $false
    foreach ($r in $script:Rows) {
        if ($r.Pending -ne $null -and $r.Pending.HideTools) { $any = $true; $base += @($r.Pending.LaunchBase) }
    }
    if (-not $any) { return }
    $tools = @(Get-LaunchToolPids | Where-Object { $base -notcontains $_ })
    if ($tools.Count -gt 0) { [WinHelper]::MoveOffScreen([int[]]$tools) }
}
function Update-State {
    # mark rows whose game client has exited
    foreach ($r in $script:Rows) {
        if ($r.GamePid -and -not (Get-Process -Id $r.GamePid -ErrorAction SilentlyContinue)) {
            $r.GamePid = $null
            Set-Status $r 'Stopped' $cGray $true
        }
        $r.Stop.Enabled = ($r.GamePid -ne $null)
    }

    # give newly started game clients to rows whose Arc was closed early (oldest first)
    foreach ($pr in @($script:Rows | Where-Object { $_.Pending -ne $null })) {
        if (((Get-Date) - $pr.Pending.Since).TotalSeconds -gt $PendingTimeoutSeconds) {
            $pr.Pending = $null
            $pr.Button.Text = 'SIGN IN'
            Set-Status $pr 'Timed out waiting for the game client' $cAmber $true
            Write-Log 'pending launch timed out'
        }
    }

    # Arc is already closed and we're waiting for the game client (true for both Launcher Modes - Hidden Arc
    # Mode's own thread returns the instant the launcher/patcher is detected, so from here on it is just a
    # pending row like Show Arc Mode's), so automatically click Start on the launcher/patcher until it closes
    # or we time out. The "Starting Game" popup (separate from the "Obtaining ARC / PWI TOKEN Now" popup, which
    # already closed) covers this whole phase, in both modes alike.
    if ($UseHiddenLogin -or $ClickPatcherStart) {
        foreach ($pr in @($script:Rows | Where-Object { $_.Pending -ne $null })) {
            if (((Get-Date) - $pr.Pending.Since).TotalSeconds -gt $PatcherStartTimeoutSeconds) { continue }
            if ($pr.Pending.LastStartClickAt -ne $null -and ((Get-Date) - $pr.Pending.LastStartClickAt).TotalMilliseconds -lt $PatcherStartPollIntervalMs) { continue }
            $pr.Pending.LastStartClickAt = Get-Date
            $toolPids = @(Get-LaunchToolPids | Where-Object { $pr.Pending.LaunchBase -notcontains $_ })
            if ($toolPids.Count -eq 0) {
                # only trust this as "Start worked and it closed" once we actually saw it running; an empty read
                # before that just means it has not finished launching yet (the launcher.exe process it starts as
                # can briefly hand off to patcher.exe, with neither name matching for an instant)
                continue
            }
            if (-not $pr.Pending.SawTool) { $pr.Pending.SawTool = $true; $pr.Pending.ToolFirstSeenAt = Get-Date; continue }   # give it a moment to reach its real size before the first click
            if (((Get-Date) - $pr.Pending.ToolFirstSeenAt).TotalMilliseconds -lt 1500) { continue }   # still settling
            $toolHwnd = [WinHelper]::FindVisibleWindow([int[]]$toolPids)
            if ($toolHwnd -ne [IntPtr]::Zero -and [WinHelper]::ClientAtLeast($toolHwnd, 900, 650)) { [HiddenLogin]::ClickAt($toolHwnd, 853, 557) }   # the patcher's Start button (confirmed coordinate)
        }
    }
    $pendingRows = @($script:Rows | Where-Object { $_.Pending -ne $null } | Sort-Object { $_.Pending.Since })
    if ($pendingRows.Count -gt 0) {
        $claimed = @(Get-ClaimedPids)
        foreach ($gp in (Get-GamePids)) {
            if ($claimed -contains $gp) { continue }
            foreach ($pr in $pendingRows) {
                if ($pr.Pending -ne $null -and $pr.Pending.Base -notcontains $gp) {
                    $launchBase = $pr.Pending.LaunchBase
                    $pr.GamePid = $gp
                    $pr.Pending = $null
                    $pr.Button.Text = 'SIGN IN'
                    $claimed += $gp
                    Set-Status $pr ('Running (PID ' + $gp + ')') $cGreen
                    Write-Log ('assigned game client ' + $gp + ' to a pending row')
                    Stop-LaunchTools $launchBase $pr
                    break
                }
            }
        }
    }

    # "Starting Game" covers the whole click-Start phase above; close it the instant no row is in that phase any
    # more - including the instant a row above just got matched to a real elementclient.exe / elementclient_64.exe
    # (Get-GamePids only matches those two process names in non-private mode), and on cancel or timeout too.
    $stillStarting = $false
    if ($UseHiddenLogin -or $ClickPatcherStart) {
        foreach ($pr in @($script:Rows | Where-Object { $_.Pending -ne $null })) {
            if (((Get-Date) - $pr.Pending.Since).TotalSeconds -le $PatcherStartTimeoutSeconds) { $stillStarting = $true; break }
        }
    }
    if ($stillStarting) { Show-StartingPopup } else { Close-StartingPopup }

    $a = $script:Active
    if ($a -eq $null) { return }
    if ($a.Priv) { return }   # a private-server sign-in is handled by Private-Tick
    if ($a.Phase -eq 'hidden') { Update-HiddenLogin; return }
    $elapsed = ((Get-Date) - $a.Start).TotalSeconds
    $a.ArcPids = @(Get-ArcPids | Where-Object { $a.ArcBase -notcontains $_ })

    # what tells us the launch has started: launcher.exe spawned by THIS Arc, or a new game client
    $claimed = @(Get-ClaimedPids)
    $new = @(Get-GamePids | Where-Object { $a.GameBase -notcontains $_ -and $claimed -notcontains $_ })
    $launch = @()
    $launch = @(Get-ArcLauncherPids $a.ArcPids)   # launcher.exe / patcher.exe started by THIS Arc
    if ($a.Phase -ne 'closing' -and ($new.Count -gt 0 -or $launch.Count -gt 0)) {
        $a.Phase = 'closing'
        $a.SeenAt = Get-Date
        if ($new.Count -gt 0) { $a.Trigger = 'game'; $a.Row.GamePid = $new[0] } else { $a.Trigger = 'launcher' }
        Write-Log ('trigger=' + $a.Trigger + ' - closing Arc soon')
        return
    }

    if ($a.Phase -eq 'login') {
        $a.ArcPids = @(Get-ArcPids | Where-Object { $a.ArcBase -notcontains $_ })
        if ($DebugLog) {
            $fam = @(Get-Process -Name 'Arc*' -ErrorAction SilentlyContinue)
            $famNames = ''
            foreach ($pr in $fam) { $famNames += ($pr.Name + ':' + $pr.Id + ' ') }
            $famWin = ''
            if ($fam.Count -gt 0) { $famWin = [WinHelper]::DescribeWindows([int[]]@($fam | ForEach-Object { $_.Id })) }
            $desc = 'procs= ' + $famNames + ' windows= ' + $famWin
            if ($desc -ne $script:LastDesc) { Write-Log $desc; $script:LastDesc = $desc }
        }
        $h = [IntPtr]::Zero
        if ($a.ArcPids.Count -gt 0) { $h = [WinHelper]::FindVisibleWindow([int[]]$a.ArcPids) }
        if ($h -ne [IntPtr]::Zero) {
            $hv = $h.ToInt64()
            if ($a.Hwnd -ne $hv) {
                $a.Hwnd = $hv
                $a.HwndSince = Get-Date
            } elseif (((Get-Date) - $a.HwndSince).TotalMilliseconds -ge $LoginDelayMs -and $elapsed -ge $MinWaitSeconds) {
                $a.Phase = 'waiting'
                Write-Log ('window ' + $hv + ' stable, ' + [int]$elapsed + 's since start -> typing')
                $submitted = Invoke-AutoFill $a
                if ($submitted -and $ClickArcPlay) { $a.Phase = 'clickplay'; $a.PlayClickStart = Get-Date }
            }
        } elseif ($elapsed -gt $WindowTimeoutSeconds) {
            $a.Phase = 'waiting'
            Write-Log 'timed out finding a visible Arc window'
            Use-Fallback $a "Couldn't find Arc's login window"
        }
    }
    elseif ($a.Phase -eq 'clickplay') {
        # Show Arc Mode: credentials were submitted; wait for Arc to swap from the login page to its real
        # library/Play page (clicking too soon can hit an unfinished placeholder instead) and click Play there -
        # the same confirmed coordinate Hidden Arc Mode uses, found the same way (FindArcMainWindow)
        if ($elapsed -gt $TimeoutSeconds) { Finish-Active 'Timed out waiting for a game client' $cAmber $true; return }
        if (((Get-Date) - $a.PlayClickStart).TotalMilliseconds -lt 1500) { return }   # give Arc a moment to swap pages before the first attempt
        $mainHwnd = [HiddenLogin]::FindArcMainWindow()
        if ($mainHwnd -ne [IntPtr]::Zero) {
            [HiddenLogin]::ClickAt($mainHwnd, 288, 405)   # Arc's Play button (confirmed coordinate)
            Write-Log 'clicked Play automatically (show arc mode)'
            $a.Phase = 'waiting'
        }
    }
    elseif ($a.Phase -eq 'waiting') {
        if ($elapsed -gt $TimeoutSeconds) {
            Finish-Active 'Timed out waiting for a game client' $cAmber $true
        }
    }
    elseif ($a.Phase -eq 'closing') {
        # no delay: Arc is closed the instant the launcher/patcher (or game client) is detected
        # close only the Arc process(es) that were started for this launch
        foreach ($p in (Get-ArcPids | Where-Object { $a.ArcBase -notcontains $_ })) {
            Stop-ProcessLogged $p
        }
        if ($a.Row.GamePid) {
            Stop-LaunchTools $a.LaunchBase $a.Row
            Finish-Active ("Running (PID " + $a.Row.GamePid + ")") $cGreen
        } else {
            # Arc is closed; the row picks up its game client when it appears
            $waitRow = $a.Row
            $waitRow.Pending = @{ Since = Get-Date; Base = $a.GameBase; LaunchBase = $a.LaunchBase; LastStartClickAt = $null; SawTool = $false; ToolFirstSeenAt = $null; HideTools = $false }   # Show Arc Mode: the launcher/patcher stays visible
            Finish-Active 'Arc closed - waiting for game client (CANCEL to stop)' $cWhite
            $waitRow.Button.Text = 'CANCEL'
        }
    }
}

# ---------- remembering running game clients between runs (session.txt: username <TAB> pid <TAB> start time) ----------
$script:LastSession = ''
function Get-ProcStart([int]$id) {
    try { return (Get-Process -Id $id -ErrorAction Stop).StartTime.ToFileTimeUtc() } catch { return 0 }
}
function Get-SessionText {
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $script:Rows) {
        if (-not $r.GamePid) { continue }
        if ($r.GameStartPid -ne $r.GamePid) { $r.GameStartPid = $r.GamePid; $r.GameStart = Get-ProcStart $r.GamePid }
        $u = $r.Box.Text.Trim()
        if (-not $r.GameStart -or $u -eq '') { continue }
        [void]$sb.Append($u + "`t" + $r.GamePid + "`t" + $r.GameStart + "`r`n")
    }
    return $sb.ToString()
}
function Save-Session {
    $now = Get-SessionText
    if ($now -ceq $script:LastSession) { return }
    $script:LastSession = $now
    try {
        if ($now -eq '') { if (Test-Path $SessionFile) { Remove-Item -Path $SessionFile -Force } }
        else { [System.IO.File]::WriteAllText($SessionFile, $now, (New-Object System.Text.UTF8Encoding($false))) }
    } catch { }
}
# at start-up: game clients that were running when the manager was closed are picked up again
function Adopt-Session {
    if (-not (Test-Path $SessionFile)) { return }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($SessionFile) } catch { return }
    $games = @(Get-GamePids)
    foreach ($line in ($text -split "`n")) {
        $parts = $line.TrimEnd("`r") -split "`t"
        if ($parts.Count -lt 3) { continue }
        $user = $parts[0]
        $id = [int]0
        $saved = [long]0
        if (-not [int]::TryParse($parts[1], [ref]$id)) { continue }
        if (-not [long]::TryParse($parts[2], [ref]$saved)) { continue }
        if ($games -notcontains $id) { continue }
        if ((Get-ProcStart $id) -ne $saved) { continue }
        if ((Get-ClaimedPids) -contains $id) { continue }
        foreach ($r in $script:Rows) {
            if ($r.GamePid -or $r.Box.Text.Trim() -ne $user) { continue }
            $r.GamePid = $id
            $r.GameStartPid = $id
            $r.GameStart = $saved
            Set-Status $r ('Running (PID ' + $id + ')' <# + ' - found again' #>) $cGreen
            $r.Stop.Enabled = $true
            Write-Log ('found game client ' + $id + ' again for row ' + ($script:Rows.IndexOf($r) + 1))
            break
        }
    }
    $script:LastSession = $text
    Save-Session   # forget entries that were not found
}
# the game windows get the Notes text of their row as title (only the game client: not the launcher or patcher).
# The client opens and closes windows while it loads, so for a while after it started every large visible window is re-checked every second.
function Apply-WindowTitles {
    if (-not $RenameGameWindows) { return }
    foreach ($r in $script:Rows) {
        if (-not $r.GamePid) { $r.TitlePid = $null; $r.TitleSeen = $null; continue }
        if ($r.TitlePid -ne $r.GamePid) { $r.TitlePid = $r.GamePid; $r.Title = ''; $r.TitleSeen = $null; $r.TitleLogs = 0 }
        $notes = $r.Notes.Text.Trim()
        # how long ago did the client start? (start time of the process; the first sighting if that is unknown)
        $age = 0.0
        if ($r.GameStart) { $age = ([DateTime]::UtcNow.ToFileTimeUtc() - $r.GameStart) / 10000000.0 }
        else {
            if (-not $r.TitleSeen) { $r.TitleSeen = Get-Date }
            $age = ((Get-Date) - $r.TitleSeen).TotalSeconds
        }
        $inPeriod = ($age -lt $RenameDurationSeconds)
        $notesChanged = ($notes -cne $r.Title)   # $r.Title = the Notes text handled last
        if ((-not $inPeriod) -and (-not $notesChanged)) { continue }
        if ($notes -eq '') { $r.Title = $notes; continue }
        $res = ([WinTitle]::Rename([int]$r.GamePid, $notes)).Split(';')
        $found = [int]$res[0]
        $renamed = [int]$res[1]
        if ($renamed -gt 0 -and $r.TitleLogs -lt 40) {
            $r.TitleLogs = $r.TitleLogs + 1
            $more = ''
            if ($r.TitleLogs -eq 40) { $more = ' - further renames are not logged' }
            Write-Log ('renamed ' + $renamed + ' game window(s) of row ' + ($script:Rows.IndexOf($r) + 1) + ' (window class ' + $res[2] + ')' + $more)
        }
        if ($inPeriod -or $found -gt 0) { $r.Title = $notes }   # after the period: keep trying only until a window was found
    }
}
# transient messages (Stopped, Cancelled, Timed out...) go back to Idle after a while
function Expire-Statuses {
    if ($StatusResetSeconds -le 0) { return }
    foreach ($r in $script:Rows) {
        if ((-not $r.StatusTransient) -or ($r.Pending -ne $null)) { continue }
        if (($script:Active -ne $null) -and ($script:Active.Row -eq $r)) { continue }
        if (((Get-Date) - $r.StatusSince).TotalSeconds -ge $StatusResetSeconds) { Set-Status $r 'Idle' $cGray }
    }
}

# ---------- background image ----------
$script:BgSource = $null
$script:BgStream = $null

function Set-DoubleBuffered($ctl) {
    try {
        $ctl.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($ctl, $true, $null)
    } catch { }
}
function Find-BackgroundPath {
    if ($BackgroundImage -ne '') {
        if (Test-Path $BackgroundImage) { return $BackgroundImage }
        Write-Log ('background not found: ' + $BackgroundImage)
    }
    foreach ($dir in @($ScriptDir, $ConfigDir)) {
        foreach ($ext in @('png', 'jpg', 'jpeg', 'bmp', 'gif')) {
            $c = Join-Path $dir ('background.' + $ext)
            if (Test-Path $c) { return $c }
        }
    }
    return $null
}
# The built-in default background is a Base64 text block at the very END of this file (between the two marker lines).
# It is used when no background picture is set or found. To use another built-in picture, replace the text between the
# marker lines with the Base64 text of your PNG:  [Convert]::ToBase64String([IO.File]::ReadAllBytes('picture.png'))
function Get-BuiltInBackgroundBytes {
    try {
        $text = [System.IO.File]::ReadAllText($ScriptPath)
        $begin = 'BUILTIN-BACK' + 'GROUND-BEGIN'   # (written in two pieces so that this line itself is not mistaken for the marker)
        $end = 'BUILTIN-BACK' + 'GROUND-END'
        $i = $text.LastIndexOf($begin)
        if ($i -lt 0) { return $null }
        $i = $i + $begin.Length
        $j = $text.IndexOf($end, $i)
        if ($j -lt 0) { return $null }
        return [Convert]::FromBase64String(($text.Substring($i, $j - $i) -replace '\s', ''))
    } catch { return $null }
}
function Set-BackgroundFromBytes($bytes, [string]$label) {
    # read into memory so a file is not locked and can be swapped while the manager runs
    $script:BgStream = New-Object System.IO.MemoryStream(, $bytes)
    $script:BgSource = [System.Drawing.Image]::FromStream($script:BgStream)
    Write-Log ('background loaded: ' + $label)
}
function Load-Background {
    $path = Find-BackgroundPath
    if ($path) {   # 1) your own picture (settings file, next to the program, or %AppData%\ArcManager)
        try { Set-BackgroundFromBytes ([System.IO.File]::ReadAllBytes($path)) $path; return }
        catch { $script:BgSource = $null; Write-Log ('background failed to load: ' + $_.Exception.Message + ' (using the built-in image)') }
    }
    # 2) the built-in default picture
    $bytes = Get-BuiltInBackgroundBytes
    if ($null -eq $bytes) { Write-Log 'no background image available'; return }
    try { Set-BackgroundFromBytes $bytes '(built-in default)' }
    catch { $script:BgSource = $null; Write-Log ('built-in background failed to load: ' + $_.Exception.Message) }
}
# draws the image to fill the window (cropped, not stretched) with a dark overlay
function Update-Background {
    if ($script:BgSource -eq $null) { return }
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    if ($w -lt 10 -or $h -lt 10) { return }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear($cBg)
        $sw = $script:BgSource.Width
        $sh = $script:BgSource.Height
        $mode = ([string]$BackgroundMode).Trim().ToLower()
        if ($mode -eq 'tile' -and ($sw -lt 4 -or $sh -lt 4)) { $mode = 'stretch' }
        if ($mode -eq 'tile') {
            for ($ty = 0; $ty -lt $h; $ty += $sh) {
                for ($tx = 0; $tx -lt $w; $tx += $sw) {
                    $g.DrawImage($script:BgSource, [int]$tx, [int]$ty, [int]$sw, [int]$sh)
                }
            }
        } else {
            if ($mode -eq 'stretch') { $dw = $w; $dh = $h }
            elseif ($mode -eq 'fit') { $scale = [math]::Min($w / $sw, $h / $sh); $dw = $sw * $scale; $dh = $sh * $scale }
            elseif ($mode -eq 'center') { $dw = $sw; $dh = $sh }
            else { $scale = [math]::Max($w / $sw, $h / $sh); $dw = $sw * $scale; $dh = $sh * $scale }
            $g.DrawImage($script:BgSource, [single](($w - $dw) / 2), [single](($h - $dh) / 2), [single]$dw, [single]$dh)
        }
        if ($BackgroundDim -gt 0) {
            $alpha = [int][math]::Min(255, [math]::Max(0, 255 * $BackgroundDim))
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, 0, 0, 0))
            $g.FillRectangle($brush, 0, 0, $w, $h)
            $brush.Dispose()
        }
    } finally { $g.Dispose() }
    $old = $form.BackgroundImage
    $form.BackgroundImageLayout = 'None'
    $form.BackgroundImage = $bmp
    if ($old -ne $null) { $old.Dispose() }
}

# close any Arc left running (e.g. a signed-in instance) before doing anything else
Start-NewLog
if (-not $PrivateMode) { Initialize-ArcPath }   # the configured Arc.exe is missing: look for it
if ($KillArcOnStart -and -not $PrivateMode) {   # (private server mode never touches Arc)
    $startArc = @(Get-ArcPids)
    if ($startArc.Count -gt 0) {
        Write-Log ('manager start: closing ' + $startArc.Count + ' running Arc process(es)')
        foreach ($p in $startArc) { Stop-ProcessLogged $p }
    }
}

# ---------- settings window (gear button) ----------
# whole-number settings (text boxes); the variable of the same name holds the value
$script:NumFields = @(
    @{ Key = 'WindowWidth';           Label = 'Window width';                   Min = 1040; Max = 7680 },
    @{ Key = 'WindowHeight';          Label = 'Window height';                  Min = 420; Max = 4320 },
    @{ Key = 'UsernameFocusTabs';     Label = 'Tabs before username box';       Min = 0;   Max = 20 },
    @{ Key = 'FieldSeparatorTabs';    Label = 'Tabs between the two boxes';     Min = 0;   Max = 20 },
    @{ Key = 'LoginDelayMs';          Label = 'Login delay (milliseconds)';     Min = 0;   Max = 60000 },
    @{ Key = 'MinWaitSeconds';        Label = 'Minimum wait (seconds)';         Min = 0;   Max = 600 },
    @{ Key = 'WindowTimeoutSeconds';  Label = 'Login window timeout (seconds)'; Min = 1;   Max = 600 },
    @{ Key = 'TimeoutSeconds';        Label = 'Give up after (seconds)';        Min = 10;  Max = 86400 },
    @{ Key = 'PendingTimeoutSeconds'; Label = 'Game wait after close (seconds)'; Min = 10; Max = 86400 },
    @{ Key = 'RenameDurationSeconds'; Label = 'Rename duration (seconds)';      Min = 10;  Max = 3600 },
    @{ Key = 'StatusResetSeconds';    Label = 'Reset status after (seconds)'; Min = 0; Max = 86400 },
    @{ Key = 'PrivateWindowWaitSeconds';    Label = 'Wait for the game window (sec)';  Min = 1; Max = 3600 },
    @{ Key = 'PrivateFirstKeyDelaySeconds'; Label = 'Wait before the first key (sec)'; Min = 0; Max = 600 },
    @{ Key = 'PrivateEntersBefore';         Label = 'Enter/Escape presses for the pop-up';    Min = 0; Max = 10 },
    @{ Key = 'PrivatePauseAfterPopupMs';    Label = 'Pause after the pop-up (ms)';     Min = 0; Max = 60000 },
    @{ Key = 'PrivatePauseStepMs';          Label = 'Pause between steps (ms)';        Min = 0; Max = 60000 },
    @{ Key = 'PrivateTabs';                 Label = 'Tabs between the two boxes';      Min = 0; Max = 10 },
    @{ Key = 'PrivateClearBackspaces';      Label = 'Backspaces to clear a box';       Min = 0; Max = 60 },
    @{ Key = 'EntersBefore';                Label = 'Enter/Escape presses for the pop-up'; Min = 0; Max = 10 },
    @{ Key = 'PauseAfterPopupMs';           Label = 'Pause after the pop-up (ms)';     Min = 0; Max = 60000 },
    @{ Key = 'ClearBackspaces';             Label = 'Backspaces to clear a box';       Min = 0; Max = 60 },
    @{ Key = 'HiddenKeyDelayMs';            Label = 'Key press hold (ms)';             Min = 0; Max = 5000 },
    @{ Key = 'HiddenCharDelayMs';           Label = 'Delay between characters (ms)';   Min = 0; Max = 5000 },
    @{ Key = 'HiddenPostTabDelayMs';        Label = 'Pause after Tab (ms)';            Min = 0; Max = 5000 },
    @{ Key = 'HiddenPostFieldDelayMs';      Label = 'Pause after each box (ms)';       Min = 0; Max = 5000 },
    @{ Key = 'HiddenHideSettleDelayMs';     Label = 'Pause after hiding (ms)';         Min = 0; Max = 5000 },
    @{ Key = 'HiddenSignInTimeoutSeconds';  Label = 'Give up finding Sign In (sec)';   Min = 1; Max = 3600 },
    @{ Key = 'HiddenSignInPollIntervalMs';  Label = 'Check for Sign In every (ms)';    Min = 100; Max = 10000 },
    @{ Key = 'HiddenMainWindowInitialDelayMs'; Label = 'Wait before looking for Play (ms)'; Min = 0; Max = 20000 },
    @{ Key = 'HiddenMainWindowTimeoutSeconds'; Label = 'Give up finding Play (sec)';   Min = 1; Max = 3600 },
    @{ Key = 'HiddenMainWindowPollIntervalMs'; Label = 'Check for Play every (ms)';    Min = 100; Max = 10000 },
    @{ Key = 'HiddenPatcherWaitTimeoutSeconds'; Label = 'Watch for the launcher (sec)'; Min = 0; Max = 3600 },
    @{ Key = 'HiddenPatcherWaitPollIntervalMs'; Label = 'Check for the launcher every (ms)'; Min = 100; Max = 10000 },
    # clicking Start on the launcher/patcher (applies to both Launcher Modes)
    @{ Key = 'PatcherStartPollIntervalMs';   Label = 'Click Start every (ms)';       Min = 200; Max = 60000 },
    @{ Key = 'PatcherStartTimeoutSeconds';   Label = 'Give up clicking after (sec)'; Min = 1;   Max = 3600 }
)
# on/off settings (tick boxes)
$script:BoolFields = @('RememberWindowSize', 'AutoFill', 'ConfirmStop', 'KillArcOnStart', 'DebugLog', 'RenameGameWindows', 'ShowStorageHint', 'PrivateEnterAfterPassword', 'PrivateShowWarning', 'EnterAfterPassword', 'ClickPatcherStart', 'ClickArcPlay')
$script:ModeNames  = @('fill', 'fit', 'stretch', 'tile', 'center')
$script:ModeLabels = @('Fill', 'Fit', 'Stretch', 'Tile', 'Center')
$script:Ui = @{}
$script:PageBasic = New-Object System.Collections.ArrayList   # the controls of each top-level page (PageAdv = controls shown for Advanced regardless of sub-tab)
$script:PageAdv = New-Object System.Collections.ArrayList
$script:PagePriv = New-Object System.Collections.ArrayList
$script:PageAdvShared = New-Object System.Collections.ArrayList   # Advanced / Shared Settings sub-tab
$script:PageAdvHidden = New-Object System.Collections.ArrayList   # Advanced / Hidden Arc Mode sub-tab
$script:PageAdvShow = New-Object System.Collections.ArrayList     # Advanced / Show Arc Mode sub-tab
$script:AdvSub = 0   # 0 = Shared Settings (default), 1 = Hidden Arc Mode, 2 = Show Arc Mode
$script:PageList = $null                                       # while building: which page the new controls belong to
$script:SetDlg = $null
$script:SetTip = $null
$script:SetDirty = $false
$script:SetLoading = $false
$script:SetBuilt = $false

function Get-CurrentValues {
    $v = @{ PopupKey = $PopupKey; PrivatePopupKey = $PrivatePopupKey; PrivateClientPath = $PrivateClientPath; PrivateFlags = $PrivateFlags; PrivateProcessNames = $PrivateProcessNames; ArcPath = $ArcPath; BackgroundImage = $BackgroundImage; BackgroundMode = $BackgroundMode; BackgroundDim = $BackgroundDim; UseHiddenLogin = [bool]$UseHiddenLogin }
    foreach ($f in $script:NumFields) { $v[$f.Key] = [int](Get-Variable -Name $f.Key -Scope Script -ValueOnly) }
    foreach ($k in $script:BoolFields) { $v[$k] = [bool](Get-Variable -Name $k -Scope Script -ValueOnly) }
    return $v
}

# greys out the boxes that do not matter for the current choices
function Update-SEnabled {
    if (-not $script:SetBuilt) { return }
    $u = $script:Ui
    $priv = [bool]$PrivateMode   # private server mode: the Arc settings are not used, so they are greyed out
    $af = $u['AutoFill'].Checked
    foreach ($k in @('UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds', 'EntersBefore', 'PauseAfterPopupMs', 'ClearBackspaces', 'EnterAfterPassword', 'PopEnter', 'PopEsc')) { $u[$k].Enabled = ($af -and -not $priv) }
    $u['PendingTimeoutSeconds'].Enabled = (-not $priv)
    $u['TimeoutSeconds'].Enabled = (-not $priv)
    $u['RenameDurationSeconds'].Enabled = $u['RenameGameWindows'].Checked
    foreach ($k in @('ArcPath', 'BrowseArc', 'ModeHidden', 'ModeShow', 'KillArcOnStart')) { $u[$k].Enabled = (-not $priv) }
    $hl = $u['ModeHidden'].Checked
    $u['ClickPatcherStart'].Enabled = (-not $priv -and -not $hl)   # Show Arc Mode only - Hidden Arc Mode always clicks Start
    $u['PatcherStartPollIntervalMs'].Enabled = (-not $priv -and ($u['ClickPatcherStart'].Checked -or $hl))
    $u['PatcherStartTimeoutSeconds'].Enabled = (-not $priv -and ($u['ClickPatcherStart'].Checked -or $hl))
    foreach ($k in @('HiddenKeyDelayMs', 'HiddenCharDelayMs', 'HiddenPostTabDelayMs', 'HiddenPostFieldDelayMs', 'HiddenHideSettleDelayMs', 'HiddenSignInTimeoutSeconds', 'HiddenSignInPollIntervalMs', 'HiddenMainWindowInitialDelayMs', 'HiddenMainWindowTimeoutSeconds', 'HiddenMainWindowPollIntervalMs', 'HiddenPatcherWaitTimeoutSeconds', 'HiddenPatcherWaitPollIntervalMs')) { $u[$k].Enabled = ($hl -and -not $priv) }
    # the hidden method replaces the old visible pop-up/typing method, so grey the old one out while it is on
    foreach ($k in @('UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds', 'EntersBefore', 'PauseAfterPopupMs', 'ClearBackspaces', 'EnterAfterPassword', 'PopEnter', 'PopEsc', 'AutoFill')) { if ($u[$k].Enabled) { $u[$k].Enabled = -not $hl } }
    $u['ClickArcPlay'].Enabled = ($af -and -not $priv -and -not $hl)   # Show Arc Mode only - needs auto-fill to have submitted the credentials first
}
function Update-DimLabel {
    if ($script:Ui['DimLbl'] -eq $null) { return }
    $script:Ui['DimLbl'].Text = ([string]$script:Ui['Dim'].Value) + '%'
}
function Set-SDirty {
    if (-not $script:SetBuilt -or $script:SetLoading) { return }
    $script:SetDirty = $true
    Update-SEnabled
}
# fills the window from a hashtable of values
function Set-UiFromValues($v) {
    $script:SetLoading = $true
    $u = $script:Ui
    $u['ArcPath'].Text = [string]$v['ArcPath']
    $u['PrivateClientPath'].Text = [string]$v['PrivateClientPath']
    $u['PrivateFlags'].Text = [string]$v['PrivateFlags']
    $u['PrivateProcessNames'].Text = [string]$v['PrivateProcessNames']
    foreach ($f in $script:NumFields) { $u[$f.Key].Text = [string]$v[$f.Key] }
    foreach ($k in $script:BoolFields) { $u[$k].Checked = [bool]$v[$k] }
    $u['ModeHidden'].Checked = [bool]$v['UseHiddenLogin']
    $u['ModeShow'].Checked = -not [bool]$v['UseHiddenLogin']
    $u['PopEnter'].Checked = ($v['PopupKey'] -ne 'escape')
    $u['PopEsc'].Checked = ($v['PopupKey'] -eq 'escape')
    $u['PopupEnter'].Checked = ($v['PrivatePopupKey'] -ne 'escape')
    $u['PopupEsc'].Checked = ($v['PrivatePopupKey'] -eq 'escape')
    $u['BackgroundImage'].Text = [string]$v['BackgroundImage']
    $mi = 0
    for ($i = 0; $i -lt 5; $i++) { if ($v['BackgroundMode'] -eq $script:ModeNames[$i]) { $mi = $i } }
    for ($i = 0; $i -lt 5; $i++) { $u['Mode' + $i].Checked = ($i -eq $mi) }
    $u['Dim'].Value = [int][math]::Min(100, [math]::Max(0, [math]::Round([double]$v['BackgroundDim'] * 100)))
    Update-DimLabel
    $script:SetLoading = $false
    Update-SEnabled
}
function Show-SWarn([string]$text, $ctl) {
    [void][System.Windows.Forms.MessageBox]::Show($script:SetDlg, $text, 'Configuration', 'OK', 'Warning')
    if ($ctl -ne $null) {
        $ctl.Focus()
        if ($ctl -is [System.Windows.Forms.TextBox]) { $ctl.SelectAll() }
    }
}
# reads the window; shows a message and returns $null when something is not valid
function Read-UiValues {
    $u = $script:Ui
    $v = @{}
    $arc = $u['ArcPath'].Text.Trim()
    if ($arc -eq '' -or -not (Test-ArcExeName $arc)) {
        Show-SWarn "The Arc Location must point to a file named Arc.exe.`n`nFor safety the manager only launches a program with that name." $u['ArcPath']
        return $null
    }
    $v['ArcPath'] = $arc
    $v['PrivateClientPath'] = $u['PrivateClientPath'].Text.Trim()
    $v['PrivateFlags'] = $u['PrivateFlags'].Text.Trim()
    $v['PrivateProcessNames'] = $u['PrivateProcessNames'].Text.Trim()
    if ($v['PrivateProcessNames'] -eq '') {
        Show-SWarn 'Enter at least one process name for the game client (for example elementclient.exe).' $u['PrivateProcessNames']
        return $null
    }
    foreach ($f in $script:NumFields) {
        $t = $u[$f.Key].Text.Trim()
        $ok = ($t -match '^\d{1,6}$')
        $n = 0
        if ($ok) {
            $n = [int]$t
            if ($n -lt $f.Min -or $n -gt $f.Max) { $ok = $false }
        }
        if (-not $ok) {
            Show-SWarn ('"' + $f.Label + '" must be a whole number from ' + $f.Min + ' to ' + $f.Max + '.') $u[$f.Key]
            return $null
        }
        $v[$f.Key] = $n
    }
    foreach ($k in $script:BoolFields) { $v[$k] = [bool]$u[$k].Checked }
    $v['UseHiddenLogin'] = [bool]$u['ModeHidden'].Checked
    $v['PopupKey'] = 'enter'
    if ($u['PopEsc'].Checked) { $v['PopupKey'] = 'escape' }
    $v['PrivatePopupKey'] = 'enter'
    if ($u['PopupEsc'].Checked) { $v['PrivatePopupKey'] = 'escape' }
    $bg = $u['BackgroundImage'].Text.Trim()
    if ($bg -ne '' -and -not (Test-Path -LiteralPath $bg)) {
        Show-SWarn ("The background image file was not found:`n" + $bg + "`n`nFix the path, or clear the box to use the default background.") $u['BackgroundImage']
        return $null
    }
    $v['BackgroundImage'] = $bg
    $v['BackgroundMode'] = 'fill'
    for ($i = 0; $i -lt 5; $i++) { if ($u['Mode' + $i].Checked) { $v['BackgroundMode'] = $script:ModeNames[$i] } }
    $v['BackgroundDim'] = [double]$u['Dim'].Value / 100.0
    return $v
}
# makes the values the active settings
function Apply-Values($v) {
    $script:ArcPath = $v['ArcPath']
    $script:PrivateClientPath = $v['PrivateClientPath']
    $script:PrivateFlags = $v['PrivateFlags']
    $script:PrivateProcessNames = $v['PrivateProcessNames']
    foreach ($f in $script:NumFields) { Set-Variable -Name $f.Key -Value ([int]$v[$f.Key]) -Scope Script }
    foreach ($k in $script:BoolFields) { Set-Variable -Name $k -Value ([bool]$v[$k]) -Scope Script }
    $script:UseHiddenLogin = [bool]$v['UseHiddenLogin']
    $script:PopupKey = $v['PopupKey']
    $script:PrivatePopupKey = $v['PrivatePopupKey']
    $script:BackgroundImage = $v['BackgroundImage']
    $script:BackgroundMode = $v['BackgroundMode']
    $script:BackgroundDim = [double]$v['BackgroundDim']
    $script:UsernameFocusKeys = '{TAB}' * $script:UsernameFocusTabs
    $script:FieldSeparatorKeys = '{TAB}' * $script:FieldSeparatorTabs
}
# writes every setting that has a box in the window; comments and other lines in the file stay as they are
function Write-SettingsToIni($v) {
    $ok = $true
    if (-not [IniFile]::Put($IniFile, 'ArcPath', [string]$v['ArcPath'])) { $ok = $false }
    foreach ($k in @('PrivateClientPath', 'PrivateFlags', 'PrivateProcessNames')) { if (-not [IniFile]::Put($IniFile, $k, [string]$v[$k])) { $ok = $false } }
    foreach ($f in $script:NumFields) { if (-not [IniFile]::Put($IniFile, $f.Key, [string]$v[$f.Key])) { $ok = $false } }
    foreach ($k in $script:BoolFields) {
        $t = '0'
        if ($v[$k]) { $t = '1' }
        if (-not [IniFile]::Put($IniFile, $k, $t)) { $ok = $false }
    }
    $hlt = '0'; if ($v['UseHiddenLogin']) { $hlt = '1' }
    if (-not [IniFile]::Put($IniFile, 'UseHiddenLogin', $hlt)) { $ok = $false }
    if (-not [IniFile]::Put($IniFile, 'PopupKey', [string]$v['PopupKey'])) { $ok = $false }
    if (-not [IniFile]::Put($IniFile, 'PrivatePopupKey', [string]$v['PrivatePopupKey'])) { $ok = $false }
    if (-not [IniFile]::Put($IniFile, 'BackgroundImage', [string]$v['BackgroundImage'])) { $ok = $false }
    if (-not [IniFile]::Put($IniFile, 'BackgroundMode', [string]$v['BackgroundMode'])) { $ok = $false }
    $dimText = ([double]$v['BackgroundDim']).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not [IniFile]::Put($IniFile, 'BackgroundDim', $dimText)) { $ok = $false }
    return $ok
}
# swaps in a different background while the program is running
function Reload-Background {
    if ($script:BgSource -ne $null) { $script:BgSource.Dispose(); $script:BgSource = $null }
    if ($script:BgStream -ne $null) { $script:BgStream.Dispose(); $script:BgStream = $null }
    Load-Background
    if ($script:BgSource -ne $null) { Update-Background }
    else {
        $old = $form.BackgroundImage
        $form.BackgroundImage = $null
        if ($old -ne $null) { $old.Dispose() }
    }
}
# resizes the main window so its inside area is exactly w x h (kept on screen)
# the inside size of the main window, or the size it will have once restored when it is maximized / minimized
function Get-RestoredClientSize {
    if ($form.WindowState -eq 'Normal') { return $form.ClientSize }
    $rb = $form.RestoreBounds
    return New-Object System.Drawing.Size(($rb.Width - $script:FrameW), ($rb.Height - $script:FrameH))
}
function Set-FormClientSize([int]$w, [int]$h) {
    if ($form.WindowState -ne 'Normal') { return }
    $form.ClientSize = New-Object System.Drawing.Size($w, $h)
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $x = [math]::Max($wa.Left, [math]::Min($form.Left, ($wa.Right - $form.Width)))
    $y = [math]::Max($wa.Top, [math]::Min($form.Top, ($wa.Bottom - $form.Height)))
    $form.Location = New-Object System.Drawing.Point($x, $y)
    Update-Background
}
function Save-Settings {
    $v = Read-UiValues
    if ($v -eq $null) { return }
    $bgChanged = ($v['BackgroundImage'] -ne $BackgroundImage) -or ($v['BackgroundMode'] -ne $BackgroundMode) -or ([math]::Abs([double]$v['BackgroundDim'] - $BackgroundDim) -gt 0.0001)
    $cur = Get-RestoredClientSize
    $sizeChanged = ($v['WindowWidth'] -ne $cur.Width) -or ($v['WindowHeight'] -ne $cur.Height)
    $logWasOff = -not $DebugLog
    Apply-Values $v
    $wrote = Write-SettingsToIni $v
    # everything takes effect right away; no restart needed
    if ($logWasOff -and $DebugLog) { Start-NewLog }
    $hintPanel.Visible = [bool]$ShowStorageHint
    if ($bgChanged) { Reload-Background }
    if ($sizeChanged) {
        if ($form.WindowState -ne 'Normal') { $form.WindowState = 'Normal' }   # a maximized window cannot be resized: restore it first
        Set-FormClientSize $v['WindowWidth'] $v['WindowHeight']
    }
    if (-not $wrote) {
        [void][System.Windows.Forms.MessageBox]::Show($script:SetDlg, ("The settings are active now, but the settings file could not be written:`n" + $IniFile), 'Configuration', 'OK', 'Warning')
    }
    $script:SetDirty = $false
    $script:SetDlg.Close()
}

# ---- small builders (x / y are positions inside the settings window, even for controls inside a group box)
function Add-SCtl($parent, $ctl, [int]$x, [int]$y, [int]$w, [int]$h) {
    $ox = 0
    $oy = 0
    if ($parent -is [System.Windows.Forms.GroupBox]) { $ox = $parent.Left; $oy = $parent.Top }
    $ctl.SetBounds(($x - $ox), ($y - $oy), $w, $h)
    $parent.Controls.Add($ctl)
    if ($null -ne $script:PageList) { [void]$script:PageList.Add($ctl) }   # (null on the LEFT: an empty list on the left would count as false)
}
function New-SGroup([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $c = New-Object System.Windows.Forms.GroupBox
    $c.Text = $text
    Add-SCtl $script:SetDlg $c $x $y $w $h
    return $c
}
function New-SLabel($parent, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text
    $c.AutoSize = $false
    $c.TextAlign = 'MiddleLeft'
    Add-SCtl $parent $c $x $y $w $h
    return $c
}
function New-SEdit($parent, [string]$key, [int]$x, [int]$y, [int]$w, [bool]$numeric) {
    $c = New-Object System.Windows.Forms.TextBox
    if ($numeric) {
        $c.MaxLength = 6
        $c.Add_KeyPress({ param($s, $e) if (-not [char]::IsControl($e.KeyChar) -and -not [char]::IsDigit($e.KeyChar)) { $e.Handled = $true } })
    } else { $c.MaxLength = 520 }
    $c.Add_TextChanged({ Set-SDirty })
    Add-SCtl $parent $c $x $y $w 23
    $script:Ui[$key] = $c
    return $c
}
function New-SCheck($parent, [string]$key, [string]$text, [int]$x, [int]$y, [int]$w) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.AutoSize = $false
    $c.Add_CheckedChanged({ Set-SDirty })
    Add-SCtl $parent $c $x $y $w 20
    $script:Ui[$key] = $c
    return $c
}
function New-SRadio($parent, [string]$key, [string]$text, [int]$x, [int]$y, [int]$w) {
    $c = New-Object System.Windows.Forms.RadioButton
    $c.Text = $text
    $c.AutoSize = $false
    $c.Add_CheckedChanged({ Set-SDirty })
    Add-SCtl $parent $c $x $y $w 20
    $script:Ui[$key] = $c
    return $c
}
function New-SButton([string]$key, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $c = New-Object System.Windows.Forms.Button
    $c.Text = $text
    $c.UseVisualStyleBackColor = $true
    Add-SCtl $script:SetDlg $c $x $y $w $h
    $script:Ui[$key] = $c
    return $c
}
# a label + whole-number box on one line
function New-SNumRow($parent, [string]$key, [int]$labelX, [int]$labelW, [int]$editX, [int]$editW, [int]$y) {
    $label = ''
    foreach ($f in $script:NumFields) { if ($f.Key -eq $key) { $label = $f.Label } }
    [void](New-SLabel $parent $label $labelX $y $labelW 23)
    [void](New-SEdit $parent $key $editX $y $editW $true)
}
# which of the three Advanced sub-tabs is showing (only matters while page 1 itself is showing)
function Show-AdvSub([int]$sub) {
    $script:AdvSub = if ($sub -eq 1 -or $sub -eq 2) { $sub } else { 0 }
    foreach ($c in $script:PageAdvShared) { $c.Visible = ($script:AdvSub -eq 0) }
    foreach ($c in $script:PageAdvHidden) { $c.Visible = ($script:AdvSub -eq 1) }
    foreach ($c in $script:PageAdvShow) { $c.Visible = ($script:AdvSub -eq 2) }
    $script:Ui['AdvSubShared'].Checked = ($script:AdvSub -eq 0)
    $script:Ui['AdvSubHidden'].Checked = ($script:AdvSub -eq 1)
    $script:Ui['AdvSubShow'].Checked = ($script:AdvSub -eq 2)
}
function Show-SettingsPage([int]$page) {
    foreach ($c in $script:PageBasic) { $c.Visible = ($page -eq 0) }
    foreach ($c in $script:PageAdv) { $c.Visible = ($page -eq 1) }
    foreach ($c in $script:PagePriv) { $c.Visible = ($page -eq 2) }
    $onAdv = ($page -eq 1)
    foreach ($c in $script:PageAdvShared) { $c.Visible = ($onAdv -and $script:AdvSub -eq 0) }
    foreach ($c in $script:PageAdvHidden) { $c.Visible = ($onAdv -and $script:AdvSub -eq 1) }
    foreach ($c in $script:PageAdvShow) { $c.Visible = ($onAdv -and $script:AdvSub -eq 2) }
    $script:Ui['PageBasic'].Checked = ($page -eq 0)
    $script:Ui['PageAdv'].Checked = ($page -eq 1)
    $script:Ui['PagePriv'].Checked = ($page -eq 2)
}
function Browse-Into([string]$key, [string]$filter, [string]$title) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $filter
    $dlg.Title = $title
    $dlg.CheckFileExists = $true
    $cur = $script:Ui[$key].Text.Trim()
    try {
        if ($cur -ne '' -and (Test-Path -LiteralPath $cur)) { $dlg.FileName = $cur }
        elseif ($cur -ne '' -and (Test-Path -LiteralPath (Split-Path -Parent $cur))) { $dlg.InitialDirectory = (Split-Path -Parent $cur) }
    } catch { }
    if ($dlg.ShowDialog($script:SetDlg) -eq 'OK') { $script:Ui[$key].Text = $dlg.FileName }
    $dlg.Dispose()
}

function Show-Settings {
    $script:Ui = @{}
    $script:SetBuilt = $false
    $script:SetDirty = $false
    $dlg = New-Object System.Windows.Forms.Form
    $script:SetDlg = $dlg
    $dlg.Text = 'Configuration'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.AutoScaleMode = 'None'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 558)
    $dlg.BackColor = [System.Drawing.SystemColors]::Control
    $dlg.ForeColor = [System.Drawing.SystemColors]::ControlText
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 20000
    $script:SetTip = $tt

    $script:PageBasic.Clear()
    $script:PageAdv.Clear()
    $script:PagePriv.Clear()
    $script:PageAdvShared.Clear()
    $script:PageAdvHidden.Clear()
    $script:PageAdvShow.Clear()
    $script:AdvSub = 0
    $script:PageList = $null
    $title = New-SLabel $dlg 'CONFIGURATION' 16 8 250 36
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    # two push-like radio buttons switch between the pages
    $pb = New-Object System.Windows.Forms.RadioButton
    $pb.Text = 'Basic'
    $pb.Appearance = 'Button'
    $pb.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $pb 276 14 70 26
    $script:Ui['PageBasic'] = $pb
    $pa = New-Object System.Windows.Forms.RadioButton
    $pa.Text = 'Advanced'
    $pa.Appearance = 'Button'
    $pa.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $pa 350 14 84 26
    $script:Ui['PageAdv'] = $pa
    $pv = New-Object System.Windows.Forms.RadioButton
    $pv.Text = 'Private Servers'
    $pv.Appearance = 'Button'
    $pv.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $pv 438 14 186 26
    $script:Ui['PagePriv'] = $pv
    $pv.Add_Click({ Show-SettingsPage 2 })
    $pb.Add_Click({ Show-SettingsPage 0 })
    $pa.Add_Click({ Show-SettingsPage 1 })

    $script:PageList = $script:PageBasic   # the Arc location is part of the Basic page only
    [void](New-SLabel $dlg 'Arc Location' 16 50 300 20)
    [void](New-SEdit $dlg 'ArcPath' 16 72 520 $false)
    $b1 = New-SButton 'BrowseArc' 'Browse...' 544 71 80 25
    $b1.Add_Click({ Browse-Into 'ArcPath' 'Arc.exe|Arc.exe|All files|*.*' 'Locate Arc.exe' })

    # ======== page 1: Basic
    $script:PageList = $script:PageBasic
    $g = New-SGroup 'Main window' 16 106 300 84
    [void](New-SLabel $g 'Width' 28 128 42 23)
    [void](New-SEdit $g 'WindowWidth' 72 128 58 $true)
    [void](New-SLabel $g 'Height' 144 128 44 23)
    [void](New-SEdit $g 'WindowHeight' 190 128 58 $true)
    [void](New-SLabel $g 'pixels' 256 128 44 23)
    [void](New-SCheck $g 'RememberWindowSize' 'Remember the size when closing' 28 158 266)

    $g = New-SGroup 'Launcher Mode' 16 198 300 82
    [void](New-SRadio $g 'ModeHidden' 'Hidden Arc Mode' 28 220 266)
    [void](New-SRadio $g 'ModeShow' 'Show Arc Mode' 28 244 266)

    $g = New-SGroup 'Options' 332 106 292 222
    [void](New-SCheck $g 'DebugLog' 'Debug / Logs' 344 130 270)
    [void](New-SCheck $g 'KillArcOnStart' 'Close running Arc at start / sign-in' 344 154 270)
    [void](New-SCheck $g 'AutoFill' 'Auto-fill username and password' 344 178 270)
    [void](New-SCheck $g 'ClickArcPlay' 'Auto-click Play (arc)' 344 202 270)
    [void](New-SCheck $g 'ClickPatcherStart' 'Auto-click Start (launcher/patcher)' 344 226 270)
    [void](New-SCheck $g 'RenameGameWindows' 'Rename game windows to Notes' 344 250 270)
    [void](New-SCheck $g 'ConfirmStop' 'Ask before stopping a game client' 344 274 270)
    [void](New-SCheck $g 'ShowStorageHint' 'Show plain-text storage notice' 344 298 270)

    $g = New-SGroup 'Background' 16 336 608 146
    [void](New-SLabel $g 'Background Image Location' 28 332 300 20)
    [void](New-SEdit $g 'BackgroundImage' 28 354 496 $false)
    $b2 = New-SButton 'BrowseBg' 'Browse...' 532 353 80 25
    $g.Controls.Add($b2)
    $b2.SetBounds((532 - $g.Left), (353 - $g.Top), 80, 25)
    $b2.Add_Click({ Browse-Into 'BackgroundImage' 'Pictures|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files|*.*' 'Choose a background image' })
    [void](New-SLabel $g 'Mode' 28 390 44 20)
    for ($i = 0; $i -lt 5; $i++) { [void](New-SRadio $g ('Mode' + $i) $script:ModeLabels[$i] (74 + $i * 96) 390 92) }
    [void](New-SLabel $g 'Darkness' 28 422 62 30)
    $tb = New-Object System.Windows.Forms.TrackBar
    $tb.Minimum = 0
    $tb.Maximum = 100
    $tb.TickFrequency = 10
    $tb.LargeChange = 10
    $tb.SmallChange = 1
    $tb.Add_ValueChanged({ Update-DimLabel; Set-SDirty })
    Add-SCtl $g $tb 92 418 420 40
    $script:Ui['Dim'] = $tb
    $dl = New-SLabel $g '50%' 520 422 80 30
    $script:Ui['DimLbl'] = $dl

    # ======== page 2: Advanced - one shared description, then three sub-tabs: Shared Settings (default), Hidden Arc Mode and Show Arc Mode
    $script:PageList = $script:PageAdv
    [void](New-SLabel $dlg 'Timing and fine-tuning. The defaults suit most computers.' 16 108 608 20)
    $sa = New-Object System.Windows.Forms.RadioButton
    $sa.Text = 'Shared Settings'
    $sa.Appearance = 'Button'
    $sa.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $sa 16 132 150 24
    $script:Ui['AdvSubShared'] = $sa
    $sh = New-Object System.Windows.Forms.RadioButton
    $sh.Text = 'Hidden Arc Mode'
    $sh.Appearance = 'Button'
    $sh.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $sh 172 132 150 24
    $script:Ui['AdvSubHidden'] = $sh
    $ss = New-Object System.Windows.Forms.RadioButton
    $ss.Text = 'Show Arc Mode'
    $ss.Appearance = 'Button'
    $ss.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $ss 328 132 150 24
    $script:Ui['AdvSubShow'] = $ss
    $sa.Add_Click({ Show-AdvSub 0 })
    $sh.Add_Click({ Show-AdvSub 1 })
    $ss.Add_Click({ Show-AdvSub 2 })

    # ---- Advanced / Shared Settings sub-tab (used by both Launcher Modes)
    $script:PageList = $script:PageAdvShared
    $g = New-SGroup 'Game clients and windows' 16 164 300 140
    $y = 192
    foreach ($k in @('PendingTimeoutSeconds', 'RenameDurationSeconds', 'StatusResetSeconds')) {
        New-SNumRow $g $k 28 205 240 58 $y
        $y += 30
    }
    $g = New-SGroup 'Clicking Start (launcher / patcher)' 332 164 292 100
    $y = 192
    foreach ($k in @('PatcherStartPollIntervalMs', 'PatcherStartTimeoutSeconds')) {
        New-SNumRow $g $k 344 210 556 56 $y
        $y += 30
    }

    # ---- Advanced / Show Arc Mode sub-tab (the old visible pop-up method's timing)
    $script:PageList = $script:PageAdvShow
    $g = New-SGroup 'Signing in' 16 164 300 200
    $y = 190
    foreach ($k in @('UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds')) {
        New-SNumRow $g $k 28 205 240 58 $y
        $y += 30
    }
    $g = New-SGroup 'Waiting for the game' 332 164 292 62
    New-SNumRow $g 'TimeoutSeconds' 344 210 556 56 190
    $g = New-SGroup 'Login pop-up and typing' 16 372 608 104
    New-SNumRow $g 'EntersBefore' 28 235 270 50 396
    [void](New-SLabel $g 'Key for the pop-up' 28 422 120 23)
    [void](New-SRadio $g 'PopEnter' 'Enter' 160 422 70)
    [void](New-SRadio $g 'PopEsc' 'Escape' 240 422 72)
    New-SNumRow $g 'PauseAfterPopupMs' 28 235 270 50 448
    New-SNumRow $g 'ClearBackspaces' 344 210 566 50 396
    [void](New-SCheck $g 'EnterAfterPassword' 'Press Enter after the password' 344 424 270)

    # ---- Advanced / Hidden Arc Mode sub-tab (the hidden sign-in's timing)
    $script:PageList = $script:PageAdvHidden
    $g = New-SGroup 'Signing in (hidden)' 16 164 300 212
    $y = 188
    foreach ($k in @('HiddenKeyDelayMs', 'HiddenCharDelayMs', 'HiddenPostTabDelayMs', 'HiddenPostFieldDelayMs', 'HiddenHideSettleDelayMs', 'HiddenSignInTimeoutSeconds', 'HiddenSignInPollIntervalMs')) {
        New-SNumRow $g $k 28 205 240 58 $y
        $y += 24
    }
    $g = New-SGroup 'After sign-in (clicking Play)' 332 164 292 100
    $y = 190
    foreach ($k in @('HiddenMainWindowInitialDelayMs', 'HiddenMainWindowTimeoutSeconds', 'HiddenMainWindowPollIntervalMs')) {
        New-SNumRow $g $k 344 210 556 56 $y
        $y += 26
    }
    $g = New-SGroup 'Waiting for the launcher / patcher' 332 276 292 80
    New-SNumRow $g 'HiddenPatcherWaitTimeoutSeconds' 344 210 556 56 302
    New-SNumRow $g 'HiddenPatcherWaitPollIntervalMs' 344 210 556 56 330

    # ======== page 3: Private Servers
    $script:PageList = $script:PagePriv
    [void](New-SLabel $dlg 'Used while the switch at the top of the main window is set to Private Servers. Arc is not used in that mode.' 16 108 608 20)
    $g = New-SGroup 'Program to start' 16 134 608 120
    [void](New-SLabel $g 'Client or launcher location (it starts in its own folder)' 28 154 400 20)
    [void](New-SEdit $g 'PrivateClientPath' 28 176 496 $false)
    $b3 = New-SButton 'BrowsePriv' 'Browse...' 532 175 80 25
    $g.Controls.Add($b3)
    $b3.SetBounds((532 - $g.Left), (175 - $g.Top), 80, 25)
    $b3.Add_Click({ Browse-Into 'PrivateClientPath' 'Programs (*.exe)|*.exe|All files|*.*' 'Locate the game client or launcher' })
    [void](New-SLabel $g 'Command-line flags (example: game:cpw nocheck startbypatcher console:1)' 28 202 580 20)
    [void](New-SEdit $g 'PrivateFlags' 28 224 584 $false)
    $g = New-SGroup 'Game client' 16 262 300 180
    [void](New-SLabel $g 'Process name(s) to wait for (use commas)' 28 282 280 20)
    [void](New-SEdit $g 'PrivateProcessNames' 28 304 272 $false)
    New-SNumRow $g 'PrivateWindowWaitSeconds' 28 205 240 58 339
    New-SNumRow $g 'PrivateFirstKeyDelaySeconds' 28 205 240 58 367
    [void](New-SCheck $g 'PrivateEnterAfterPassword' 'Press Enter after the password' 28 396 270)
    $g = New-SGroup 'Typing sequence' 332 262 292 180
    New-SNumRow $g 'PrivateEntersBefore' 344 220 566 50 286
    [void](New-SLabel $g 'Key for the pop-up' 344 314 120 23)
    [void](New-SRadio $g 'PopupEnter' 'Enter' 470 314 70)
    [void](New-SRadio $g 'PopupEsc' 'Escape' 544 314 72)
    $y = 338
    foreach ($k in @('PrivatePauseAfterPopupMs', 'PrivatePauseStepMs', 'PrivateTabs', 'PrivateClearBackspaces')) {
        New-SNumRow $g $k 344 220 566 50 $y
        $y += 26
    }
    [void](New-SCheck $dlg 'PrivateShowWarning' 'Show a warning when switching to Private Servers' 150 452 340)

    $script:PageList = $null

    # ======== buttons (always visible)
    $bd = New-SButton 'Defaults' 'LOAD DEFAULTS' 16 490 130 28
    $bf = New-SButton 'Folder' 'OPEN SETTINGS FOLDER' 154 490 176 28
    $bs = New-SButton 'Save' 'SAVE CONFIGURATION' 338 490 184 28
    $bc = New-SButton 'Cancel' 'CANCEL' 530 490 94 28
    $bc.DialogResult = 'Cancel'
    $dlg.AcceptButton = $bs
    $dlg.CancelButton = $bc
    $bd.Add_Click({
        $d = Get-DefaultValues
        Set-UiFromValues $d
        $script:SetDirty = $true
    })
    $bf.Add_Click({ [void][System.Diagnostics.Process]::Start($ConfigDir) })
    $bs.Add_Click({ Save-Settings })
    $info = New-SLabel $dlg ('Settings file: ' + $IniFile) 16 530 440 20
    $info.AutoEllipsis = $true
    $ver = New-SLabel $dlg (([string][char]169) + ' 2026 Sparc343') 464 530 160 20
    $ver.TextAlign = 'MiddleRight'

    # hover hints
    $tips = @{
        PageBasic = 'The settings most people use.'
        PageAdv = 'Timing and fine-tuning. The defaults suit most computers.'
        PagePriv = 'Settings for private servers (game servers that do not use Arc).'
        ModeHidden = "Hides Arc's window throughout the login process (it may flicker very briefly on your screen). The game's launcher / patcher window is hidden too."
        ModeShow = "Shows Arc's window and uses the old pop-up/auto-fill method to sign in."
        AdvSubShared = 'Settings used by both Hidden Arc Mode and Show Arc Mode.'
        AdvSubHidden = 'Timing for the hidden sign-in method (Hidden Arc Mode).'
        AdvSubShow = 'Timing for the old visible pop-up method (Show Arc Mode).'
        HiddenKeyDelayMs = 'How long each simulated key press is held down, in milliseconds.'
        HiddenCharDelayMs = 'Pause between typed characters, in milliseconds.'
        HiddenPostTabDelayMs = 'Pause after moving to the next box with Tab, in milliseconds.'
        HiddenPostFieldDelayMs = 'Pause after finishing a box (username or password), in milliseconds.'
        HiddenHideSettleDelayMs = "Pause right after hiding Arc's Sign In window, before typing begins."
        HiddenSignInTimeoutSeconds = "Give up if Arc's Sign In window has not appeared after this many seconds."
        HiddenSignInPollIntervalMs = "How often to check whether Arc's Sign In window has appeared, in milliseconds."
        HiddenMainWindowInitialDelayMs = "After pressing Enter on the password, wait this long before looking for Arc's main window."
        HiddenMainWindowTimeoutSeconds = "Give up if Arc's main window (where Play is clicked) has not appeared after this many seconds."
        HiddenMainWindowPollIntervalMs = "How often to check for Arc's main window, in milliseconds."
        HiddenPatcherWaitTimeoutSeconds = 'How long to watch for the launcher / patcher after clicking Play (for the log only; 0 skips this wait).'
        HiddenPatcherWaitPollIntervalMs = 'How often to check for the launcher / patcher, in milliseconds.'
        ClickArcPlay = "Show Arc Mode only: once auto-fill submits your username and password, automatically click Arc's own Play button too, instead of clicking it yourself. Hidden Arc Mode always does this."
        ClickPatcherStart = "Show Arc Mode only: once the launcher/patcher shows up, automatically click its Start button so the game client opens on its own. Hidden Arc Mode always does this (its launcher/patcher window is hidden)."
        PatcherStartPollIntervalMs = 'How often to click Start while waiting for the launcher/patcher to finish updating and launch the game. Applies to both Launcher Modes.'
        PatcherStartTimeoutSeconds = 'Give up clicking Start after this many seconds. Applies to both Launcher Modes.'
        PrivateClientPath = 'The game client (elementclient.exe) or the launcher / patcher of the private server. It is started with administrator rights.'
        PrivateFlags = 'Command-line flags, passed exactly as typed. Never put your password here.'
        PrivateShowWarning = 'Show a warning every time you switch the main window to Private Servers.'
        PrivateProcessNames = 'The real game client. If you start a launcher or patcher, the manager waits until one of these processes appears.'
        PrivateWindowWaitSeconds = 'Give up if the game client and its window have not appeared after this many seconds. Raise it if the server patches first.'
        PrivateFirstKeyDelaySeconds = 'After the game window appears, wait this long before the first key is pressed.'
        PrivateEntersBefore = 'How many times the key below is pressed first, for the message that appears before the login page (0 = none).'
        PopupEnter = 'Clear the start-up pop-up of the client with the Enter key.'
        EntersBefore = "Official game: how many times the key below is pressed before the username is typed (that clears any pop-ups before Arc's login page)."
        PopEnter = 'Clear the pop-up with the Enter key.'
        PopEsc = 'Clear the pop-up with the Escape key.'
        PauseAfterPopupMs = 'Pause after those key presses, so the login page can appear (only used when the count is above 0).'
        ClearBackspaces = 'Backspaces pressed before typing each box, to remove old text. 0 = none.'
        EnterAfterPassword = 'Press Enter after the password to log in (on by default).'
        PopupEsc = 'Clear the start-up pop-up of the client with the Escape key (some private servers need this).'
        PrivatePauseAfterPopupMs = 'Pause after the last of those Enter presses, so the login page can appear.'
        PrivatePauseStepMs = 'Pause between the other steps (typing the name, Tab, typing the password).'
        PrivateTabs = 'Tab presses between the username and the password.'
        PrivateClearBackspaces = 'Backspaces pressed before typing each box, to remove old text (for example a remembered username). 0 = none.'
        PrivateEnterAfterPassword = 'Press Enter after the password to log in.'
        ArcPath = 'Full path to Arc.exe. The file must be named Arc.exe. (If it is missing, the manager tries to find it by itself.)'
        Folder = 'Open the folder that holds the settings, accounts and log files.'
        WindowWidth = "Width of the manager window's inside area, in pixels (1040 or more)."
        WindowHeight = "Height of the manager window's inside area, in pixels (420 or more)."
        RememberWindowSize = 'Save the window size when the program closes, so it opens the same way next time.'
        AutoFill = 'Type the username and password into the Arc login window for you.'
        UsernameFocusTabs = "Tab key presses sent first, to move onto the username box in Arc's login window."
        FieldSeparatorTabs = 'Tab key presses sent between the username and the password.'
        LoginDelayMs = "How long Arc's login window must be showing before typing starts (1000 = 1 second)."
        MinWaitSeconds = 'Never type sooner than this after starting Arc (skips update pop-ups).'
        WindowTimeoutSeconds = "Give up looking for Arc's login window after this many seconds."
        TimeoutSeconds = 'Give up waiting for a game client after this many seconds.'
        PendingTimeoutSeconds = 'After Arc has been closed early, how long to keep watching for its game client.'
        ConfirmStop = 'Ask for confirmation before the STOP button force-closes a game client.'
        KillArcOnStart = 'Force-close any running Arc when the manager starts and before every SIGN IN.'
        RenameGameWindows = 'Set the title of each game client window to the Notes text of its row, so the windows are easy to tell apart.'
        RenameDurationSeconds = 'How long after a game client starts its windows are re-checked every second (the game opens and closes windows while loading). Raise it on a slow computer.'
        StatusResetSeconds = 'Messages such as Stopped, Cancelled or Timed out go back to Idle after this many seconds. 0 = never.'
        ShowStorageHint = 'Show a note at the bottom of the window that usernames and passwords are saved as plain text.'
        DebugLog = 'Write a log file (never containing passwords) to %AppData%\ArcManager\debug.log.'
        BackgroundImage = 'Your own picture (png, jpg, bmp or gif). Leave empty to use a background.* file next to the program, or the default.'
        Dim = '0% = picture as it is, 100% = black. Darker keeps the text easier to read.'
        Defaults = 'Fill in the standard values. Nothing is saved until you press SAVE CONFIGURATION.'
    }
    foreach ($k in $tips.Keys) { $tt.SetToolTip($script:Ui[$k], $tips[$k]) }

    $v = Get-CurrentValues
    # show the size the window has right now (so typing exactly 1280 x 720 and saving always does what it says)
    $rs = Get-RestoredClientSize
    $v['WindowWidth'] = $rs.Width
    $v['WindowHeight'] = $rs.Height
    $script:SetBuilt = $true
    Set-UiFromValues $v
    Show-AdvSub 0
    Show-SettingsPage 0
    $script:SetDirty = $false

    $dlg.Add_FormClosing({
        param($s, $e)
        if ($script:SetDirty) {
            $ans = [System.Windows.Forms.MessageBox]::Show($s, 'Discard your unsaved changes?', 'Configuration', 'YesNo', 'Question')
            if ($ans -ne 'Yes') { $e.Cancel = $true }
        }
    })
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    $script:SetDlg = $null
    $form.Activate()   # do not let the manager fall behind other windows
}

# the gear and the log (sheet of paper) icons, drawn in code (no image files needed)
function New-PtF([double]$x, [double]$y) { return (New-Object System.Drawing.PointF([single]$x, [single]$y)) }
function Paint-Symbol($btn, $e, [bool]$paper, [bool]$hot) {
    $g = $e.Graphics
    $w = $btn.ClientSize.Width
    $h = $btn.ClientSize.Height
    $bg = $cBox
    $fg = [System.Drawing.Color]::FromArgb(190, 190, 200)
    if ($hot) { $bg = [System.Drawing.Color]::FromArgb(62, 62, 72); $fg = $cWhite }
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($bg)
    $cx = $w / 2.0
    $cy = $h / 2.0
    $sz = [math]::Min($w, $h)
    $fgBrush = New-Object System.Drawing.SolidBrush($fg)
    $bgBrush = New-Object System.Drawing.SolidBrush($bg)
    if (-not $paper) {
        $ro = $sz * 0.40
        $ri = $sz * 0.30
        $rh = $sz * 0.14
        $pts = New-Object System.Collections.ArrayList
        $step = 2 * [math]::PI / 8
        for ($t = 0; $t -lt 8; $t++) {
            $a = $t * $step
            $angs = @(($a - 0.26 * $step), ($a - 0.16 * $step), ($a + 0.16 * $step), ($a + 0.26 * $step), ($a + 0.5 * $step))
            $rads = @($ri, $ro, $ro, $ri, $ri)
            for ($k = 0; $k -lt 5; $k++) {
                [void]$pts.Add((New-PtF ($cx + $rads[$k] * [math]::Cos($angs[$k])) ($cy + $rads[$k] * [math]::Sin($angs[$k]))))
            }
        }
        $g.FillPolygon($fgBrush, ([System.Drawing.PointF[]]$pts.ToArray()))
        $g.FillEllipse($bgBrush, [single]($cx - $rh), [single]($cy - $rh), [single](2 * $rh), [single](2 * $rh))
    } else {
        $ox = $cx - $sz / 2.0
        $oy = $cy - $sz / 2.0
        $L = $ox + $sz * 0.27
        $R = $ox + $sz * 0.73
        $T = $oy + $sz * 0.14
        $B = $oy + $sz * 0.86
        $f = $sz * 0.17
        $page = [System.Drawing.PointF[]]@((New-PtF $L $T), (New-PtF ($R - $f) $T), (New-PtF $R ($T + $f)), (New-PtF $R $B), (New-PtF $L $B))
        $g.FillPolygon($fgBrush, $page)
        $mix = [System.Drawing.Color]::FromArgb([int](($fg.R + $bg.R) / 2), [int](($fg.G + $bg.G) / 2), [int](($fg.B + $bg.B) / 2))
        $foldBrush = New-Object System.Drawing.SolidBrush($mix)
        $fold = [System.Drawing.PointF[]]@((New-PtF ($R - $f) $T), (New-PtF ($R - $f) ($T + $f)), (New-PtF $R ($T + $f)))
        $g.FillPolygon($foldBrush, $fold)
        $foldBrush.Dispose()
        for ($i = 0; $i -lt 4; $i++) {
            $x1 = $L + $sz * 0.07
            $x2 = $R - $sz * 0.07
            if ($i -eq 3) { $x2 = $L + ($R - $L) * 0.55 }
            $y1 = $T + $sz * (0.27 + 0.135 * $i)
            $g.FillRectangle($bgBrush, [single]$x1, [single]$y1, [single]($x2 - $x1), [single]($sz * 0.05))
        }
    }
    $fgBrush.Dispose()
    $bgBrush.Dispose()
}

# ---------- log viewer (the paper button next to the gear) ----------
$script:LogDlg = $null
$script:LvShown = ''
function Read-LogText([bool]$previous) {
    $path = $LogFile
    if ($previous) { $path = $PrevLogFile }
    $text = $null
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Default)
        $text = $sr.ReadToEnd()
        $sr.Close()
        $fs.Close()
    } catch { }
    if ($text -eq $null -or $text -eq '') {
        if ($previous) { return '(There is no log from a previous run.)' }
        return '(The log is empty. Turn on "Debug / Logs" in the settings window to record one.)'
    }
    if (-not $previous -and -not $DebugLog) { $text = "(Logging is turned off - see ""Debug / Logs"" in the settings window. This is the last saved log.)`r`n`r`n" + $text }
    return $text
}
function Update-LogView([bool]$force) {
    if ($script:LogDlg -eq $null -or $script:LogDlg.IsDisposed) { return }
    $prev = $script:LvPrev.Checked
    $text = Read-LogText $prev
    if ((-not $force) -and ($text -ceq $script:LvShown)) { return }
    $script:LvShown = $text
    $script:LvText.Text = $text
    if (-not $prev) {   # the current run: follow the end of the log
        $script:LvText.SelectionStart = $text.Length
        $script:LvText.ScrollToCaret()
    }
}
# what gets copied: a short, private (no paths, usernames or passwords) description of the setup + the log
function Build-LogReport([string]$shown, [bool]$previous) {
    $r = 'ArcManager (PowerShell) ' + $AppVersion + ' log report - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n"
    $os = [Environment]::OSVersion.Version
    $r += 'Windows ' + $os.Major + '.' + $os.Minor + ' build ' + $os.Build + '   PowerShell ' + $PSVersionTable.PSVersion + "`r`n"
    $modeText = 'Official Servers (Arc)'
    if ($PrivateMode) { $modeText = 'Private Servers' }
    $r += 'Mode: ' + $modeText + "`r`n"
    $found = 'no'
    if (Test-Path -LiteralPath $ArcPath) { $found = 'yes' }
    $r += 'Arc.exe found: ' + $found + '   running as administrator: ' + $script:IsAdmin + "`r`n"
    $r += 'Settings: '
    foreach ($k in @('AutoFill', 'UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds', 'TimeoutSeconds', 'PendingTimeoutSeconds', 'KillArcOnStart', 'RenameGameWindows', 'RenameDurationSeconds', 'StatusResetSeconds')) {
        $val = Get-Variable -Name $k -Scope Script -ValueOnly
        if ($val -is [bool]) { $val = [int]$val }
        $r += $k + '=' + $val + '  '
    }
    $which = 'current run'
    if ($previous) { $which = 'previous run' }
    $r += "`r`n(showing: " + $which + ")`r`n----------------------------------------`r`n" + $shown
    return $r
}
function Show-LogViewer {
    if ($script:LogDlg -ne $null -and -not $script:LogDlg.IsDisposed) {
        if ($script:LogDlg.WindowState -eq 'Minimized') { $script:LogDlg.WindowState = 'Normal' }
        $script:LogDlg.Activate()
        return
    }
    $dlg = New-Object System.Windows.Forms.Form
    $script:LogDlg = $dlg
    $dlg.Text = 'Log'
    $dlg.StartPosition = 'CenterParent'
    $dlg.AutoScaleMode = 'None'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 520)
    $dlg.MinimumSize = New-Object System.Drawing.Size(580, 360)

    $cur = New-Object System.Windows.Forms.RadioButton
    $cur.Text = 'This run'
    $cur.Checked = $true
    $cur.SetBounds(12, 12, 90, 22)
    $prev = New-Object System.Windows.Forms.RadioButton
    $prev.Text = 'Previous run'
    $prev.SetBounds(106, 12, 120, 22)
    $live = New-Object System.Windows.Forms.CheckBox
    $live.Text = 'Update live'
    $live.Checked = $true
    $live.SetBounds(240, 12, 140, 22)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.WordWrap = $false
    $tb.ScrollBars = 'Both'
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $tb.BackColor = [System.Drawing.SystemColors]::Window
    $tb.SetBounds(12, 44, 736, 424)
    $tb.Anchor = 'Top,Bottom,Left,Right'
    $copy = New-Object System.Windows.Forms.Button
    $copy.Text = 'COPY LOG TO CLIPBOARD'
    $copy.SetBounds(12, 480, 210, 28)
    $copy.Anchor = 'Bottom,Left'
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'REFRESH'
    $refresh.SetBounds(230, 480, 90, 28)
    $refresh.Anchor = 'Bottom,Left'
    $folder = New-Object System.Windows.Forms.Button
    $folder.Text = 'OPEN LOG FOLDER'
    $folder.SetBounds(328, 480, 150, 28)
    $folder.Anchor = 'Bottom,Left'
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'CLOSE'
    $close.SetBounds(658, 480, 90, 28)
    $close.Anchor = 'Bottom,Right'
    $dlg.Controls.AddRange(@($cur, $prev, $live, $tb, $copy, $refresh, $folder, $close))
    $dlg.AcceptButton = $copy
    $dlg.CancelButton = $close
    $script:LvPrev = $prev
    $script:LvLive = $live
    $script:LvText = $tb
    $script:LvCopy = $copy

    $script:LvTimer = New-Object System.Windows.Forms.Timer
    $script:LvTimer.Interval = 1000
    $script:LvTimer.Add_Tick({ if ($script:LvLive.Checked -and -not $script:LvPrev.Checked) { Update-LogView $false } })
    $script:LvCopyTimer = New-Object System.Windows.Forms.Timer
    $script:LvCopyTimer.Interval = 1500
    $script:LvCopyTimer.Add_Tick({ $script:LvCopyTimer.Stop(); $script:LvCopy.Text = 'COPY LOG TO CLIPBOARD' })

    $cur.Add_CheckedChanged({ Update-LogView $true })
    $refresh.Add_Click({ Update-LogView $true })
    $copy.Add_Click({
        Update-LogView $false
        try {
            [System.Windows.Forms.Clipboard]::SetText((Build-LogReport $script:LvShown $script:LvPrev.Checked))
            $script:LvCopy.Text = 'COPIED!'
            $script:LvCopyTimer.Stop()
            $script:LvCopyTimer.Start()
        } catch { [void][System.Windows.Forms.MessageBox]::Show('Could not copy to the clipboard.', 'Log') }
    })
    $folder.Add_Click({ [void][System.Diagnostics.Process]::Start($ConfigDir) })
    $close.Add_Click({ $script:LogDlg.Close() })
    $dlg.Add_FormClosed({
        $script:LvTimer.Stop()
        $script:LvTimer.Dispose()
        $script:LvCopyTimer.Dispose()
        $script:LogDlg = $null
        $form.Activate()   # do not let the manager fall behind other windows
    })
    Update-LogView $true
    $script:LvTimer.Start()
    $dlg.Show($form)
}

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PWI Account Manager'
$form.ClientSize = New-Object System.Drawing.Size($WindowWidth, $WindowHeight)   # the inside area, same meaning as in the C++ version
$script:FrameW = $form.Width - $form.ClientSize.Width    # window frame + title bar, needed to work out the restored size
$script:FrameH = $form.Height - $form.ClientSize.Height
$form.MinimumSize = New-Object System.Drawing.Size(($script:FrameW + 1040), ($script:FrameH + 420))   # the rows need this much room
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.ForeColor = $cWhite
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
Set-DoubleBuffered $form
Load-Background
Update-Background

$title = New-Object System.Windows.Forms.Label
$title.Text = 'PWI'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(16, 10)
$modeBtn = New-Object System.Windows.Forms.Button
$modeBtn.FlatStyle = 'Flat'
$modeBtn.FlatAppearance.BorderSize = 0
$modeBtn.Size = New-Object System.Drawing.Size(240, 40)
$modeBtn.Location = New-Object System.Drawing.Point([math]::Max(230, [int](($form.ClientSize.Width - 240) / 2)), 12)
$modeBtn.Anchor = 'Top'
$modeBtn.BackColor = $cBox
$modeBtn.Add_Paint({ param($s, $e) Paint-ModeSwitch $s $e })
$modeBtn.Add_Click({ Set-PrivateMode (-not [bool]$PrivateMode) })
$form.Controls.Add($modeBtn)
$form.Add_Resize({ $modeBtn.Left = [math]::Max(230, [int](($form.ClientSize.Width - 240) / 2)) })
$title.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($title)

$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(0, 56)
$panel.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - 56 - 54))
$panel.AutoScroll = $true
$panel.Anchor = 'Top,Bottom,Left,Right'
$panel.BackColor = [System.Drawing.Color]::Transparent
Set-DoubleBuffered $panel
$panel.Add_Scroll({ $panel.Invalidate($true) })
# the mouse wheel scrolls the panel without raising the Scroll event, which left pieces of the background picture behind:
# repaint everything (also once more after the scrolling has happened)
$panel.Add_MouseWheel({
    $panel.Invalidate($true)
    [void]$panel.BeginInvoke([System.Windows.Forms.MethodInvoker]{ $panel.Invalidate($true) })
})
$panel.Add_ClientSizeChanged({ Update-StatusWidths })   # also fires when the vertical scroll bar appears
$form.Controls.Add($panel)

$script:CueHandler = { param($s, $e) try { [WinHelper]::SetCue($s.Handle, [string]$s.Tag) } catch { } }

# ---- characters that would break accounts.txt (tab, line breaks and other control characters) are refused
$script:LastGoodText = @{}
$script:GuardBusy = $false
$script:BadCharsText = "Usernames, passwords and notes cannot contain tabs or line breaks.`n`nThey would corrupt the saved accounts file."
function Guard-TextBox($box) {
    $script:LastGoodText[$box.GetHashCode()] = $box.Text
    $box.Add_TextChanged({
        param($s, $e)
        if ($script:GuardBusy) { return }
        $key = $s.GetHashCode()
        if ($s.Text -match '[\x00-\x1F]') {
            $script:GuardBusy = $true
            $s.Text = [string]$script:LastGoodText[$key]   # the text goes back to what it was: nothing was pasted
            $s.SelectionStart = $s.Text.Length
            $script:GuardBusy = $false
            [void][System.Windows.Forms.MessageBox]::Show($form, ($script:BadCharsText + ' Nothing was pasted.'), 'Characters not allowed', 'OK', 'Warning')
        } else { $script:LastGoodText[$key] = $s.Text }
    })
}
# ---- the minus button of a row (grey, red when hovered; red with a ring when selected)
$script:DelTipText = "CLICK to delete (with confirmation)`nSHIFT+CLICK to delete (without confirmation)`nCONTROL+CLICK to select several rows to delete,`n      then ALT+D to delete them`nBlank entries are also deleted on exit"
$script:HotDel = $null
$script:GripTipText = "DRAG up or down to move this account to a new place`n(ESC while dragging cancels)`nOr press ALT+UP / ALT+DOWN while the cursor is in`n      any box of this row to move it one place"
# the drag handle of a row: three lines (grey, blue when hovered or dragged)
function Paint-Grip($btn, $e) {
    $g = $e.Graphics
    $w = $btn.ClientSize.Width
    $h = $btn.ClientSize.Height
    $disabled = (-not $btn.Enabled)
    $dragging = ($script:Drag -ne $null) -and [object]::ReferenceEquals($script:Drag.Grip, $btn)
    $hot = (([object]::ReferenceEquals($script:HotDel, $btn)) -or $dragging) -and (-not $disabled)
    $col = [System.Drawing.Color]::FromArgb(128, 128, 138)
    if ($hot) { $col = [System.Drawing.Color]::FromArgb(70, 125, 205) }
    if ($disabled) { $col = [System.Drawing.Color]::FromArgb(72, 72, 80) }
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($cBox)
    $cx = $w / 2.0
    $cy = $h / 2.0
    $rad = [math]::Min($w, $h) * 0.40
    $hw = $rad * 0.85
    $gap = $rad * 0.62
    $brush = New-Object System.Drawing.SolidBrush($col)
    foreach ($k in -1, 0, 1) {
        $g.FillRectangle($brush, [single]($cx - $hw), [single]($cy + $k * $gap - 1), [single](2 * $hw), [single]2)
    }
    $brush.Dispose()
}
function Paint-Minus($btn, $e) {
    $row = $btn.Tag
    $g = $e.Graphics
    $w = $btn.ClientSize.Width
    $h = $btn.ClientSize.Height
    $disabled = (-not $btn.Enabled)
    $hot = ([object]::ReferenceEquals($script:HotDel, $btn)) -and (-not $disabled)
    $selected = ($row -ne $null) -and [bool]$row.Selected
    $fill = [System.Drawing.Color]::FromArgb(128, 128, 138)
    if ($hot -or $selected) { $fill = [System.Drawing.Color]::FromArgb(215, 55, 55) }
    if ($disabled) { $fill = [System.Drawing.Color]::FromArgb(72, 72, 80) }
    $bar = [System.Drawing.Color]::White
    if ($disabled) { $bar = [System.Drawing.Color]::FromArgb(112, 112, 120) }
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($cBox)
    $cx = $w / 2.0
    $cy = $h / 2.0
    $rad = [math]::Min($w, $h) * 0.40
    if ($selected) {   # a white ring around the red disc
        $ringBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $g.FillEllipse($ringBrush, [single]($cx - $rad - 2), [single]($cy - $rad - 2), [single](2 * $rad + 4), [single](2 * $rad + 4))
        $ringBrush.Dispose()
    }
    $fillBrush = New-Object System.Drawing.SolidBrush($fill)
    $g.FillEllipse($fillBrush, [single]($cx - $rad), [single]($cy - $rad), [single](2 * $rad), [single](2 * $rad))
    $barBrush = New-Object System.Drawing.SolidBrush($bar)
    $g.FillRectangle($barBrush, [single]($cx - $rad * 0.58), [single]($cy - 1), [single]($rad * 1.16), [single]2)
    $fillBrush.Dispose()
    $barBrush.Dispose()
}
# the status text is as wide as the window allows; it must never reach past the edge (that gives a horizontal scroll bar)
function Update-StatusWidths {
    $w = [math]::Max(40, ($panel.ClientSize.Width - 901 - 12))   # (40 is small enough to fit even at the smallest window size)
    foreach ($r in $script:Rows) { if ($r.Label.Width -ne $w) { $r.Label.Width = $w } }
}
# after the whole list was replaced (or the window was shown) the panel can keep an old "needs a horizontal scroll bar" state:
# lay it out again, fit the status texts, and make the panel work out its scroll bars from scratch
function Refresh-PanelScroll {
    $panel.PerformLayout()
    Update-StatusWidths
    $panel.AutoScroll = $false
    $panel.AutoScroll = $true
    $panel.PerformLayout()
}
function Add-Row([string]$user, [string]$pass, [string]$notes) {
    $y = 8 + ($script:Rows.Count * 40) + $panel.AutoScrollPosition.Y   # (AutoScrollPosition.Y is 0 or negative: positions inside a scrolled panel are relative to what is shown)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(66, $y)
    $tb.Size = New-Object System.Drawing.Size(195, 26)
    $tb.Text = $user
    $tb.BackColor = $cBox
    $tb.ForeColor = $cWhite
    $tb.BorderStyle = 'FixedSingle'

    $pw = New-Object System.Windows.Forms.TextBox
    $pw.Location = New-Object System.Drawing.Point(273, $y)
    $pw.Size = New-Object System.Drawing.Size(195, 26)
    $pw.Text = $pass
    $pw.UseSystemPasswordChar = $true
    $pw.BackColor = $cBox
    $pw.ForeColor = $cWhite
    $pw.BorderStyle = 'FixedSingle'

    $nt = New-Object System.Windows.Forms.TextBox
    $nt.Location = New-Object System.Drawing.Point(480, $y)
    $nt.Size = New-Object System.Drawing.Size(195, 26)
    $nt.Text = $notes
    $nt.BackColor = $cBox
    $nt.ForeColor = $cWhite
    $nt.BorderStyle = 'FixedSingle'

    # grey placeholder text so the three boxes are self-explanatory when empty
    $tb.Tag = 'Username'
    $pw.Tag = 'Password'
    $nt.Tag = 'Main character'
    $tb.Add_HandleCreated($script:CueHandler)
    $pw.Add_HandleCreated($script:CueHandler)
    $nt.Add_HandleCreated($script:CueHandler)

    Guard-TextBox $tb
    Guard-TextBox $pw
    Guard-TextBox $nt

    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point(687, ($y - 1))
    $btn.Size = New-Object System.Drawing.Size(122, 28)
    $btn.Text = 'SIGN IN'
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $cRed
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    $stop = New-Object System.Windows.Forms.Button
    $stop.Location = New-Object System.Drawing.Point(817, ($y - 1))
    $stop.Size = New-Object System.Drawing.Size(76, 28)
    $stop.Text = 'STOP'
    $stop.Enabled = $false
    $stop.FlatStyle = 'Flat'
    $stop.FlatAppearance.BorderSize = 0
    $stop.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $stop.ForeColor = [System.Drawing.Color]::White
    $stop.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(901, ($y + 4))
    $lbl.Size = New-Object System.Drawing.Size([math]::Max(40, ($panel.ClientSize.Width - 901 - 12)), 22)   # as wide as the window allows (never wider: that gave a scroll bar)
    $lbl.AutoEllipsis = $true
    $lbl.Text = 'Idle'
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.ForeColor = $cGray

    $del = New-Object System.Windows.Forms.Button
    $del.Location = New-Object System.Drawing.Point(34, ($y + 1))
    $del.Size = New-Object System.Drawing.Size(24, 24)
    $del.FlatStyle = 'Flat'
    $del.FlatAppearance.BorderSize = 0
    $del.BackColor = $cBox
    $del.TabStop = $false   # not reachable with the Tab key
    $del.Add_Paint({ param($s, $e) Paint-Minus $s $e })
    $del.Add_MouseEnter({ param($s, $e) $script:HotDel = $s; $s.Invalidate() })
    $del.Add_MouseLeave({ param($s, $e) if ([object]::ReferenceEquals($script:HotDel, $s)) { $script:HotDel = $null }; $s.Invalidate() })
    $del.Add_Click({ param($s, $e) Delete-Click $s.Tag })
    if ($script:TipMain -ne $null) { $script:TipMain.SetToolTip($del, $script:DelTipText) }

    $grip = New-Object System.Windows.Forms.Button
    $grip.Size = New-Object System.Drawing.Size(24, 24)
    $grip.Location = New-Object System.Drawing.Point(8, ($y + 1))
    $grip.FlatStyle = 'Flat'
    $grip.FlatAppearance.BorderSize = 0
    $grip.BackColor = $cBox
    $grip.TabStop = $false
    $grip.Cursor = [System.Windows.Forms.Cursors]::SizeAll
    $grip.Add_Paint({ param($s, $e) Paint-Grip $s $e })
    $grip.Add_MouseEnter({ param($s, $e) $script:HotDel = $s; $s.Invalidate() })
    $grip.Add_MouseLeave({ param($s, $e) if ([object]::ReferenceEquals($script:HotDel, $s)) { $script:HotDel = $null }; $s.Invalidate() })
    $grip.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-Drag $s } })
    $grip.Add_MouseMove({ param($s, $e) Update-Drag })
    $grip.Add_MouseUp({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { End-Drag $true } })
    $grip.Add_MouseCaptureChanged({ param($s, $e) End-Drag $false })   # e.g. Alt+Tab or a pop-up window appeared: cancel quietly
    if ($script:TipMain -ne $null) { $script:TipMain.SetToolTip($grip, $script:GripTipText) }

    $row = @{ Grip = $grip; Del = $del; Selected = $false; Box = $tb; Pass = $pw; Notes = $nt; Button = $btn; Stop = $stop; Label = $lbl; GamePid = $null; Pending = $null; GameStart = $null; GameStartPid = $null; Title = ''; TitlePid = $null; TitleSeen = $null; TitleLogs = 0; StatusSince = $null; StatusTransient = $false }
    $btn.Tag = $row
    $del.Tag = $row
    $grip.Tag = $row
    $stop.Tag = $row
    $stop.Add_Click({ param($s, $e) Stop-Client $s.Tag })
    $btn.Add_Click({ param($s, $e) Start-Play $s.Tag })

    $panel.Controls.Add($del)
    $panel.Controls.Add($grip)
    $panel.Controls.Add($tb)
    $panel.Controls.Add($pw)
    $panel.Controls.Add($nt)
    $panel.Controls.Add($btn)
    $panel.Controls.Add($stop)
    $panel.Controls.Add($lbl)
    [void]$script:Rows.Add($row)
}

# ---- deleting accounts: CLICK = ask first, SHIFT+CLICK = no question, CONTROL+CLICK = select, ALT+D = delete the selected ones
function Get-SelectedCount { return @($script:Rows | Where-Object { $_.Selected }).Count }
function Update-SelectionHint {
    $n = Get-SelectedCount
    if ($n -gt 0) { $blankHint.Text = [string]$n + ' selected - ALT+D to delete' } else { $blankHint.Text = '' }   # (Esc clears the selection)
}
function Clear-Selection {
    foreach ($r in $script:Rows) { if ($r.Selected) { $r.Selected = $false; $r.Del.Invalidate() } }
    Update-SelectionHint
}
function Test-RowBusy($r) { return [bool]($r.GamePid -or ($r.Pending -ne $null)) }
# a game client is running / a sign-in is in progress: those rows (and, while a sign-in runs, all rows) cannot be deleted
function Update-DeleteButtons {
    foreach ($r in $script:Rows) {
        $ok = (($script:Active -eq $null) -and (-not (Test-RowBusy $r)))
        if ($r.Del.Enabled -ne $ok) {
            $r.Del.Enabled = $ok
            if ((-not $ok) -and $r.Selected) { $r.Selected = $false }
            $r.Del.Invalidate()
        }
        $gripOk = (($script:Active -eq $null) -and ($script:Rows.Count -gt 1))   # moving rows is only blocked while a sign-in runs (or when there is just one row)
        if ($r.Grip.Enabled -ne $gripOk) { $r.Grip.Enabled = $gripOk; $r.Grip.Invalidate() }
    }
    Update-SelectionHint
}
function Remove-Row($r) {
    if ($script:TipMain -ne $null) { $script:TipMain.SetToolTip($r.Del, '') }
    if ([object]::ReferenceEquals($script:HotDel, $r.Del)) { $script:HotDel = $null }
    foreach ($c in @($r.Box, $r.Pass, $r.Notes, $r.Button, $r.Stop, $r.Label, $r.Del, $r.Grip)) { $panel.Controls.Remove($c); $c.Dispose() }
    $script:Rows.Remove($r)
}
function Relayout-Rows {
    $i = 0
    foreach ($r in $script:Rows) {
        $y = 8 + ($i * 40) + $panel.AutoScrollPosition.Y   # (see Add-Row: a scrolled panel shifts every position)
        $r.Box.Top = $y
        $r.Pass.Top = $y
        $r.Notes.Top = $y
        $r.Button.Top = $y - 1
        $r.Stop.Top = $y - 1
        $r.Label.Top = $y + 4
        $r.Del.Top = $y + 1
        $r.Grip.Top = $y + 1
        $i++
    }
}
function After-Delete {
    if ($script:Rows.Count -eq 0) { Add-Row '' '' '' }   # there is always at least one row
    Relayout-Rows
    Save-Accounts   # saved right away (accounts.txt.bak keeps the version from before)
    Save-Session
    Update-DeleteButtons
}
function Get-RowLabel($r) {
    $u = $r.Box.Text.Trim()
    $n = $r.Notes.Text.Trim()
    if ($u -eq '') { $u = '(no username)' }
    if ($n -eq '') { return $u }
    return ($u + '  (' + $n + ')')
}
# moves a row to place $to (any distance); the whole row (texts, running client, status) moves with it
function Move-RowTo($r, [int]$to) {
    $from = $script:Rows.IndexOf($r)
    if ($from -lt 0 -or $to -lt 0 -or $to -ge $script:Rows.Count -or $from -eq $to) { return }
    if ($script:Active -ne $null) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'A sign-in is in progress. Wait for it to finish, or cancel it first.', 'Cannot move now', 'OK', 'Information')
        return
    }
    $script:Rows.RemoveAt($from)
    $script:Rows.Insert($to, $r)
    Relayout-Rows
    $t = 0   # keep the Tab order the same as the order on screen
    foreach ($x in $script:Rows) { foreach ($c in @($x.Box, $x.Pass, $x.Notes, $x.Button, $x.Stop)) { $c.TabIndex = $t; $t++ } }
    Save-Accounts   # the new order is saved right away
    Save-Session
    Update-DeleteButtons
}
# moves a row one place up (-1) or down (+1), used by ALT+UP / ALT+DOWN
function Move-Row($r, [int]$dir) {
    $i = $script:Rows.IndexOf($r)
    if ($i -lt 0) { return }
    Move-RowTo $r ($i + $dir)
}
# ---- dragging a row by its grip: the blue line shows where the row would land; ESC or Alt+Tab cancels
$script:Drag = $null
$script:DragLine = $null
$script:DragTimer = New-Object System.Windows.Forms.Timer
$script:DragTimer.Interval = 40   # keeps the list scrolling while the mouse rests near its top / bottom edge
function Show-DragLine {
    if ($script:DragLine -eq $null) {
        $script:DragLine = New-Object System.Windows.Forms.Label
        $script:DragLine.AutoSize = $false
        $script:DragLine.Height = 3
        $script:DragLine.BackColor = [System.Drawing.Color]::FromArgb(70, 125, 205)
        $script:DragLine.Visible = $false
        $panel.Controls.Add($script:DragLine)
    }
    $d = $script:Drag
    if (($d -eq $null) -or ($d.Target -eq $d.From)) { $script:DragLine.Visible = $false; return }
    $edge = 8 + ($d.Target + $(if ($d.Target -gt $d.From) { 1 } else { 0 })) * 40 + $panel.AutoScrollPosition.Y   # top of the row after the line
    $script:DragLine.Left = 4
    $script:DragLine.Width = [math]::Max(8, ($panel.ClientSize.Width - 8))
    $script:DragLine.Top = [math]::Max(0, ($edge - 7))
    $script:DragLine.Visible = $true
    $script:DragLine.BringToFront()
}
function Update-Drag {
    if ($script:Drag -eq $null) { return }
    $p = $panel.PointToClient([System.Windows.Forms.Cursor]::Position)
    $ch = $panel.ClientSize.Height
    $step = 0
    if ($p.Y -lt 28) { $step = -([math]::Min(28 - $p.Y, 56) / 4 + 4) }
    elseif ($p.Y -gt ($ch - 28)) { $step = [math]::Min($p.Y - ($ch - 28), 56) / 4 + 4 }
    if ($step -ne 0) {
        $cur = - $panel.AutoScrollPosition.Y
        $panel.AutoScrollPosition = New-Object System.Drawing.Point((- $panel.AutoScrollPosition.X), [int][math]::Max(0, $cur + $step))
        # while the list scrolls, the timer keeps the message queue busy and the rows were never painted: paint everything right now
        [WinHelper]::RedrawNow($panel.Handle)
        $p = $panel.PointToClient([System.Windows.Forms.Cursor]::Position)
    }
    $n = $script:Rows.Count
    $t = [int][math]::Floor(($p.Y - $panel.AutoScrollPosition.Y - 8) / 40)
    $t = [math]::Max(0, [math]::Min($t, $n - 1))
    if ($t -ne $script:Drag.Target) { $script:Drag.Target = $t }
    Show-DragLine
}
function Start-Drag($grip) {
    if (($script:Drag -ne $null) -or (-not $grip.Enabled)) { return }
    $r = $grip.Tag
    $i = $script:Rows.IndexOf($r)
    if ($i -lt 0) { return }
    $script:Drag = @{ Row = $r; From = $i; Target = $i; Grip = $grip }
    $grip.Capture = $true
    $script:DragTimer.Start()
    $grip.Invalidate()
}
function End-Drag([bool]$drop) {
    $d = $script:Drag
    if ($d -eq $null) { return }
    if ($drop) { Update-Drag }
    $script:Drag = $null   # (cleared first: releasing the mouse capture raises the capture-changed event)
    $script:DragTimer.Stop()
    if ($script:DragLine -ne $null) { $script:DragLine.Visible = $false }
    if ($d.Grip.Capture) { $d.Grip.Capture = $false }
    $d.Grip.Invalidate()
    $panel.Invalidate($true)
    if ($drop -and ($d.Target -ne $d.From)) { Move-RowTo $d.Row $d.Target }
}
$script:DragTimer.Add_Tick({ Update-Drag })
function Delete-Click($r) {
    $mods = [System.Windows.Forms.Control]::ModifierKeys
    $shift = (($mods -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift)
    $ctrl = (($mods -band [System.Windows.Forms.Keys]::Control) -eq [System.Windows.Forms.Keys]::Control)
    if (($script:Active -ne $null) -or (Test-RowBusy $r)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'This account is busy (a sign-in is in progress or its game client is running).', 'Cannot delete now', 'OK', 'Information')
        return
    }
    if ($ctrl) {   # select / unselect
        $r.Selected = (-not [bool]$r.Selected)
        $r.Del.Invalidate()
        Update-SelectionHint
        return
    }
    $empty = (($r.Box.Text -eq '') -and ($r.Pass.Text -eq '') -and ($r.Notes.Text -eq ''))
    if ((-not $shift) -and (-not $empty)) {
        $q = 'Delete this account?' + "`n`n" + (Get-RowLabel $r) + "`n`n" + 'It is removed from the list.'
        if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Delete account', 'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
    }
    Write-Log ('account deleted (row ' + ($script:Rows.IndexOf($r) + 1) + ')')
    Remove-Row $r
    After-Delete
}
function Delete-Selected {
    if ((Get-SelectedCount) -eq 0) { return }
    if ($script:Active -ne $null) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'A sign-in is in progress. Wait for it to finish, or cancel it first.', 'Cannot delete now', 'OK', 'Information')
        return
    }
    $targets = @($script:Rows | Where-Object { $_.Selected -and (-not (Test-RowBusy $_)) })
    if ($targets.Count -eq 0) { Clear-Selection; return }
    $list = ''
    $shown = 0
    foreach ($t in $targets) { if ($shown -lt 8) { $list += "`n" + (Get-RowLabel $t) }; $shown++ }
    if ($targets.Count -gt 8) { $list += "`n... and " + ($targets.Count - 8) + ' more' }
    $q = 'Delete the ' + $targets.Count + ' selected account(s)?' + "`n" + $list + "`n`n" + 'They are removed from the list.'
    if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Delete accounts', 'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
    foreach ($t in $targets) { Write-Log 'account deleted'; Remove-Row $t }
    Clear-Selection
    After-Delete
}

foreach ($acc in $accounts) { Add-Row $acc.User $acc.Pass $acc.Notes }
Adopt-Session

# ---- the OFFICIAL | PRIVATE switch at the top of the main window
function Update-ModeUi {
    if ($PrivateMode) { $form.Text = 'PWI Account Manager - Private Servers' } else { $form.Text = 'PWI Account Manager - Official Servers' }
    if ($modeBtn -ne $null) { $modeBtn.Invalidate() }
}
function Paint-ModeSwitch($btn, $e) {
    $g = $e.Graphics
    $w = $btn.ClientSize.Width
    $h = $btn.ClientSize.Height
    $half = [int]($w / 2)
    $mid = [int]($h / 2)
    $blue = [System.Drawing.Color]::FromArgb(55, 95, 155)
    $orange = [System.Drawing.Color]::FromArgb(190, 105, 35)
    $leftColor = $blue
    $rightColor = $cBox
    $leftText = $cWhite
    $rightText = $cGray
    if ($PrivateMode) { $leftColor = $cBox; $rightColor = $orange; $leftText = $cGray; $rightText = $cWhite }
    $b1 = New-Object System.Drawing.SolidBrush($leftColor)
    $b2 = New-Object System.Drawing.SolidBrush($rightColor)
    $g.FillRectangle($b1, 0, 0, $half, $h)
    $g.FillRectangle($b2, $half, 0, ($w - $half), $h)
    $pen = New-Object System.Drawing.Pen($cGray)
    $g.DrawRectangle($pen, 0, 0, ($w - 1), ($h - 1))
    # each side: the name on top, the word "Servers" tightly under it
    $sfTop = New-Object System.Drawing.StringFormat
    $sfTop.Alignment = [System.Drawing.StringAlignment]::Center
    $sfTop.LineAlignment = [System.Drawing.StringAlignment]::Far
    $sfBottom = New-Object System.Drawing.StringFormat
    $sfBottom.Alignment = [System.Drawing.StringAlignment]::Center
    $sfBottom.LineAlignment = [System.Drawing.StringAlignment]::Near
    $bold = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $plain = New-Object System.Drawing.Font('Segoe UI', 9)
    $t1 = New-Object System.Drawing.SolidBrush($leftText)
    $t2 = New-Object System.Drawing.SolidBrush($rightText)
    $g.DrawString('OFFICIAL', $bold, $t1, (New-Object System.Drawing.RectangleF(0, 0, $half, ($mid + 1))), $sfTop)
    $g.DrawString('PRIVATE', $bold, $t2, (New-Object System.Drawing.RectangleF($half, 0, ($w - $half), ($mid + 1))), $sfTop)
    $g.DrawString('Servers', $plain, $t1, (New-Object System.Drawing.RectangleF(0, $mid, $half, ($h - $mid))), $sfBottom)
    $g.DrawString('Servers', $plain, $t2, (New-Object System.Drawing.RectangleF($half, $mid, ($w - $half), ($h - $mid))), $sfBottom)
    foreach ($o in @($b1, $b2, $pen, $sfTop, $sfBottom, $bold, $plain, $t1, $t2)) { $o.Dispose() }
}
# switching between the official game (Arc) and private servers: each mode has its own account list
function Set-PrivateMode([bool]$on) {
    if ($on -eq [bool]$PrivateMode) { return }
    $busy = ($script:Active -ne $null) -or (@($script:Rows | Where-Object { $_.Pending -ne $null }).Count -gt 0)
    if ($busy) { [void][System.Windows.Forms.MessageBox]::Show($form, 'A sign-in is still in progress. Finish or cancel it first, then switch.', 'Busy'); return }
    if ($on -and $PrivateShowWarning) {   # shown every time (it can be turned off on the Private Servers page); never at start-up
        $m = 'Private Servers mode' + "`n`n" + 'In this mode the manager starts the program YOU choose (gear icon > Private Servers) with administrator rights and types your saved username and password into it. Arc is not used.' + "`n`n" + 'Private servers are run by other people: use passwords here that you do not use anywhere else. This mode has its own account list.' + "`n`n" + '(You can turn this warning off on the Private Servers page of the settings.)' + "`n`n" + 'Switch to private servers mode?'
        if ([System.Windows.Forms.MessageBox]::Show($form, $m, 'Private Servers', 'OKCancel', 'Warning') -ne 'OK') { return }
    }
    Save-Accounts   # the list of the mode we are leaving
    Save-Session
    $script:PrivateMode = $on
    $flag = '0'
    if ($on) { $flag = '1' }
    [void][IniFile]::Put($IniFile, 'PrivateMode', $flag)
    Apply-ModePaths
    $script:LastSession = ''
    foreach ($r in @($script:Rows)) {
        foreach ($c in @($r.Box, $r.Pass, $r.Notes, $r.Button, $r.Stop, $r.Label, $r.Del, $r.Grip)) { $panel.Controls.Remove($c); $c.Dispose() }
    }
    $script:Rows.Clear()
    Update-SelectionHint
    $accs = Load-AccountList
    foreach ($acc in $accs) { Add-Row $acc.User $acc.Pass $acc.Notes }
    Adopt-Session   # game clients of this mode that are still running
    Refresh-PanelScroll   # (without this a horizontal scroll bar could stay behind when switching to a list with a vertical scroll bar)
    Update-ModeUi
    if ($on) { Write-Log 'mode switched to Private Servers' } else { Write-Log 'mode switched to Official Servers' }
}

$addBtn = New-Object System.Windows.Forms.Button
$addBtn.Text = '+ Add account'
$addBtn.Location = New-Object System.Drawing.Point(16, ($form.ClientSize.Height - 42))
$addBtn.Size = New-Object System.Drawing.Size(120, 28)
$addBtn.Anchor = 'Bottom,Left'
$addBtn.FlatStyle = 'Flat'
$addBtn.BackColor = $cBox
$addBtn.ForeColor = $cWhite
$addBtn.Add_Click({
    Add-Row '' '' ''
    $newRow = $script:Rows[$script:Rows.Count - 1]
    $panel.ScrollControlIntoView($newRow.Box)   # show the new row, also when the list is long
    $newRow.Box.Focus()
})
$form.Controls.Add($addBtn)

# import / export of the accounts list (a text file in the same format as accounts.txt)
function Import-Accounts {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Import accounts'
    $dlg.Filter = 'Account lists (*.txt)|*.txt|All files|*.*'
    $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog($form) -ne 'OK') { $dlg.Dispose(); return }
    $file = $dlg.FileName
    $dlg.Dispose()
    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8) } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'The file could not be read.', 'Import accounts', 'OK', 'Information')
        return
    }
    $added = 0
    $skipped = 0
    foreach ($line in $lines) {
        if ($line.Trim() -eq '') { continue }
        $parts = $line -split "`t", 3
        $u = $parts[0].Trim()
        $pw = ''
        $nt = ''
        if ($parts.Count -ge 2) { $pw = $parts[1] }
        if ($parts.Count -ge 3) { $nt = $parts[2] }
        # control characters (a tab inside the notes, for example) would break the file format: they become spaces
        $u = ($u -replace '[\x00-\x1F]', ' ')
        $pw = ($pw -replace '[\x00-\x1F]', ' ')
        $nt = ($nt -replace '[\x00-\x1F]', ' ')
        if ($u -eq '') { continue }
        $dup = $false
        foreach ($r in $script:Rows) { if ($r.Box.Text.Trim() -eq $u) { $dup = $true } }   # -eq ignores case
        if ($dup) { $skipped++; continue }   # accounts that are already in the list are never overwritten
        $blank = $null
        foreach ($r in $script:Rows) {
            if ($blank -eq $null -and $r.Box.Text -eq '' -and $r.Pass.Text -eq '' -and $r.Notes.Text -eq '') { $blank = $r }   # an empty row is filled instead of adding a new one
        }
        if ($blank -ne $null) { $blank.Box.Text = $u; $blank.Pass.Text = $pw; $blank.Notes.Text = $nt }
        else { Add-Row $u $pw $nt }
        $added++
    }
    Save-Accounts
    if ($added -eq 0 -and $skipped -eq 0) { $m = 'No accounts were found in that file.' }
    else {
        $m = 'Imported ' + $added + ' account(s).'
        if ($skipped -gt 0) { $m += "`n" + $skipped + ' account(s) already in the list (same username) were skipped.' }
    }
    [void][System.Windows.Forms.MessageBox]::Show($form, $m, 'Import accounts', 'OK', 'Information')
}
function Export-Accounts {
    $lines = @()
    foreach ($r in $script:Rows) {
        $u = ($r.Box.Text.Trim() -replace '[\x00-\x1F]', ' ')
        if ($u -eq '') { continue }
        $lines += ($u + [string][char]9 + ($r.Pass.Text -replace '[\x00-\x1F]', ' ') + [string][char]9 + ($r.Notes.Text.Trim() -replace '[\x00-\x1F]', ' '))
    }
    if ($lines.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($form, 'There are no accounts to export.', 'Export accounts', 'OK', 'Information'); return }
    $warn = 'The exported file contains your usernames and PASSWORDS as plain text.' + "`n`n" + 'Keep it somewhere safe and delete it when you no longer need it.'
    if ([System.Windows.Forms.MessageBox]::Show($form, $warn, 'Export accounts', 'OKCancel', 'Warning') -ne 'OK') { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = 'Export accounts'
    $dlg.Filter = 'Account lists (*.txt)|*.txt|All files|*.*'
    $dlg.FileName = 'ArcManager-accounts.txt'
    $dlg.DefaultExt = 'txt'
    $dlg.OverwritePrompt = $true
    if ($dlg.ShowDialog($form) -ne 'OK') { $dlg.Dispose(); return }
    $file = $dlg.FileName
    $dlg.Dispose()
    try {
        [System.IO.File]::WriteAllLines($file, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        [void][System.Windows.Forms.MessageBox]::Show($form, ('Exported ' + $lines.Count + " account(s) to:`n" + $file), 'Export accounts', 'OK', 'Information')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'The file could not be written.', 'Export accounts', 'OK', 'Warning')
    }
}

$importBtn = New-Object System.Windows.Forms.Button
$importBtn.Text = 'Import...'
$importBtn.Location = New-Object System.Drawing.Point(292, ($form.ClientSize.Height - 42))
$importBtn.Size = New-Object System.Drawing.Size(80, 28)
$importBtn.Anchor = 'Bottom,Left'
$importBtn.FlatStyle = 'Flat'
$importBtn.BackColor = $cBox
$importBtn.ForeColor = $cWhite
$importBtn.Add_Click({ Import-Accounts })
$form.Controls.Add($importBtn)
$exportBtn = New-Object System.Windows.Forms.Button
$exportBtn.Text = 'Export...'
$exportBtn.Location = New-Object System.Drawing.Point(378, ($form.ClientSize.Height - 42))
$exportBtn.Size = New-Object System.Drawing.Size(80, 28)
$exportBtn.Anchor = 'Bottom,Left'
$exportBtn.FlatStyle = 'Flat'
$exportBtn.BackColor = $cBox
$exportBtn.ForeColor = $cWhite
$exportBtn.Add_Click({ Export-Accounts })
$form.Controls.Add($exportBtn)

$showPw = New-Object System.Windows.Forms.CheckBox
$showPw.Text = 'Show passwords'
$showPw.AutoSize = $true
$showPw.Location = New-Object System.Drawing.Point(150, ($form.ClientSize.Height - 38))
$showPw.Anchor = 'Bottom,Left'
$showPw.BackColor = [System.Drawing.Color]::Transparent
$showPw.Add_CheckedChanged({
    foreach ($r in $script:Rows) { $r.Pass.UseSystemPasswordChar = (-not $showPw.Checked) }
})
$form.Controls.Add($showPw)

# the plain-text warning scrolls when there is not enough room for it
$hintPanel = New-Object System.Windows.Forms.Panel
$hintPanel.BackColor = [System.Drawing.Color]::Transparent
$hintPanel.Anchor = 'Bottom,Left,Right'
$hintPanel.Visible = [bool]$ShowStorageHint
$hintPanel.Location = New-Object System.Drawing.Point(676, ($form.ClientSize.Height - 36))
$hintPanel.Size = New-Object System.Drawing.Size([math]::Max(60, ($form.ClientSize.Width - 206 - 12 - 676)), 20)
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'WARNING: Usernames & Passwords are saved as PLAIN TEXT'
$hint.UseMnemonic = $false
$hint.ForeColor = $cAmber
$hint.AutoSize = $true
$hint.BackColor = [System.Drawing.Color]::Transparent
$hint.Location = New-Object System.Drawing.Point(0, 1)
$hintPanel.Controls.Add($hint)
$form.Controls.Add($hintPanel)
$script:HintTimer = New-Object System.Windows.Forms.Timer
$script:HintTimer.Interval = 30
$script:HintTimer.Add_Tick({
    if (-not $hintPanel.Visible) { return }
    if ($hint.Width -le $hintPanel.Width) { if ($hint.Left -ne 0) { $hint.Left = 0 }; return }
    $hint.Left = $hint.Left - 1
    if ($hint.Left -lt -($hint.Width + 40)) { $hint.Left = $hintPanel.Width }
})
$script:HintTimer.Start()

# the version number: bottom right, left of the paper and gear buttons
$verLabel = New-Object System.Windows.Forms.Label
$verLabel.Text = $AppVersion
$verLabel.ForeColor = $cGray
$verLabel.AutoSize = $false
$verLabel.TextAlign = 'MiddleRight'
$verLabel.BackColor = [System.Drawing.Color]::Transparent
$verLabel.Anchor = 'Bottom,Right'
$verLabel.Size = New-Object System.Drawing.Size(110, 20)
$verLabel.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 206), ($form.ClientSize.Height - 36))
$form.Controls.Add($verLabel)

# always shown
$blankHint = New-Object System.Windows.Forms.Label
$blankHint.Text = ''   # 'Blank entries deleted on exit.' (now in the minus button tooltip; this label shows how many rows are selected)
$blankHint.ForeColor = $cGray
$blankHint.AutoSize = $true
$blankHint.Anchor = 'Bottom,Left'
$blankHint.BackColor = [System.Drawing.Color]::Transparent
$blankHint.Location = New-Object System.Drawing.Point(472, ($form.ClientSize.Height - 36))
$form.Controls.Add($blankHint)

# gear button: opens the settings window
$script:GearHot = $false
$gearBtn = New-Object System.Windows.Forms.Button
$gearBtn.FlatStyle = 'Flat'
$gearBtn.FlatAppearance.BorderSize = 0
$gearBtn.Size = New-Object System.Drawing.Size(28, 28)
$gearBtn.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 16 - 28), ($form.ClientSize.Height - 42))
$gearBtn.Anchor = 'Bottom,Right'
$gearBtn.BackColor = $cBox
$gearBtn.Add_Paint({ param($s, $e) Paint-Symbol $s $e $false $script:GearHot })
$gearBtn.Add_MouseEnter({ $script:GearHot = $true; $gearBtn.Invalidate() })
$gearBtn.Add_MouseLeave({ $script:GearHot = $false; $gearBtn.Invalidate() })
$gearBtn.Add_Click({ Show-Settings })
$form.Controls.Add($gearBtn)
$script:LogHot = $false
$logBtn = New-Object System.Windows.Forms.Button
$logBtn.FlatStyle = 'Flat'
$logBtn.FlatAppearance.BorderSize = 0
$logBtn.Size = New-Object System.Drawing.Size(28, 28)
$logBtn.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 16 - 28 - 8 - 28), ($form.ClientSize.Height - 42))
$logBtn.Anchor = 'Bottom,Right'
$logBtn.BackColor = $cBox
$logBtn.Add_Paint({ param($s, $e) Paint-Symbol $s $e $true $script:LogHot })
$logBtn.Add_MouseEnter({ $script:LogHot = $true; $logBtn.Invalidate() })
$logBtn.Add_MouseLeave({ $script:LogHot = $false; $logBtn.Invalidate() })
$logBtn.Add_Click({ Show-LogViewer })
$form.Controls.Add($logBtn)
$script:TipMain = New-Object System.Windows.Forms.ToolTip
$script:TipMain.SetToolTip($gearBtn, 'Settings')
foreach ($r in $script:Rows) {
    $script:TipMain.SetToolTip($r.Del, $script:DelTipText)
    $script:TipMain.SetToolTip($r.Grip, $script:GripTipText)
}
$script:TipMain.SetToolTip($modeBtn, 'OFFICIAL Servers = the game through Arc. PRIVATE Servers = private servers (no Arc). Each mode has its own account list. Click to switch.')
$script:TipMain.SetToolTip($logBtn, 'View log')
$script:TipMain.SetToolTip($importBtn, 'Add accounts from a text file (same format as accounts.txt). Accounts already in the list are skipped.')
$script:TipMain.SetToolTip($exportBtn, 'Save the accounts list to a text file. The file contains the passwords as plain text.')

$script:PrivTimer = New-Object System.Windows.Forms.Timer   # runs the private-server typing sequence in small steps
$script:PrivTimer.Interval = 100
$script:PrivTimer.Add_Tick({ Private-Tick })
Update-ModeUi

$script:ToolHideTimer = New-Object System.Windows.Forms.Timer   # keeps the launcher/patcher off-screen in Hidden Arc Mode
$script:ToolHideTimer.Interval = 100
$script:ToolHideTimer.Add_Tick({ Hide-LaunchToolWindows })
$script:ToolHideTimer.Start()

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Update-State; Expire-Statuses; Update-DeleteButtons; Save-Session; Apply-WindowTitles })
$timer.Start()

$script:LastState = $form.WindowState
$form.Add_ResizeEnd({ Update-Background })
$form.Add_SizeChanged({
    if ($form.WindowState -ne $script:LastState) { $script:LastState = $form.WindowState; Update-Background }
})
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s, $e)
    if (($script:Drag -ne $null) -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { End-Drag $false; $e.Handled = $true; $e.SuppressKeyPress = $true }   # ESC cancels a drag
    elseif ($e.Alt -and $e.KeyCode -eq [System.Windows.Forms.Keys]::D) { Delete-Selected; $e.Handled = $true; $e.SuppressKeyPress = $true }   # ALT+D
    elseif ($e.Alt -and ($e.KeyCode -eq [System.Windows.Forms.Keys]::Up -or $e.KeyCode -eq [System.Windows.Forms.Keys]::Down) -and ($script:Drag -eq $null)) {   # ALT+UP / ALT+DOWN: move the row that has the cursor
        $c = $form.ActiveControl
        while (($c -is [System.Windows.Forms.ContainerControl]) -and ($c.ActiveControl -ne $null)) { $c = $c.ActiveControl }
        $mine = $null
        foreach ($r in $script:Rows) { if (([object]::ReferenceEquals($r.Box, $c)) -or ([object]::ReferenceEquals($r.Pass, $c)) -or ([object]::ReferenceEquals($r.Notes, $c)) -or ([object]::ReferenceEquals($r.Button, $c)) -or ([object]::ReferenceEquals($r.Stop, $c))) { $mine = $r } }
        if ($mine -ne $null) {
            $dir = 1
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Up) { $dir = -1 }
            Move-Row $mine $dir
            $panel.ScrollControlIntoView($c)   # follow the row when it moved out of sight
            $c.Focus()
        }
        $e.Handled = $true; $e.SuppressKeyPress = $true
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and (Get-SelectedCount) -gt 0) { Clear-Selection; $e.Handled = $true }
})
# Closing while game clients are running: the first attempt is ALWAYS cancelled; the question is asked afterwards (not inside the
# closing event, where a dialog is less reliable) and only a "Yes" closes the manager for real.
$script:CloseConfirmed = $false
$script:AskingClose = $false
# game clients of the OTHER server mode (the list that is not shown) that are still running, counted from that mode's session file
function Get-OtherModeRunningCount {
    $path = Join-Path $ConfigDir 'session-private.txt'
    $names = @('elementclient', 'elementclient_64')
    if ($PrivateMode) {
        $path = Join-Path $ConfigDir 'session.txt'
    } else {
        $names = @($PrivateProcessNames.Split(',') | ForEach-Object { ($_.Trim() -replace '\.exe$', '') } | Where-Object { $_ -ne '' })
    }
    if (-not (Test-Path $path)) { return 0 }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($path) } catch { return 0 }
    $alive = @()
    if ($names.Count -gt 0) { $alive = @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
    $n = 0
    foreach ($line in ($text -split "`n")) {
        $parts = $line.TrimEnd("`r") -split "`t"
        if ($parts.Count -lt 3) { continue }
        $id = [int]0
        $saved = [long]0
        if (-not [int]::TryParse($parts[1], [ref]$id)) { continue }
        if (-not [long]::TryParse($parts[2], [ref]$saved)) { continue }
        if (($alive -contains $id) -and ((Get-ProcStart $id) -eq $saved)) { $n++ }
    }
    return $n
}
function Confirm-Close {
    $other = Get-OtherModeRunningCount   # clients of the other list (Official / Private Servers) count too
    $running = @($script:Rows | Where-Object { $_.GamePid }).Count + $other
    if ($running -gt 0) {
        $otherName = 'Private Servers'
        if ($PrivateMode) { $otherName = 'Official Servers' }
        $note = ''
        if ($other -gt 0) { $note = "`n(" + $other + ' in the ' + $otherName + ' list)' }
        $q = [string]$running + ' game client(s) still running.' + $note + "`n`n" + 'They keep running if you close the manager, and the manager finds them again the next time it starts.' + "`n`n" + 'Close the manager anyway?'
        $ans = [System.Windows.Forms.MessageBox]::Show($form, $q, 'Game clients running', 'YesNo', 'Question', 'Button2')
        if ($ans -ne 'Yes') { $script:AskingClose = $false; return }
    }
    $script:CloseConfirmed = $true
    $script:AskingClose = $false
    $form.Close()
}
$form.Add_FormClosing({
    param($s, $e)
    $running = @($script:Rows | Where-Object { $_.GamePid }).Count + (Get-OtherModeRunningCount)
    if (($running -gt 0) -and (-not $script:CloseConfirmed) -and ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing)) {
        $e.Cancel = $true
        if (-not $script:AskingClose) {
            $script:AskingClose = $true
            [void]$form.BeginInvoke([System.Windows.Forms.MethodInvoker]{ Confirm-Close })
        }
        return
    }
    if ($script:Active -ne $null -and $script:Active.Phase -eq 'hidden') {
        # let the hidden-login thread finish cleanly (it kills Arc itself) instead of leaving it running after the window is gone
        if ($script:HiddenState -ne $null) {
            $script:HiddenState.Cancel = $true
            for ($i = 0; $i -lt 100 -and -not $script:HiddenState.Done; $i++) { Start-Sleep -Milliseconds 100 }   # bounded wait (up to 10s)
        }
        Close-HiddenPopup
        $script:Active = $null
    }
    Save-Accounts
    Save-Session
    if ($RememberWindowSize -and $form.WindowState -eq 'Normal') {
        [void][IniFile]::Put($IniFile, 'WindowWidth', [string]$form.ClientSize.Width)
        [void][IniFile]::Put($IniFile, 'WindowHeight', [string]$form.ClientSize.Height)
    }
})
$form.Add_Shown({ Refresh-PanelScroll })
[void]$form.ShowDialog()

# ---------------------------------------------------------------------------------------------------------------
# Built-in default background picture (Base64 text of the PNG). Nothing below this line is program code.
# Replace the text between the two marker lines to use a different built-in picture (see Get-BuiltInBackgroundBytes).
# ---------------------------------------------------------------------------------------------------------------
<#
BUILTIN-BACKGROUND-BEGIN
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
QgghPuWm8xnHk1MeNSOs3+vx0ksv8+yzz1AUJUmSkGUpWZZ3M/zKskItl2W0t1X37ZJowz+g+WsqIF8eX1BVJlCCbgIj27bX5rN1
bbG+h1IRSil29nZRyiJeLEhnJ1SeyWaveUVxnGNkC2zTwHE1gXfedrq62CPNCoqypigrLGXiaMU8zrl7PMPVNpe2m6UWO4MmdHv7
w6bN92C5eCLyNPvbw26jL0BRFJRpilJqbUEHNMHfZJaS581G36KssZSB0i7zpAZUF/xBE/7Zto3rOfQHwweGfmeTBWWWLNuDXQYO
aMfulnsAuGaFpS2g+WDa8O/oeMLd8YLJPMOiCUpP7i54693bHB6mPHUp5Ae+f5vNvo0f+PQcE+Va7UeH2/Yp5wZlmXfB4KqyrJhN
Z0Dz2a7P+jPJshS9nPOnqhTPtehtbHP79ph33/smju/xwvPX8OySXtA8bpZXaCMni3Pee+8D/EDz9CWXs2nM8ThlmtTUVnnebl5W
YMHxyQl37hxy5amn1hKysigpy5I0TbGt5pi8aN6rne3tLigGSPKUqq4wDfMT/RuXAFAIIYQQQgghhPiUquqKeycnj1zusTHc4HOv
fA87+7sApGlGHMfMZrOVczUz/wzTpCwrqrKp/mrDwLb6bzX8a48riuVMtftClCzLm7bfLMVSFn4Q4Dgaf1lx1YaCylL4foBSiqgX
URabTKYT/mIMO4MxXn+PYXZALzBx1fl8t6Ks1ir+krTAskzSJGO2ss33mStb7G6FbEY2R9OcP33zDu+9f5dpnKFtReTpblOxF3pY
ymS+WFb7KRPHcS4Ef23FX53HlGVFrRxc1yLPC7JSoVW5rPZrops2+BtELq7vd6FfnNacTc432ToWuL0NAHpWjm3x0OUeab0Mt9KM
8emC07M5YOBYcPtgylffPyadVDx1KeSHv3/IoO/ja4Xnu92m3qwq0I4iqwrIzz/XNtxrPqem5XexKCmqjHjRfN+0leC4EWBTlLBI
Fs2MwKppWY42hjiOzVe++g73jk+59vQlRht9hp6J62mSuGlVDm2TcKPHi1fHvPt+zOn4FK0tbtydchLXTJIcQy8wnQDbskjL5riq
qjg5OWa0uYnjnLdUV2VOkmZkacasLLpW5fZ7vLW9w8HBQff9zbIcd+X4TyIJAIUQQgghhBBCiE+hLM85HB8/cs7f5z73OZ595lkm
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
82Wf8+tVUrcZN+ss+4dP8222ALepV6tUdX37nB4ybscZ1uvUVZW62YTAbnvy7ub+u34YbhbtJk3zJiwuFjm52pz267s6SZ1mNKQZ
DWlHTVZdn2evhyyrN4tLdnf3tqf/hgxDla7r8+rVyyyW7zjtV91ZzPIbbPWdTiZpu8t88fF/+7ULPmbjaY4Pj9KO5KnfN68wAAAA
8DtTV3WOD4+yuzPLy7PX7xwLni9X+cUvf5nD58/zlz/6KOO9g80o6neEwLquMyy7+5ts58tkOs7ozt2AN6fqVt0q1VCn71aZz68z
DOuM6j7X83mu58lkPNqeelukaaq07Thnl/O8Ouuzv9Pmg+NZzq9X+ezFRb4+SR7tTnK8N87V1W//mtw854cCWt00qbOJfU3TZLVa
Zblapu+7NM39dDOsN6cKq7rOqBnlcnE3/iXN6M3r8/Xz8yyX62TvB+m6VfphyGw2y3g8Ttf1Wa+HLJbDd4751r9u+27VZjQaZTqd
5mC8zDdffZa/+9kv8vJ8/uA9f20zypPDR5lOJn5g/kAEQAAAAOB3bjIe54MnT3N+eZlX56fvHAs+PTvLf/n7f8iPP3gvP/jwxxmN
mgx1ldGwTrYjqHfvCRyGIatumWobpUZDNuPBbXu7IORmt3BdN1ktFxmGdYZhswV3qDb3+e2M65xfr9L1q1STUfbq0Z0QOM359Twn
F8tMx6P89QeHOblY5ZPnp3l+Vmd8+MOM7/wbRk29GU0ehjen/35LdV1nPB6n7/vN8+z7zfNeJ9X2867Xw238G9br1MOQUdvmZL45
YXf3FN3Z2SJnF8sc7I3T7T7Oqu/TD0NGzSj7e/tZdd1mq3KSoR9ye7RwewfhqB6SNL/2eVfNJJNxm3E7ztWLz/LzTz/Nx8/PHwx/
dVXl8cGj7M1mfkD+wARAAAAA4Pekyv7uXnZns5ycvs7Z9buPz3365Td59uIkP/mzP8/R4+MMQ5+hrjan9vrbrRbp1pvfr2/iYJPU
fZ1Ru/1EdxaE1PVwO3o7akfp+z6TyTg/fznPv3tvJ08Pp+n7IWfXm1OBo21UvJ7f3PdX5fTiKqcXyeHeLP/rv3kvf/fNPGnaNKNR
0r8Zjb2JgLf/f6cB3sS7uzYLOPrtnzdpmuZN/NsGvmSzEfdG04zSL9+cphzW68zn1/fC36rr8vrVInVb5fjJk5z34yyXy/TDkKau
s7+/n3bUbrb8bl+bIevNmPE2/tVVlaZp0/dDsl4lVbv59d63tU3T1JlMJqkuXubjX7PgI0mO9w6yv7eXuqr9WPwraB7tH/xvXgYA
AADg96WqqsymO9kZT7JYLu8t/bjR9UNevHqZ8/OzHO0fpJ1MUlVJ6irrqkq3HtJ1Xe5tiVivU1d12u2ykGHVpauS9WqVPkm9Xifr
dZqqTtXUSapcL7t088skVYZUOdpt09RV1kkWyy6jpsmqqXN6Ps941CSTOqtFny9PrnK23snu3m5G1eb53h1H3izyqDbxr9kUyaGp
0y0WOXr0KEdHR7m+vs5qvtou+9iO7LZNqmoz4nx9fZWXr07y2WefJllnOp3ePi7ZRL97I9Bdl9lomuvr13l9Os9i2Wd2cJx5DnKx
HDahL5uod3BwmJ3ZLFWqpHrzX1PXqUebewer25d1fSf63f9e3Sz5mCzP8uqrn+WnP/80n764ePDU38HOLO8dP8lsupOqst33X4sT
gAAAAMAfxHQyyUfv/SDnl5d5efY671qNcXp2lv/y0/92Zyy43ZwIHEapqjrr9LePvRkF7larzXbgZHNPYJJktT0JWGeUKuO6ST3b
SdM0eXmWdKdXebQzzmI5yuHeLAfjIcvxOPPlMs2yy7Nlm1k1ybhfZdzWuWqn2WlH2yA3JP3Dp93SrzIej5Jll6ppUv2aU29N0+TV
q5d59eokq26Vv/mbf5tPPv0kw3CSp0+fbP41q9Xt2O7NyO6wXueynmU17GZndzer9SSv5qust/GuquqMJ+McHBxm3LZvTha+416/
9Z2w+NaJv5vvX12nWV3k4uWz/PSzF3n2+uELESftOI8PjjIZj73xvwcEQAAAAOAPaDMWvDPdycvXJ7lazt/5qJux4L/4yV/m4NFR
ptMmXd9lfj1k3fe3Ya1uNzGr7of79wWu+qRfp27qdO1os1G4GaWe1qnrKpdXV7m+us6TLJOLzVKQ3XGd3ekkl9erjMfjVE2TrmrT
p0rT1NuNvkOuV126bS/r+mEzArz99cayr5Kmzajq7p3iu2e82fp7eXmRr7/+Oh9++FH+/X/4D/nggw/Sjsf5v/7T/7kZgx41Gdbf
OgE4rFOnypB1RvvvZ9Utk67PTjPKsL3vbzqdZn9/P6NRk+Vyla7rUtV1mm+NJff9m7Hj+8PMG9O6TtMvcnX+Ov/82Vf58uTqwRN/
TV3nyeGjzKY73urfI0aAAQAAgD+4uq6zN5tlZzzJ9WK+GTv9lq4f8vzli1xdXWV/NsvObDd13aSqq1RVndGoySjVZvy3Xyf3poPX
Wa/X6Ych637YjgtXqZomo9Fmc+06dV5d9VktrzNfdpkv+5yuFnk2n2Yy3UmqKuthBSUbfwAAHuFJREFUSNOMNttz281o73rYjP/e
RLCbeDas1xk12zHXeruNeNXl8ZPH2dvbz2KxyPJ6eRsExzvTTKfTXF5eZTqd5unTp0mV/PxnP8uHH36YJ0+f5leffZbd3b3bhSZ3
X6d1kipVmlGT8WSSUdtmOp5kd3c3BwcH2d2dbbYnD5v7EOu6Tl1Vt/FvWG+Wlwz9sNn4W/X3Xv9pXWdUVVmcP8tXX3yen378TV6e
z9+50KVK8uTgKD84Pk57eykj3xdOAAIAAAD/aqaTSX78/g/z+uw8Jxdn7xwLfnXyKmdnr/PBBx/m/fff35yI224K7rLOaNW9tS34
rmEY0iXp+kXq8Sjjusm4HW/Gg0dtFstpTi6vMlz0me3tZmc6TV1XGfpkNGrz6Pg4dar0Q5/lcplutXoT/+7dA1inG+4sAelXyXds
BW7bNqNRk+lkkuPj4xw9epR+u1zkF7/4RX70Z3+WxWKRtm3TNKOsuv6tzzFke89hknbU3IbRJLeLRm6e480m4ST3twAnqes3n3u6
DZTd/CyvX36Vj78+y6uLxYP/jsPZXo4ODlJXddZr7+nvIwEQAAAA+Fe1Xlc53D/IbGeWV6ev3zkW3PVDPvvVr/Ly5fP8+KOfZLa/
m9SjjFZdlk2dZJ3067fi343bjy+7zJs+o7SbseDJZLO8o9kkkrYdpW6arNfr1MM6R0dHGbdtlqtVum6V9P3bn/Pu/387+PVD6vrt
O/fq6ShN06RpRhm1bSaTSfq+S7+NdpPJJN88e5b5/M1rUVdVsh37TZI3azs2mma0CZfD5nW4G/xuX+vhzqnFb/3hTfhr+kXOn3+R
nz97/Z33/M3G0xwfHt3bRMz3k+8QAAAA8L3Qjkb5weMnuZpf58XpSfp3xLzLq3n+4ef/I08fP8mPPvwwdTvKeGjS1V26rFKnfjAC
JptIV6dO1y/TNVVGbZvRdrR31Lapqzcbeutplclkkm7VZbVcpOv62/j2XV+jG5JR3izSqLfbb+8u3xjmXfqdPn3fpWma7Mxmefni
Ra6vr/PRj36Uv/jLv8z//Z//cw4PD2//TlXXm1Hmb4W/uqpSbz/Udf07w9+91+BO/GuqOpOmT7K55+/i7Fk++fLVd97z1zajPDl8
lOlk4k37R0IABAAAAL5XZtOdfDSZ5PXZWU6vLt75mOcvX+Tk9at88MGHOXr0KKNmtL0PcJWuqZL+4VD3ZpFG0vXrpKky2ka1zVjw
JtQ1ozZDP2TVLTen6tZDsuq+87nfLgXZjgL3ebjErVabSHh9fZ3XJye5vr7O8+ff5KMf/Sj/6f/437Mz282f/+QnWSwWqesqzZ1l
Iutv/bs2izy++7nd/J1mXSVVtQ1/mxOHi/Nn+eLLb/KrV1eZL9+9Bbiuqjw+eJS92U7yrQjJ95sACAAAAHzv1FWd48Oj7M128+L0
JIvV8q3H3B0Lfv+997N/eJTxbGc7FtxvNwO/MQzD7VKMex9Lvb1DcBO+6rpKXdfpu1XW9bBdovEm/nX9m89zc1rwXaGx+9aH7p4A
TJKh75O2TV1V+du//f8yHo/z3g/ezz/9/Gc5ODjI06fvpWma9H2/WeBRr995KvLe1/jWxuG7pwGrIanbOm31JvB187M8++JX+fjV
dS6v5g9+3uO9g+zv7aWuam/OP0ICIAAAAPC9NW7bfPDkvVxcXeXl2ck7N9BeXs3z6a8+y9PL0zx69INMd2cZN01S9xm1uV3acTfa
fTsCJrkdDc6q24wFN03qenhz+i95cCz2JgSOmt8+kB0cHuSv/uqv0nV9xuNxxuNxmqbJaNTk6uoqi/k8y+Vqs9H4gQBY1XWaut6G
ws09gMnmZGBdJe2wSpokw+bEXzc/y/NvPs/nzy+/c8HHwc4sh/uHGTWNN+MfMQEQAAAA+N7bm80y25nm5PR1zq7fXkzR9UO+en6S
s8vrPH78NMfHjzNqN9lj3G6WhcxXy9TZ3u9356TcTQC8iYNdP6TLMvWw2RZ8c/rvXfHv7inAt/6sqTNcr1I/EM9uYubObJb3x5P0
2wUj48k4fddnuVzk4uIi8/k8y9XqzdKOukpdVbcn+pLNApCb0eXNc9pEwKqqM+rfBL6mX+Tly8/yT796/Z3hb9KO8/jgKJPx2Juv
AAIgAAAA8Eehruo8PjrO3mwvr8/PsuiWb43EXl7Ns1h8kcX5yzx68lFm+3sZjZrUk3Fm7WizzXe1ur0jMMm7x3j7dYZ+E/2G5iYb
Jqths2QjSaqqTpPqTQRsqu0ocTJKlfWd04r9ne3B7zKeTNKONl/l8vI6V1dXubi4yPX1VVZdf+eU4ib+Nc1mlLeupkmSnWaZ62V9
+5ibX8e5zjy5XfDxs89e5OX5/MGTjE1d58nho8ymO95wBREAAQAAgD8qk/E4P3j8OFfzec4vL3O9nN9btdH1Q569vsrp1cf5wZNH
2T9+L9PJJHVdZzqZpGtG6fruwRCYb32uZJ2hX2c19Bm6Vbpt2BtVVZrRmxNyN4tEun5Ivz2ZV4/azV1/7zBsx3GXi2WSZS76LovF
MtfX17en/oZhuHfyL0mmVZ8MfaZNklwmSfpVkmyey0775r7EfvWbLfiokjw+OMrB3m7Waws+SiMAAgAAAH+EqsymOxm341xeXeb0
6uKt04Dz5SqffvlNjs9O8+jJD3P46DijUZPxeJzR0KRrRlmulptA1z+8rTf9erMIZBv/1sOQqq7Trdep1n3GTZvkzf2AQ5XUNxt3
v7Ut92ZMN0myXKef9rm6usr19XWGoU/X9Vkul+n6/k34S5K6Sls1mTQ34e++eZ9Mm8s0bXv7sdPXL/P8m8/zy2dX37ng43C2l6OD
g9RVnfXaO6tEAiAAAADwR2vUNDk62M9kPMnpxflbpwGT5NXFIlfLL3K1XRIy29/NaNRmPN6UtK7uknzrjr/mTri7Ewdv4t/tr32f
NO39L9gPyXozEjxuR2m7yyTH9+Jf1/UZjZosl8vUVZX5fJ6u6zL0Q4bcP/FXp0pT1Tkcv/sk4Sb+5Tb+zS8v8sU3X+dXX37znff8
zcbTHB8epR3JQ8X/nHgJAAAAgD9m63WV6WSS8bjN5dVVTi7O3nka8OT0Iovrq+wfHObwyfvbseAqo75K144yuhsB+3XSVBmlSt/W
qe9Mzt7EvxvfXgTSZ50MQ+qmyfZavzTvWARyvZxn3SVNU6fvh3vxr67rjNv2dmPxXh4OeXfj3xdffJZPPv/qO+/5a5tRnhw+ynQy
8eb5EyEAAgAAAEWoqzr7u3uZjCc5vzzP+fXVvdOA8+UqXV9nMZzlfDsWvH94lDqb+/uWTZ1k/ebEX7/eLvWoMmrqDKNxuvUi6ztx
sWrubt59+w7B8XiTXvq+z2KxSNdtTvGthlVWfZf0yd08U9d1mqbJznSSum4y6a/SD2/q42q5SDt+E+5uwt+r55/nnz/7Kl+eXD0Y
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
AAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACg
YAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAA
gIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAA
AAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAA
AAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMA
AQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRM
AAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQ
MAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAA
QMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAA
AAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAA
AAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmA
AAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAom
AAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAo
mAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAA
oGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAA
AICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAA
AAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRA
AAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUT
AAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAU
TAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAA
UDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAA
AEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgA
AAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIg
AAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJ
gAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAK
JgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAA
KJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAA
AKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQA
AACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQ
AAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEE
QAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAF
EwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAA
FEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAA
AFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIA
AABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAI
AAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGAC
IAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICC
CYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAA
CiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAEAAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAA
ACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDABEAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEA
AACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDBBEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAAUTAAE
AAAAgIIJgAAAAABQMAEQAAAAAAomAAIAAABAwQRAAAAAACiYAAgAAAAABRMAAQAAAKBgAiAAAAAAFEwABAAAAICCCYAAAAAAUDAB
EAAAAAAKJgACAAAAQMEEQAAAAAAomAAIAAAAAAUTAAEAAACgYAIgAAAAABRMAAQAAACAggmAAAAAAFAwARAAAAAACiYAAgAAAEDB
BEAAAAAAKJgACAAAAAAFEwABAAAAoGACIAAAAAD/fzt2IAMAAAAwyN/6Hl9hxJgABAAAAIAxAQgAAAAAYwIQAAAAAMYEIAAAAACM
CUAAAAAAGBOAAAAAADAmAAEAAABgTAACAAAAwJgABAAAAIAxAQgAAAAAYwIQAAAAAMYEIAAAAACMCUAAAAAAGBOAAAAAADAmAAEA
AABgTAACAAAAwJgABAAAAIAxAQgAAAAAYwIQAAAAAMYEIAAAAACMCUAAAAAAGBOAAAAAADAmAAEAAABgTAACAAAAwJgABAAAAIAx
AQgAAAAAYwIQAAAAAMYEIAAAAACMCUAAAAAAGBOAAAAAADAmAAEAAABgTAACAAAAwJgABAAAAIAxAQgAAAAAYwIQAAAAAMYEIAAA
AACMCUAAAAAAGAuDx3c3IAOGbwAAAABJRU5ErkJggg==
BUILTIN-BACKGROUND-END
#>
