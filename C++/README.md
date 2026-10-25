# ArcManager - PWI Account Manager

A small, portable helper for people who play **Perfect World International** through the **Arc** launcher
on several accounts. Keep your accounts in one window, press **SIGN IN**, and the manager starts Arc, types the
login for you, lets the game launch, and closes Arc again so the next account can sign in.

> **Unofficial.** This project is not made, endorsed or supported by Arc, Perfect World, Gameforge or any other
> company. All names and trademarks belong to their owners. You use it at your own risk; please check the game's
> Terms of Service yourself.

Two versions are provided. They do the same thing and **share the same settings and accounts files**:

| Version | File | Needs |
|---|---|---|
| **C++ (native)** | `ArcManager.exe` | Nothing to install. A single small file. |
| **PowerShell** | `ArcManager.ps1` + `StartArcManager.bat` | Windows with PowerShell 2.0 or newer (included in Windows 7 and later). |

Both run only one copy at a time (you cannot start the C++ and PowerShell versions together).

---

## Features

- Any number of accounts, each with **username, password and a note** (for example the character name).
- **One-click sign-in**: closes any old Arc, starts Arc, waits for its login window, types the username and password.
- Closes Arc at the moment you choose (**when the launcher starts** or **when the game client starts**).
- **CANCEL** (the SIGN IN button turns into CANCEL while working) closes Arc, the launcher and the patcher that this sign-in started.
- **STOP** closes that account's game client.
- Game client windows are **renamed to the note of their row**, so seven clients are easy to tell apart.
- **Remembers running game clients**: close and reopen the manager and it recognises the clients it started (by process id and start time).
- **Import / Export** of the accounts list as a text file.
- A built-in **settings window** (gear icon) with *Basic* and *Advanced* pages, and a **log viewer** (paper icon) with *Copy log to clipboard*.
- Optional background picture (a nice default is built into the program).
- Portable: no installer, nothing is written outside `%AppData%\ArcManager` (and the program's own folder if you choose).

---

## Quick start

### C++ version
1. Put `ArcManager.exe` anywhere (the desktop is fine - it does not leave files next to itself).
2. Double-click it and accept the administrator prompt (see *Security and privacy* for why).
3. Type a username, password and (optionally) a note in the first row. Use **+ Add account** for more rows.
4. Press **SIGN IN**.

### PowerShell version
1. Keep `ArcManager.ps1`, `StartArcManager.bat` and `background.png` together in one folder.
2. Double-click `StartArcManager.bat` (it starts the script with the right options) and accept the administrator prompt.
3. Continue as above.

The first time, the manager looks for `Arc.exe` by itself (a running Arc, the list of installed programs, and the usual
`Program Files` folders on your drives). If it cannot find it, open the gear icon and set **Arc Location**.

---

## Using the main window

| Control | What it does |
|---|---|
| Username / Password / Notes | One account per row. The note is also used as the game window title. |
| **SIGN IN** | Signs in that account. While it works the button reads **CANCEL**. |
| **STOP** | Force-closes that account's game client (asks first if you enabled *Ask before stopping*). |
| Status text | Shows what is happening. Messages like *Stopped* or *Cancelled* return to *Idle* after a while. Running clients show their **PID**. |
| **+ Add account** | Adds an empty row. Rows left completely empty are removed when you close the manager. |
| **Import...** | Adds accounts from a text file in the same format as `accounts.txt` (`username`, `password`, `note`, separated by tabs). Accounts whose username is already in the list are skipped, never overwritten. |
| **Export...** | Saves the accounts list to a text file (handy as a backup or for moving to another computer). **The file contains the passwords as plain text.** |
| **Show passwords** | Shows or hides the passwords on screen. |
| Paper icon | Opens the log viewer. |
| Gear icon | Opens the settings window. |

Usernames, passwords and notes cannot contain **tabs or line breaks** (they would corrupt the accounts file); such text is refused with a message.

---

## Settings

Open the **gear icon**. Changes take effect **immediately** after *SAVE CONFIGURATION* - no restart needed.
*LOAD DEFAULTS* only fills in the standard values; nothing is saved until you press Save.
*OPEN SETTINGS FOLDER* opens the folder with all of the program's files.

Everything is stored in a plain text file, `ArcManager.ini`, which you can also edit by hand (save it and restart the
manager). Comments in the file are kept when the program saves.

| Key | Default | Window label | Meaning |
|---|---|---|---|
| `ArcPath` | `C:\Program Files (x86)\Arc\Arc.exe` | Arc Location | Full path to Arc. The file **must be named `Arc.exe`**. |
| `WindowWidth`, `WindowHeight` | `1280`, `720` | Main window | Size of the window's inside area in pixels (minimum 900 x 420). |
| `RememberWindowSize` | `1` | Remember the size when closing | Saves the size when you close the manager. |
| `AutoFill` | `1` | Auto-fill username and password | Types the login for you. |
| `CloseArcAt` | `launcher` | Close Arc when | `launcher` = as soon as the launcher starts, `game` = when the game client starts. |
| `ConfirmStop` | `0` | Ask before stopping a game client | Confirmation before STOP. |
| `KillArcOnStart` | `1` | Close running Arc at start / sign-in | Closes a leftover Arc when the manager starts and before each sign-in. |
| `RenameGameWindows` | `1` | Rename game windows to Notes | Sets each game window's title to its row's note. |
| `ShowStorageHint` | `0` | Show plain-text storage notice | Shows a note at the bottom of the window that accounts are stored as plain text. |
| `DebugLog` | `1` | Debug / Logs | Writes the log (never containing passwords). |
| `BackgroundImage` | *(empty)* | Background Image Location | Your own picture. Empty = a `background.*` file next to the program, or the built-in image. |
| `BackgroundMode` | `fill` | Mode | `fill`, `fit`, `stretch`, `tile` or `center`. |
| `BackgroundDim` | `0.5` | Darkness | `0` = picture as it is, `1` = black. |
| `UsernameFocusTabs` | `1` | Tabs before username box | Tab presses sent first, to reach the username box. *(Advanced)* |
| `FieldSeparatorTabs` | `1` | Tabs between the two boxes | Tab presses between username and password. *(Advanced)* |
| `LoginDelayMs` | `3000` | Login delay (milliseconds) | Wait after Arc's login window appears, before typing. *(Advanced)* |
| `MinWaitSeconds` | `6` | Minimum wait (seconds) | Never type sooner than this after starting Arc. *(Advanced)* |
| `WindowTimeoutSeconds` | `40` | Login window timeout | Give up waiting for the login window. *(Advanced)* |
| `LauncherGraceSeconds` | `2` | Delay after launcher | Wait before closing Arc (launcher mode). *(Advanced)* |
| `GraceSeconds` | `6` | Delay after game | Wait before closing Arc (game mode). *(Advanced)* |
| `TimeoutSeconds` | `300` | Give up after | Give up waiting for the game client. *(Advanced)* |
| `PendingTimeoutSeconds` | `600` | Game wait after close | How long to keep watching for the client after Arc was closed early. *(Advanced)* |
| `RenameDurationSeconds` | `180` | Rename duration | The game opens and closes windows while loading, so its windows are re-checked every second for this long after the client starts. Raise it on a slow computer. *(Advanced)* |
| `StatusResetSeconds` | `90` | Reset status after | Seconds until *Stopped / Cancelled / Timed out* return to *Idle* (`0` = never). *(Advanced)* |
| `RunElevated` | `1` | *(not in the window)* | **PowerShell version only**: restart as administrator. The C++ version always asks for it. |

### Where the files are

Everything lives in `%AppData%\ArcManager` (type that into the Explorer address bar):

| File | Purpose |
|---|---|
| `ArcManager.ini` | The settings. |
| `accounts.txt` | Your accounts (**plain text**, see below). `accounts.txt.bak` is the previous version, kept automatically. |
| `session.txt` | Which game clients are running (so they are recognised after a restart). |
| `debug.log` / `debug.previous.log` | The log of this run and of the run before it. |

**Portable mode:** if a file called `ArcManager.ini` sits next to the program, that copy is used instead.
The program never creates it by itself.

---

## The log viewer

Click the **paper icon**. *This run / Previous run*, *Update live*, **COPY LOG TO CLIPBOARD** and *OPEN LOG FOLDER*.
The copied report starts with the program version, your Windows version, whether Arc was found and the non-secret
settings. It contains **no paths, usernames or passwords**, so it is safe to paste into a bug report.

---

## Security and privacy - please read

- **Accounts are stored as PLAIN TEXT** in `%AppData%\ArcManager\accounts.txt`. Anyone who can read your Windows user
  profile can read your passwords. Do not use passwords you use elsewhere, and do not share the file or the folder.
  (Turn on *Show plain-text storage notice* in the settings to be reminded at the bottom of the window.)
- **No network access.** The program never connects to the internet. It does not send, upload or check for updates.
- **Why administrator rights?** To type into Arc's windows and close its processes, the manager has to run with the
  same rights as Arc. For safety it only ever launches a program named **`Arc.exe`**, and only closes Arc, launcher,
  patcher and the game client of the accounts it manages.
- **The log never contains passwords** (or usernames); only things like the number of characters typed.
- **Antivirus warnings:** a program that types into other windows and closes processes can look suspicious to some
  antivirus tools, especially when it is not digitally signed. The complete source code is included - you can read it
  and build it yourself.

---

## Troubleshooting

1. Click the **paper icon**, then **COPY LOG TO CLIPBOARD**, and look at (or share) the text.
2. *Arc not found*: set **Arc Location** with the gear icon (Browse...).
3. *Typing goes to the wrong box or too early*: **Advanced** page - raise **Login delay**, or change the **Tabs** values.
4. *Game windows are not renamed*: check *Rename game windows to Notes*, that the row has a note, and raise
   **Rename duration** on a slow computer.
5. *Accounts file damaged*: the previous version is `accounts.txt.bak` in the same folder.
6. *Start over*: close the manager and delete `ArcManager.ini` (settings) - it is recreated with the defaults.

---

## Building from source

The C++ program is a single source file (`main.cpp`) plus a resource script.

**Tools:** [w64devkit](https://github.com/skeeto/w64devkit) **x86 (32-bit)** kit, so the result runs on every Windows
from XP to 11. Check with `gcc -dumpmachine` (it should say `i686-w64-mingw32`).

1. Put `w64devkit\bin` on your PATH (or open its terminal) and go to the project folder.
2. Run **`build.bat`** (or `make`).
3. `ArcManager.exe` is created. Optionally open the folder as a project in the Eclipse C/C++ IDE.

Files: `main.cpp` (program), `ArcManager.rc` (icon, built-in background, version information), `resource.h`
(ids **and version text**), `ArcManager.manifest` (administrator + visual styles), `res\` (icon and default background).

### Changing the version information
Edit the clearly marked block at the top of **`resource.h`** (file description, product name, version text, numeric
version, copyright) and rebuild. The text is shown in *Properties > Details* of `ArcManager.exe`, in the log and in the
settings window. For the PowerShell version change `$AppVersion` near the top of `ArcManager.ps1`.

---

## Project layout

```
ArcManager.exe  (built)        C++ version
  main.cpp  ArcManager.rc  resource.h  ArcManager.manifest  build.bat  Makefile  res\
ArcManager.ps1  StartArcManager.bat  background.png        PowerShell version
README.md
```

## Credits and license

Made by **Sparc343**.

**License:** *to be decided.*
