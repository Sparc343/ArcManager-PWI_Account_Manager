# ArcManager.ps1 (v2) - multi-account helper for the official Arc client
# Works on Windows 7 (PowerShell 2.0+). No install needed.
#
# Flow per row: SIGN IN -> starts a fresh Arc.exe -> types the username and password into
#   Arc's login window and presses Enter -> YOU click Play in Arc -> manager sees Arc start
#   launcher.exe (or the game client, see $CloseArcAt) -> closes that Arc after a short delay.
#
# Accounts are saved in PLAIN TEXT in %AppData%\ArcManager\accounts.txt (username<TAB>password).

# ---------- settings ----------
# All settings are stored in %AppData%\ArcManager\ArcManager.ini (the same file the C++ version uses).
# Change them with the gear button in the program. To edit the file by hand, save it and restart the program.
# A copy of ArcManager.ini placed next to this script is used instead of that one (portable mode).
# Program version, shown in the log and in the settings window. >>> Change it here when you release a new version. <<<
$AppVersion = 'v25.OCT.2026'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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
using System.Runtime.InteropServices;
public class WinHelper {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);

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
; CloseArcAt: launcher (as soon as Arc starts launcher.exe) or game (wait for elementclient.exe)
CloseArcAt=launcher
LauncherGraceSeconds=2
GraceSeconds=6
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
StatusResetSeconds=90
; Background image. Leave BackgroundImage blank to use background.png/jpg/jpeg/bmp/gif found next to the program or in %AppData%\ArcManager;
; if none is found, the C++ version uses its built-in image (the PowerShell version a plain dark background).
BackgroundImage=
; BackgroundMode: fill (cover, cropped) | fit (whole image, bars) | stretch | tile | center
BackgroundMode=fill
; BackgroundDim: 0 = image as-is ... 1 = black (keeps the text readable)
BackgroundDim=0.5
; Advanced (not shown in the settings window). PowerShell version only (this program always asks for administrator rights): 1 = restart as administrator
RunElevated=1
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
        CloseArcAt = 'launcher'; LauncherGraceSeconds = 2; GraceSeconds = 6
        TimeoutSeconds = 300; PendingTimeoutSeconds = 600
        ConfirmStop = $false; KillArcOnStart = $true; DebugLog = $true; RenameGameWindows = $true; RenameDurationSeconds = 180; StatusResetSeconds = 90
        BackgroundImage = ''; BackgroundMode = 'fill'; BackgroundDim = 0.5
        ShowStorageHint = $false
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
    $script:WindowWidth = [math]::Max(900, (Get-IniInt 'WindowWidth' $d.WindowWidth))
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
    $script:CloseArcAt = 'launcher'
    if ((Get-IniText 'CloseArcAt' 'launcher').Trim().ToLower() -eq 'game') { $script:CloseArcAt = 'game' }
    $script:LauncherGraceSeconds = Get-IniInt 'LauncherGraceSeconds' $d.LauncherGraceSeconds
    $script:GraceSeconds = Get-IniInt 'GraceSeconds' $d.GraceSeconds
    $script:TimeoutSeconds = Get-IniInt 'TimeoutSeconds' $d.TimeoutSeconds
    $script:PendingTimeoutSeconds = Get-IniInt 'PendingTimeoutSeconds' $d.PendingTimeoutSeconds
    $script:ConfirmStop = Get-IniBool 'ConfirmStop' $d.ConfirmStop
    $script:KillArcOnStart = Get-IniBool 'KillArcOnStart' $d.KillArcOnStart
    $script:ShowStorageHint = Get-IniBool 'ShowStorageHint' $d.ShowStorageHint
    $script:RenameGameWindows = Get-IniBool 'RenameGameWindows' $d.RenameGameWindows
    $script:RenameDurationSeconds = Get-IniInt 'RenameDurationSeconds' $d.RenameDurationSeconds
    $script:StatusResetSeconds = Get-IniInt 'StatusResetSeconds' $d.StatusResetSeconds
    $script:DebugLog = Get-IniBool 'DebugLog' $d.DebugLog
    $script:BackgroundImage = (Get-IniText 'BackgroundImage' '').Trim()
    $script:BackgroundMode = (Get-IniText 'BackgroundMode' 'fill').Trim().ToLower()
    $dimText = (Get-IniText 'BackgroundDim' '0.5').Trim().Replace(',', '.')
    $dim = 0.5
    if (-not [double]::TryParse($dimText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dim)) { $dim = 0.5 }
    $script:BackgroundDim = [math]::Min(1.0, [math]::Max(0.0, $dim))
}
if (-not (Test-Path $IniFile)) { Write-UnicodeFile $IniFile ($DefaultIniText -replace "`r?`n", "`r`n") } else { Ensure-UnicodeIni $IniFile }
Load-Settings

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
        [void]$accounts.Add(@{ User = $parts[0].Trim(); Pass = $p; Notes = $nt })
    }
}
if ($accounts.Count -eq 0) {
    [void]$accounts.Add(@{ User = ''; Pass = ''; Notes = '' })   # first start: one empty row
}

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
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-GamePids {
    @(Get-Process -Name 'elementclient', 'elementclient_64' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
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
        if (Test-Path $AccountsFile) {
            if ((Get-Item $AccountsFile).Length -gt 0) { Copy-Item -Path $AccountsFile -Destination ($AccountsFile + '.bak') -Force }
            [System.IO.File]::Replace($tmp, $AccountsFile, $null)
        } else {
            [System.IO.File]::Move($tmp, $AccountsFile)
        }
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
    if (-not (Test-ArcFocused $a.ArcPids)) { Write-Log 'Arc not focused - fallback'; Use-Fallback $a 'Could not focus Arc'; return }

    Write-Log 'moving focus to the username field'
    if ($UsernameFocusKeys -ne '') { [System.Windows.Forms.SendKeys]::SendWait($UsernameFocusKeys) }
    Start-Sleep -Milliseconds 300
    Write-Log ('typing username (' + $user.Length + ' chars)')
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $user))
    Start-Sleep -Milliseconds 200
    if ($FieldSeparatorKeys -ne '') { [System.Windows.Forms.SendKeys]::SendWait($FieldSeparatorKeys) }
    Start-Sleep -Milliseconds 200

    if ($pass -eq '') {
        Set-Status $row 'Username typed - no password saved, enter it in Arc' $cAmber
        return
    }
    # safety: never type the password into some other window
    if (-not (Test-ArcFocused $a.ArcPids)) {
        Set-Status $row 'Focus left Arc - password was NOT typed' $cAmber
        return
    }
    Write-Log ('typing password (' + $pass.Length + ' chars), foreground pid=' + [WinHelper]::GetForegroundPid())
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $pass))
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Set-Status $row ("Signed in as '" + $user + "' - click Play in Arc") $cWhite
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

function Start-Play($row) {
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
        ArcPids = @(); Hwnd = [int64]0; HwndSince = Get-Date; SeenAt = $null; Trigger = ''
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
    $pendingRows = @($script:Rows | Where-Object { $_.Pending -ne $null } | Sort-Object { $_.Pending.Since })
    if ($pendingRows.Count -gt 0) {
        $claimed = @(Get-ClaimedPids)
        foreach ($gp in (Get-GamePids)) {
            if ($claimed -contains $gp) { continue }
            foreach ($pr in $pendingRows) {
                if ($pr.Pending -ne $null -and $pr.Pending.Base -notcontains $gp) {
                    $pr.GamePid = $gp
                    $pr.Pending = $null
                    $pr.Button.Text = 'SIGN IN'
                    $claimed += $gp
                    Set-Status $pr ('Running (PID ' + $gp + ')') $cGreen
                    Write-Log ('assigned game client ' + $gp + ' to a pending row')
                    break
                }
            }
        }
    }

    $a = $script:Active
    if ($a -eq $null) { return }
    $elapsed = ((Get-Date) - $a.Start).TotalSeconds
    $a.ArcPids = @(Get-ArcPids | Where-Object { $a.ArcBase -notcontains $_ })

    # what tells us the launch has started: launcher.exe spawned by THIS Arc, or a new game client
    $claimed = @(Get-ClaimedPids)
    $new = @(Get-GamePids | Where-Object { $a.GameBase -notcontains $_ -and $claimed -notcontains $_ })
    $launch = @()
    if ($CloseArcAt -eq 'launcher') { $launch = @(Get-ArcLauncherPids $a.ArcPids) }
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
                Invoke-AutoFill $a
            }
        } elseif ($elapsed -gt $WindowTimeoutSeconds) {
            $a.Phase = 'waiting'
            Write-Log 'timed out finding a visible Arc window'
            Use-Fallback $a "Couldn't find Arc's login window"
        }
    }
    elseif ($a.Phase -eq 'waiting') {
        if ($elapsed -gt $TimeoutSeconds) {
            Finish-Active 'Timed out waiting for a game client' $cAmber $true
        }
    }
    elseif ($a.Phase -eq 'closing') {
        $grace = $GraceSeconds
        if ($a.Trigger -eq 'launcher') { $grace = $LauncherGraceSeconds }
        $left = $grace - ((Get-Date) - $a.SeenAt).TotalSeconds
        if ($left -gt 0) {
            if ($a.Trigger -eq 'launcher') {
                Set-Status $a.Row ("Launcher started - closing Arc in " + [int][math]::Ceiling($left) + "s") $cGreen
            } else {
                Set-Status $a.Row ("Game running (PID " + $a.Row.GamePid + ") - closing Arc in " + [int][math]::Ceiling($left) + "s") $cGreen
            }
            return
        }
        # close only the Arc process(es) that were started for this launch
        foreach ($p in (Get-ArcPids | Where-Object { $a.ArcBase -notcontains $_ })) {
            Stop-ProcessLogged $p
        }
        if ($a.Row.GamePid) {
            Finish-Active ("Running (PID " + $a.Row.GamePid + ")") $cGreen
        } else {
            # Arc is closed; the row picks up its game client when it appears
            $waitRow = $a.Row
            $waitRow.Pending = @{ Since = Get-Date; Base = $a.GameBase; LaunchBase = $a.LaunchBase }
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
function Load-Background {
    $path = Find-BackgroundPath
    if (-not $path) { return }
    try {
        # read into memory so the file is not locked and can be swapped while the manager runs
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $script:BgStream = New-Object System.IO.MemoryStream(, $bytes)
        $script:BgSource = [System.Drawing.Image]::FromStream($script:BgStream)
        Write-Log ('background loaded: ' + $path)
    } catch {
        $script:BgSource = $null
        Write-Log ('background failed to load: ' + $_.Exception.Message)
    }
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
Initialize-ArcPath   # the configured Arc.exe is missing: look for it
if ($KillArcOnStart) {
    $startArc = @(Get-ArcPids)
    if ($startArc.Count -gt 0) {
        Write-Log ('manager start: closing ' + $startArc.Count + ' running Arc process(es)')
        foreach ($p in $startArc) { Stop-ProcessLogged $p }
    }
}

# ---------- settings window (gear button) ----------
# whole-number settings (text boxes); the variable of the same name holds the value
$script:NumFields = @(
    @{ Key = 'WindowWidth';           Label = 'Window width';                   Min = 900; Max = 7680 },
    @{ Key = 'WindowHeight';          Label = 'Window height';                  Min = 420; Max = 4320 },
    @{ Key = 'UsernameFocusTabs';     Label = 'Tabs before username box';       Min = 0;   Max = 20 },
    @{ Key = 'FieldSeparatorTabs';    Label = 'Tabs between the two boxes';     Min = 0;   Max = 20 },
    @{ Key = 'LoginDelayMs';          Label = 'Login delay (milliseconds)';     Min = 0;   Max = 60000 },
    @{ Key = 'MinWaitSeconds';        Label = 'Minimum wait (seconds)';         Min = 0;   Max = 600 },
    @{ Key = 'WindowTimeoutSeconds';  Label = 'Login window timeout (seconds)'; Min = 1;   Max = 600 },
    @{ Key = 'LauncherGraceSeconds';  Label = 'Delay after launcher (seconds)'; Min = 0;   Max = 600 },
    @{ Key = 'GraceSeconds';          Label = 'Delay after game (seconds)';     Min = 0;   Max = 600 },
    @{ Key = 'TimeoutSeconds';        Label = 'Give up after (seconds)';        Min = 10;  Max = 86400 },
    @{ Key = 'PendingTimeoutSeconds'; Label = 'Game wait after close (seconds)'; Min = 10; Max = 86400 },
    @{ Key = 'RenameDurationSeconds'; Label = 'Rename duration (seconds)';      Min = 10;  Max = 3600 },
    @{ Key = 'StatusResetSeconds';    Label = 'Reset status after (seconds)'; Min = 0; Max = 86400 }
)
# on/off settings (tick boxes)
$script:BoolFields = @('RememberWindowSize', 'AutoFill', 'ConfirmStop', 'KillArcOnStart', 'DebugLog', 'RenameGameWindows', 'ShowStorageHint')
$script:ModeNames  = @('fill', 'fit', 'stretch', 'tile', 'center')
$script:ModeLabels = @('Fill', 'Fit', 'Stretch', 'Tile', 'Center')
$script:Ui = @{}
$script:PageBasic = New-Object System.Collections.ArrayList   # the controls of the two pages (Basic / Advanced)
$script:PageAdv = New-Object System.Collections.ArrayList
$script:PageList = $null                                       # while building: which page the new controls belong to
$script:SetDlg = $null
$script:SetTip = $null
$script:SetDirty = $false
$script:SetLoading = $false
$script:SetBuilt = $false

function Get-CurrentValues {
    $v = @{ ArcPath = $ArcPath; CloseArcAt = $CloseArcAt; BackgroundImage = $BackgroundImage; BackgroundMode = $BackgroundMode; BackgroundDim = $BackgroundDim }
    foreach ($f in $script:NumFields) { $v[$f.Key] = [int](Get-Variable -Name $f.Key -Scope Script -ValueOnly) }
    foreach ($k in $script:BoolFields) { $v[$k] = [bool](Get-Variable -Name $k -Scope Script -ValueOnly) }
    return $v
}

# greys out the boxes that do not matter for the current choices
function Update-SEnabled {
    if (-not $script:SetBuilt) { return }
    $u = $script:Ui
    $af = $u['AutoFill'].Checked
    foreach ($k in @('UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds')) { $u[$k].Enabled = $af }
    $l = $u['CloseLauncher'].Checked
    $u['LauncherGraceSeconds'].Enabled = $l
    $u['PendingTimeoutSeconds'].Enabled = $l
    $u['GraceSeconds'].Enabled = (-not $l)
    $u['RenameDurationSeconds'].Enabled = $u['RenameGameWindows'].Checked
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
    foreach ($f in $script:NumFields) { $u[$f.Key].Text = [string]$v[$f.Key] }
    foreach ($k in $script:BoolFields) { $u[$k].Checked = [bool]$v[$k] }
    $u['CloseLauncher'].Checked = ($v['CloseArcAt'] -ne 'game')
    $u['CloseGame'].Checked = ($v['CloseArcAt'] -eq 'game')
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
    $v['CloseArcAt'] = 'game'
    if ($u['CloseLauncher'].Checked) { $v['CloseArcAt'] = 'launcher' }
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
    foreach ($f in $script:NumFields) { Set-Variable -Name $f.Key -Value ([int]$v[$f.Key]) -Scope Script }
    foreach ($k in $script:BoolFields) { Set-Variable -Name $k -Value ([bool]$v[$k]) -Scope Script }
    $script:CloseArcAt = $v['CloseArcAt']
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
    foreach ($f in $script:NumFields) { if (-not [IniFile]::Put($IniFile, $f.Key, [string]$v[$f.Key])) { $ok = $false } }
    foreach ($k in $script:BoolFields) {
        $t = '0'
        if ($v[$k]) { $t = '1' }
        if (-not [IniFile]::Put($IniFile, $k, $t)) { $ok = $false }
    }
    if (-not [IniFile]::Put($IniFile, 'CloseArcAt', [string]$v['CloseArcAt'])) { $ok = $false }
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
    $hint.Visible = [bool]$ShowStorageHint
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
function Show-SettingsPage([int]$page) {
    foreach ($c in $script:PageBasic) { $c.Visible = ($page -eq 0) }
    foreach ($c in $script:PageAdv) { $c.Visible = ($page -eq 1) }
    $script:Ui['PageBasic'].Checked = ($page -eq 0)
    $script:Ui['PageAdv'].Checked = ($page -eq 1)
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
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 512)
    $dlg.BackColor = [System.Drawing.SystemColors]::Control
    $dlg.ForeColor = [System.Drawing.SystemColors]::ControlText
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.AutoPopDelay = 20000
    $script:SetTip = $tt

    $script:PageBasic.Clear()
    $script:PageAdv.Clear()
    $script:PageList = $null
    $title = New-SLabel $dlg 'CONFIGURATION' 16 8 400 36
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    # two push-like radio buttons switch between the pages
    $pb = New-Object System.Windows.Forms.RadioButton
    $pb.Text = 'Basic'
    $pb.Appearance = 'Button'
    $pb.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $pb 440 14 90 26
    $script:Ui['PageBasic'] = $pb
    $pa = New-Object System.Windows.Forms.RadioButton
    $pa.Text = 'Advanced'
    $pa.Appearance = 'Button'
    $pa.TextAlign = 'MiddleCenter'
    Add-SCtl $dlg $pa 534 14 90 26
    $script:Ui['PageAdv'] = $pa
    $pb.Add_Click({ Show-SettingsPage 0 })
    $pa.Add_Click({ Show-SettingsPage 1 })

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

    $g = New-SGroup 'Close Arc when' 16 198 300 82
    [void](New-SRadio $g 'CloseLauncher' 'The launcher starts' 28 220 266)
    [void](New-SRadio $g 'CloseGame' 'The game client starts' 28 244 266)

    $g = New-SGroup 'Options' 332 106 292 174
    [void](New-SCheck $g 'DebugLog' 'Debug / Logs' 344 130 270)
    [void](New-SCheck $g 'KillArcOnStart' 'Close running Arc at start / sign-in' 344 154 270)
    [void](New-SCheck $g 'AutoFill' 'Auto-fill username and password' 344 178 270)
    [void](New-SCheck $g 'RenameGameWindows' 'Rename game windows to Notes' 344 202 270)
    [void](New-SCheck $g 'ConfirmStop' 'Ask before stopping a game client' 344 226 270)
    [void](New-SCheck $g 'ShowStorageHint' 'Show plain-text storage notice' 344 250 270)

    $g = New-SGroup 'Background' 16 288 608 146
    [void](New-SLabel $g 'Background Image Location' 28 308 300 20)
    [void](New-SEdit $g 'BackgroundImage' 28 330 496 $false)
    $b2 = New-SButton 'BrowseBg' 'Browse...' 532 329 80 25
    $g.Controls.Add($b2)
    $b2.SetBounds((532 - $g.Left), (329 - $g.Top), 80, 25)
    $b2.Add_Click({ Browse-Into 'BackgroundImage' 'Pictures|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files|*.*' 'Choose a background image' })
    [void](New-SLabel $g 'Mode' 28 366 44 20)
    for ($i = 0; $i -lt 5; $i++) { [void](New-SRadio $g ('Mode' + $i) $script:ModeLabels[$i] (74 + $i * 96) 366 92) }
    [void](New-SLabel $g 'Darkness' 28 398 62 30)
    $tb = New-Object System.Windows.Forms.TrackBar
    $tb.Minimum = 0
    $tb.Maximum = 100
    $tb.TickFrequency = 10
    $tb.LargeChange = 10
    $tb.SmallChange = 1
    $tb.Add_ValueChanged({ Update-DimLabel; Set-SDirty })
    Add-SCtl $g $tb 92 394 420 40
    $script:Ui['Dim'] = $tb
    $dl = New-SLabel $g '50%' 520 398 80 30
    $script:Ui['DimLbl'] = $dl

    # ======== page 2: Advanced (rarely needs changing)
    $script:PageList = $script:PageAdv
    [void](New-SLabel $dlg 'Timing and fine-tuning. The defaults suit most computers.' 16 108 608 20)
    $g = New-SGroup 'Signing in' 16 134 300 200
    $y = 160
    foreach ($k in @('UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds')) {
        New-SNumRow $g $k 28 205 240 58 $y
        $y += 30
    }
    $g = New-SGroup 'Closing Arc and other' 332 134 292 200
    $y = 160
    foreach ($k in @('LauncherGraceSeconds', 'GraceSeconds', 'TimeoutSeconds', 'PendingTimeoutSeconds', 'RenameDurationSeconds', 'StatusResetSeconds')) {
        New-SNumRow $g $k 344 210 556 56 $y
        $y += 28
    }
    $script:PageList = $null

    # ======== buttons (always visible)
    $bd = New-SButton 'Defaults' 'LOAD DEFAULTS' 16 446 130 28
    $bf = New-SButton 'Folder' 'OPEN SETTINGS FOLDER' 154 446 176 28
    $bs = New-SButton 'Save' 'SAVE CONFIGURATION' 338 446 184 28
    $bc = New-SButton 'Cancel' 'CANCEL' 530 446 94 28
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
    $info = New-SLabel $dlg ('Settings file: ' + $IniFile) 16 486 440 20
    $info.AutoEllipsis = $true
    $ver = New-SLabel $dlg ($AppVersion + ' (PowerShell)') 464 486 160 20
    $ver.TextAlign = 'MiddleRight'

    # hover hints
    $tips = @{
        PageBasic = 'The settings most people use.'
        PageAdv = 'Timing and fine-tuning. The defaults suit most computers.'
        ArcPath = 'Full path to Arc.exe. The file must be named Arc.exe. (If it is missing, the manager tries to find it by itself.)'
        Folder = 'Open the folder that holds the settings, accounts and log files.'
        WindowWidth = "Width of the manager window's inside area, in pixels (900 or more)."
        WindowHeight = "Height of the manager window's inside area, in pixels (420 or more)."
        RememberWindowSize = 'Save the window size when the program closes, so it opens the same way next time.'
        AutoFill = 'Type the username and password into the Arc login window for you.'
        UsernameFocusTabs = "Tab key presses sent first, to move onto the username box in Arc's login window."
        FieldSeparatorTabs = 'Tab key presses sent between the username and the password.'
        LoginDelayMs = "How long Arc's login window must be showing before typing starts (1000 = 1 second)."
        MinWaitSeconds = 'Never type sooner than this after starting Arc (skips update pop-ups).'
        WindowTimeoutSeconds = "Give up looking for Arc's login window after this many seconds."
        CloseLauncher = 'Close this Arc as soon as it starts the game launcher (launcher.exe).'
        CloseGame = 'Wait until the game client (elementclient.exe) is running before closing Arc.'
        LauncherGraceSeconds = 'Seconds to wait after the launcher appears before closing Arc.'
        GraceSeconds = 'Seconds to wait after the game client appears before closing Arc.'
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
    $found = 'no'
    if (Test-Path -LiteralPath $ArcPath) { $found = 'yes' }
    $r += 'Arc.exe found: ' + $found + '   running as administrator: ' + $script:IsAdmin + "`r`n"
    $r += 'Settings: '
    foreach ($k in @('AutoFill', 'UsernameFocusTabs', 'FieldSeparatorTabs', 'LoginDelayMs', 'MinWaitSeconds', 'WindowTimeoutSeconds', 'CloseArcAt', 'LauncherGraceSeconds', 'GraceSeconds', 'TimeoutSeconds', 'PendingTimeoutSeconds', 'KillArcOnStart', 'RenameGameWindows', 'RenameDurationSeconds', 'StatusResetSeconds')) {
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
function Add-Row([string]$user, [string]$pass, [string]$notes) {
    $y = 8 + ($script:Rows.Count * 40)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(16, $y)
    $tb.Size = New-Object System.Drawing.Size(195, 26)
    $tb.Text = $user
    $tb.BackColor = $cBox
    $tb.ForeColor = $cWhite
    $tb.BorderStyle = 'FixedSingle'

    $pw = New-Object System.Windows.Forms.TextBox
    $pw.Location = New-Object System.Drawing.Point(223, $y)
    $pw.Size = New-Object System.Drawing.Size(195, 26)
    $pw.Text = $pass
    $pw.UseSystemPasswordChar = $true
    $pw.BackColor = $cBox
    $pw.ForeColor = $cWhite
    $pw.BorderStyle = 'FixedSingle'

    $nt = New-Object System.Windows.Forms.TextBox
    $nt.Location = New-Object System.Drawing.Point(430, $y)
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
    $btn.Location = New-Object System.Drawing.Point(637, ($y - 1))
    $btn.Size = New-Object System.Drawing.Size(130, 28)
    $btn.Text = 'SIGN IN'
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $cRed
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    $stop = New-Object System.Windows.Forms.Button
    $stop.Location = New-Object System.Drawing.Point(777, ($y - 1))
    $stop.Size = New-Object System.Drawing.Size(84, 28)
    $stop.Text = 'STOP'
    $stop.Enabled = $false
    $stop.FlatStyle = 'Flat'
    $stop.FlatAppearance.BorderSize = 0
    $stop.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $stop.ForeColor = [System.Drawing.Color]::White
    $stop.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(871, ($y + 4))
    $lbl.Size = New-Object System.Drawing.Size(370, 22)
    $lbl.AutoEllipsis = $true
    $lbl.Text = 'Idle'
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.ForeColor = $cGray

    $row = @{ Box = $tb; Pass = $pw; Notes = $nt; Button = $btn; Stop = $stop; Label = $lbl; GamePid = $null; Pending = $null; GameStart = $null; GameStartPid = $null; Title = ''; TitlePid = $null; TitleSeen = $null; TitleLogs = 0; StatusSince = $null; StatusTransient = $false }
    $btn.Tag = $row
    $stop.Tag = $row
    $stop.Add_Click({ param($s, $e) Stop-Client $s.Tag })
    $btn.Add_Click({ param($s, $e) Start-Play $s.Tag })

    $panel.Controls.Add($tb)
    $panel.Controls.Add($pw)
    $panel.Controls.Add($nt)
    $panel.Controls.Add($btn)
    $panel.Controls.Add($stop)
    $panel.Controls.Add($lbl)
    [void]$script:Rows.Add($row)
}

foreach ($acc in $accounts) { Add-Row $acc.User $acc.Pass $acc.Notes }
Adopt-Session

$addBtn = New-Object System.Windows.Forms.Button
$addBtn.Text = '+ Add account'
$addBtn.Location = New-Object System.Drawing.Point(16, ($form.ClientSize.Height - 42))
$addBtn.Size = New-Object System.Drawing.Size(120, 28)
$addBtn.Anchor = 'Bottom,Left'
$addBtn.FlatStyle = 'Flat'
$addBtn.BackColor = $cBox
$addBtn.ForeColor = $cWhite
$addBtn.Add_Click({ Add-Row '' '' ''; $script:Rows[$script:Rows.Count - 1].Box.Focus() })
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

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Usernames and passwords are saved as PLAIN TEXT in %AppData%\ArcManager\accounts.txt'
$hint.ForeColor = $cGray
$hint.AutoSize = $false
$hint.AutoEllipsis = $true
$hint.Anchor = 'Bottom,Left,Right'
$hint.BackColor = [System.Drawing.Color]::Transparent
$hint.Visible = [bool]$ShowStorageHint
$hint.Location = New-Object System.Drawing.Point(676, ($form.ClientSize.Height - 36))
$hint.Size = New-Object System.Drawing.Size([math]::Max(100, ($form.ClientSize.Width - 676 - 16 - 80)), 20)
$form.Controls.Add($hint)

# always shown
$blankHint = New-Object System.Windows.Forms.Label
$blankHint.Text = 'Blank entries deleted on exit.'
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
$script:TipMain.SetToolTip($logBtn, 'View log')
$script:TipMain.SetToolTip($importBtn, 'Add accounts from a text file (same format as accounts.txt). Accounts already in the list are skipped.')
$script:TipMain.SetToolTip($exportBtn, 'Save the accounts list to a text file. The file contains the passwords as plain text.')

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Update-State; Expire-Statuses; Save-Session; Apply-WindowTitles })
$timer.Start()

$script:LastState = $form.WindowState
$form.Add_ResizeEnd({ Update-Background })
$form.Add_SizeChanged({
    if ($form.WindowState -ne $script:LastState) { $script:LastState = $form.WindowState; Update-Background }
})
$form.Add_FormClosing({
    param($s, $e)
    $running = @($script:Rows | Where-Object { $_.GamePid }).Count
    if ($running -gt 0) {
        $q = [string]$running + ' game client(s) still running.' + "`n`n" + 'They keep running if you close the manager, and the manager finds them again the next time it starts.' + "`n`n" + 'Close the manager anyway?'
        if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Game clients running', 'YesNo', 'Question', 'Button2') -ne 'Yes') { $e.Cancel = $true; return }
    }
    Save-Accounts
    Save-Session
    if ($RememberWindowSize -and $form.WindowState -eq 'Normal') {
        [void][IniFile]::Put($IniFile, 'WindowWidth', [string]$form.ClientSize.Width)
        [void][IniFile]::Put($IniFile, 'WindowHeight', [string]$form.ClientSize.Height)
    }
})
[void]$form.ShowDialog()
