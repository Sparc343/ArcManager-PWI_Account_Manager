// ArcManager - native Win32 account manager (resizable window, scrolling list, background image).
// Build as 32-bit with the w64devkit "x86" kit to run on Windows XP .. Windows 11.
// Uses only APIs that exist on Windows XP. No .NET, no PowerShell, no runtime DLLs.

#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define _WIN32_IE 0x0600
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include <tlhelp32.h>
#include <commctrl.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <string>
#include <vector>

#include "resource.h"

static const wchar_t* kAppVersion = L"" APP_VERSION_TEXT;   // version text: edit it in resource.h

#ifndef EM_SETCUEBANNER
#define EM_SETCUEBANNER 0x1501
#endif
#ifndef ICC_STANDARD_CLASSES
#define ICC_STANDARD_CLASSES 0x00004000
#endif
#ifndef ICC_BAR_CLASSES
#define ICC_BAR_CLASSES 0x00000004
#endif

// ------------------------------------------------------------------ constants
static const COLORREF cBg     = RGB(24, 24, 28);
static const COLORREF cBox    = RGB(38, 38, 44);
static const COLORREF cWhite  = RGB(235, 235, 235);
static const COLORREF cGray   = RGB(140, 140, 150);
static const COLORREF cRed    = RGB(230, 30, 60);
static const COLORREF cGreen  = RGB(80, 200, 120);
static const COLORREF cAmber  = RGB(240, 170, 60);
static const COLORREF cStopBg = RGB(70, 70, 80);

enum {
    ID_TITLE = 800, ID_HDR1, ID_HDR2, ID_HDR3, ID_BLANKHINT, ID_STORAGEHINT,
    ID_ADD = 810, ID_SHOWPW = 811, ID_GEAR = 812, ID_LOG = 813, ID_IMPORT = 814, ID_EXPORT = 815,
    ID_TIMER = 1, ID_BGTIMER = 2,
    ID_ROW_BASE = 1000
};
enum { K_USER = 0, K_PASS, K_NOTES, K_SIGN, K_STOP, K_STATUS };
static inline int RowId(int row, int kind) { return ID_ROW_BASE + row * 10 + kind; }

typedef std::vector<DWORD> PidList;

// ------------------------------------------------------------------ settings
struct Settings {
    std::wstring arcPath;
    bool autoFill, closeAtLauncher, confirmStop, killArcOnStart, debugLog, showStorageHint, renameWindows;
    int usernameFocusTabs, fieldSeparatorTabs, loginDelayMs, minWaitSeconds, windowTimeoutSeconds;
    int graceSeconds, launcherGraceSeconds, timeoutSeconds, pendingTimeoutSeconds;
    int windowWidth, windowHeight;
    bool rememberSize;
    int renameDurationSeconds, statusResetSeconds;
    std::wstring bgImage, bgMode;
    double bgDim;
};
static Settings S;

static std::wstring g_iniPath, g_configDir, g_accountsPath, g_logPath, g_prevLogPath, g_sessionPath, g_exeDir;
static HINSTANCE g_hInst;
static HWND g_hwnd;
static HFONT g_font, g_fontBold, g_fontTitle;
static HBRUSH g_brBg, g_brBox;
static bool g_showPw = false;

// ------------------------------------------------------------------ small helpers
static std::string ToUtf8(const std::wstring& w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), NULL, 0, NULL, NULL);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, NULL, NULL);
    return s;
}
static std::wstring FromUtf8(const char* p, int len) {
    if (len <= 0) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, p, len, NULL, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, p, len, &w[0], n);
    return w;
}
static std::wstring Trim(const std::wstring& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == L' ' || s[a] == L'\t' || s[a] == L'\r' || s[a] == L'\n')) a++;
    while (b > a && (s[b - 1] == L' ' || s[b - 1] == L'\t' || s[b - 1] == L'\r' || s[b - 1] == L'\n')) b--;
    return s.substr(a, b - a);
}
static std::wstring GetText(HWND h) {
    int n = GetWindowTextLengthW(h);
    std::wstring s((size_t)n, L'\0');
    if (n > 0) GetWindowTextW(h, &s[0], n + 1);
    return s;
}
static bool Has(const PidList& v, DWORD p) { return std::find(v.begin(), v.end(), p) != v.end(); }
static PidList Minus(const PidList& a, const PidList& b) {
    PidList out;
    for (size_t i = 0; i < a.size(); i++) if (!Has(b, a[i])) out.push_back(a[i]);
    return out;
}
static bool FileExists(const std::wstring& p) { return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; }

static bool ReadWholeFile(const std::wstring& path, std::string& out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD size = GetFileSize(h, NULL);
    out.assign(size, '\0');
    DWORD got = 0;
    BOOL ok = size == 0 ? TRUE : ReadFile(h, &out[0], size, &got, NULL);
    CloseHandle(h);
    if (!ok) return false;
    out.resize(got);
    return true;
}
static bool WriteWholeFile(const std::wstring& path, const std::string& data) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD put = 0;
    BOOL ok = data.empty() ? TRUE : WriteFile(h, data.data(), (DWORD)data.size(), &put, NULL);
    if (ok) FlushFileBuffers(h);
    CloseHandle(h);
    return ok != FALSE;
}
// Writes the data to "<file>.tmp" first and swaps it in afterwards, so a crash or power loss can never leave a half-written file.
// The previous version of the file (when it was not empty) is kept as "<file>.bak".
static bool WriteWholeFileSafe(const std::wstring& path, const std::string& data) {
    std::wstring tmp = path + L".tmp", bak = path + L".bak";
    if (!WriteWholeFile(tmp, data)) { DeleteFileW(tmp.c_str()); return false; }
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fa) && (fa.nFileSizeLow || fa.nFileSizeHigh)) CopyFileW(path.c_str(), bak.c_str(), FALSE);
    if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) { DeleteFileW(tmp.c_str()); return false; }
    return true;
}

// ------------------------------------------------------------------ logging (never writes passwords)
static void Log(const std::wstring& msg) {
    if (!S.debugLog) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t ts[32];
    wsprintfW(ts, L"%02d:%02d:%02d.%03d  ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    std::string line = ToUtf8(std::wstring(ts) + msg + L"\r\n");
    HANDLE h = CreateFileW(g_logPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SetFilePointer(h, 0, NULL, FILE_END);
    DWORD put = 0;
    WriteFile(h, line.data(), (DWORD)line.size(), &put, NULL);
    CloseHandle(h);
}
static void ResetLog() {
    if (!S.debugLog) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t ts[64];
    wsprintfW(ts, L"%04d-%02d-%02d %02d:%02d:%02d", (int)t.wYear, (int)t.wMonth, (int)t.wDay, (int)t.wHour, (int)t.wMinute, (int)t.wSecond);
    WriteWholeFile(g_logPath, ToUtf8(L"ArcManager (C++) " + std::wstring(kAppVersion) + L" debug log - started " + std::wstring(ts) + L"\r\n"));
}
// a new log for this run; the log of the run before it is kept as debug.previous.log
static void StartNewLog() {
    if (!S.debugLog) return;
    if (FileExists(g_logPath)) CopyFileW(g_logPath.c_str(), g_prevLogPath.c_str(), FALSE);
    ResetLog();
}

// ------------------------------------------------------------------ paths + settings file
static std::wstring EnvVar(const wchar_t* name) {
    wchar_t buf[1024];
    DWORD n = GetEnvironmentVariableW(name, buf, 1024);
    return (n > 0 && n < 1024) ? std::wstring(buf, n) : std::wstring();
}
static void InitPaths() {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    std::wstring dir(exe);
    size_t cut = dir.find_last_of(L"\\/");
    dir = (cut == std::wstring::npos) ? L"." : dir.substr(0, cut);
    g_exeDir = dir;
    std::wstring appdata = EnvVar(L"APPDATA");
    if (appdata.empty()) appdata = dir;
    g_configDir = appdata + L"\\ArcManager";
    CreateDirectoryW(g_configDir.c_str(), NULL);
    g_accountsPath = g_configDir + L"\\accounts.txt";
    g_logPath = g_configDir + L"\\debug.log";
    g_prevLogPath = g_configDir + L"\\debug.previous.log";
    g_sessionPath = g_configDir + L"\\session.txt";
    // the settings file lives in %AppData%\ArcManager; a copy placed next to the program is used instead (portable mode)
    g_iniPath = g_configDir + L"\\ArcManager.ini";
    std::wstring portable = dir + L"\\ArcManager.ini";
    if (FileExists(portable)) g_iniPath = portable;
}
static const char* kDefaultIni =
    "; ArcManager settings.\r\n"
    "; The easiest way to change them is the gear button in the program. If you edit this file by hand,\r\n"
    "; save it and restart the program. 1 = on, 0 = off.\r\n"
    "; (A copy of this file placed next to the program is used instead of this one.)\r\n"
    "[Settings]\r\n"
    "; Full path to Arc.exe (the file must be named Arc.exe)\r\n"
    "ArcPath=C:\\Program Files (x86)\\Arc\\Arc.exe\r\n"
    "; Window size. The window can also be resized by hand; RememberWindowSize=1 saves the size when you close the program.\r\n"
    "WindowWidth=1280\r\n"
    "WindowHeight=720\r\n"
    "RememberWindowSize=1\r\n"
    "AutoFill=1\r\n"
    "; Tab presses before the username box / between username and password\r\n"
    "UsernameFocusTabs=1\r\n"
    "FieldSeparatorTabs=1\r\n"
    "LoginDelayMs=3000\r\n"
    "MinWaitSeconds=6\r\n"
    "WindowTimeoutSeconds=40\r\n"
    "; CloseArcAt: launcher (as soon as Arc starts launcher.exe) or game (wait for elementclient.exe)\r\n"
    "CloseArcAt=launcher\r\n"
    "LauncherGraceSeconds=2\r\n"
    "GraceSeconds=6\r\n"
    "TimeoutSeconds=300\r\n"
    "PendingTimeoutSeconds=600\r\n"
    "ConfirmStop=0\r\n"
    "KillArcOnStart=1\r\n"
    "DebugLog=1\r\n"
    "; Show a note at the bottom of the window that accounts are saved as plain text: 1 = yes, 0 = no\r\n"
    "ShowStorageHint=0\r\n"
    "; Rename each game client window to the Notes text of its row: 1 = yes\r\n"
    "RenameGameWindows=1\r\n"
    "; Windows are re-checked every second for this many seconds after a game client starts (the game opens and closes windows while loading)\r\n"
    "RenameDurationSeconds=180\r\n"
    "; Messages such as Stopped / Cancelled / Timed out go back to Idle after this many seconds (0 = never)\r\n"
    "StatusResetSeconds=90\r\n"
    "; Background image. Leave BackgroundImage blank to use background.png/jpg/jpeg/bmp/gif found next to the program or in %AppData%\\ArcManager;\r\n"
    "; if none is found, the C++ version uses its built-in image (the PowerShell version a plain dark background).\r\n"
    "BackgroundImage=\r\n"
    "; BackgroundMode: fill (cover, cropped) | fit (whole image, bars) | stretch | tile | center\r\n"
    "BackgroundMode=fill\r\n"
    "; BackgroundDim: 0 = image as-is ... 1 = black (keeps the text readable)\r\n"
    "BackgroundDim=0.5\r\n"
    "; Advanced (not shown in the settings window). PowerShell version only (this program always asks for administrator rights): 1 = restart as administrator\r\n"
    "RunElevated=1\r\n";

// the built-in defaults (keep in step with kDefaultIni above)
static Settings DefaultSettings() {
    Settings d;
    d.arcPath = L"C:\\Program Files (x86)\\Arc\\Arc.exe";
    d.autoFill = true; d.closeAtLauncher = true; d.confirmStop = false; d.killArcOnStart = true; d.debugLog = true; d.showStorageHint = false; d.renameWindows = true; d.renameDurationSeconds = 180; d.statusResetSeconds = 90;
    d.usernameFocusTabs = 1; d.fieldSeparatorTabs = 1; d.loginDelayMs = 3000; d.minWaitSeconds = 6; d.windowTimeoutSeconds = 40;
    d.graceSeconds = 6; d.launcherGraceSeconds = 2; d.timeoutSeconds = 300; d.pendingTimeoutSeconds = 600;
    d.windowWidth = 1280; d.windowHeight = 720; d.rememberSize = true;
    d.bgImage = L""; d.bgMode = L"fill"; d.bgDim = 0.5;
    return d;
}

// The settings file is stored as UTF-16 so that folder names with accented / non-Latin letters survive.
static void WriteUnicodeFile(const std::wstring& path, const std::wstring& text) {
    std::string bytes("\xFF\xFE", 2);
    bytes.append((const char*)text.data(), text.size() * sizeof(wchar_t));
    WriteWholeFile(path, bytes);
}
// converts an older ANSI / UTF-8 settings file to UTF-16 (leaves UTF-16 files alone)
static void EnsureUnicodeIni() {
    std::string raw;
    if (!ReadWholeFile(g_iniPath, raw) || raw.empty()) return;
    const unsigned char* p = (const unsigned char*)raw.data();
    if (raw.size() >= 2 && p[0] == 0xFF && p[1] == 0xFE) return;
    std::wstring text;
    if (raw.size() >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) {
        text = FromUtf8(raw.data() + 3, (int)raw.size() - 3);
    } else {
        int n = MultiByteToWideChar(CP_ACP, 0, raw.data(), (int)raw.size(), NULL, 0);
        if (n <= 0) return;
        text.assign((size_t)n, L'\0');
        MultiByteToWideChar(CP_ACP, 0, raw.data(), (int)raw.size(), &text[0], n);
    }
    WriteUnicodeFile(g_iniPath, text);
}

static std::wstring IniStr(const wchar_t* key, const wchar_t* def) {
    wchar_t buf[1024];
    GetPrivateProfileStringW(L"Settings", key, def, buf, 1024, g_iniPath.c_str());
    return std::wstring(buf);
}
static int IniInt(const wchar_t* key, int def) {
    return (int)GetPrivateProfileIntW(L"Settings", key, def, g_iniPath.c_str());
}
static void LoadSettings() {
    if (!FileExists(g_iniPath)) WriteUnicodeFile(g_iniPath, FromUtf8(kDefaultIni, (int)strlen(kDefaultIni)));
    else EnsureUnicodeIni();
    const Settings D = DefaultSettings();
    S.arcPath = IniStr(L"ArcPath", D.arcPath.c_str());
    S.autoFill = IniInt(L"AutoFill", D.autoFill) != 0;
    S.usernameFocusTabs = IniInt(L"UsernameFocusTabs", D.usernameFocusTabs);
    S.fieldSeparatorTabs = IniInt(L"FieldSeparatorTabs", D.fieldSeparatorTabs);
    S.loginDelayMs = IniInt(L"LoginDelayMs", D.loginDelayMs);
    S.minWaitSeconds = IniInt(L"MinWaitSeconds", D.minWaitSeconds);
    S.windowTimeoutSeconds = IniInt(L"WindowTimeoutSeconds", D.windowTimeoutSeconds);
    S.closeAtLauncher = _wcsicmp(IniStr(L"CloseArcAt", L"launcher").c_str(), L"game") != 0;
    S.launcherGraceSeconds = IniInt(L"LauncherGraceSeconds", D.launcherGraceSeconds);
    S.graceSeconds = IniInt(L"GraceSeconds", D.graceSeconds);
    S.timeoutSeconds = IniInt(L"TimeoutSeconds", D.timeoutSeconds);
    S.pendingTimeoutSeconds = IniInt(L"PendingTimeoutSeconds", D.pendingTimeoutSeconds);
    S.confirmStop = IniInt(L"ConfirmStop", D.confirmStop) != 0;
    S.killArcOnStart = IniInt(L"KillArcOnStart", D.killArcOnStart) != 0;
    S.showStorageHint = IniInt(L"ShowStorageHint", D.showStorageHint) != 0;
    S.renameWindows = IniInt(L"RenameGameWindows", D.renameWindows) != 0;
    S.renameDurationSeconds = IniInt(L"RenameDurationSeconds", D.renameDurationSeconds);
    S.statusResetSeconds = IniInt(L"StatusResetSeconds", D.statusResetSeconds);
    S.debugLog = IniInt(L"DebugLog", D.debugLog) != 0;
    S.windowWidth = std::max(900, IniInt(L"WindowWidth", D.windowWidth));
    S.windowHeight = std::max(420, IniInt(L"WindowHeight", D.windowHeight));
    S.rememberSize = IniInt(L"RememberWindowSize", D.rememberSize) != 0;
    S.bgImage = Trim(IniStr(L"BackgroundImage", L""));
    S.bgMode = IniStr(L"BackgroundMode", L"fill");
    for (size_t i = 0; i < S.bgMode.size(); i++) S.bgMode[i] = (wchar_t)towlower(S.bgMode[i]);
    S.bgMode = Trim(S.bgMode);
    std::wstring dim = IniStr(L"BackgroundDim", L"0.5");
    for (size_t i = 0; i < dim.size(); i++) if (dim[i] == L',') dim[i] = L'.';
    S.bgDim = wcstod(dim.c_str(), NULL);
    if (S.bgDim < 0.0) S.bgDim = 0.0;
    if (S.bgDim > 1.0) S.bgDim = 1.0;
}

// For safety the manager only ever launches a program named Arc.exe (it runs with administrator rights).
static bool IsArcExeName(const std::wstring& path) {
    size_t cut = path.find_last_of(L"\\/");
    std::wstring name = (cut == std::wstring::npos) ? path : path.substr(cut + 1);
    return _wcsicmp(name.c_str(), L"Arc.exe") == 0;
}

// ------------------------------------------------------------------ processes
struct Proc { DWORD pid; DWORD ppid; std::wstring name; };

static std::vector<Proc> Snapshot() {
    std::vector<Proc> out;
    HANDLE h = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (h == INVALID_HANDLE_VALUE) return out;
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(h, &pe)) {
        do {
            Proc p;
            p.pid = pe.th32ProcessID;
            p.ppid = pe.th32ParentProcessID;
            p.name = pe.szExeFile;
            out.push_back(p);
        } while (Process32NextW(h, &pe));
    }
    CloseHandle(h);
    return out;
}
static PidList PidsByName(const std::vector<Proc>& snap, const wchar_t* n1, const wchar_t* n2 = NULL) {
    PidList out;
    for (size_t i = 0; i < snap.size(); i++) {
        if (_wcsicmp(snap[i].name.c_str(), n1) == 0 || (n2 && _wcsicmp(snap[i].name.c_str(), n2) == 0))
            out.push_back(snap[i].pid);
    }
    return out;
}
static PidList ArcPids(const std::vector<Proc>& s) { return PidsByName(s, L"Arc.exe"); }
static PidList GamePids(const std::vector<Proc>& s) { return PidsByName(s, L"elementclient.exe", L"elementclient_64.exe"); }
// launcher.exe / patcher.exe started directly by one of the given Arc processes
static PidList LauncherPidsOf(const std::vector<Proc>& snap, const PidList& arcPids) {
    PidList out;
    for (size_t i = 0; i < snap.size(); i++) {
        if ((_wcsicmp(snap[i].name.c_str(), L"launcher.exe") == 0 || _wcsicmp(snap[i].name.c_str(), L"patcher.exe") == 0)
            && Has(arcPids, snap[i].ppid))
            out.push_back(snap[i].pid);
    }
    return out;
}
static bool KillPid(DWORD pid);
// CANCEL: closes Arc.exe plus the launcher.exe / patcher.exe that appeared since the sign-in began (game clients are never touched)
static void CloseLaunchLeftovers(const PidList& launchBase) {
    std::vector<Proc> snap = Snapshot();
    PidList arc = ArcPids(snap);
    for (size_t k = 0; k < arc.size(); k++) KillPid(arc[k]);
    PidList tools = PidsByName(snap, L"launcher.exe", L"patcher.exe");
    int closed = 0;
    for (size_t k = 0; k < tools.size(); k++) if (!Has(launchBase, tools[k])) { KillPid(tools[k]); closed++; }
    Log(L"cancel: closed " + std::to_wstring((long long)arc.size()) + L" Arc process(es) and " + std::to_wstring((long long)closed) + L" launcher/patcher process(es)");
}
static bool KillPid(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    if (!h) { Log(L"FAILED to open pid " + std::to_wstring((long long)pid) + L" (error " + std::to_wstring((long long)GetLastError()) + L")"); return false; }
    BOOL ok = TerminateProcess(h, 1);
    CloseHandle(h);
    Log(std::wstring(ok ? L"closed pid " : L"FAILED to close pid ") + std::to_wstring((long long)pid));
    return ok != FALSE;
}

// ------------------------------------------------------------------ windows + keyboard
struct FindCtx { PidList pids; HWND best; int bestArea; };
static BOOL CALLBACK EnumProc(HWND h, LPARAM lp) {
    FindCtx* c = (FindCtx*)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (!Has(c->pids, pid) || !IsWindowVisible(h)) return TRUE;
    RECT r;
    GetWindowRect(h, &r);
    int w = r.right - r.left, ht = r.bottom - r.top;
    if (w < 200 || ht < 150) return TRUE;
    int area = w * ht;
    if (area > c->bestArea) { c->bestArea = area; c->best = h; }
    return TRUE;
}
// the largest visible top-level window of the given processes
static HWND FindVisibleWindow(const PidList& pids) {
    FindCtx c;
    c.pids = pids; c.best = NULL; c.bestArea = 0;
    EnumWindows(EnumProc, (LPARAM)&c);
    return c.best;
}
static bool ArcFocused(const PidList& arcPids) {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return Has(arcPids, pid);
}
static void BringToFront(HWND h) {
    ShowWindow(h, SW_RESTORE);
    HWND fg = GetForegroundWindow();
    DWORD fgThread = fg ? GetWindowThreadProcessId(fg, NULL) : 0;
    DWORD me = GetCurrentThreadId();
    bool attached = false;
    if (fgThread && fgThread != me) attached = AttachThreadInput(me, fgThread, TRUE) != FALSE;
    SetForegroundWindow(h);
    BringWindowToTop(h);
    if (attached) AttachThreadInput(me, fgThread, FALSE);
}
static void KeyEvent(WORD vk, bool up) {
    INPUT in;
    ZeroMemory(&in, sizeof(in));
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.wScan = (WORD)MapVirtualKeyW(vk, 0);
    in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    SendInput(1, &in, sizeof(in));
}
static void TapKey(WORD vk) { KeyEvent(vk, false); KeyEvent(vk, true); Sleep(15); }
static void CtrlA() { KeyEvent(VK_CONTROL, false); TapKey('A'); KeyEvent(VK_CONTROL, true); Sleep(30); }
static void TypeUnicodeChar(wchar_t c) {
    INPUT in[2];
    ZeroMemory(in, sizeof(in));
    in[0].type = INPUT_KEYBOARD; in[0].ki.wScan = c; in[0].ki.dwFlags = KEYEVENTF_UNICODE;
    in[1].type = INPUT_KEYBOARD; in[1].ki.wScan = c; in[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}
// types like a keyboard (layout aware); falls back to unicode input for characters not on the layout
static void TypeText(const std::wstring& s) {
    bool caps = (GetKeyState(VK_CAPITAL) & 1) != 0;
    if (caps) TapKey(VK_CAPITAL);
    for (size_t i = 0; i < s.size(); i++) {
        SHORT v = VkKeyScanW(s[i]);
        if (v == -1) { TypeUnicodeChar(s[i]); Sleep(10); continue; }
        BYTE vk = LOBYTE(v), st = HIBYTE(v);
        if (st & 1) KeyEvent(VK_SHIFT, false);
        if (st & 2) KeyEvent(VK_CONTROL, false);
        if (st & 4) KeyEvent(VK_MENU, false);
        TapKey(vk);
        if (st & 4) KeyEvent(VK_MENU, true);
        if (st & 2) KeyEvent(VK_CONTROL, true);
        if (st & 1) KeyEvent(VK_SHIFT, true);
        Sleep(10);
    }
    if (caps) TapKey(VK_CAPITAL);
}
static void SetClipboardText(const std::wstring& s) {
    if (!OpenClipboard(g_hwnd)) return;
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (s.size() + 1) * sizeof(wchar_t));
    if (h) {
        wchar_t* p = (wchar_t*)GlobalLock(h);
        memcpy(p, s.c_str(), (s.size() + 1) * sizeof(wchar_t));
        GlobalUnlock(h);
        SetClipboardData(CF_UNICODETEXT, h);
    }
    CloseClipboard();
}

// ------------------------------------------------------------------ rows + launch state
struct Row {
    HWND user, pass, notes, sign, stop, status;
    DWORD gamePid;
    unsigned long long gameStart; DWORD gameStartPid;     // start time of the game client (tells it apart from a reused PID)
    std::wstring title; DWORD titlePid; DWORD titleSeen;   // window renaming state
    bool pending; DWORD pendingSince; PidList pendingBase, pendingLaunchBase;
    COLORREF statusColor;
    DWORD statusSince; bool statusTransient;   // transient messages (Stopped, Cancelled...) return to Idle after a while
    int titleLogs;
};
static std::vector<Row> g_rows;

enum Phase { PH_NONE, PH_LOGIN, PH_WAITING, PH_CLOSING };
struct Active {
    int row; Phase phase; DWORD start;
    PidList gameBase, arcBase, arcPids;
    HWND hwnd; DWORD hwndSince; DWORD seenAt; bool triggerLauncher;
    PidList launchBase;   // launcher.exe / patcher.exe that already existed when this sign-in began
};
static Active g_active = { -1, PH_NONE, 0, PidList(), PidList(), PidList(), NULL, 0, 0, false, PidList() };

static void SetStatus(int i, const std::wstring& text, COLORREF col, bool transient = false) {
    Row& r = g_rows[i];
    if (r.statusColor == col && GetText(r.status) == text) return;   // nothing changed: no repaint
    r.statusSince = GetTickCount();
    r.statusTransient = transient;
    r.statusColor = col;
    SetWindowTextW(r.status, text.c_str());
    InvalidateRect(r.status, NULL, FALSE);
}
static void SetSignText(int i, const wchar_t* t) {
    SetWindowTextW(g_rows[i].sign, t);
    InvalidateRect(g_rows[i].sign, NULL, FALSE);
}
static void FinishActive(const std::wstring& text, COLORREF col, bool transient = false) {
    if (g_active.row < 0) return;
    int i = g_active.row;
    SetSignText(i, L"SIGN IN");
    SetStatus(i, text, col, transient);
    g_active.row = -1;
    g_active.phase = PH_NONE;
}
static void Msg(const wchar_t* text, const wchar_t* title) { MessageBoxW(g_hwnd, text, title, MB_OK | MB_ICONINFORMATION); }

// ------------------------------------------------------------------ accounts file (same format as the PowerShell version)
struct Account { std::wstring user, pass, notes; };

// turns the text of an accounts file (username <TAB> password <TAB> notes, one account per line) into accounts
static std::vector<Account> ParseAccounts(const std::string& raw) {
    std::vector<Account> out;
    size_t start = 0;
    if (raw.size() >= 3 && (unsigned char)raw[0] == 0xEF && (unsigned char)raw[1] == 0xBB && (unsigned char)raw[2] == 0xBF) start = 3;
    while (start <= raw.size()) {
        size_t nl = raw.find('\n', start);
        size_t end = (nl == std::string::npos) ? raw.size() : nl;
        std::wstring line = FromUtf8(raw.data() + start, (int)(end - start));
        while (!line.empty() && (line[line.size() - 1] == L'\r')) line.erase(line.size() - 1);
        if (!Trim(line).empty()) {
            Account a;
            size_t t1 = line.find(L'\t');
            if (t1 == std::wstring::npos) { a.user = Trim(line); }
            else {
                a.user = Trim(line.substr(0, t1));
                size_t t2 = line.find(L'\t', t1 + 1);
                if (t2 == std::wstring::npos) a.pass = line.substr(t1 + 1);
                else { a.pass = line.substr(t1 + 1, t2 - t1 - 1); a.notes = line.substr(t2 + 1); }
            }
            // control characters (a tab inside the notes, for example) would break the file format: they become spaces
            for (size_t k = 0; k < a.user.size(); k++) if (a.user[k] < 0x20) a.user[k] = L' ';
            for (size_t k = 0; k < a.pass.size(); k++) if (a.pass[k] < 0x20) a.pass[k] = L' ';
            for (size_t k = 0; k < a.notes.size(); k++) if (a.notes[k] < 0x20) a.notes[k] = L' ';
            out.push_back(a);
        }
        if (nl == std::string::npos) break;
        start = nl + 1;
    }
    return out;
}
static std::vector<Account> LoadAccounts() {
    std::vector<Account> out;
    std::string raw;
    bool haveFile = ReadWholeFile(g_accountsPath, raw);
    if (!haveFile) haveFile = ReadWholeFile(g_accountsPath + L".bak", raw);   // the main file is missing: use the backup
    if (haveFile) out = ParseAccounts(raw);
    if (out.empty()) {
        Account a;   // first start: one empty row
        out.push_back(a);
    }
    return out;
}
// the accounts of all rows as file text (blank entries are dropped); count = number of accounts
static std::wstring BuildAccountsText(int* count) {
    std::wstring all;
    int n = 0;
    for (size_t i = 0; i < g_rows.size(); i++) {
        std::wstring u = Trim(GetText(g_rows[i].user));
        if (u.empty()) continue;   // blank entries are dropped
        std::wstring notes = Trim(GetText(g_rows[i].notes));
        std::wstring pw = GetText(g_rows[i].pass);
        // last line of defence (typing and pasting are already blocked): tabs and line breaks would corrupt the file
        for (size_t k = 0; k < u.size(); k++) if (u[k] < 0x20) u[k] = L' ';
        for (size_t k = 0; k < pw.size(); k++) if (pw[k] < 0x20) pw[k] = L' ';
        for (size_t k = 0; k < notes.size(); k++) if (notes[k] < 0x20) notes[k] = L' ';
        all += u + L"\t" + pw + L"\t" + notes + L"\r\n";
        n++;
    }
    if (count) *count = n;
    return all;
}
static void SaveAccounts() {
    WriteWholeFileSafe(g_accountsPath, ToUtf8(BuildAccountsText(NULL)));
}

// ------------------------------------------------------------------ the launch flow
static bool LaunchArc() {
    std::wstring cmd = L"\"" + S.arcPath + L"\"";
    size_t cut = S.arcPath.find_last_of(L"\\/");
    std::wstring dir = (cut == std::wstring::npos) ? L"." : S.arcPath.substr(0, cut);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    BOOL ok = CreateProcessW(NULL, &buf[0], NULL, NULL, FALSE, 0, NULL, dir.c_str(), &si, &pi);
    if (ok) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    return ok != FALSE;
}

static void Fallback(int row, const std::wstring& why) {
    SetClipboardText(Trim(GetText(g_rows[row].user)));
    SetStatus(row, why + L" - sign in manually (name copied)", cAmber);
}

static void InvokeAutoFill() {
    int i = g_active.row;
    std::wstring user = Trim(GetText(g_rows[i].user));
    std::wstring pass = GetText(g_rows[i].pass);

    BringToFront(g_active.hwnd);
    Sleep(400);
    if (!ArcFocused(g_active.arcPids)) { BringToFront(g_active.hwnd); Sleep(500); }
    if (!ArcFocused(g_active.arcPids)) { Log(L"Arc not focused - fallback"); Fallback(i, L"Could not focus Arc"); return; }

    wchar_t cls[128] = L"", title[128] = L"";
    GetClassNameW(g_active.hwnd, cls, 128);
    GetWindowTextW(g_active.hwnd, title, 128);
    Log(L"typing into window class='" + std::wstring(cls) + L"' title='" + std::wstring(title) + L"'");

    for (int k = 0; k < S.usernameFocusTabs; k++) TapKey(VK_TAB);
    Sleep(300);
    Log(L"typing username (" + std::to_wstring((long long)user.size()) + L" chars)");
    CtrlA();
    TypeText(user);
    Sleep(200);
    for (int k = 0; k < S.fieldSeparatorTabs; k++) TapKey(VK_TAB);
    Sleep(200);

    if (pass.empty()) { SetStatus(i, L"Username typed - no password saved, enter it in Arc", cAmber); return; }
    if (!ArcFocused(g_active.arcPids)) { SetStatus(i, L"Focus left Arc - password was NOT typed", cAmber); Log(L"focus left Arc before password"); return; }
    Log(L"typing password (" + std::to_wstring((long long)pass.size()) + L" chars)");
    CtrlA();
    TypeText(pass);
    Sleep(200);
    TapKey(VK_RETURN);
    SetStatus(i, L"Signed in as '" + user + L"' - click Play in Arc", cWhite);
}

// ---- characters that would break accounts.txt (tab, line breaks and other control characters) are refused
static bool HasControlChars(const std::wstring& t) {
    for (size_t i = 0; i < t.size(); i++) if (t[i] < 0x20) return true;
    return false;
}
static void WarnBadChars(const wchar_t* extra) {
    MessageBoxW(g_hwnd, (std::wstring(L"Usernames, passwords and notes cannot contain tabs or line breaks.\n\n"
                                      L"They would corrupt the saved accounts file. ") + extra).c_str(), L"Characters not allowed", MB_OK | MB_ICONWARNING);
}
static bool ClipboardHasControlChars() {
    bool bad = false;
    if (!OpenClipboard(g_hwnd)) return false;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t* p = (const wchar_t*)GlobalLock(h);
        if (p) { bad = HasControlChars(std::wstring(p)); GlobalUnlock(h); }
    }
    CloseClipboard();
    return bad;
}
static LRESULT CALLBACK EditGuardProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    WNDPROC old = (WNDPROC)GetWindowLongPtrW(h, GWLP_USERDATA);
    if (msg == WM_PASTE && ClipboardHasControlChars()) { WarnBadChars(L"Nothing was pasted."); return 0; }
    return CallWindowProcW(old, h, msg, wp, lp);
}
static void GuardEdit(HWND e) {
    WNDPROC old = (WNDPROC)SetWindowLongPtrW(e, GWLP_WNDPROC, (LONG_PTR)EditGuardProc);
    SetWindowLongPtrW(e, GWLP_USERDATA, (LONG_PTR)old);
}

// ---- finding Arc.exe automatically
static std::wstring RegStr(HKEY k, const wchar_t* name) {
    wchar_t buf[520];
    DWORD type = 0, size = sizeof(buf) - sizeof(wchar_t);
    ZeroMemory(buf, sizeof(buf));
    if (RegQueryValueExW(k, name, NULL, &type, (LPBYTE)buf, &size) != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) return L"";
    return std::wstring(buf);
}
typedef BOOL (WINAPI *PFN_QueryFullProcessImageNameW)(HANDLE, DWORD, LPWSTR, PDWORD);
// where is Arc.exe? 1) a running Arc.exe knows, 2) the list of installed programs, 3) the usual folders on every fixed drive
static std::wstring DetectArcPath() {
    PFN_QueryFullProcessImageNameW query = (PFN_QueryFullProcessImageNameW)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "QueryFullProcessImageNameW");
    PidList arc = ArcPids(Snapshot());
    for (size_t i = 0; query && i < arc.size(); i++) {
        HANDLE h = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, FALSE, arc[i]);
        if (!h) continue;
        wchar_t buf[MAX_PATH * 2];
        DWORD n = MAX_PATH * 2;
        BOOL ok = query(h, 0, buf, &n);
        CloseHandle(h);
        if (ok && FileExists(buf)) return std::wstring(buf);
    }
    const REGSAM views[2] = { KEY_WOW64_64KEY, KEY_WOW64_32KEY };
    for (int v = 0; v < 2; v++) {
        HKEY hk;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall", 0, KEY_READ | views[v], &hk) != ERROR_SUCCESS) continue;
        wchar_t name[256];
        for (DWORD idx = 0;; idx++) {
            DWORD len = 256;
            if (RegEnumKeyExW(hk, idx, name, &len, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
            HKEY sub;
            if (RegOpenKeyExW(hk, name, 0, KEY_READ | views[v], &sub) != ERROR_SUCCESS) continue;
            std::wstring display = RegStr(sub, L"DisplayName"), loc = RegStr(sub, L"InstallLocation");
            RegCloseKey(sub);
            if (_wcsicmp(display.c_str(), L"Arc") != 0 || loc.empty()) continue;
            while (!loc.empty() && (loc[loc.size() - 1] == L'\\' || loc[loc.size() - 1] == L'"')) loc.erase(loc.size() - 1);
            if (!loc.empty() && loc[0] == L'"') loc.erase(0, 1);
            if (FileExists(loc + L"\\Arc.exe")) { RegCloseKey(hk); return loc + L"\\Arc.exe"; }
        }
        RegCloseKey(hk);
    }
    DWORD drives = GetLogicalDrives();
    for (int d = 0; d < 26; d++) {
        if (!(drives & (1u << d))) continue;
        std::wstring root = std::wstring(1, (wchar_t)(L'A' + d)) + L":\\";
        if (GetDriveTypeW(root.c_str()) != DRIVE_FIXED) continue;
        if (FileExists(root + L"Program Files (x86)\\Arc\\Arc.exe")) return root + L"Program Files (x86)\\Arc\\Arc.exe";
        if (FileExists(root + L"Program Files\\Arc\\Arc.exe")) return root + L"Program Files\\Arc\\Arc.exe";
    }
    return L"";
}
// when the configured Arc.exe does not exist: look for it and (if found) save the new location to the settings file
static void AutoConfigArcPath() {
    if (FileExists(S.arcPath)) return;
    std::wstring found = DetectArcPath();
    if (found.empty()) { Log(L"Arc.exe was not found at the configured location and could not be detected"); return; }
    S.arcPath = found;
    WritePrivateProfileStringW(L"Settings", L"ArcPath", found.c_str(), g_iniPath.c_str());
    Log(L"Arc.exe detected automatically; ArcPath updated");
}

static void StartPlay(int i) {
    // Arc was already closed and we are only waiting for the game client: CANCEL stops waiting
    if (g_rows[i].pending) {
        g_rows[i].pending = false;
        CloseLaunchLeftovers(g_rows[i].pendingLaunchBase);
        SetSignText(i, L"SIGN IN");
        SetStatus(i, L"Cancelled - Arc, launcher and patcher closed", cGray, true);
        Log(L"pending launch cancelled by user");
        return;
    }
    if (g_active.row >= 0) {
        if (g_active.row == i) {
            CloseLaunchLeftovers(g_active.launchBase);
            if (g_rows[i].gamePid) FinishActive(L"Running (PID " + std::to_wstring((long long)g_rows[i].gamePid) + L")", cGreen);   // the game client was already up
            else FinishActive(L"Cancelled - Arc, launcher and patcher closed", cGray, true);
            Log(L"sign-in cancelled by user");
        }
        else Msg(L"Another account is still launching. Wait for it to finish, or cancel it first.", L"Busy");
        return;
    }
    Row& r = g_rows[i];
    if (r.gamePid) { Msg(L"That account already has a game client running.", L"Already running"); return; }
    std::wstring name = Trim(GetText(r.user));
    if (name.empty()) { Msg(L"Type an account name in the box first.", L"No name"); return; }
    if (HasControlChars(GetText(r.user)) || HasControlChars(GetText(r.pass)) || HasControlChars(GetText(r.notes))) { WarnBadChars(L"Remove them and try again."); return; }
    if (!FileExists(S.arcPath)) AutoConfigArcPath();   // maybe Arc was installed (or moved) after the last start
    if (!IsArcExeName(S.arcPath)) {
        Msg(L"The Arc Location must point to a file named Arc.exe.\n\nChange it with the gear button (bottom right).", L"Arc Location");
        return;
    }
    if (!FileExists(S.arcPath)) {
        Msg((L"Arc.exe not found at:\n" + S.arcPath + L"\n\nSet the Arc Location with the gear button (bottom right).").c_str(), L"Arc not found");
        return;
    }

    // a still-running Arc would just take focus instead of starting fresh, so close it first
    PidList existing = ArcPids(Snapshot());
    for (size_t k = 0; k < existing.size(); k++) KillPid(existing[k]);
    for (int k = 0; k < 8 && !ArcPids(Snapshot()).empty(); k++) Sleep(500);
    if (!ArcPids(Snapshot()).empty()) {
        Msg(L"An Arc process is still running and couldn't be closed. Close it in Task Manager and try again.", L"Arc still running");
        return;
    }

    SaveAccounts();
    Log(L"---- SIGN IN, row " + std::to_wstring((long long)(i + 1)) + L" ----");
    Log(L"Arc processes closed before launch: " + std::to_wstring((long long)existing.size()));

    std::vector<Proc> snap = Snapshot();
    g_active.row = i;
    g_active.phase = S.autoFill ? PH_LOGIN : PH_WAITING;
    g_active.start = GetTickCount();
    g_active.gameBase = GamePids(snap);
    g_active.launchBase = PidsByName(snap, L"launcher.exe", L"patcher.exe");
    g_active.arcBase = ArcPids(snap);
    g_active.arcPids.clear();
    g_active.hwnd = NULL;
    g_active.hwndSince = g_active.start;
    g_active.seenAt = 0;
    g_active.triggerLauncher = false;

    if (!LaunchArc()) {
        Log(L"CreateProcess failed, error " + std::to_wstring((long long)GetLastError()));
        g_active.row = -1;
        g_active.phase = PH_NONE;
        Msg(L"Could not start Arc.exe.", L"Launch failed");
        return;
    }
    Log(L"started Arc.exe");
    SetSignText(i, L"CANCEL");
    if (S.autoFill) {
        SetStatus(i, L"Waiting for Arc's login window - don't click elsewhere", cWhite);
    } else {
        SetClipboardText(name);
        SetStatus(i, L"Arc opened - sign in as '" + name + L"' and click Play (name copied)", cWhite);
    }
}

static void StopClient(int i) {
    Row& r = g_rows[i];
    if (!r.gamePid) return;
    DWORD pid = r.gamePid;
    // never kill a pid that is no longer the game client (pids get reused)
    if (!Has(GamePids(Snapshot()), pid)) { r.gamePid = 0; SetStatus(i, L"Stopped", cGray, true); EnableWindow(r.stop, FALSE); return; }
    if (S.confirmStop) {
        std::wstring q = L"Force close the game client for '" + Trim(GetText(r.user)) + L"' (PID " + std::to_wstring((long long)pid) +
                         L")?\n\nThis ends it immediately. Anything unsaved in the game is lost.";
        if (MessageBoxW(g_hwnd, q.c_str(), L"Stop client", MB_YESNO | MB_ICONQUESTION) != IDYES) return;
    }
    if (KillPid(pid)) {
        Log(L"STOP button: closed game client pid " + std::to_wstring((long long)pid));
        r.gamePid = 0;
        SetStatus(i, L"Stopped (closed by manager)", cGray, true);
        EnableWindow(r.stop, FALSE);
    } else {
        SetStatus(i, L"Could not close it (error " + std::to_wstring((long long)GetLastError()) + L")", cAmber, true);
    }
}

static PidList ClaimedPids() {
    PidList out;
    for (size_t i = 0; i < g_rows.size(); i++) if (g_rows[i].gamePid) out.push_back(g_rows[i].gamePid);
    return out;
}

// ---- remembering running game clients between runs (session.txt: username <TAB> pid <TAB> start time)
static std::wstring g_lastSession;
static bool ProcessStartTime(DWORD pid, unsigned long long& out) {
    HANDLE h = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!h) h = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, FALSE, pid);
    if (!h) return false;
    FILETIME c, e, k, u;
    BOOL ok = GetProcessTimes(h, &c, &e, &k, &u);
    CloseHandle(h);
    if (!ok) return false;
    out = ((unsigned long long)c.dwHighDateTime << 32) | (unsigned long long)c.dwLowDateTime;
    return true;
}
static std::wstring SessionText() {
    std::wstring all;
    for (size_t i = 0; i < g_rows.size(); i++) {
        Row& r = g_rows[i];
        if (!r.gamePid) continue;
        if (r.gameStartPid != r.gamePid) {
            r.gameStartPid = r.gamePid;
            r.gameStart = 0;
            ProcessStartTime(r.gamePid, r.gameStart);
        }
        std::wstring u = Trim(GetText(r.user));
        if (!r.gameStart || u.empty()) continue;
        all += u + L"\t" + std::to_wstring((long long)r.gamePid) + L"\t" + std::to_wstring(r.gameStart) + L"\r\n";
    }
    return all;
}
static void SaveSession() {
    std::wstring now = SessionText();
    if (now == g_lastSession) return;
    g_lastSession = now;
    if (now.empty()) DeleteFileW(g_sessionPath.c_str());
    else WriteWholeFile(g_sessionPath, ToUtf8(now));
}
// at start-up: game clients that were running when the manager was closed are picked up again
static void AdoptSession() {
    std::string raw;
    if (!ReadWholeFile(g_sessionPath, raw)) return;
    std::wstring text = FromUtf8(raw.data(), (int)raw.size());
    PidList games = GamePids(Snapshot());
    size_t start = 0;
    while (start < text.size()) {
        size_t nl = text.find(L'\n', start);
        std::wstring line = text.substr(start, (nl == std::wstring::npos) ? std::wstring::npos : nl - start);
        start = (nl == std::wstring::npos) ? text.size() : nl + 1;
        while (!line.empty() && line[line.size() - 1] == L'\r') line.erase(line.size() - 1);
        size_t t1 = line.find(L'\t');
        size_t t2 = (t1 == std::wstring::npos) ? t1 : line.find(L'\t', t1 + 1);
        if (t2 == std::wstring::npos) continue;
        std::wstring user = line.substr(0, t1);
        DWORD pid = (DWORD)_wcstoui64(line.substr(t1 + 1, t2 - t1 - 1).c_str(), NULL, 10);
        unsigned long long saved = _wcstoui64(line.substr(t2 + 1).c_str(), NULL, 10);
        unsigned long long actual = 0;
        if (!pid || !Has(games, pid) || !ProcessStartTime(pid, actual) || actual != saved || Has(ClaimedPids(), pid)) continue;
        for (size_t i = 0; i < g_rows.size(); i++) {
            Row& r = g_rows[i];
            if (r.gamePid || _wcsicmp(Trim(GetText(r.user)).c_str(), user.c_str()) != 0) continue;
            r.gamePid = pid;
            r.gameStartPid = pid;
            r.gameStart = actual;
            SetStatus((int)i, L"Running (PID " + std::to_wstring((long long)pid) + L")" /* + L" - found again" */, cGreen);
            EnableWindow(r.stop, TRUE);
            Log(L"found game client " + std::to_wstring((long long)pid) + L" again for row " + std::to_wstring((long long)(i + 1)));
            break;
        }
    }
    g_lastSession = text;
    SaveSession();   // forget entries that were not found
}
// the game windows get the Notes text of their row as title (only the game client: not the launcher or patcher).
// The client opens and closes windows while it loads, so for a while after it started every large visible window is re-checked every second.
struct RenameCtx { DWORD pid; const wchar_t* title; int found; int renamed; wchar_t cls[64]; };
static BOOL CALLBACK RenameEnum(HWND h, LPARAM lp) {
    RenameCtx* c = (RenameCtx*)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != c->pid || !IsWindowVisible(h)) return TRUE;
    RECT r;
    GetWindowRect(h, &r);
    if (r.right - r.left < 200 || r.bottom - r.top < 150) return TRUE;
    c->found++;
    wchar_t cur[512];
    cur[0] = 0;
    DWORD_PTR res = 0;
    if (!SendMessageTimeoutW(h, WM_GETTEXT, 512, (LPARAM)cur, SMTO_ABORTIFHUNG, 500, &res)) return TRUE;   // not responding: try again later
    cur[511] = 0;
    if (wcscmp(cur, c->title) == 0) return TRUE;
    if (SendMessageTimeoutW(h, WM_SETTEXT, 0, (LPARAM)c->title, SMTO_ABORTIFHUNG, 1000, &res)) {
        if (c->renamed == 0) GetClassNameW(h, c->cls, 64);
        c->renamed++;
    }
    return TRUE;
}
static void ApplyWindowTitles() {
    if (!S.renameWindows) return;
    DWORD now = GetTickCount();
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    unsigned long long nowFt = ((unsigned long long)ft.dwHighDateTime << 32) | (unsigned long long)ft.dwLowDateTime;
    for (size_t i = 0; i < g_rows.size(); i++) {
        Row& r = g_rows[i];
        if (!r.gamePid) { r.titlePid = 0; r.titleSeen = 0; continue; }
        if (r.titlePid != r.gamePid) { r.titlePid = r.gamePid; r.title.clear(); r.titleSeen = 0; r.titleLogs = 0; }
        std::wstring notes = Trim(GetText(r.notes));
        // how long ago did the client start? (start time of the process; the first sighting if that is unknown)
        double age;
        if (r.gameStart && nowFt >= r.gameStart) age = (double)(nowFt - r.gameStart) / 10000000.0;
        else { if (!r.titleSeen) r.titleSeen = now ? now : 1; age = (now - r.titleSeen) / 1000.0; }
        bool inPeriod = age < S.renameDurationSeconds;
        bool notesChanged = (notes != r.title);   // r.title = the Notes text handled last
        if (!inPeriod && !notesChanged) continue;
        if (notes.empty()) { r.title = notes; continue; }
        RenameCtx c;
        ZeroMemory(&c, sizeof(c));
        c.pid = r.gamePid;
        c.title = notes.c_str();
        EnumWindows(RenameEnum, (LPARAM)&c);
        if (c.renamed > 0 && r.titleLogs < 40) {
            r.titleLogs++;
            Log(L"renamed " + std::to_wstring((long long)c.renamed) + L" game window(s) of row " + std::to_wstring((long long)(i + 1)) +
                L" (window class " + std::wstring(c.cls) + L")" + (r.titleLogs == 40 ? L" - further renames are not logged" : L""));
        }
        if (inPeriod || c.found > 0) r.title = notes;   // after the period: keep trying only until a window was found
    }
}
// transient messages (Stopped, Cancelled, Timed out...) go back to Idle after a while
static void ExpireStatuses() {
    if (S.statusResetSeconds <= 0) return;
    DWORD now = GetTickCount();
    for (size_t i = 0; i < g_rows.size(); i++) {
        Row& r = g_rows[i];
        if (!r.statusTransient || r.pending || g_active.row == (int)i) continue;
        if ((now - r.statusSince) >= (DWORD)S.statusResetSeconds * 1000) SetStatus((int)i, L"Idle", cGray, false);
    }
}

static void UpdateStateCore() {
    std::vector<Proc> snap = Snapshot();
    PidList arcNow = ArcPids(snap);
    PidList gameNow = GamePids(snap);
    DWORD now = GetTickCount();

    // rows whose game client has exited
    for (size_t i = 0; i < g_rows.size(); i++) {
        Row& r = g_rows[i];
        if (r.gamePid && !Has(gameNow, r.gamePid)) { r.gamePid = 0; SetStatus((int)i, L"Stopped", cGray, true); }
        EnableWindow(r.stop, r.gamePid != 0);
    }

    // rows whose Arc was closed early: time out, or hand them a newly started game client (oldest first)
    for (size_t i = 0; i < g_rows.size(); i++) {
        Row& r = g_rows[i];
        if (r.pending && (now - r.pendingSince) > (DWORD)S.pendingTimeoutSeconds * 1000) {
            r.pending = false;
            SetSignText((int)i, L"SIGN IN");
            SetStatus((int)i, L"Timed out waiting for the game client", cAmber, true);
            Log(L"pending launch timed out");
        }
    }
    PidList claimed = ClaimedPids();
    for (size_t g = 0; g < gameNow.size(); g++) {
        if (Has(claimed, gameNow[g])) continue;
        int best = -1;
        for (size_t i = 0; i < g_rows.size(); i++) {
            if (!g_rows[i].pending || Has(g_rows[i].pendingBase, gameNow[g])) continue;
            if (best < 0 || g_rows[i].pendingSince < g_rows[best].pendingSince) best = (int)i;
        }
        if (best >= 0) {
            Row& r = g_rows[best];
            r.gamePid = gameNow[g];
            r.pending = false;
            SetSignText(best, L"SIGN IN");
            claimed.push_back(gameNow[g]);
            SetStatus(best, L"Running (PID " + std::to_wstring((long long)r.gamePid) + L")", cGreen);
            EnableWindow(r.stop, TRUE);
            Log(L"assigned game client " + std::to_wstring((long long)r.gamePid) + L" to a pending row");
        }
    }

    if (g_active.row < 0) return;
    Active& a = g_active;
    Row& r = g_rows[a.row];
    double elapsed = (now - a.start) / 1000.0;
    a.arcPids = Minus(arcNow, a.arcBase);

    // what tells us the launch has started: launcher.exe spawned by THIS Arc, or a new game client
    PidList newGame = Minus(Minus(gameNow, a.gameBase), ClaimedPids());
    PidList launch;
    if (S.closeAtLauncher) launch = LauncherPidsOf(snap, a.arcPids);
    if (a.phase != PH_CLOSING && (!newGame.empty() || !launch.empty())) {
        a.phase = PH_CLOSING;
        a.seenAt = now;
        if (!newGame.empty()) { a.triggerLauncher = false; r.gamePid = newGame[0]; }
        else a.triggerLauncher = true;
        Log(std::wstring(L"trigger=") + (a.triggerLauncher ? L"launcher" : L"game") + L" - closing Arc soon");
        return;
    }

    if (a.phase == PH_LOGIN) {
        HWND h = a.arcPids.empty() ? NULL : FindVisibleWindow(a.arcPids);
        if (h) {
            if (h != a.hwnd) { a.hwnd = h; a.hwndSince = now; Log(L"Arc window appeared / changed"); }
            else if ((now - a.hwndSince) >= (DWORD)S.loginDelayMs && elapsed >= S.minWaitSeconds) {
                a.phase = PH_WAITING;
                Log(L"window stable, " + std::to_wstring((long long)(int)elapsed) + L"s since start -> typing");
                InvokeAutoFill();
            }
        } else if (elapsed > S.windowTimeoutSeconds) {
            a.phase = PH_WAITING;
            Log(L"timed out finding a visible Arc window");
            Fallback(a.row, L"Couldn't find Arc's login window");
        }
    } else if (a.phase == PH_WAITING) {
        if (elapsed > S.timeoutSeconds) FinishActive(L"Timed out waiting for a game client", cAmber, true);
    } else if (a.phase == PH_CLOSING) {
        int grace = a.triggerLauncher ? S.launcherGraceSeconds : S.graceSeconds;
        double left = grace - (now - a.seenAt) / 1000.0;
        if (left > 0) {
            std::wstring secs = std::to_wstring((long long)(int)(left + 0.999));
            if (a.triggerLauncher) SetStatus(a.row, L"Launcher started - closing Arc in " + secs + L"s", cGreen);
            else SetStatus(a.row, L"Game running (PID " + std::to_wstring((long long)r.gamePid) + L") - closing Arc in " + secs + L"s", cGreen);
            return;
        }
        // close only the Arc process(es) that were started for this launch
        PidList mine = Minus(ArcPids(Snapshot()), a.arcBase);
        for (size_t k = 0; k < mine.size(); k++) KillPid(mine[k]);
        if (r.gamePid) {
            FinishActive(L"Running (PID " + std::to_wstring((long long)r.gamePid) + L")", cGreen);
        } else {
            // Arc is closed; the row picks up its game client when it appears
            r.pending = true;
            r.pendingSince = now;
            r.pendingBase = a.gameBase;
            r.pendingLaunchBase = a.launchBase;
            int waitRow = a.row;
            FinishActive(L"Arc closed - waiting for game client (CANCEL to stop)", cWhite);
            SetSignText(waitRow, L"CANCEL");
        }
    }
}

static void UpdateState() {
    UpdateStateCore();
    ExpireStatuses();
    SaveSession();
    ApplyWindowTitles();
}

// ------------------------------------------------------------------ background image
static HBITMAP g_bgSrc = NULL;       // the loaded image (kept as a GDI bitmap)
static int g_bgW = 0, g_bgH = 0;
static HBITMAP g_bgComposed = NULL;  // image laid out for the current window size, dimmed
static int g_bgCW = 0, g_bgCH = 0;

static HWND g_panel, g_btnAdd, g_btnShowPw, g_btnImport, g_btnExport, g_btnGear, g_btnLog, g_lblBlank, g_lblStorage;
static int g_scroll = 0;
static bool g_inLayout = false;

static const int ROW_H = 40, ROW_TOP = 4, LIST_TOP = 80, BOTTOM_H = 52;
static const int X_USER = 16, X_PASS = 223, X_NOTES = 430, X_SIGN = 637, X_STOP = 777, X_STATUS = 871, FIELD_W = 195;

// paints the part of the background that lies behind rect rc of a window.
// (ox, oy) = where that window's client origin sits inside the main window's client area.
static void PaintBg(HDC dc, const RECT& rc, int ox, int oy) {
    FillRect(dc, &rc, g_brBg);
    if (!g_bgComposed) return;
    int sx = rc.left + ox, sy = rc.top + oy;
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    int x0 = std::max(0, sx), y0 = std::max(0, sy);
    int x1 = std::min(g_bgCW, sx + w), y1 = std::min(g_bgCH, sy + h);
    if (x1 <= x0 || y1 <= y0) return;
    HDC m = CreateCompatibleDC(dc);
    HGDIOBJ old = SelectObject(m, g_bgComposed);
    BitBlt(dc, rc.left + (x0 - sx), rc.top + (y0 - sy), x1 - x0, y1 - y0, m, x0, y0, SRCCOPY);
    SelectObject(m, old);
    DeleteDC(m);
}

static std::wstring FindBackgroundPath() {
    if (!S.bgImage.empty()) {
        if (FileExists(S.bgImage)) return S.bgImage;
        Log(L"background not found: " + S.bgImage);
    }
    const wchar_t* exts[] = { L"png", L"jpg", L"jpeg", L"bmp", L"gif" };
    std::wstring dirs[2] = { g_exeDir, g_configDir };
    for (int d = 0; d < 2; d++)
        for (int e = 0; e < 5; e++) {
            std::wstring p = dirs[d] + L"\\background." + exts[e];
            if (FileExists(p)) return p;
        }
    return std::wstring();
}

// GDI+ is loaded at run time (it ships with Windows XP and later), so there is no link-time dependency.
struct GdipStartupInput { DWORD GdiplusVersion; void* DebugEventCallback; BOOL SuppressBackgroundThread; BOOL SuppressExternalCodecs; };
typedef int (WINAPI *PFN_GdiplusStartup)(ULONG_PTR*, const GdipStartupInput*, void*);
typedef void (WINAPI *PFN_GdiplusShutdown)(ULONG_PTR);
typedef int (WINAPI *PFN_GdipCreateBitmapFromFile)(const wchar_t*, void**);
typedef int (WINAPI *PFN_GdipCreateHBITMAPFromBitmap)(void*, HBITMAP*, DWORD);
typedef int (WINAPI *PFN_GdipDisposeImage)(void*);

typedef int (WINAPI *PFN_GdipCreateBitmapFromStream)(IStream*, void**);

// Wraps the built-in background (an RCDATA resource inside the .exe) in a memory stream. Release() it when done.
static IStream* OpenEmbeddedBackground() {
    HRSRC res = FindResourceW(NULL, MAKEINTRESOURCEW(IDR_DEFAULT_BG), MAKEINTRESOURCEW(10) /* RT_RCDATA */);
    if (!res) return NULL;
    DWORD size = SizeofResource(NULL, res);
    HGLOBAL loaded = LoadResource(NULL, res);
    const void* data = loaded ? LockResource(loaded) : NULL;
    if (!data || size == 0) return NULL;
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!mem) return NULL;
    void* dst = GlobalLock(mem);
    if (!dst) { GlobalFree(mem); return NULL; }
    memcpy(dst, data, size);
    GlobalUnlock(mem);
    IStream* stream = NULL;
    if (CreateStreamOnHGlobal(mem, TRUE, &stream) != S_OK || !stream) { GlobalFree(mem); return NULL; }
    return stream;   // owns 'mem' and frees it on Release()
}

static void LoadBackgroundSource() {
    std::wstring path = FindBackgroundPath();   // empty = no external image, use the built-in one
    HMODULE lib = LoadLibraryW(L"gdiplus.dll");
    if (!lib) { Log(L"background: gdiplus.dll not available"); return; }
    PFN_GdiplusStartup startup = (PFN_GdiplusStartup)(void*)GetProcAddress(lib, "GdiplusStartup");
    PFN_GdiplusShutdown shutdown = (PFN_GdiplusShutdown)(void*)GetProcAddress(lib, "GdiplusShutdown");
    PFN_GdipCreateBitmapFromFile createFromFile = (PFN_GdipCreateBitmapFromFile)(void*)GetProcAddress(lib, "GdipCreateBitmapFromFile");
    PFN_GdipCreateBitmapFromStream createFromStream = (PFN_GdipCreateBitmapFromStream)(void*)GetProcAddress(lib, "GdipCreateBitmapFromStream");
    PFN_GdipCreateHBITMAPFromBitmap toHbitmap = (PFN_GdipCreateHBITMAPFromBitmap)(void*)GetProcAddress(lib, "GdipCreateHBITMAPFromBitmap");
    PFN_GdipDisposeImage dispose = (PFN_GdipDisposeImage)(void*)GetProcAddress(lib, "GdipDisposeImage");
    if (!startup || !shutdown || !createFromFile || !createFromStream || !toHbitmap || !dispose) { Log(L"background: GDI+ functions missing"); return; }

    ULONG_PTR token = 0;
    GdipStartupInput in;
    in.GdiplusVersion = 1; in.DebugEventCallback = NULL; in.SuppressBackgroundThread = FALSE; in.SuppressExternalCodecs = FALSE;
    if (startup(&token, &in, NULL) != 0) { Log(L"background: GdiplusStartup failed"); return; }

    DWORD argb = 0xFF000000u | ((DWORD)GetRValue(cBg) << 16) | ((DWORD)GetGValue(cBg) << 8) | (DWORD)GetBValue(cBg);
    HBITMAP hbm = NULL;
    std::wstring source;

    if (!path.empty()) {   // 1) an external image (config file, next to the program, or %AppData%)
        void* bmp = NULL;
        if (createFromFile(path.c_str(), &bmp) == 0 && bmp) {
            toHbitmap(bmp, &hbm, argb);
            dispose(bmp);   // the file is released here, so it can be replaced while the program runs
        }
        if (hbm) source = path;
        else Log(L"background: could not decode " + path + L", using the built-in image");
    }
    if (!hbm) {            // 2) the built-in default image
        IStream* stream = OpenEmbeddedBackground();
        if (stream) {
            void* bmp = NULL;
            if (createFromStream(stream, &bmp) == 0 && bmp) {
                toHbitmap(bmp, &hbm, argb);
                dispose(bmp);
            }
            stream->Release();
        }
        if (hbm) source = L"(built-in default)";
    }
    shutdown(token);
    if (!hbm) { Log(L"background: no image could be loaded"); return; }
    BITMAP bm;
    ZeroMemory(&bm, sizeof(bm));
    GetObjectW(hbm, sizeof(bm), &bm);
    g_bgSrc = hbm;
    g_bgW = bm.bmWidth;
    g_bgH = bm.bmHeight;
    Log(L"background loaded: " + source + L" (" + std::to_wstring((long long)g_bgW) + L"x" + std::to_wstring((long long)g_bgH) + L")");
}

// lays the image out for the current client size (fill/fit/stretch/tile/center) and dims it
static void RenderBackground(bool force) {
    if (!g_bgSrc || !g_hwnd) return;
    RECT cr;
    GetClientRect(g_hwnd, &cr);
    int w = cr.right, h = cr.bottom;
    if (w < 10 || h < 10) return;
    if (!force && g_bgComposed && w == g_bgCW && h == g_bgCH) return;

    HDC screen = GetDC(NULL);
    BITMAPINFO bi;
    ZeroMemory(&bi, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;       // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = NULL;
    HBITMAP dib = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!dib || !bits) { ReleaseDC(NULL, screen); return; }

    HDC mem = CreateCompatibleDC(screen);
    HGDIOBJ oldM = SelectObject(mem, dib);
    HDC src = CreateCompatibleDC(screen);
    HGDIOBJ oldS = SelectObject(src, g_bgSrc);

    RECT all = { 0, 0, w, h };
    FillRect(mem, &all, g_brBg);
    SetStretchBltMode(mem, HALFTONE);
    SetBrushOrgEx(mem, 0, 0, NULL);

    std::wstring mode = S.bgMode;
    if (mode == L"tile") {
        for (int ty = 0; ty < h; ty += g_bgH)
            for (int tx = 0; tx < w; tx += g_bgW)
                BitBlt(mem, tx, ty, g_bgW, g_bgH, src, 0, 0, SRCCOPY);
    } else {
        double dw, dh;
        if (mode == L"stretch") { dw = w; dh = h; }
        else if (mode == L"center") { dw = g_bgW; dh = g_bgH; }
        else if (mode == L"fit") { double sc = std::min((double)w / g_bgW, (double)h / g_bgH); dw = g_bgW * sc; dh = g_bgH * sc; }
        else { double sc = std::max((double)w / g_bgW, (double)h / g_bgH); dw = g_bgW * sc; dh = g_bgH * sc; }   // fill
        int dx = (int)((w - dw) / 2.0), dy = (int)((h - dh) / 2.0);
        if (mode == L"center") BitBlt(mem, dx, dy, g_bgW, g_bgH, src, 0, 0, SRCCOPY);
        else StretchBlt(mem, dx, dy, (int)(dw + 0.5), (int)(dh + 0.5), src, 0, 0, g_bgW, g_bgH, SRCCOPY);
    }
    GdiFlush();

    if (S.bgDim > 0.0) {
        unsigned keep = (unsigned)((1.0 - S.bgDim) * 256.0 + 0.5);
        if (keep > 256) keep = 256;
        DWORD* px = (DWORD*)bits;
        size_t n = (size_t)w * (size_t)h;
        for (size_t k = 0; k < n; k++) {
            DWORD v = px[k];
            DWORD r = (((v >> 16) & 0xFF) * keep) >> 8;
            DWORD g = (((v >> 8) & 0xFF) * keep) >> 8;
            DWORD b = ((v & 0xFF) * keep) >> 8;
            px[k] = (r << 16) | (g << 8) | b;
        }
    }

    SelectObject(src, oldS);
    DeleteDC(src);
    SelectObject(mem, oldM);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);

    HBITMAP old = g_bgComposed;
    g_bgComposed = dib;
    g_bgCW = w;
    g_bgCH = h;
    if (old) DeleteObject(old);
    RedrawWindow(g_hwnd, NULL, NULL, RDW_ERASE | RDW_INVALIDATE | RDW_ALLCHILDREN);
}

// swaps in a different background while the program is running
static void ReloadBackground() {
    if (g_bgSrc) { DeleteObject(g_bgSrc); g_bgSrc = NULL; }
    if (g_bgComposed) { DeleteObject(g_bgComposed); g_bgComposed = NULL; }
    g_bgW = g_bgH = 0;
    g_bgCW = g_bgCH = 0;
    LoadBackgroundSource();
    RenderBackground(true);
    RedrawWindow(g_hwnd, NULL, NULL, RDW_ERASE | RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
}

// ------------------------------------------------------------------ UI
static HWND MakeLabel(HWND parent, int id, const wchar_t* text, int x, int y, int w, int h) {
    return CreateWindowExW(0, L"STATIC", text, WS_CHILD | WS_VISIBLE | SS_OWNERDRAW, x, y, w, h, parent, (HMENU)(INT_PTR)id, g_hInst, NULL);
}
static HWND MakeEdit(HWND parent, int id, const std::wstring& text, const wchar_t* cue, bool password) {
    DWORD style = WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL | (password ? ES_PASSWORD : 0);
    HWND c = CreateWindowExW(0, L"EDIT", text.c_str(), style, 0, 0, FIELD_W, 26, parent, (HMENU)(INT_PTR)id, g_hInst, NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_font, TRUE);
    if (password && !g_showPw) SendMessageW(c, EM_SETPASSWORDCHAR, 0x2022, 0);
    SendMessageW(c, EM_SETCUEBANNER, TRUE, (LPARAM)cue);   // placeholder text: Windows Vista and later, ignored on XP
    return c;
}
static HWND MakeButton(HWND parent, int id, const wchar_t* text, int x, int y, int w, int h) {
    HWND c = CreateWindowExW(0, L"BUTTON", text, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, x, y, w, h, parent, (HMENU)(INT_PTR)id, g_hInst, NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_fontBold, TRUE);
    return c;
}
static void AddRow(const Account& acc) {
    int i = (int)g_rows.size();
    Row r;
    r.user = MakeEdit(g_panel, RowId(i, K_USER), acc.user, L"Username", false);
    r.pass = MakeEdit(g_panel, RowId(i, K_PASS), acc.pass, L"Password", true);
    r.notes = MakeEdit(g_panel, RowId(i, K_NOTES), acc.notes, L"Main character", false);
    r.sign = MakeButton(g_panel, RowId(i, K_SIGN), L"SIGN IN", 0, 0, 130, 28);
    r.stop = MakeButton(g_panel, RowId(i, K_STOP), L"STOP", 0, 0, 84, 28);
    r.status = MakeLabel(g_panel, RowId(i, K_STATUS), L"Idle", 0, 0, 300, 22);
    GuardEdit(r.user);
    GuardEdit(r.pass);
    GuardEdit(r.notes);
    EnableWindow(r.stop, FALSE);
    r.gamePid = 0; r.gameStart = 0; r.gameStartPid = 0; r.titlePid = 0; r.titleSeen = 0;
    r.pending = false; r.pendingSince = 0; r.statusColor = cGray;
    r.statusSince = 0; r.statusTransient = false; r.titleLogs = 0;
    g_rows.push_back(r);
}

// ---- scrolling list
static int ListTotalHeight() { return ROW_TOP + (int)g_rows.size() * ROW_H + ROW_TOP; }

static void UpdateScroll() {
    RECT pc;
    GetClientRect(g_panel, &pc);
    int page = pc.bottom;
    int total = ListTotalHeight();
    int maxPos = std::max(0, total - page);
    if (g_scroll > maxPos) g_scroll = maxPos;
    if (g_scroll < 0) g_scroll = 0;
    SCROLLINFO si;
    ZeroMemory(&si, sizeof(si));
    si.cbSize = sizeof(si);
    si.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    si.nMin = 0;
    si.nMax = total - 1;
    si.nPage = (UINT)page;
    si.nPos = g_scroll;
    SetScrollInfo(g_panel, SB_VERT, &si, TRUE);
}
static void LayoutRows() {
    RECT pc;
    GetClientRect(g_panel, &pc);
    int statusW = std::max(120, (int)pc.right - X_STATUS - 12);
    HDWP dwp = BeginDeferWindowPos((int)g_rows.size() * 6 + 1);
    const UINT f = SWP_NOZORDER | SWP_NOACTIVATE;
    for (size_t i = 0; i < g_rows.size() && dwp; i++) {
        int y = ROW_TOP + (int)i * ROW_H - g_scroll;
        Row& r = g_rows[i];
        dwp = DeferWindowPos(dwp, r.user, NULL, X_USER, y, FIELD_W, 26, f);
        if (dwp) dwp = DeferWindowPos(dwp, r.pass, NULL, X_PASS, y, FIELD_W, 26, f);
        if (dwp) dwp = DeferWindowPos(dwp, r.notes, NULL, X_NOTES, y, FIELD_W, 26, f);
        if (dwp) dwp = DeferWindowPos(dwp, r.sign, NULL, X_SIGN, y - 1, 130, 28, f);
        if (dwp) dwp = DeferWindowPos(dwp, r.stop, NULL, X_STOP, y - 1, 84, 28, f);
        if (dwp) dwp = DeferWindowPos(dwp, r.status, NULL, X_STATUS, y + 4, statusW, 22, f | SWP_NOCOPYBITS);
    }
    if (dwp) EndDeferWindowPos(dwp);
}
static void RelayoutRows() {
    if (g_inLayout || !g_panel) return;
    g_inLayout = true;
    UpdateScroll();
    LayoutRows();
    g_inLayout = false;
}
static void ScrollTo(int pos) {
    RECT pc;
    GetClientRect(g_panel, &pc);
    int maxPos = std::max(0, ListTotalHeight() - (int)pc.bottom);
    pos = std::min(std::max(pos, 0), maxPos);
    if (pos == g_scroll) return;
    g_scroll = pos;
    RelayoutRows();
}
static void EnsureRowVisible(int i) {
    RECT pc;
    GetClientRect(g_panel, &pc);
    int top = ROW_TOP + i * ROW_H, bottom = top + ROW_H;
    if (top - g_scroll < 0) ScrollTo(top - ROW_TOP);
    else if (bottom - g_scroll > pc.bottom) ScrollTo(bottom - (int)pc.bottom + ROW_TOP);
}

// ---- main window layout (everything except the rows, which live in the scrolling panel)
static void LayoutMain() {
    RECT cr;
    GetClientRect(g_hwnd, &cr);
    int cw = cr.right, ch = cr.bottom;
    int listH = std::max(60, ch - LIST_TOP - BOTTOM_H);
    SetWindowPos(g_panel, NULL, 0, LIST_TOP, cw, listH, SWP_NOZORDER | SWP_NOACTIVATE);
    int by = ch - 42;
    const UINT f = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS;
    SetWindowPos(g_btnAdd, NULL, 16, by, 120, 28, f);
    SetWindowPos(g_btnShowPw, NULL, 150, by + 4, 130, 22, f);
    if (g_btnImport) SetWindowPos(g_btnImport, NULL, 292, by, 80, 28, f);
    if (g_btnExport) SetWindowPos(g_btnExport, NULL, 378, by, 80, 28, f);
    SetWindowPos(g_lblBlank, NULL, 472, by + 6, 200, 20, f);
    if (g_lblStorage) SetWindowPos(g_lblStorage, NULL, 676, by + 6, std::max(100, cw - 676 - 16 - 80), 20, f);
    if (g_btnGear) SetWindowPos(g_btnGear, NULL, cw - 16 - 28, by, 28, 28, f);
    if (g_btnLog) SetWindowPos(g_btnLog, NULL, cw - 16 - 28 - 8 - 28, by, 28, 28, f);
}

// ---- tooltips (hover hints)
#define TOOLINFO_V1_SIZE ((UINT)(offsetof(TOOLINFOW, lpszText) + sizeof(LPWSTR)))   // old size: also accepted by Windows XP
static HWND MakeTooltips(HWND parent) {
    HWND tt = CreateWindowExW(WS_EX_TOPMOST, L"tooltips_class32", NULL, WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP,
                              CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, parent, NULL, g_hInst, NULL);
    if (tt) {
        SendMessageW(tt, TTM_SETMAXTIPWIDTH, 0, 340);
        SendMessageW(tt, TTM_SETDELAYTIME, TTDT_AUTOPOP, 20000);
    }
    return tt;
}
static void AddTip(HWND tt, HWND parent, HWND ctl, const wchar_t* text) {
    if (!tt || !ctl) return;
    TOOLINFOW ti;
    ZeroMemory(&ti, sizeof(ti));
    ti.cbSize = TOOLINFO_V1_SIZE;
    ti.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    ti.hwnd = parent;
    ti.uId = (UINT_PTR)ctl;
    ti.lpszText = (LPWSTR)text;   // must stay valid: only string literals are passed
    SendMessageW(tt, TTM_ADDTOOLW, 0, (LPARAM)&ti);
}

// ---- the gear and the log (sheet of paper) buttons, drawn in code: no image files needed.
// Drawn 4x larger and scaled down for smooth edges.
static bool g_gearHot = false, g_logHot = false;
static WNDPROC g_gearOldProc = NULL, g_logOldProc = NULL;
static COLORREF Mix(COLORREF a, COLORREF b) {
    return RGB((GetRValue(a) + GetRValue(b)) / 2, (GetGValue(a) + GetGValue(b)) / 2, (GetBValue(a) + GetBValue(b)) / 2);
}
static void DrawSymbol(HDC dc, const RECT& rc, COLORREF bg, COLORREF fg, bool paper) {
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return;
    const int K = 4;
    HDC mem = CreateCompatibleDC(dc);
    HBITMAP bmp = CreateCompatibleBitmap(dc, w * K, h * K);
    HGDIOBJ oldBmp = SelectObject(mem, bmp);
    RECT all = { 0, 0, w * K, h * K };
    HBRUSH bgBrush = CreateSolidBrush(bg);
    FillRect(mem, &all, bgBrush);
    HBRUSH fgBrush = CreateSolidBrush(fg);
    HGDIOBJ oldPen = SelectObject(mem, GetStockObject(NULL_PEN));
    HGDIOBJ oldBr = SelectObject(mem, fgBrush);
    double cx = w * K / 2.0, cy = h * K / 2.0, sz = (double)std::min(w, h) * K;

    if (!paper) {   // gear
        const double PI = 3.14159265358979323846;
        double ro = sz * 0.40, ri = sz * 0.30, rh = sz * 0.14;   // tooth tip, tooth root, centre hole
        const int teeth = 8;
        POINT pts[teeth * 5];
        int n = 0;
        double step = 2.0 * PI / teeth;
        for (int t = 0; t < teeth; t++) {
            double a = t * step;
            const double ang[5] = { a - 0.26 * step, a - 0.16 * step, a + 0.16 * step, a + 0.26 * step, a + 0.50 * step };
            const double rad[5] = { ri, ro, ro, ri, ri };
            for (int k = 0; k < 5; k++) {
                pts[n].x = (LONG)(cx + rad[k] * std::cos(ang[k]) + 0.5);
                pts[n].y = (LONG)(cy + rad[k] * std::sin(ang[k]) + 0.5);
                n++;
            }
        }
        Polygon(mem, pts, n);
        SelectObject(mem, bgBrush);
        Ellipse(mem, (int)(cx - rh), (int)(cy - rh), (int)(cx + rh), (int)(cy + rh));
    } else {        // sheet of paper with a folded corner and lines of text
        double ox = cx - sz / 2.0, oy = cy - sz / 2.0;
        double L = ox + sz * 0.27, R = ox + sz * 0.73, T = oy + sz * 0.14, B = oy + sz * 0.86, f = sz * 0.17;
        POINT page[5] = { { (LONG)L, (LONG)T }, { (LONG)(R - f), (LONG)T }, { (LONG)R, (LONG)(T + f) }, { (LONG)R, (LONG)B }, { (LONG)L, (LONG)B } };
        Polygon(mem, page, 5);
        HBRUSH foldBrush = CreateSolidBrush(Mix(fg, bg));
        SelectObject(mem, foldBrush);
        POINT fold[3] = { { (LONG)(R - f), (LONG)T }, { (LONG)(R - f), (LONG)(T + f) }, { (LONG)R, (LONG)(T + f) } };
        Polygon(mem, fold, 3);
        SelectObject(mem, fgBrush);
        DeleteObject(foldBrush);
        for (int i = 0; i < 4; i++) {
            RECT line;
            line.left = (LONG)(L + sz * 0.07);
            line.right = (LONG)((i == 3) ? (L + (R - L) * 0.55) : (R - sz * 0.07));
            line.top = (LONG)(T + sz * (0.27 + 0.135 * i));
            line.bottom = (LONG)(line.top + sz * 0.05);
            FillRect(mem, &line, bgBrush);
        }
    }
    SelectObject(mem, oldBr);
    SelectObject(mem, oldPen);

    SetStretchBltMode(dc, HALFTONE);
    SetBrushOrgEx(dc, 0, 0, NULL);
    StretchBlt(dc, rc.left, rc.top, w, h, mem, 0, 0, w * K, h * K, SRCCOPY);
    SelectObject(mem, oldBmp);
    DeleteObject(bmp);
    DeleteObject(fgBrush);
    DeleteObject(bgBrush);
    DeleteDC(mem);
}
static void DrawGearButton(const DRAWITEMSTRUCT* d) {
    bool paper = (int)d->CtlID == ID_LOG;
    bool hot = paper ? g_logHot : g_gearHot;
    bool pressed = (d->itemState & ODS_SELECTED) != 0;
    COLORREF bg = hot ? RGB(62, 62, 72) : cBox;
    if (pressed) bg = RGB(GetRValue(bg) * 3 / 4, GetGValue(bg) * 3 / 4, GetBValue(bg) * 3 / 4);
    DrawSymbol(d->hDC, d->rcItem, bg, hot ? cWhite : RGB(190, 190, 200), paper);
}
// follows the mouse so the button can light up while hovered
static LRESULT CALLBACK HoverProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    bool paper = GetDlgCtrlID(h) == ID_LOG;
    bool* hot = paper ? &g_logHot : &g_gearHot;
    WNDPROC old = paper ? g_logOldProc : g_gearOldProc;
    if (msg == WM_MOUSEMOVE && !*hot) {
        *hot = true;
        TRACKMOUSEEVENT t;
        ZeroMemory(&t, sizeof(t));
        t.cbSize = sizeof(t);
        t.dwFlags = TME_LEAVE;
        t.hwndTrack = h;
        TrackMouseEvent(&t);
        InvalidateRect(h, NULL, FALSE);
    } else if (msg == WM_MOUSELEAVE) {
        *hot = false;
        InvalidateRect(h, NULL, FALSE);
    }
    return CallWindowProcW(old, h, msg, wp, lp);
}

// ---- owner-drawn controls. Labels paint their own slice of the background, so text sits cleanly on the image.
static void DrawLabel(const DRAWITEMSTRUCT* d) {
    int id = (int)d->CtlID;
    RECT rc = d->rcItem;
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return;
    HDC mem = CreateCompatibleDC(d->hDC);
    HBITMAP bmp = CreateCompatibleBitmap(d->hDC, w, h);
    HGDIOBJ old = SelectObject(mem, bmp);
    POINT o = { 0, 0 };
    MapWindowPoints(d->hwndItem, g_hwnd, &o, 1);
    RECT r0 = { 0, 0, w, h };
    PaintBg(mem, r0, o.x, o.y);

    COLORREF col = cGray;
    HFONT font = g_font;
    if (id == ID_TITLE) { col = cWhite; font = g_fontTitle; }
    else if (id >= ID_ROW_BASE && (id - ID_ROW_BASE) % 10 == K_STATUS) {
        int ri = (id - ID_ROW_BASE) / 10;
        if (ri < (int)g_rows.size()) col = g_rows[ri].statusColor;
    }
    wchar_t txt[512];
    GetWindowTextW(d->hwndItem, txt, 512);
    SelectObject(mem, font);
    SetBkMode(mem, TRANSPARENT);
    SetTextColor(mem, col);
    DrawTextW(mem, txt, -1, &r0, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
    BitBlt(d->hDC, rc.left, rc.top, w, h, mem, 0, 0, SRCCOPY);
    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
}

static void DrawButton(const DRAWITEMSTRUCT* d) {
    int id = (int)d->CtlID;
    HDC dc = d->hDC;
    RECT rc = d->rcItem;
    bool disabled = (d->itemState & ODS_DISABLED) != 0;
    bool pressed = (d->itemState & ODS_SELECTED) != 0;
    wchar_t txt[64];
    GetWindowTextW(d->hwndItem, txt, 64);
    if (id == ID_GEAR || id == ID_LOG) { DrawGearButton(d); return; }
    if (id == ID_SHOWPW) {
        int w = rc.right - rc.left, h = rc.bottom - rc.top;
        HDC mem = CreateCompatibleDC(dc);
        HBITMAP bmp = CreateCompatibleBitmap(dc, w, h);
        HGDIOBJ old = SelectObject(mem, bmp);
        POINT o = { 0, 0 };
        MapWindowPoints(d->hwndItem, g_hwnd, &o, 1);
        RECT r0 = { 0, 0, w, h };
        PaintBg(mem, r0, o.x, o.y);
        // a small square with a check mark, then the text
        const int bs = 14;
        RECT box = { 1, (h - bs) / 2, 1 + bs, (h - bs) / 2 + bs };
        HBRUSH fill = CreateSolidBrush(cBox);
        FillRect(mem, &box, fill);
        DeleteObject(fill);
        HBRUSH frame = CreateSolidBrush(g_showPw ? cWhite : cGray);
        FrameRect(mem, &box, frame);
        DeleteObject(frame);
        if (g_showPw) {
            HPEN pen = CreatePen(PS_SOLID, 2, cGreen);
            HGDIOBJ oldPen = SelectObject(mem, pen);
            MoveToEx(mem, box.left + 3, box.top + 7, NULL);
            LineTo(mem, box.left + 6, box.top + 10);
            LineTo(mem, box.left + 11, box.top + 4);
            SelectObject(mem, oldPen);
            DeleteObject(pen);
        }
        RECT tr = { 1 + bs + 8, 0, w, h };
        SelectObject(mem, g_font);
        SetBkMode(mem, TRANSPARENT);
        SetTextColor(mem, cWhite);
        DrawTextW(mem, txt, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        BitBlt(dc, rc.left, rc.top, w, h, mem, 0, 0, SRCCOPY);
        SelectObject(mem, old);
        DeleteObject(bmp);
        DeleteDC(mem);
        return;
    }
    SetBkMode(dc, TRANSPARENT);
    COLORREF bg = cBox, fg = cWhite;
    if (id != ID_ADD && id != ID_IMPORT && id != ID_EXPORT) {
        int kind = (id - ID_ROW_BASE) % 10;
        if (kind == K_SIGN) bg = cRed;
        else if (kind == K_STOP) bg = cStopBg;
    }
    if (pressed) bg = RGB(GetRValue(bg) * 3 / 4, GetGValue(bg) * 3 / 4, GetBValue(bg) * 3 / 4);
    if (disabled) { bg = RGB(GetRValue(bg) / 2 + 12, GetGValue(bg) / 2 + 12, GetBValue(bg) / 2 + 12); fg = RGB(110, 110, 118); }
    HBRUSH b = CreateSolidBrush(bg);
    FillRect(dc, &rc, b);
    DeleteObject(b);
    SelectObject(dc, g_fontBold);
    SetTextColor(dc, fg);
    DrawTextW(dc, txt, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

// ---- the scrolling panel that holds the account rows
static LRESULT CALLBACK PanelProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_ERASEBKGND: {
        HDC dc = (HDC)wp;
        RECT rc;
        GetClipBox(dc, &rc);
        POINT o = { 0, 0 };
        MapWindowPoints(hwnd, g_hwnd, &o, 1);
        PaintBg(dc, rc, o.x, o.y);
        return 1;
    }
    case WM_SIZE:
        RelayoutRows();
        return 0;
    case WM_VSCROLL: {
        SCROLLINFO si;
        ZeroMemory(&si, sizeof(si));
        si.cbSize = sizeof(si);
        si.fMask = SIF_ALL;
        GetScrollInfo(hwnd, SB_VERT, &si);
        int pos = si.nPos;
        switch (LOWORD(wp)) {
        case SB_LINEUP: pos -= 20; break;
        case SB_LINEDOWN: pos += 20; break;
        case SB_PAGEUP: pos -= (int)si.nPage; break;
        case SB_PAGEDOWN: pos += (int)si.nPage; break;
        case SB_THUMBTRACK:
        case SB_THUMBPOSITION: pos = si.nTrackPos; break;
        case SB_TOP: pos = 0; break;
        case SB_BOTTOM: pos = 1 << 20; break;
        }
        ScrollTo(pos);
        return 0;
    }
    case WM_MOUSEWHEEL: {
        int delta = (short)HIWORD(wp);
        ScrollTo(g_scroll - delta * 60 / 120);
        return 0;
    }
    case WM_COMMAND: {
        int id = LOWORD(wp);
        if (HIWORD(wp) == EN_SETFOCUS && id >= ID_ROW_BASE) EnsureRowVisible((id - ID_ROW_BASE) / 10);
        return SendMessageW(g_hwnd, msg, wp, lp);
    }
    case WM_DRAWITEM:
    case WM_CTLCOLOREDIT:
        return SendMessageW(g_hwnd, msg, wp, lp);
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// ------------------------------------------------------------------ settings window (opened with the gear button)
enum {
    ID_S_ARC = 2000, ID_S_ARCBROWSE, ID_S_W, ID_S_H, ID_S_REMEMBER, ID_S_AUTOFILL,
    ID_S_UTABS, ID_S_FTABS, ID_S_LOGINMS, ID_S_MINWAIT, ID_S_WINTIMEOUT,
    ID_S_CLOSE_LAUNCHER, ID_S_CLOSE_GAME, ID_S_LGRACE, ID_S_GRACE, ID_S_TIMEOUT, ID_S_PENDING,
    ID_S_CONFIRM, ID_S_KILL, ID_S_DEBUG, ID_S_RENAME, ID_S_STORAGE, ID_S_RENDUR, ID_S_STATRESET,
    ID_S_BG, ID_S_BGBROWSE, ID_S_MODE0, ID_S_MODE1, ID_S_MODE2, ID_S_MODE3, ID_S_MODE4,
    ID_S_DIM, ID_S_DIMLBL, ID_S_DEFAULTS, ID_S_SAVE, ID_S_CANCEL, ID_S_PAGE_BASIC, ID_S_PAGE_ADV, ID_S_FOLDER
};

static HWND g_setWnd = NULL;       // the settings window (NULL while closed)
static std::vector<HWND> g_pageBasic, g_pageAdv;       // the controls of the two pages (Basic / Advanced)
static std::vector<HWND>* g_pageList = NULL;           // while building: which page the new controls belong to
static HWND g_setTip = NULL;
static HWND g_tipMain = NULL;      // tooltip control of the main window
static bool g_setDirty = false;    // something was changed and not saved yet
static bool g_setLoading = false;  // true while the controls are being filled in by the program

// whole-number settings: text boxes in the window
struct NumField { int id; const wchar_t* key; const wchar_t* label; int Settings::* mem; int minV, maxV; };
static const NumField kNumFields[] = {
    { ID_S_W,          L"WindowWidth",          L"Window width",                 &Settings::windowWidth,          900, 7680 },
    { ID_S_H,          L"WindowHeight",         L"Window height",                &Settings::windowHeight,         420, 4320 },
    { ID_S_UTABS,      L"UsernameFocusTabs",    L"Tabs before username box",     &Settings::usernameFocusTabs,    0,   20 },
    { ID_S_FTABS,      L"FieldSeparatorTabs",   L"Tabs between the two boxes",   &Settings::fieldSeparatorTabs,   0,   20 },
    { ID_S_LOGINMS,    L"LoginDelayMs",         L"Login delay (milliseconds)",   &Settings::loginDelayMs,         0,   60000 },
    { ID_S_MINWAIT,    L"MinWaitSeconds",       L"Minimum wait (seconds)",       &Settings::minWaitSeconds,       0,   600 },
    { ID_S_WINTIMEOUT, L"WindowTimeoutSeconds", L"Login window timeout (seconds)", &Settings::windowTimeoutSeconds, 1, 600 },
    { ID_S_LGRACE,     L"LauncherGraceSeconds", L"Delay after launcher (seconds)", &Settings::launcherGraceSeconds, 0,  600 },
    { ID_S_GRACE,      L"GraceSeconds",         L"Delay after game (seconds)",   &Settings::graceSeconds,         0,   600 },
    { ID_S_TIMEOUT,    L"TimeoutSeconds",       L"Give up after (seconds)",      &Settings::timeoutSeconds,       10,  86400 },
    { ID_S_PENDING,    L"PendingTimeoutSeconds", L"Game wait after close (seconds)", &Settings::pendingTimeoutSeconds, 10, 86400 },
    { ID_S_RENDUR,     L"RenameDurationSeconds", L"Rename duration (seconds)",   &Settings::renameDurationSeconds, 10, 3600 },
    { ID_S_STATRESET,  L"StatusResetSeconds",    L"Reset status after (seconds)", &Settings::statusResetSeconds, 0, 86400 },
};
// on/off settings: tick boxes in the window
struct BoolField { int id; const wchar_t* key; bool Settings::* mem; };
static const BoolField kBoolFields[] = {
    { ID_S_REMEMBER, L"RememberWindowSize", &Settings::rememberSize },
    { ID_S_AUTOFILL, L"AutoFill",           &Settings::autoFill },
    { ID_S_CONFIRM,  L"ConfirmStop",        &Settings::confirmStop },
    { ID_S_KILL,     L"KillArcOnStart",     &Settings::killArcOnStart },
    { ID_S_DEBUG,    L"DebugLog",           &Settings::debugLog },
    { ID_S_RENAME,   L"RenameGameWindows",  &Settings::renameWindows },
    { ID_S_STORAGE,  L"ShowStorageHint",    &Settings::showStorageHint },
};
static const wchar_t* const kModeNames[5]  = { L"fill", L"fit", L"stretch", L"tile", L"center" };
static const wchar_t* const kModeLabels[5] = { L"Fill", L"Fit", L"Stretch", L"Tile", L"Center" };

static HWND SCtl(int id) { return GetDlgItem(g_setWnd, id); }
static void ShowSettingsPage(int page) {
    for (size_t i = 0; i < g_pageBasic.size(); i++) ShowWindow(g_pageBasic[i], page == 0 ? SW_SHOW : SW_HIDE);
    for (size_t i = 0; i < g_pageAdv.size(); i++) ShowWindow(g_pageAdv[i], page == 1 ? SW_SHOW : SW_HIDE);
    CheckRadioButton(g_setWnd, ID_S_PAGE_BASIC, ID_S_PAGE_ADV, page == 0 ? ID_S_PAGE_BASIC : ID_S_PAGE_ADV);
}
static HWND SMake(const wchar_t* cls, const wchar_t* text, DWORD style, DWORD ex, int x, int y, int w, int h, int id) {
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, g_setWnd, (HMENU)(INT_PTR)id, g_hInst, NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_font, TRUE);
    if (g_pageList) g_pageList->push_back(c);
    return c;
}
static HWND SLabel(const wchar_t* text, int x, int y, int w, int h) { return SMake(L"STATIC", text, SS_LEFT | SS_NOPREFIX, 0, x, y, w, h, -1); }
static HWND SGroup(const wchar_t* text, int x, int y, int w, int h) { return SMake(L"BUTTON", text, BS_GROUPBOX | WS_GROUP, 0, x, y, w, h, -1); }
static HWND SCheck(int id, const wchar_t* text, int x, int y, int w, int h) { return SMake(L"BUTTON", text, BS_AUTOCHECKBOX | WS_TABSTOP, 0, x, y, w, h, id); }
static HWND SRadio(int id, const wchar_t* text, int x, int y, int w, int h, bool first) {
    return SMake(L"BUTTON", text, BS_AUTORADIOBUTTON | (first ? (WS_GROUP | WS_TABSTOP) : 0), 0, x, y, w, h, id);
}
static HWND SButton(int id, const wchar_t* text, int x, int y, int w, int h, bool def) {
    return SMake(L"BUTTON", text, (def ? BS_DEFPUSHBUTTON : BS_PUSHBUTTON) | WS_TABSTOP, 0, x, y, w, h, id);
}
static HWND SEdit(int id, int x, int y, int w, int h, bool numeric, bool groupStart) {
    HWND c = SMake(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL | (numeric ? ES_NUMBER : 0) | (groupStart ? WS_GROUP : 0), WS_EX_CLIENTEDGE, x, y, w, h, id);
    SendMessageW(c, EM_LIMITTEXT, numeric ? 6 : 520, 0);
    return c;
}
static void Tip(int id, const wchar_t* text) { AddTip(g_setTip, g_setWnd, SCtl(id), text); }

static bool Checked(int id) { return SendMessageW(SCtl(id), BM_GETCHECK, 0, 0) == BST_CHECKED; }
static void UpdateDimLabel() {
    int pct = (int)SendMessageW(SCtl(ID_S_DIM), TBM_GETPOS, 0, 0);
    SetWindowTextW(SCtl(ID_S_DIMLBL), (std::to_wstring((long long)pct) + L"%").c_str());
}
// greys out the boxes that do not matter for the current choices
static void SettingsUpdateEnabled() {
    bool af = Checked(ID_S_AUTOFILL);
    const int fillIds[] = { ID_S_UTABS, ID_S_FTABS, ID_S_LOGINMS, ID_S_MINWAIT, ID_S_WINTIMEOUT };
    for (size_t i = 0; i < sizeof(fillIds) / sizeof(fillIds[0]); i++) EnableWindow(SCtl(fillIds[i]), af);
    bool launcher = Checked(ID_S_CLOSE_LAUNCHER);
    EnableWindow(SCtl(ID_S_LGRACE), launcher);
    EnableWindow(SCtl(ID_S_PENDING), launcher);
    EnableWindow(SCtl(ID_S_GRACE), !launcher);
    EnableWindow(SCtl(ID_S_RENDUR), Checked(ID_S_RENAME));
}
// fills the window from a Settings value
static void SettingsToUi(const Settings& v) {
    g_setLoading = true;
    SetWindowTextW(SCtl(ID_S_ARC), v.arcPath.c_str());
    for (size_t i = 0; i < sizeof(kNumFields) / sizeof(kNumFields[0]); i++)
        SetWindowTextW(SCtl(kNumFields[i].id), std::to_wstring((long long)(v.*(kNumFields[i].mem))).c_str());
    for (size_t i = 0; i < sizeof(kBoolFields) / sizeof(kBoolFields[0]); i++)
        SendMessageW(SCtl(kBoolFields[i].id), BM_SETCHECK, (v.*(kBoolFields[i].mem)) ? BST_CHECKED : BST_UNCHECKED, 0);
    CheckRadioButton(g_setWnd, ID_S_CLOSE_LAUNCHER, ID_S_CLOSE_GAME, v.closeAtLauncher ? ID_S_CLOSE_LAUNCHER : ID_S_CLOSE_GAME);
    SetWindowTextW(SCtl(ID_S_BG), v.bgImage.c_str());
    int mode = 0;
    for (int i = 0; i < 5; i++) if (v.bgMode == kModeNames[i]) mode = i;
    CheckRadioButton(g_setWnd, ID_S_MODE0, ID_S_MODE4, ID_S_MODE0 + mode);
    SendMessageW(SCtl(ID_S_DIM), TBM_SETPOS, TRUE, (LPARAM)(int)(v.bgDim * 100.0 + 0.5));
    UpdateDimLabel();
    SettingsUpdateEnabled();
    g_setLoading = false;
}
static void SettingsWarn(const std::wstring& text, int focusId) {
    MessageBoxW(g_setWnd, text.c_str(), L"Configuration", MB_OK | MB_ICONWARNING);
    if (focusId) {
        SetFocus(SCtl(focusId));
        SendMessageW(SCtl(focusId), EM_SETSEL, 0, -1);
    }
}
// reads the window into n; shows a message and returns false when something is not valid
static bool UiToSettings(Settings& n) {
    std::wstring arc = Trim(GetText(SCtl(ID_S_ARC)));
    if (arc.empty() || !IsArcExeName(arc)) {
        SettingsWarn(L"The Arc Location must point to a file named Arc.exe.\n\nFor safety the manager only launches a program with that name.", ID_S_ARC);
        return false;
    }
    n.arcPath = arc;
    for (size_t i = 0; i < sizeof(kNumFields) / sizeof(kNumFields[0]); i++) {
        const NumField& f = kNumFields[i];
        std::wstring t = Trim(GetText(SCtl(f.id)));
        wchar_t* end = NULL;
        long v = t.empty() ? -1 : wcstol(t.c_str(), &end, 10);
        bool ok = !t.empty() && end && *end == 0 && v >= f.minV && v <= f.maxV;
        if (!ok) {
            SettingsWarn(std::wstring(L"\"") + f.label + L"\" must be a whole number from " + std::to_wstring((long long)f.minV) +
                         L" to " + std::to_wstring((long long)f.maxV) + L".", f.id);
            return false;
        }
        n.*(f.mem) = (int)v;
    }
    for (size_t i = 0; i < sizeof(kBoolFields) / sizeof(kBoolFields[0]); i++) n.*(kBoolFields[i].mem) = Checked(kBoolFields[i].id);
    n.closeAtLauncher = Checked(ID_S_CLOSE_LAUNCHER);
    std::wstring bg = Trim(GetText(SCtl(ID_S_BG)));
    if (!bg.empty() && !FileExists(bg)) {
        SettingsWarn(L"The background image file was not found:\n" + bg + L"\n\nFix the path, or clear the box to use the default background.", ID_S_BG);
        return false;
    }
    n.bgImage = bg;
    n.bgMode = kModeNames[0];
    for (int i = 0; i < 5; i++) if (Checked(ID_S_MODE0 + i)) n.bgMode = kModeNames[i];
    n.bgDim = (double)SendMessageW(SCtl(ID_S_DIM), TBM_GETPOS, 0, 0) / 100.0;
    return true;
}

static bool IniPutStr(const wchar_t* key, const std::wstring& v) {
    return WritePrivateProfileStringW(L"Settings", key, v.c_str(), g_iniPath.c_str()) != FALSE;
}
static bool IniPutInt(const wchar_t* key, int v) { return IniPutStr(key, std::to_wstring((long long)v)); }
static std::wstring DimText(double dim) {
    int pct = (int)(dim * 100.0 + 0.5);
    int whole = pct / 100, frac = pct % 100;
    return std::to_wstring((long long)whole) + L"." + (frac < 10 ? L"0" : L"") + std::to_wstring((long long)frac);
}
// writes every setting that has a box in the window; comments and other lines in the file stay as they are
static bool WriteSettingsToIni(const Settings& s) {
    bool ok = IniPutStr(L"ArcPath", s.arcPath);
    for (size_t i = 0; i < sizeof(kNumFields) / sizeof(kNumFields[0]); i++) ok = IniPutInt(kNumFields[i].key, s.*(kNumFields[i].mem)) && ok;
    for (size_t i = 0; i < sizeof(kBoolFields) / sizeof(kBoolFields[0]); i++) ok = IniPutInt(kBoolFields[i].key, (s.*(kBoolFields[i].mem)) ? 1 : 0) && ok;
    ok = IniPutStr(L"CloseArcAt", s.closeAtLauncher ? L"launcher" : L"game") && ok;
    ok = IniPutStr(L"BackgroundImage", s.bgImage) && ok;
    ok = IniPutStr(L"BackgroundMode", s.bgMode) && ok;
    ok = IniPutStr(L"BackgroundDim", DimText(s.bgDim)) && ok;
    return ok;
}

// resizes the main window so its client area is exactly w x h (kept on screen)
static void ApplyWindowSize(int w, int h) {
    if (!g_hwnd || IsIconic(g_hwnd) || IsZoomed(g_hwnd)) return;
    DWORD style = (DWORD)GetWindowLongW(g_hwnd, GWL_STYLE), ex = (DWORD)GetWindowLongW(g_hwnd, GWL_EXSTYLE);
    RECT rc = { 0, 0, w, h };
    AdjustWindowRectEx(&rc, style, FALSE, ex);
    int ow = rc.right - rc.left, oh = rc.bottom - rc.top;
    RECT wa = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) };
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    if (ow > wa.right - wa.left) ow = wa.right - wa.left;
    if (oh > wa.bottom - wa.top) oh = wa.bottom - wa.top;
    RECT cur;
    GetWindowRect(g_hwnd, &cur);
    int x = std::min((int)cur.left, (int)wa.right - ow), y = std::min((int)cur.top, (int)wa.bottom - oh);
    x = std::max(x, (int)wa.left);
    y = std::max(y, (int)wa.top);
    SetWindowPos(g_hwnd, NULL, x, y, ow, oh, SWP_NOZORDER | SWP_NOACTIVATE);
}

// the inside size of the main window, or the size it will have once restored when it is maximized / minimized
static bool RestoredClientSize(int& w, int& h) {
    if (!g_hwnd) return false;
    if (!IsIconic(g_hwnd) && !IsZoomed(g_hwnd)) {
        RECT cr;
        GetClientRect(g_hwnd, &cr);
        w = (int)cr.right;
        h = (int)cr.bottom;
        return true;
    }
    WINDOWPLACEMENT wp;
    ZeroMemory(&wp, sizeof(wp));
    wp.length = sizeof(wp);
    if (!GetWindowPlacement(g_hwnd, &wp)) return false;
    RECT fr = { 0, 0, 0, 0 };
    AdjustWindowRectEx(&fr, (DWORD)GetWindowLongW(g_hwnd, GWL_STYLE), FALSE, (DWORD)GetWindowLongW(g_hwnd, GWL_EXSTYLE));
    w = (int)(wp.rcNormalPosition.right - wp.rcNormalPosition.left) - (int)(fr.right - fr.left);
    h = (int)(wp.rcNormalPosition.bottom - wp.rcNormalPosition.top) - (int)(fr.bottom - fr.top);
    return true;
}

static void SettingsSave() {
    Settings n = S;   // starts from the current values
    if (!UiToSettings(n)) return;
    int curW = 0, curH = 0;
    bool haveCur = RestoredClientSize(curW, curH);
    bool bgChanged = n.bgImage != S.bgImage || n.bgMode != S.bgMode || n.bgDim != S.bgDim;
    bool sizeChanged = haveCur && (n.windowWidth != curW || n.windowHeight != curH);
    bool logWasOff = !S.debugLog;
    S = n;
    bool wrote = WriteSettingsToIni(S);
    // everything takes effect right away; no restart needed
    if (logWasOff && S.debugLog) StartNewLog();
    if (g_lblStorage) ShowWindow(g_lblStorage, S.showStorageHint ? SW_SHOW : SW_HIDE);
    if (bgChanged) ReloadBackground();
    if (sizeChanged) {
        if (IsZoomed(g_hwnd) || IsIconic(g_hwnd)) ShowWindow(g_hwnd, SW_RESTORE);   // a maximized window cannot be resized: restore it first
        ApplyWindowSize(S.windowWidth, S.windowHeight);
    }
    if (!wrote) {
        MessageBoxW(g_setWnd, (L"The settings are active now, but the settings file could not be written:\n" + g_iniPath).c_str(), L"Configuration", MB_OK | MB_ICONWARNING);
    }
    g_setDirty = false;
    PostMessageW(g_setWnd, WM_CLOSE, 0, 0);
}

static void BrowseInto(int editId, const wchar_t* filter, const wchar_t* title) {
    wchar_t file[MAX_PATH * 2];
    std::wstring cur = Trim(GetText(SCtl(editId)));
    lstrcpynW(file, cur.c_str(), MAX_PATH * 2);
    OPENFILENAMEW o;
    ZeroMemory(&o, sizeof(o));
    o.lStructSize = sizeof(o);
    o.hwndOwner = g_setWnd;
    o.lpstrFilter = filter;
    o.lpstrFile = file;
    o.nMaxFile = MAX_PATH * 2;
    o.lpstrTitle = title;
    o.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&o)) SetWindowTextW(SCtl(editId), file);
}

static void BuildSettingsWindow() {
    g_pageBasic.clear();
    g_pageAdv.clear();
    g_pageList = NULL;
    g_setTip = MakeTooltips(g_setWnd);
    HWND title = SLabel(L"CONFIGURATION", 16, 8, 400, 36);
    SendMessageW(title, WM_SETFONT, (WPARAM)g_fontTitle, TRUE);
    // two push-like radio buttons switch between the pages
    SMake(L"BUTTON", L"Basic", BS_AUTORADIOBUTTON | BS_PUSHLIKE | WS_GROUP | WS_TABSTOP, 0, 440, 14, 90, 26, ID_S_PAGE_BASIC);
    SMake(L"BUTTON", L"Advanced", BS_AUTORADIOBUTTON | BS_PUSHLIKE, 0, 534, 14, 90, 26, ID_S_PAGE_ADV);

    SLabel(L"Arc Location", 16, 52, 300, 18);
    SEdit(ID_S_ARC, 16, 72, 520, 22, false, false);
    SButton(ID_S_ARCBROWSE, L"Browse...", 544, 71, 80, 24, false);

    // ======== page 1: Basic
    g_pageList = &g_pageBasic;
    SGroup(L"Main window", 16, 106, 300, 84);
    SLabel(L"Width", 28, 131, 42, 18);   SEdit(ID_S_W, 72, 128, 58, 22, true, false);
    SLabel(L"Height", 144, 131, 44, 18); SEdit(ID_S_H, 190, 128, 58, 22, true, false);
    SLabel(L"pixels", 256, 131, 50, 18);
    SCheck(ID_S_REMEMBER, L"Remember the size when closing", 28, 158, 280, 20);

    SGroup(L"Close Arc when", 16, 198, 300, 82);
    SRadio(ID_S_CLOSE_LAUNCHER, L"The launcher starts", 28, 220, 270, 20, true);
    SRadio(ID_S_CLOSE_GAME, L"The game client starts", 28, 244, 270, 20, false);

    SGroup(L"Options", 332, 106, 292, 174);
    SCheck(ID_S_DEBUG, L"Debug / Logs", 344, 130, 270, 20);
    SCheck(ID_S_KILL, L"Close running Arc at start / sign-in", 344, 154, 270, 20);
    SCheck(ID_S_AUTOFILL, L"Auto-fill username and password", 344, 178, 270, 20);
    SCheck(ID_S_RENAME, L"Rename game windows to Notes", 344, 202, 270, 20);
    SCheck(ID_S_CONFIRM, L"Ask before stopping a game client", 344, 226, 270, 20);
    SCheck(ID_S_STORAGE, L"Show plain-text storage notice", 344, 250, 270, 20);

    SGroup(L"Background", 16, 288, 608, 146);
    SLabel(L"Background Image Location", 28, 310, 300, 18);
    SEdit(ID_S_BG, 28, 330, 496, 22, false, false);
    SButton(ID_S_BGBROWSE, L"Browse...", 532, 329, 80, 24, false);
    SLabel(L"Mode", 28, 368, 44, 18);
    for (int i = 0; i < 5; i++) SRadio(ID_S_MODE0 + i, kModeLabels[i], 74 + i * 96, 366, 92, 20, i == 0);
    SLabel(L"Darkness", 28, 400, 62, 18);
    HWND tb = CreateWindowExW(0, L"msctls_trackbar32", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_GROUP | TBS_AUTOTICKS,
                              92, 394, 420, 30, g_setWnd, (HMENU)(INT_PTR)ID_S_DIM, g_hInst, NULL);
    g_pageBasic.push_back(tb);
    SendMessageW(tb, TBM_SETRANGE, TRUE, MAKELONG(0, 100));
    SendMessageW(tb, TBM_SETTICFREQ, 10, 0);
    SendMessageW(tb, TBM_SETPAGESIZE, 0, 10);
    SMake(L"STATIC", L"50%", SS_LEFT | SS_NOPREFIX, 0, 520, 400, 80, 18, ID_S_DIMLBL);

    // ======== page 2: Advanced (rarely needs changing)
    g_pageList = &g_pageAdv;
    SLabel(L"Timing and fine-tuning. The defaults suit most computers.", 16, 108, 608, 18);
    SGroup(L"Signing in", 16, 134, 300, 200);
    const int signIds[5] = { ID_S_UTABS, ID_S_FTABS, ID_S_LOGINMS, ID_S_MINWAIT, ID_S_WINTIMEOUT };
    const int signIdx[5] = { 2, 3, 4, 5, 6 };
    for (int i = 0; i < 5; i++) {
        int y = 160 + i * 30;
        SLabel(kNumFields[signIdx[i]].label, 28, y + 3, 205, 18);
        SEdit(signIds[i], 240, y, 58, 22, true, false);
    }
    SGroup(L"Closing Arc and other", 332, 134, 292, 200);
    const int closeIds[6] = { ID_S_LGRACE, ID_S_GRACE, ID_S_TIMEOUT, ID_S_PENDING, ID_S_RENDUR, ID_S_STATRESET };
    for (int i = 0; i < 6; i++) {
        int y = 160 + i * 28;
        SLabel(kNumFields[7 + i].label, 344, y + 3, 210, 18);
        SEdit(closeIds[i], 556, y, 56, 22, true, false);
    }
    g_pageList = NULL;

    // ======== buttons (always visible)
    SButton(ID_S_DEFAULTS, L"LOAD DEFAULTS", 16, 446, 130, 28, false);
    SButton(ID_S_FOLDER, L"OPEN SETTINGS FOLDER", 154, 446, 176, 28, false);
    SButton(ID_S_SAVE, L"SAVE CONFIGURATION", 338, 446, 184, 28, true);
    SButton(ID_S_CANCEL, L"CANCEL", 530, 446, 94, 28, false);
    SMake(L"STATIC", (L"Settings file: " + g_iniPath).c_str(), SS_LEFT | SS_NOPREFIX | SS_PATHELLIPSIS, 0, 16, 486, 440, 16, -1);
    SMake(L"STATIC", (std::wstring(kAppVersion) + L" (C++)").c_str(), SS_RIGHT | SS_NOPREFIX, 0, 464, 486, 160, 16, -1);

    // hover hints
    Tip(ID_S_PAGE_BASIC, L"The settings most people use.");
    Tip(ID_S_PAGE_ADV, L"Timing and fine-tuning. The defaults suit most computers.");
    Tip(ID_S_ARC, L"Full path to Arc.exe. The file must be named Arc.exe. (If it is missing, the manager tries to find it by itself.)");
    Tip(ID_S_FOLDER, L"Open the folder that holds the settings, accounts and log files.");
    Tip(ID_S_W, L"Width of the manager window's inside area, in pixels (900 or more).");
    Tip(ID_S_H, L"Height of the manager window's inside area, in pixels (420 or more).");
    Tip(ID_S_REMEMBER, L"Save the window size when the program closes, so it opens the same way next time.");
    Tip(ID_S_AUTOFILL, L"Type the username and password into Arc's login window for you.");
    Tip(ID_S_UTABS, L"Tab key presses sent first, to move onto the username box in Arc's login window.");
    Tip(ID_S_FTABS, L"Tab key presses sent between the username and the password.");
    Tip(ID_S_LOGINMS, L"How long Arc's login window must be showing before typing starts (1000 = 1 second).");
    Tip(ID_S_MINWAIT, L"Never type sooner than this after starting Arc (skips update pop-ups).");
    Tip(ID_S_WINTIMEOUT, L"Give up looking for Arc's login window after this many seconds.");
    Tip(ID_S_CLOSE_LAUNCHER, L"Close this Arc as soon as it starts the game launcher (launcher.exe).");
    Tip(ID_S_CLOSE_GAME, L"Wait until the game client (elementclient.exe) is running before closing Arc.");
    Tip(ID_S_LGRACE, L"Seconds to wait after the launcher appears before closing Arc.");
    Tip(ID_S_GRACE, L"Seconds to wait after the game client appears before closing Arc.");
    Tip(ID_S_TIMEOUT, L"Give up waiting for a game client after this many seconds.");
    Tip(ID_S_PENDING, L"After Arc has been closed early, how long to keep watching for its game client.");
    Tip(ID_S_CONFIRM, L"Ask for confirmation before the STOP button force-closes a game client.");
    Tip(ID_S_KILL, L"Force-close any running Arc when the manager starts and before every SIGN IN.");
    Tip(ID_S_RENAME, L"Set the title of each game client window to the Notes text of its row, so the windows are easy to tell apart.");
    Tip(ID_S_RENDUR, L"How long after a game client starts its windows are re-checked every second (the game opens and closes windows while loading). Raise it on a slow computer.");
    Tip(ID_S_STATRESET, L"Messages such as Stopped, Cancelled or Timed out go back to Idle after this many seconds. 0 = never.");
    Tip(ID_S_STORAGE, L"Show a note at the bottom of the window that usernames and passwords are saved as plain text.");
    Tip(ID_S_DEBUG, L"Write a log file (never containing passwords) to %AppData%\\ArcManager\\debug.log.");
    Tip(ID_S_BG, L"Your own picture (png, jpg, bmp or gif). Leave empty to use a background.* file next to the program, or the built-in image.");
    Tip(ID_S_DIM, L"0% = picture as it is, 100% = black. Darker keeps the text easier to read.");
    Tip(ID_S_DEFAULTS, L"Fill in the standard values. Nothing is saved until you press SAVE CONFIGURATION.");
    ShowSettingsPage(0);
}

static LRESULT CALLBACK SettingsProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        g_setWnd = hwnd;
        g_setLoading = true;   // ignore change notifications while the window is being built
        BuildSettingsWindow();
        g_setLoading = false;
        return 0;
    case WM_HSCROLL:
        if ((HWND)lp == SCtl(ID_S_DIM)) {
            UpdateDimLabel();
            if (!g_setLoading) g_setDirty = true;
        }
        return 0;
    case WM_COMMAND: {
        int id = LOWORD(wp), note = HIWORD(wp);
        if (id == ID_S_SAVE && note == BN_CLICKED) SettingsSave();
        else if (id == ID_S_CANCEL && note == BN_CLICKED) PostMessageW(hwnd, WM_CLOSE, 0, 0);
        else if (id == ID_S_DEFAULTS && note == BN_CLICKED) {
            Settings d = DefaultSettings();
            SettingsToUi(d);
            g_setDirty = true;
        }
        else if ((id == ID_S_PAGE_BASIC || id == ID_S_PAGE_ADV) && note == BN_CLICKED) ShowSettingsPage(id == ID_S_PAGE_ADV ? 1 : 0);
        else if (id == ID_S_FOLDER && note == BN_CLICKED) ShellExecuteW(hwnd, L"open", g_configDir.c_str(), NULL, NULL, SW_SHOWNORMAL);
        else if (id == ID_S_ARCBROWSE && note == BN_CLICKED) BrowseInto(ID_S_ARC, L"Arc.exe\0Arc.exe\0All files\0*.*\0", L"Locate Arc.exe");
        else if (id == ID_S_BGBROWSE && note == BN_CLICKED) BrowseInto(ID_S_BG, L"Pictures\0*.png;*.jpg;*.jpeg;*.bmp;*.gif\0All files\0*.*\0", L"Choose a background image");
        else if (!g_setLoading && (note == EN_CHANGE || note == BN_CLICKED)) {
            g_setDirty = true;
            SettingsUpdateEnabled();
        }
        return 0;
    }
    case WM_CLOSE:
        if (g_setDirty && MessageBoxW(hwnd, L"Discard your unsaved changes?", L"Configuration", MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;
        EnableWindow(g_hwnd, TRUE);
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        g_setWnd = NULL;
        g_setTip = NULL;
        SetForegroundWindow(g_hwnd);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void OpenSettings() {
    if (g_setWnd) { SetForegroundWindow(g_setWnd); return; }
    DWORD style = WS_CAPTION | WS_SYSMENU, ex = WS_EX_CONTROLPARENT;
    RECT rc = { 0, 0, 640, 512 };
    AdjustWindowRectEx(&rc, style, FALSE, ex);
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    RECT mr, wa = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) };
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    GetWindowRect(g_hwnd, &mr);
    int x = mr.left + ((mr.right - mr.left) - w) / 2, y = mr.top + ((mr.bottom - mr.top) - h) / 2;
    x = std::max((int)wa.left, std::min(x, (int)wa.right - w));
    y = std::max((int)wa.top, std::min(y, (int)wa.bottom - h));
    HWND wnd = CreateWindowExW(ex, L"ArcManagerSettings", L"Configuration", style, x, y, w, h, g_hwnd, NULL, g_hInst, NULL);
    if (!wnd) return;
    // show the size the window has right now (so typing exactly 1280 x 720 and saving always does what it says)
    Settings v = S;
    int curW = 0, curH = 0;
    if (RestoredClientSize(curW, curH)) { v.windowWidth = curW; v.windowHeight = curH; }
    SettingsToUi(v);
    g_setDirty = false;
    EnableWindow(g_hwnd, FALSE);   // the settings window is modal: the main window waits until it is closed
    ShowWindow(wnd, SW_SHOW);
    UpdateWindow(wnd);
    SetFocus(SCtl(ID_S_ARC));
}

// ------------------------------------------------------------------ log viewer (the paper button next to the gear)
enum { ID_L_TEXT = 3000, ID_L_CUR, ID_L_PREV, ID_L_AUTO, ID_L_COPY, ID_L_REFRESH, ID_L_FOLDER, ID_L_CLOSE };
static HWND g_logWnd = NULL;
static HFONT g_fontMono = NULL;
static std::wstring g_logShown;   // the text currently displayed

static HWND LCtl(int id) { return GetDlgItem(g_logWnd, id); }
static bool LogViewingPrevious() { return SendMessageW(LCtl(ID_L_PREV), BM_GETCHECK, 0, 0) == BST_CHECKED; }

static std::wstring ReadLogText(bool previous) {
    std::string raw;
    if (!ReadWholeFile(previous ? g_prevLogPath : g_logPath, raw) || raw.empty())
        return previous ? L"(There is no log from a previous run.)" : L"(The log is empty. Turn on \"Debug / Logs\" in the settings window to record one.)";
    std::wstring text = FromUtf8(raw.data(), (int)raw.size());
    if (!previous && !S.debugLog) text = L"(Logging is turned off - see \"Debug / Logs\" in the settings window. This is the last saved log.)\r\n\r\n" + text;
    return text;
}
static void LogRefresh(bool force) {
    if (!g_logWnd) return;
    bool prev = LogViewingPrevious();
    std::wstring text = ReadLogText(prev);
    if (!force && text == g_logShown) return;
    g_logShown = text;
    HWND ed = LCtl(ID_L_TEXT);
    SetWindowTextW(ed, text.c_str());
    if (!prev) {   // the current run: follow the end of the log
        SendMessageW(ed, EM_SETSEL, (WPARAM)text.size(), (LPARAM)text.size());
        SendMessageW(ed, EM_SCROLLCARET, 0, 0);
    }
}
static std::wstring KV(const wchar_t* k, int v) { return std::wstring(k) + L"=" + std::to_wstring((long long)v) + L"  "; }
// what gets copied: a short, private (no paths, usernames or passwords) description of the setup + the log
static std::wstring BuildLogReport() {
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t ts[64];
    wsprintfW(ts, L"%04d-%02d-%02d %02d:%02d:%02d", (int)t.wYear, (int)t.wMonth, (int)t.wDay, (int)t.wHour, (int)t.wMinute, (int)t.wSecond);
    OSVERSIONINFOW vi;
    ZeroMemory(&vi, sizeof(vi));
    vi.dwOSVersionInfoSize = sizeof(vi);
    GetVersionExW(&vi);
    std::wstring r = L"ArcManager (C++) " + std::wstring(kAppVersion) + L" log report - " + std::wstring(ts) + L"\r\n";
    r += L"Windows " + std::to_wstring((long long)vi.dwMajorVersion) + L"." + std::to_wstring((long long)vi.dwMinorVersion) +
         L" build " + std::to_wstring((long long)vi.dwBuildNumber) + L"\r\n";
    r += std::wstring(L"Arc.exe found: ") + (FileExists(S.arcPath) ? L"yes" : L"no") + L"\r\n";
    r += L"Settings: ";
    r += KV(L"AutoFill", S.autoFill) + KV(L"UsernameFocusTabs", S.usernameFocusTabs) + KV(L"FieldSeparatorTabs", S.fieldSeparatorTabs) +
         KV(L"LoginDelayMs", S.loginDelayMs) + KV(L"MinWaitSeconds", S.minWaitSeconds) + KV(L"WindowTimeoutSeconds", S.windowTimeoutSeconds);
    r += std::wstring(L"CloseArcAt=") + (S.closeAtLauncher ? L"launcher" : L"game") + L"  ";
    r += KV(L"LauncherGraceSeconds", S.launcherGraceSeconds) + KV(L"GraceSeconds", S.graceSeconds) + KV(L"TimeoutSeconds", S.timeoutSeconds) +
         KV(L"PendingTimeoutSeconds", S.pendingTimeoutSeconds) + KV(L"KillArcOnStart", S.killArcOnStart) + KV(L"RenameGameWindows", S.renameWindows) +
         KV(L"RenameDurationSeconds", S.renameDurationSeconds) + KV(L"StatusResetSeconds", S.statusResetSeconds);
    r += L"\r\n(showing: " + std::wstring(LogViewingPrevious() ? L"previous run" : L"current run") + L")\r\n";
    r += L"----------------------------------------\r\n";
    r += g_logShown;
    return r;
}

static void LogLayout() {
    RECT rc;
    GetClientRect(g_logWnd, &rc);
    int w = rc.right, h = rc.bottom;
    SetWindowPos(LCtl(ID_L_TEXT), NULL, 12, 44, std::max(100, w - 24), std::max(60, h - 44 - 52), SWP_NOZORDER);
    int y = h - 40;
    SetWindowPos(LCtl(ID_L_COPY), NULL, 12, y, 210, 28, SWP_NOZORDER);
    SetWindowPos(LCtl(ID_L_REFRESH), NULL, 230, y, 90, 28, SWP_NOZORDER);
    SetWindowPos(LCtl(ID_L_FOLDER), NULL, 328, y, 150, 28, SWP_NOZORDER);
    SetWindowPos(LCtl(ID_L_CLOSE), NULL, w - 12 - 90, y, 90, 28, SWP_NOZORDER);
}
static HWND LMake(const wchar_t* cls, const wchar_t* text, DWORD style, DWORD ex, int id) {
    HWND c = CreateWindowExW(ex, cls, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, g_logWnd, (HMENU)(INT_PTR)id, g_hInst, NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_font, TRUE);
    return c;
}
static LRESULT CALLBACK LogProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_logWnd = hwnd;
        if (!g_fontMono) g_fontMono = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                                  DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN, L"Consolas");
        HWND cur = LMake(L"BUTTON", L"This run", BS_AUTORADIOBUTTON | WS_GROUP | WS_TABSTOP, 0, ID_L_CUR);
        HWND prev = LMake(L"BUTTON", L"Previous run", BS_AUTORADIOBUTTON, 0, ID_L_PREV);
        HWND aut = LMake(L"BUTTON", L"Update live", BS_AUTOCHECKBOX | WS_GROUP | WS_TABSTOP, 0, ID_L_AUTO);
        SetWindowPos(cur, NULL, 12, 12, 90, 22, SWP_NOZORDER);
        SetWindowPos(prev, NULL, 106, 12, 120, 22, SWP_NOZORDER);
        SetWindowPos(aut, NULL, 240, 12, 140, 22, SWP_NOZORDER);
        SendMessageW(cur, BM_SETCHECK, BST_CHECKED, 0);
        SendMessageW(aut, BM_SETCHECK, BST_CHECKED, 0);
        HWND ed = LMake(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | ES_AUTOHSCROLL | WS_VSCROLL | WS_HSCROLL | WS_TABSTOP, WS_EX_CLIENTEDGE, ID_L_TEXT);
        SendMessageW(ed, WM_SETFONT, (WPARAM)g_fontMono, TRUE);
        SendMessageW(ed, EM_LIMITTEXT, 0x7FFFFFFE, 0);
        LMake(L"BUTTON", L"COPY LOG TO CLIPBOARD", BS_DEFPUSHBUTTON | WS_TABSTOP, 0, ID_L_COPY);
        LMake(L"BUTTON", L"REFRESH", BS_PUSHBUTTON | WS_TABSTOP, 0, ID_L_REFRESH);
        LMake(L"BUTTON", L"OPEN LOG FOLDER", BS_PUSHBUTTON | WS_TABSTOP, 0, ID_L_FOLDER);
        LMake(L"BUTTON", L"CLOSE", BS_PUSHBUTTON | WS_TABSTOP, 0, ID_L_CLOSE);
        LogLayout();
        return 0;
    }
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) LogLayout();
        return 0;
    case WM_GETMINMAXINFO: {
        MINMAXINFO* mm = (MINMAXINFO*)lp;
        RECT r = { 0, 0, 560, 300 };
        AdjustWindowRectEx(&r, (DWORD)GetWindowLongW(hwnd, GWL_STYLE), FALSE, (DWORD)GetWindowLongW(hwnd, GWL_EXSTYLE));
        mm->ptMinTrackSize.x = r.right - r.left;
        mm->ptMinTrackSize.y = r.bottom - r.top;
        return 0;
    }
    case WM_TIMER:
        if (wp == 1) {   // live update
            if (SendMessageW(LCtl(ID_L_AUTO), BM_GETCHECK, 0, 0) == BST_CHECKED && !LogViewingPrevious()) LogRefresh(false);
        } else if (wp == 2) {   // put the button text back after "COPIED!"
            KillTimer(hwnd, 2);
            SetWindowTextW(LCtl(ID_L_COPY), L"COPY LOG TO CLIPBOARD");
        }
        return 0;
    case WM_COMMAND: {
        int id = LOWORD(wp), note = HIWORD(wp);
        if (note != BN_CLICKED) return 0;
        if (id == ID_L_CUR || id == ID_L_PREV || id == ID_L_REFRESH) LogRefresh(true);
        else if (id == ID_L_COPY) {
            LogRefresh(false);
            SetClipboardText(BuildLogReport());
            SetWindowTextW(LCtl(ID_L_COPY), L"COPIED!");
            SetTimer(hwnd, 2, 1500, NULL);
        } else if (id == ID_L_FOLDER) ShellExecuteW(hwnd, L"open", g_configDir.c_str(), NULL, NULL, SW_SHOWNORMAL);
        else if (id == ID_L_CLOSE) PostMessageW(hwnd, WM_CLOSE, 0, 0);
        return 0;
    }
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        KillTimer(hwnd, 2);
        g_logWnd = NULL;
        if (g_hwnd && IsWindow(g_hwnd) && IsWindowEnabled(g_hwnd)) SetForegroundWindow(g_hwnd);   // do not let the manager fall behind other windows
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
static void OpenLogViewer() {
    if (g_logWnd) {
        if (IsIconic(g_logWnd)) ShowWindow(g_logWnd, SW_RESTORE);
        SetForegroundWindow(g_logWnd);
        return;
    }
    DWORD style = WS_OVERLAPPEDWINDOW, ex = WS_EX_CONTROLPARENT;
    RECT rc = { 0, 0, 760, 520 };
    AdjustWindowRectEx(&rc, style, FALSE, ex);
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    RECT mr, wa = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) };
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    GetWindowRect(g_hwnd, &mr);
    int x = mr.left + ((mr.right - mr.left) - w) / 2, y = mr.top + ((mr.bottom - mr.top) - h) / 2;
    x = std::max((int)wa.left, std::min(x, (int)wa.right - w));
    y = std::max((int)wa.top, std::min(y, (int)wa.bottom - h));
    HWND wnd = CreateWindowExW(ex, L"ArcManagerLog", L"Log", style, x, y, w, h, g_hwnd, NULL, g_hInst, NULL);
    if (!wnd) return;
    ShowWindow(wnd, SW_SHOW);
    UpdateWindow(wnd);
    LogRefresh(true);
    SetTimer(wnd, 1, 1000, NULL);
}

// ---- import / export of the accounts list (a text file in the same format as accounts.txt)
static void ImportAccounts() {
    wchar_t file[MAX_PATH * 2] = L"";
    OPENFILENAMEW o;
    ZeroMemory(&o, sizeof(o));
    o.lStructSize = sizeof(o);
    o.hwndOwner = g_hwnd;
    o.lpstrFilter = L"Account lists (*.txt)\0*.txt\0All files\0*.*\0";
    o.lpstrFile = file;
    o.nMaxFile = MAX_PATH * 2;
    o.lpstrTitle = L"Import accounts";
    o.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&o)) return;
    std::string raw;
    if (!ReadWholeFile(file, raw)) { Msg(L"The file could not be read.", L"Import accounts"); return; }
    std::vector<Account> in = ParseAccounts(raw);
    int added = 0, skipped = 0;
    for (size_t k = 0; k < in.size(); k++) {
        std::wstring u = Trim(in[k].user);
        if (u.empty()) continue;
        bool dup = false;
        for (size_t i = 0; i < g_rows.size(); i++)
            if (_wcsicmp(Trim(GetText(g_rows[i].user)).c_str(), u.c_str()) == 0) { dup = true; break; }
        if (dup) { skipped++; continue; }   // accounts that are already in the list are never overwritten
        in[k].user = u;
        int blank = -1;   // an empty row is filled instead of adding a new one
        for (size_t i = 0; i < g_rows.size() && blank < 0; i++)
            if (GetText(g_rows[i].user).empty() && GetText(g_rows[i].pass).empty() && GetText(g_rows[i].notes).empty()) blank = (int)i;
        if (blank >= 0) {
            SetWindowTextW(g_rows[blank].user, in[k].user.c_str());
            SetWindowTextW(g_rows[blank].pass, in[k].pass.c_str());
            SetWindowTextW(g_rows[blank].notes, in[k].notes.c_str());
        } else AddRow(in[k]);
        added++;
    }
    RelayoutRows();
    SaveAccounts();
    std::wstring m;
    if (added == 0 && skipped == 0) m = L"No accounts were found in that file.";
    else {
        m = L"Imported " + std::to_wstring((long long)added) + (added == 1 ? L" account." : L" accounts.");
        if (skipped > 0) m += L"\n" + std::to_wstring((long long)skipped) + (skipped == 1 ? L" account was" : L" accounts were") + L" already in the list (same username) and skipped.";
    }
    Msg(m.c_str(), L"Import accounts");
}
static void ExportAccounts() {
    int count = 0;
    std::wstring all = BuildAccountsText(&count);
    if (count == 0) { Msg(L"There are no accounts to export.", L"Export accounts"); return; }
    if (MessageBoxW(g_hwnd, L"The exported file contains your usernames and PASSWORDS as plain text.\n\nKeep it somewhere safe and delete it when you no longer need it.",
                    L"Export accounts", MB_OKCANCEL | MB_ICONWARNING) != IDOK) return;
    wchar_t file[MAX_PATH * 2] = L"ArcManager-accounts.txt";
    OPENFILENAMEW o;
    ZeroMemory(&o, sizeof(o));
    o.lStructSize = sizeof(o);
    o.hwndOwner = g_hwnd;
    o.lpstrFilter = L"Account lists (*.txt)\0*.txt\0All files\0*.*\0";
    o.lpstrFile = file;
    o.nMaxFile = MAX_PATH * 2;
    o.lpstrTitle = L"Export accounts";
    o.lpstrDefExt = L"txt";
    o.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;
    if (!GetSaveFileNameW(&o)) return;
    if (!WriteWholeFile(file, ToUtf8(all))) { Msg(L"The file could not be written.", L"Export accounts"); return; }
    std::wstring m = L"Exported " + std::to_wstring((long long)count) + (count == 1 ? L" account to:\n" : L" accounts to:\n") + file;
    Msg(m.c_str(), L"Export accounts");
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_hwnd = hwnd;
        MakeLabel(hwnd, ID_TITLE, L"PWI", 16, 10, 200, 40);
        MakeLabel(hwnd, ID_HDR1, L"Username", X_USER, 60, FIELD_W, 18);
        MakeLabel(hwnd, ID_HDR2, L"Password", X_PASS, 60, FIELD_W, 18);
        MakeLabel(hwnd, ID_HDR3, L"Main character / notes", X_NOTES, 60, FIELD_W, 18);

        RECT cr;
        GetClientRect(hwnd, &cr);
        g_panel = CreateWindowExW(WS_EX_CONTROLPARENT, L"ArcRows", L"", WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN,
                                  0, LIST_TOP, cr.right, std::max(60, (int)cr.bottom - LIST_TOP - BOTTOM_H), hwnd, NULL, g_hInst, NULL);
        std::vector<Account> accs = LoadAccounts();
        for (size_t i = 0; i < accs.size(); i++) AddRow(accs[i]);

        g_btnAdd = MakeButton(hwnd, ID_ADD, L"+ Add account", 16, 0, 120, 28);
        g_btnShowPw = MakeButton(hwnd, ID_SHOWPW, L"Show passwords", 150, 0, 130, 22);
        g_lblBlank = MakeLabel(hwnd, ID_BLANKHINT, L"Blank entries deleted on exit.", 296, 0, 220, 20);
        g_lblStorage = MakeLabel(hwnd, ID_STORAGEHINT, L"Usernames and passwords are saved as PLAIN TEXT in %AppData%\\ArcManager\\accounts.txt", 520, 0, 520, 20);
        if (!S.showStorageHint) ShowWindow(g_lblStorage, SW_HIDE);
        g_btnImport = MakeButton(hwnd, ID_IMPORT, L"Import...", 292, 0, 80, 28);
        g_btnExport = MakeButton(hwnd, ID_EXPORT, L"Export...", 378, 0, 80, 28);
        g_btnLog = MakeButton(hwnd, ID_LOG, L"", cr.right - 16 - 28 - 8 - 28, 0, 28, 28);
        g_logOldProc = (WNDPROC)SetWindowLongPtrW(g_btnLog, GWLP_WNDPROC, (LONG_PTR)HoverProc);
        g_btnGear = MakeButton(hwnd, ID_GEAR, L"", cr.right - 16 - 28, 0, 28, 28);
        g_gearOldProc = (WNDPROC)SetWindowLongPtrW(g_btnGear, GWLP_WNDPROC, (LONG_PTR)HoverProc);
        g_tipMain = MakeTooltips(hwnd);
        AddTip(g_tipMain, hwnd, g_btnImport, L"Add accounts from a text file (same format as accounts.txt). Accounts already in the list are skipped.");
        AddTip(g_tipMain, hwnd, g_btnExport, L"Save the accounts list to a text file. The file contains the passwords as plain text.");
        AddTip(g_tipMain, hwnd, g_btnLog, L"View log");
        AddTip(g_tipMain, hwnd, g_btnGear, L"Settings");
        LayoutMain();
        RelayoutRows();
        RenderBackground(true);
        AdoptSession();
        SetTimer(hwnd, ID_TIMER, 1000, NULL);
        return 0;
    }
    case WM_SIZE:
        if (g_panel && wp != SIZE_MINIMIZED) {
            LayoutMain();
            SetTimer(hwnd, ID_BGTIMER, 150, NULL);   // re-fit the background once resizing settles
        }
        return 0;
    case WM_GETMINMAXINFO: {
        MINMAXINFO* mm = (MINMAXINFO*)lp;
        RECT r = { 0, 0, 900, 420 };
        AdjustWindowRectEx(&r, (DWORD)GetWindowLongW(hwnd, GWL_STYLE), FALSE, (DWORD)GetWindowLongW(hwnd, GWL_EXSTYLE));
        mm->ptMinTrackSize.x = r.right - r.left;
        mm->ptMinTrackSize.y = r.bottom - r.top;
        return 0;
    }
    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(hwnd, &rc);
        PaintBg((HDC)wp, rc, 0, 0);
        return 1;
    }
    case WM_MOUSEWHEEL:
        return g_panel ? SendMessageW(g_panel, msg, wp, lp) : 0;
    case WM_TIMER:
        if (wp == ID_TIMER) UpdateState();
        else if (wp == ID_BGTIMER) { KillTimer(hwnd, ID_BGTIMER); RenderBackground(false); }
        return 0;
    case WM_COMMAND: {
        int id = LOWORD(wp), note = HIWORD(wp);
        if (id == ID_ADD && note == BN_CLICKED) {
            Account a;
            AddRow(a);
            RelayoutRows();
            EnsureRowVisible((int)g_rows.size() - 1);
            SetFocus(g_rows.back().user);
        } else if (id == ID_IMPORT && note == BN_CLICKED) {
            ImportAccounts();
        } else if (id == ID_EXPORT && note == BN_CLICKED) {
            ExportAccounts();
        } else if (id == ID_LOG && note == BN_CLICKED) {
            OpenLogViewer();
        } else if (id == ID_GEAR && note == BN_CLICKED) {
            OpenSettings();
        } else if (id == ID_SHOWPW && note == BN_CLICKED) {
            g_showPw = !g_showPw;
            for (size_t i = 0; i < g_rows.size(); i++) {
                SendMessageW(g_rows[i].pass, EM_SETPASSWORDCHAR, g_showPw ? 0 : 0x2022, 0);
                InvalidateRect(g_rows[i].pass, NULL, TRUE);
            }
            InvalidateRect(g_btnShowPw, NULL, FALSE);
        } else if (id >= ID_ROW_BASE && note == BN_CLICKED) {
            int row = (id - ID_ROW_BASE) / 10, kind = (id - ID_ROW_BASE) % 10;
            if (row < (int)g_rows.size()) {
                if (kind == K_SIGN) StartPlay(row);
                else if (kind == K_STOP) StopClient(row);
            }
        }
        return 0;
    }
    case WM_DRAWITEM: {
        const DRAWITEMSTRUCT* d = (const DRAWITEMSTRUCT*)lp;
        if (d->CtlType == ODT_STATIC) DrawLabel(d);
        else DrawButton(d);
        return TRUE;
    }
    case WM_CTLCOLOREDIT:
        SetTextColor((HDC)wp, cWhite);
        SetBkColor((HDC)wp, cBox);
        return (LRESULT)g_brBox;
    case WM_CLOSE:
        if (g_setWnd) return 0;   // the settings window is open: close that one first
        {
            int running = 0;
            for (size_t i = 0; i < g_rows.size(); i++) if (g_rows[i].gamePid) running++;
            if (running > 0) {
                std::wstring q = std::to_wstring((long long)running) + (running == 1 ? L" game client is" : L" game clients are") +
                                 L" still running.\n\nThey keep running if you close the manager, and the manager finds them again the next time it starts.\n\nClose the manager anyway?";
                if (MessageBoxW(hwnd, q.c_str(), L"Game clients running", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES) return 0;
            }
        }
        SaveAccounts();
        SaveSession();
        if (S.rememberSize && !IsIconic(hwnd) && !IsZoomed(hwnd)) {
            RECT cr;
            GetClientRect(hwnd, &cr);
            wchar_t b[32];
            wsprintfW(b, L"%d", (int)cr.right);
            WritePrivateProfileStringW(L"Settings", L"WindowWidth", b, g_iniPath.c_str());
            wsprintfW(b, L"%d", (int)cr.bottom);
            WritePrivateProfileStringW(L"Settings", L"WindowHeight", b, g_iniPath.c_str());
        }
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, ID_TIMER);
        KillTimer(hwnd, ID_BGTIMER);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int nCmdShow) {
    g_hInst = hInst;
    // only one manager at a time (the PowerShell version uses the same name, so the two never run together)
    HANDLE instanceMutex = CreateMutexW(NULL, TRUE, L"Local\\ArcManager_SingleInstance");
    if (instanceMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND other = FindWindowW(L"ArcManagerWnd", NULL);
        if (other) {
            if (IsIconic(other)) ShowWindow(other, SW_RESTORE);
            SetForegroundWindow(other);
        } else {
            MessageBoxW(NULL, L"ArcManager is already running.", L"ArcManager", MB_OK | MB_ICONINFORMATION);
        }
        return 0;
    }
    InitPaths();
    LoadSettings();

    // close any Arc left running (e.g. a signed-in instance) before doing anything else
    StartNewLog();
    AutoConfigArcPath();   // the configured Arc.exe is missing: look for it
    if (S.killArcOnStart) {
        PidList arc = ArcPids(Snapshot());
        if (!arc.empty()) {
            Log(L"manager start: closing " + std::to_wstring((long long)arc.size()) + L" running Arc process(es)");
            for (size_t i = 0; i < arc.size(); i++) KillPid(arc[i]);
        }
    }

    INITCOMMONCONTROLSEX icc;
    icc.dwSize = sizeof(icc);
    icc.dwICC = ICC_STANDARD_CLASSES | ICC_BAR_CLASSES;
    InitCommonControlsEx(&icc);

    g_brBg = CreateSolidBrush(cBg);
    g_brBox = CreateSolidBrush(cBox);
    g_font = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    g_fontBold = CreateFontW(-13, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    g_fontTitle = CreateFontW(-27, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    LoadBackgroundSource();

    WNDCLASSEXW pc;
    ZeroMemory(&pc, sizeof(pc));
    pc.cbSize = sizeof(pc);
    pc.lpfnWndProc = PanelProc;
    pc.hInstance = hInst;
    pc.hCursor = LoadCursor(NULL, IDC_ARROW);
    pc.lpszClassName = L"ArcRows";
    RegisterClassExW(&pc);

    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hIcon = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(IDI_APPICON), IMAGE_ICON,
                                 GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR);        // taskbar / Alt+Tab
    wc.hIconSm = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(IDI_APPICON), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR);  // title bar
    wc.lpszClassName = L"ArcManagerWnd";
    RegisterClassExW(&wc);

    WNDCLASSEXW sc;
    ZeroMemory(&sc, sizeof(sc));
    sc.cbSize = sizeof(sc);
    sc.lpfnWndProc = SettingsProc;
    sc.hInstance = hInst;
    sc.hCursor = LoadCursor(NULL, IDC_ARROW);
    sc.hIcon = wc.hIcon;
    sc.hIconSm = wc.hIconSm;
    sc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    sc.lpszClassName = L"ArcManagerSettings";
    RegisterClassExW(&sc);

    WNDCLASSEXW lc = sc;
    lc.lpfnWndProc = LogProc;
    lc.lpszClassName = L"ArcManagerLog";
    RegisterClassExW(&lc);

    DWORD style = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
    DWORD exstyle = WS_EX_CONTROLPARENT;
    RECT rc = { 0, 0, S.windowWidth, S.windowHeight };
    AdjustWindowRectEx(&rc, style, FALSE, exstyle);
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    RECT wa = { 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN) };
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    if (w > wa.right - wa.left) w = wa.right - wa.left;
    if (h > wa.bottom - wa.top) h = wa.bottom - wa.top;
    int x = wa.left + ((wa.right - wa.left) - w) / 2, y = wa.top + ((wa.bottom - wa.top) - h) / 2;
    HWND hwnd = CreateWindowExW(exstyle, L"ArcManagerWnd", L"PWI Account Manager", style, x, y, w, h, NULL, NULL, hInst, NULL);
    if (!hwnd) return 1;
    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        if (g_setWnd && (m.hwnd == g_setWnd || IsChild(g_setWnd, m.hwnd))) {
            if (m.message == WM_KEYDOWN && m.wParam == VK_ESCAPE) { PostMessageW(g_setWnd, WM_CLOSE, 0, 0); continue; }
            if (m.message == WM_KEYDOWN && m.wParam == VK_RETURN) {
                wchar_t cls[16];
                GetClassNameW(m.hwnd, cls, 16);
                if (_wcsicmp(cls, L"Edit") == 0) { PostMessageW(g_setWnd, WM_COMMAND, MAKEWPARAM(ID_S_SAVE, BN_CLICKED), 0); continue; }
            }
            if (IsDialogMessageW(g_setWnd, &m)) continue;
        }
        if (g_logWnd && (m.hwnd == g_logWnd || IsChild(g_logWnd, m.hwnd))) {
            if (m.message == WM_KEYDOWN && m.wParam == VK_ESCAPE) { PostMessageW(g_logWnd, WM_CLOSE, 0, 0); continue; }
            if (IsDialogMessageW(g_logWnd, &m)) continue;
        }
        if (!IsDialogMessageW(hwnd, &m)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
    return (int)m.wParam;
}
