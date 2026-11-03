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
- Game client windows are **renamed to the note of their row**, so multiple clients are easy to tell apart.
- **Remembers running game clients**: close and reopen the manager and it recognises the clients it started (by process id and start time).
- **Private server mode**: a switch on the main window turns the manager into an account manager for private servers (no Arc), with its own account list. See *Private servers* below.
- **Re-ordering accounts** with the up and down arrows at the left of every row.
- **Deleting accounts** with a minus button on every row: click (asks first), Shift+click (no question), or Control+click several rows and press Alt+D.
- **Import / Export** of the accounts list as a text file.
- A built-in **settings window** (gear icon) with *Basic*, *Advanced* and *Private Servers* pages, and a **log viewer** (paper icon) with *Copy log to clipboard*.
- Optional background picture (a nice default is built into both versions: into the .exe, and into the script as a text block at its end).
- Closing the manager while game clients are running (in **either** list: Official or Private Servers) asks first.
- Portable: no installer, nothing is written outside `%AppData%\ArcManager` (and the program's own folder if you choose).

---

## Quick start

### C++ version
1. Put `ArcManager.exe` anywhere (the desktop is fine - it does not leave files next to itself).
2. Double-click it and accept the administrator prompt (see *Security and privacy* for why).
3. Type a username, password and (optionally) a note in the first row. Use **+ Add account** for more rows.
4. Press **SIGN IN**.

### PowerShell version
1. Keep `ArcManager.ps1` and `StartArcManager.bat` together in one folder (the default background picture is built into the script).
2. Double-click `StartArcManager.bat` (it starts the script with the right options) and accept the administrator prompt.
3. Continue as above.

The first time, the manager looks for `Arc.exe` by itself (a running Arc, the list of installed programs, and the usual
`Program Files` folders on your drives). If it cannot find it, open the gear icon and set **Arc Location**.

---

## Using the main window

| Control | What it does |
|---|---|
| **OFFICIAL Servers / PRIVATE Servers** switch | At the top of the window. OFFICIAL Servers = the game through Arc (the default). PRIVATE Servers = private servers, see below. Each mode has its own account list, and the window title shows the mode ("PWI Account Manager - Official Servers" / "- Private Servers"). The manager opens in the mode it was closed in. |
| **Up / down arrows** (left and right of the minus button) | Move the account one place up or down; the whole row (texts, running game client, status) moves with it and the new order is saved right away. They are greyed out at the top or bottom of the list and while a sign-in is in progress. |
| **Minus button** (middle of the three row buttons) | Deletes that account. It is grey and turns red when you point at it. **Click** = delete, after a confirmation that shows the username and note. **Shift+click** = delete without asking. **Control+click** = select the row (it turns red with a ring) so you can select several; then press **Alt+D** to delete them all (it asks once; **Esc** clears the selection). A counter next to the buttons shows how many rows are selected. A deleted account is gone from the list immediately and the list is saved right away (`accounts.txt.bak` keeps the version from before). The minus is greyed out for an account whose game client is running, and for all rows while a sign-in is in progress. There is always at least one row: deleting the last one just empties it. Rows left completely empty are also removed when you close the manager. |
| Username / Password / Notes | One account per row. The note is also used as the game window title. |
| **SIGN IN** | Signs in that account. While it works the button reads **CANCEL**. |
| **STOP** | Force-closes that account's game client (asks first if you enabled *Ask before stopping*). |
| Status text | Shows what is happening. Messages like *Stopped* or *Cancelled* return to *Idle* after a while. Running clients show their **PID**. |
| **+ Add account** | Adds an empty row. |
| **Import...** | Adds accounts from a text file in the same format as `accounts.txt` (`username`, `password`, `note`, separated by tabs). Accounts whose username is already in the list are skipped, never overwritten. |
| **Export...** | Saves the accounts list to a text file (handy as a backup or for moving to another computer). **The file contains the passwords as plain text.** |
| **Show passwords** | Shows or hides the passwords on screen. |
| Paper icon | Opens the log viewer. |
| Gear icon | Opens the settings window (it always opens on the *Basic* page). |
| Closing the window | If game clients are running, in the shown list **or in the other one**, you are asked first. The clients keep running if you close the manager, and the next start recognises them again. |

Usernames, passwords and notes cannot contain **tabs or line breaks** (they would corrupt the accounts file); such text is refused with a message.

---

## Settings

Open the **gear icon**. Changes take effect **immediately** after *SAVE CONFIGURATION* - no restart needed.
*LOAD DEFAULTS* only fills in the standard values; nothing is saved until you press Save.
*OPEN SETTINGS FOLDER* opens the folder with all of the program's files.

Settings that were dropped in a newer version (`PrivateStartDir`, `PrivateNoticeShown`) are removed from the file automatically. Everything is stored in a plain text file, `ArcManager.ini`, which you can also edit by hand (save it and restart the
manager). Comments in the file are kept when the program saves.

| Key | Default | Window label | Meaning |
|---|---|---|---|
| `ArcPath` | `C:\Program Files (x86)\Arc\Arc.exe` | Arc Location | Full path to Arc. The file **must be named `Arc.exe`**. |
| `WindowWidth`, `WindowHeight` | `1280`, `720` | Main window | Size of the window's inside area in pixels (minimum 1040 x 420). |
| `RememberWindowSize` | `1` | Remember the size when closing | Saves the size when you close the manager. |
| `AutoFill` | `1` | Auto-fill username and password | Types the login for you. |
| `PopupKey` | `enter` | Key for the pop-up | **Advanced page, "Login pop-up and typing".** The key (`enter` or `escape`) that clears any pop-ups before Arc's login page. |
| `EntersBefore` | `0` | Enter/Escape presses for the pop-up | How many times that key is pressed before the username is typed (`0` = none). |
| `PauseAfterPopupMs` | `1500` | Pause after the pop-up (ms) | Pause after those presses (only used when the count is above 0). |
| `ClearBackspaces` | `0` | Backspaces to clear a box | Backspaces pressed before typing the username and the password, to remove old text (`0` = none). |
| `EnterAfterPassword` | `1` | Press Enter after the password | Presses Enter after the password to log in. Turn it off if you want to press it yourself. |
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
| `PrivateMode` | `0` | *(the switch on the main window)* | `1` = private server mode. |
| `PrivateClientPath` | *(empty)* | Client or launcher location | **Private Servers page.** The program to start (the game client, or a launcher / patcher). |
| `PrivateFlags` | `game:cpw nocheck startbypatcher console:1` | Command-line flags | Passed exactly as typed. The usual flags are filled in; change them for a server that needs different ones (copy the example above to get them back). |
| `PrivateShowWarning` | `1` | Show a warning when switching to Private Servers | The warning is shown every time you switch to Private Servers (never at start-up). `0` = never show it. |
| `PrivateProcessNames` | `elementclient.exe,elementclient_64.exe` | Process name(s) to wait for | The real game client, separated by commas. |
| `PrivateWindowWaitSeconds` | `90` | Wait for the game window | Give up waiting for the client and its window after this long. |
| `PrivateFirstKeyDelaySeconds` | `6` | Wait before the first key | Pause after the window appears. |
| `PrivatePopupKey` | `enter` | Key for the pop-up | The key that clears the pop-up message some clients show before the login page: `enter` or `escape` (radio buttons on the Private Servers page). |
| `PrivateEntersBefore` | `1` | Enter/Escape presses for the pop-up | How many times that key is pressed (`0` = none). |
| `PrivatePauseAfterPopupMs` | `1500` | Pause after the pop-up | Milliseconds. |
| `PrivatePauseStepMs` | `400` | Pause between steps | Milliseconds. |
| `PrivateTabs` | `1` | Tabs between the two boxes | Tab presses between username and password. |
| `PrivateClearBackspaces` | `0` | Backspaces to clear a box | Removes old text (for example a remembered username) before typing. `0` = none. |
| `PrivateEnterAfterPassword` | `1` | Press Enter after the password | Logs in. |
| `RunElevated` | `1` | *(not in the window)* | **PowerShell version only**: restart as administrator. The C++ version always asks for it. |

### Where the files are

Everything lives in `%AppData%\ArcManager` (type that into the Explorer address bar):

| File | Purpose |
|---|---|
| `ArcManager.ini` | The settings. |
| `accounts.txt` | Your accounts (**plain text**, see below). `accounts.txt.bak` is the previous version, kept automatically. |
| `accounts-private.txt` | The accounts for private server mode (same format, own `.bak`). |
| `session.txt`, `session-private.txt` | Which game clients are running in each mode (so they are recognised after a restart). |
| `debug.log` / `debug.previous.log` | The log of this run and of the run before it. |

**Portable mode:** if a file called `ArcManager.ini` sits next to the program, that copy is used instead.
The program never creates it by itself.

---

## Private Servers

Many private servers do not use Arc: the game client logs in directly. Switch the manager to **PRIVATE Servers** (the switch at the
top of the main window) and it works as an account manager for them. The manager opens in whichever mode it was closed in. The official mode is not affected in any way.

**Set it up** (gear icon > **Private Servers**):

1. **Client or launcher location**: the program to start. Usually the server's game client (`elementclient.exe`), but it can
   also be a launcher or patcher. It is started with administrator rights, in its own folder.
2. **Command-line flags**: passed exactly as typed. The usual ones (`game:cpw nocheck startbypatcher console:1`) are filled in; change them if your server needs different flags. Never put your password here.
3. **Process name(s)**: the real game client. If you start a launcher, the manager waits until one of these processes appears.
4. The **typing sequence**: Enter *or Escape* for the start-up pop-up (you choose the key, and how many presses; `0` if your client has none), a pause, the username, a
   pause, Tab, a pause, the password, a pause, Enter. All counts and pauses can be changed (and *Backspaces to clear a box* removes old text such as a remembered username first, `0` = off), because every server and every
   computer is different.

**What SIGN IN does in private mode:** starts the program, waits for the game client and its window, waits a few seconds,
then types the login as described above. The button reads **CANCEL** meanwhile (it closes the program it started).
**STOP**, the PID display, remembering running clients, window renaming and the log work as in official mode. Arc is
never touched in private mode, so an official game that is already running is safe.

**Good to know**

- Each mode has its **own account list** (`accounts-private.txt`). This keeps your official Arc password from ever being typed
  into a private server by mistake. **Use different passwords for private servers**: they are run by other people.
- A warning explains this every time you switch to Private Servers. Turn it off with *Show a warning when switching to Private Servers* on the Private Servers page.
- If the keys do not reach the game, or the login is typed too early, raise the pauses and the wait before the first key.
  The log (paper icon) records every step.
- Servers that use a launcher with its own login form, or a web login, cannot be filled in this way.

## The log viewer

Click the **paper icon**. *This run / Previous run*, *Update live*, **COPY LOG TO CLIPBOARD** and *OPEN LOG FOLDER*.
The copied report starts with the program version, your Windows version, whether Arc was found and the non-secret
settings. It contains **no paths, usernames or passwords**, so it is safe to paste into a bug report.

---

## Security and privacy - please read

- **Accounts are stored as PLAIN TEXT** in `%AppData%\ArcManager\accounts.txt` (and `accounts-private.txt`). Anyone who can read your Windows user
  profile can read your passwords. Do not use passwords you use elsewhere, and do not share the file or the folder.
  (Turn on *Show plain-text storage notice* in the settings to be reminded at the bottom of the window.) The version number is shown at the bottom right of the main window.
- **No network access.** The program never connects to the internet. It does not send, upload or check for updates.
- **Private servers** are run by third parties. Keep their passwords separate from your official ones (the two modes use separate account lists).
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
3. *Typing goes to the wrong box or too early*: **Advanced** page - raise **Login delay**, or change the **Tabs** values. If Arc shows a message before its login page, use *Login pop-up and typing* on the same page.
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
version, copyright) and rebuild. The text is shown in *Properties > Details* of `ArcManager.exe`, in the log and at the
bottom right of the main window (the settings window shows the copyright). For the PowerShell version change `$AppVersion` near the top of `ArcManager.ps1`.

---

## Project layout

```
ArcManager.exe  (built)        C++ version
  main.cpp  ArcManager.rc  resource.h  ArcManager.manifest  build.bat  Makefile  res\
ArcManager.ps1  StartArcManager.bat                           PowerShell version (the default background is inside the script)
README.md
```

## Credits and license

Made by **Sparc343**.

**License:** *to be decided.*
