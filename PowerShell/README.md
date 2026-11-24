# ArcManager - PWI Account Manager

A small, portable helper for people who play **Perfect World International** through the **Arc** launcher
on several accounts. Keep your accounts in one window, press **SIGN IN**, and the manager starts Arc, types the
login for you, lets the game launch, and closes Arc again so the next account can sign in. It can even press Arc's **Play** and the patcher's **Start** for you, so one click on **SIGN IN** takes you all the way to the open game client.

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
- **One-click sign-in**: closes any old Arc, starts Arc, signs in, and takes you to the running game client. Two **Launcher Modes** (see *Launcher Modes and automation* below): **Hidden Arc Mode** (the default; Arc's window is kept off-screen) or **Show Arc Mode** (Arc's window is shown and the login is typed into it).
- **Optional full automation** (Show Arc Mode): *Auto-click Play (arc)* and *Auto-click Start (launcher/patcher)* press those two buttons for you. Hidden Arc Mode always clicks both.
- Closes Arc **the instant the launcher / patcher is detected** (no delay or choice settings any more), and force-closes the launcher / patcher itself the instant the game client starts.
- Small always-on-top status pop-ups (**Obtaining ARC / PWI TOKEN Now** and **Starting Game**) so you always know the program is busy. The *Starting Game* pop-up also reminds you to check for updates manually if the start fails.
- An **Update Client** button (green, at the top of the window) that opens the game's launcher / patcher without signing in to anything, so you can update the game client. **Updates are never detected automatically - you have to do them yourself** (see *Updating the game client (manual)* below).
- **CANCEL** (the SIGN IN button turns into CANCEL while working) closes Arc, the launcher and the patcher that this sign-in started.
- **STOP** closes that account's game client.
- Game client windows are **renamed to the note of their row**, so multiple clients are easy to tell apart.
- **Remembers running game clients**: close and reopen the manager and it recognises the clients it started (by process id and start time).
- **Private server mode**: a switch on the main window turns the manager into an account manager for private servers (no Arc), with its own account list. See *Private servers* below.
- **Re-ordering accounts** by dragging the grip (three lines) at the left of every row up or down as far as you like, or with **Alt+Up** / **Alt+Down**.
- **Deleting accounts** with a minus button on every row: click (asks first), Shift+click (no question), or Control+click several rows and press Alt+D. **Alt+A** selects ALL rows (then Alt+D deletes them, after asking).
- **Built-in help**: press **F1** (a small "Help~F1" reminder is shown at the bottom of the main window) to read this README inside the program, nicely formatted, in a window with the same size and position as the main window. It is compiled into the program, so you can share **just the .exe** (or just the .ps1 script) and everything needed, README included, goes with it.
- **Import / Export** of the accounts list as a text file.
- A built-in **settings window** (gear icon) with *Basic*, *Advanced* (sub-tabs *Shared Settings*, *Hidden Arc Mode* and *Show Arc Mode*) and *Private Servers* pages, and a **log viewer** (paper icon) with *Copy log to clipboard*.
- Optional background picture (a nice default is built into both versions: into the .exe, and into the script as a text block at its end).
- Closing the manager while game clients are running (in **either** list: Official or Private Servers) asks first.
- Portable: no installer, nothing is written outside `%AppData%\ArcManager` (and the program's own folder if you choose).

---

## Quick start

### C++ version
1. Put `ArcManager.exe` anywhere (the desktop is fine - it does not leave files next to itself).
2. Double-click it and accept the administrator prompt (see *Security and privacy* for why).
3. **Important for Hidden Arc Mode:** make sure **Perfect World International is the first game in Arc's library list** (see *PWI must be the first game in Arc's library* below).
4. Type a username, password and (optionally) a note in the first row. Use **+ Add account** for more rows.
5. Press **SIGN IN**.
6. Optional: set the **Patcher Location** (gear icon > Basic) so the green **Update Client** button can open your game's launcher / patcher whenever the game needs an update.

### PowerShell version
1. Keep `ArcManager.ps1` and `StartArcManager.bat` together in one folder (the default background picture is built into the script).
2. Double-click `StartArcManager.bat` (it starts the script with the right options) and accept the administrator prompt.
3. Continue as above.

The first time, the manager looks for `Arc.exe` by itself (a running Arc, the list of installed programs, and the usual
`Program Files` folders on your drives). If it cannot find it, open the gear icon and set **Arc Location**.

---

## Updating the game client (manual)

**This manager depends on the game client being up to date, and it can NOT check that for you.** It never connects to the internet and never detects that the game has a new version. After a game update the old client can fail to start, or the game's launcher / patcher can keep asking to update. **You have to keep the client up to date yourself, by hand.**

The green **Update Client** button (top of the main window, half-way between the **PWI** title and the OFFICIAL / PRIVATE switch) makes that easy:

1. Set the **Patcher Location** once: gear icon > **Basic** (directly under *Arc Location*) for the official game, or gear icon > **Private Servers** (directly under *Command-Line Flags*) for private servers. Pick the game's launcher / patcher program (for example `launcher.exe` or `patcher.exe` in the game's folder) with **Browse...**. The **Command-line flags** box on the same line is filled in with `arc:1` (the patcher needs it to start Arc); you can change it if that ever changes.
2. Press **Update Client**. The button opens the patcher (with those flags) for the mode you are in (OFFICIAL or PRIVATE). You do not need to sign in first.
3. **The patcher is shown normally - never hidden, and nothing is clicked for you.** Use it yourself and let it finish updating the game.

Good to know:

- If the Patcher Location is empty or wrong, the button tells you where to set it.
- The button is greyed out while a sign-in is in progress, so the patcher you open yourself is never mixed up with the one a sign-in starts.
- Whenever the **Starting Game** pop-up is on screen it reminds you: *(Check for updates [manually] if this fails)*.
- A good habit: after a game update (or when a sign-in suddenly fails to reach the game), press **Update Client** first.

---

## Using the main window

| Control | What it does |
|---|---|
| **Update Client** (green button, top, between the **PWI** title and the OFFICIAL / PRIVATE switch) | Opens the game's launcher / patcher (see *Updating the game client (manual)*) so you can update the game client yourself. Works without signing in. The location is set with **Patcher Location** in the settings, separately for OFFICIAL and PRIVATE. Greyed out while a sign-in is in progress. |
| **OFFICIAL Servers / PRIVATE Servers** switch | At the top of the window. OFFICIAL Servers = the game through Arc (the default). PRIVATE Servers = private servers, see below. Each mode has its own account list, and the window title shows the mode ("PWI Account Manager - Official Servers" / "- Private Servers"). The manager opens in the mode it was closed in. |
| **Drag handle** (three lines, far left of every row) | Press and hold the left mouse button on it and drag the row up or down: a blue line shows where the row will land, and the list scrolls by itself when you hold the mouse near its top or bottom edge. Let go to drop it (**Esc** while dragging cancels). The whole row (texts, running game client, status) moves with it and the new order is saved right away. **Keyboard:** press **Alt+Up** or **Alt+Down** while the cursor is in any box of a row to move that row one place. The handle is greyed out while a sign-in is in progress, and when there is only one row. |
| **Minus button** (right of the drag handle) | Deletes that account. It is grey and turns red when you point at it. **Click** = delete, after a confirmation that shows the username and note. **Shift+click** = delete without asking. **Control+click** = select the row (it turns red with a ring) so you can select several; then press **Alt+D** to delete them all (it asks once; **Esc** clears the selection). Press **Alt+A** to select **all** rows at once (rows that are busy are skipped), then **Alt+D**. A counter next to the buttons shows how many rows are selected. A deleted account is gone from the list immediately and the list is saved right away (`accounts.txt.bak` keeps the version from before). The minus is greyed out for an account whose game client is running, and for all rows while a sign-in is in progress. There is always at least one row: deleting the last one just empties it. Rows left completely empty are also removed when you close the manager. |
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
| **F1** | Opens this README (built into the program) in a window with the same size and position as the main window. Works from the main window, the settings window and the log window. |
| Closing the window | If game clients are running, in the shown list **or in the other one**, you are asked first. The clients keep running if you close the manager, and the next start recognises them again. |

Usernames, passwords and notes cannot contain **tabs or line breaks** (they would corrupt the accounts file); such text is refused with a message.

**Keyboard shortcuts**

| Keys | What it does |
|---|---|
| **F1** | Opens the built-in help (this README, shown as formatted Markdown). Esc closes it. |
| **Alt+A** | Selects ALL rows for deletion (rows whose game client is running are skipped; nothing works while a sign-in is in progress). |
| **Alt+D** | Deletes the selected rows (asks once). **Esc** clears the selection. |
| **Alt+Up** / **Alt+Down** | Moves the row that has the cursor up or down one place. |
| **Esc** | Cancels a drag, clears the row selection, or closes the settings / log / help window. |

---

## Settings

Open the **gear icon**. Changes take effect **immediately** after *SAVE CONFIGURATION* - no restart needed.
*LOAD DEFAULTS* only fills in the standard values; nothing is saved until you press Save.
*OPEN SETTINGS FOLDER* opens the folder with all of the program's files.

Settings that were dropped in a newer version (`PrivateStartDir`, `PrivateNoticeShown`, `LauncherGraceSeconds`, `GraceSeconds`, `CloseArcAt`) are removed from the file automatically. Everything is stored in a plain text file, `ArcManager.ini`, which you can also edit by hand (save it and restart the
manager). Comments in the file are kept when the program saves. Default values changed in a newer version only apply to a new settings file (or after *LOAD DEFAULTS* + Save); a settings file you already have keeps its saved values.

| Key | Default | Window label | Meaning |
|---|---|---|---|
| `ArcPath` | `C:\Program Files (x86)\Arc\Arc.exe` | Arc Location | Full path to Arc. The file **must be named `Arc.exe`**. |
| `PatcherPath` | `C:\Program Files (x86)\PWI_en\patcher\patcher.exe` | Patcher Location | **Basic page**, directly under *Arc Location* (entry field and **Browse...**; the flags box is on the same line). The game's launcher / patcher, opened by the **Update Client** button while OFFICIAL Servers is selected. Nothing else ever starts it. Greyed out while PRIVATE Servers is selected. |
| `WindowWidth`, `WindowHeight` | `1280`, `720` | Main Window | Size of the window's inside area in pixels (minimum 1040 x 420). |
| `RememberWindowSize` | `1` | Remember the Size When Closing | Saves the size when you close the manager. |
| `UseHiddenLogin` | `1` | Launcher Mode | **Basic page.** `1` = **Hidden Arc Mode** (default), `0` = **Show Arc Mode**. See *Launcher Modes and automation*. |
| `AutoFill` | `1` | Auto-Fill Username and Password | **Show Arc Mode only** (Hidden Arc Mode always types the login itself). Types the login into Arc's visible window. |
| `ClickArcPlay` | `1` | Auto-Click Play (Arc) | **Show Arc Mode only.** After auto-fill has typed the login and pressed Enter, also clicks Arc's **Play** button for you. Needs *Auto-fill* and *Press Enter after the password*. Hidden Arc Mode always clicks Play. |
| `ClickPatcherStart` | `1` | Auto-Click Start (Launcher/Patcher) | **Show Arc Mode only.** Once the launcher / patcher shows up, clicks its **Start** button (retrying until it succeeds) until the game client opens. **Hidden Arc Mode always clicks Start.** |
| `PopupKey` | `enter` | Key for the Pop-Up | **Advanced page, "Login pop-up and typing".** The key (`enter` or `escape`) that clears any pop-ups before Arc's login page. |
| `EntersBefore` | `0` | Enter/Escape Presses for the Pop-Up | How many times that key is pressed before the username is typed (`0` = none). |
| `PauseAfterPopupMs` | `1500` | Pause After the Pop-Up (ms) | Pause after those presses (only used when the count is above 0). |
| `ClearBackspaces` | `0` | Backspaces to Clear a Box | Backspaces pressed before typing the username and the password, to remove old text (`0` = none). |
| `EnterAfterPassword` | `1` | Press Enter After the Password | Presses Enter after the password to log in. Turn it off if you want to press it yourself. |
| `ConfirmStop` | `0` | Ask Before Stopping a Game Client | Confirmation before STOP. |
| `KillArcOnStart` | `1` | Close Running Arc at Start / Sign-In | Closes a leftover Arc when the manager starts and before each sign-in. |
| `RenameGameWindows` | `1` | Rename Game Windows to Notes | Sets each game window's title to its row's note. |
| `ShowStorageHint` | `0` | Show Plain-Text Storage Notice | Shows a note at the bottom of the window that accounts are stored as plain text. |
| `DebugLog` | `1` | Debug / Logs | Writes the log (never containing passwords). |
| `BackgroundImage` | *(empty)* | Background Image Location | Your own picture. Empty = a `background.*` file next to the program, or the built-in image. |
| `BackgroundMode` | `fill` | Mode | `fill`, `fit`, `stretch`, `tile` or `center`. |
| `BackgroundDim` | `0.5` | Darkness | `0` = picture as it is, `1` = black. |
| `UsernameFocusTabs` | `1` | Tabs Before Username Box | Tab presses sent first, to reach the username box. *(Advanced)* |
| `FieldSeparatorTabs` | `1` | Tabs Between the Two Boxes | Tab presses between username and password. *(Advanced)* |
| `LoginDelayMs` | `3000` | Login Delay (milliseconds) | Wait after Arc's login window appears, before typing. *(Advanced)* |
| `MinWaitSeconds` | `6` | Minimum Wait (seconds) | Never type sooner than this after starting Arc. *(Advanced)* |
| `WindowTimeoutSeconds` | `40` | Login Window Timeout | Give up waiting for the login window. *(Advanced)* |
| `TimeoutSeconds` | `300` | Give Up After | Give up waiting for the game client. *(Advanced > Show Arc Mode)* |
| `PendingTimeoutSeconds` | `600` | Game Wait After Close | How long to keep watching for the client after Arc was closed early. *(Advanced > Shared Settings)* |
| `RenameDurationSeconds` | `180` | Rename Duration | The game opens and closes windows while loading, so its windows are re-checked every second for this long after the client starts. Raise it on a slow computer. *(Advanced > Shared Settings)* |
| `StatusResetSeconds` | `30` | Reset Status After | Seconds until *Stopped / Cancelled / Timed out* return to *Idle* (`0` = never). *(Advanced > Shared Settings)* |
| `PatcherStartPollIntervalMs` | `2000` | Click Start Every (ms) | How often **Start** is clicked while waiting for the launcher / patcher to finish and launch the game. *(Advanced > Shared Settings)* |
| `PatcherStartTimeoutSeconds` | `180` | Give Up Clicking After (sec) | Stop clicking **Start** after this long. *(Advanced > Shared Settings)* |
| *(the labels in the PowerShell version are worded a little differently)* | | | Applies to the five `Hidden...` rows below. |
| `HiddenKeyDelayMs`, `HiddenCharDelayMs`, `HiddenPostTabDelayMs`, `HiddenPostFieldDelayMs`, `HiddenHideSettleDelayMs` | `20` each | Key Press Delay, Typed Character Delay, Pause After Tab / a Field / Hiding Sign In (ms) | Tiny pauses used while the login is typed into the off-screen Arc. *(Advanced > Hidden Arc Mode)* |
| `HiddenSignInTimeoutSeconds`, `HiddenSignInPollIntervalMs` | `300`, `1000` | Sign In Window Timeout (sec), Poll Interval (ms) | How long to wait for Arc's Sign In window, and how often to check for it. *(Advanced > Hidden Arc Mode)* |
| `HiddenMainWindowInitialDelayMs`, `HiddenMainWindowTimeoutSeconds`, `HiddenMainWindowPollIntervalMs` | `1600`, `60`, `1000` | Initial Delay Before Play (ms), Main Window Timeout (sec), Poll Interval (ms) | After the login is submitted: how long to wait before looking for Arc's real main window (too soon can find an unfinished placeholder), how long to keep looking, and how often. *(Advanced > Hidden Arc Mode)* |
| `HiddenPatcherWaitTimeoutSeconds`, `HiddenPatcherWaitPollIntervalMs` | `120`, `1000` | Patcher Wait Timeout (sec), Poll Interval (ms) | After Play is clicked: how long to wait for the launcher / patcher to start, and how often to check. *(Advanced > Hidden Arc Mode)* |
| `PrivateMode` | `0` | *(the switch on the main window)* | `1` = private server mode. |
| `PrivateClientPath` | *(empty)* | Client or Launcher Location | **Private Servers page.** The program to start (the game client, or a launcher / patcher). |
| `PrivateFlags` | `game:cpw nocheck startbypatcher console:1` | Command-Line Flags | Passed exactly as typed. The usual flags are filled in; change them for a server that needs different ones (copy the example above to get them back). |
| `PatcherFlags` | `arc:1` | Command-Line Flags (next to Patcher Location) | **Basic page.** Passed to the patcher exactly as typed. Started by itself, the patcher would not start Arc; `arc:1` makes it do so. Change it here if that ever changes (empty = no flags). |
| `PrivatePatcherFlags` | *(empty)* | Command-Line Flags (next to Patcher Location) | **Private Servers page.** The same for the private server's patcher. Empty by default (private servers do not use Arc); fill it in only if that server's patcher needs flags. |
| `PrivatePatcherPath` | *(empty)* | Patcher Location | **Private Servers page**, directly under *Command-Line Flags* (entry field and **Browse...**). The private server's launcher / patcher, opened by the **Update Client** button while PRIVATE Servers is selected. |
| `PrivateShowWarning` | `1` | Show a Warning When Switching to Private Servers | The warning is shown every time you switch to Private Servers (never at start-up). `0` = never show it. |
| `PrivateProcessNames` | `elementclient.exe,elementclient_64.exe` | Process Name(s) to Wait for | The real game client, separated by commas. |
| `PrivateWindowWaitSeconds` | `90` | Wait for the Game Window | Give up waiting for the client and its window after this long. |
| `PrivateFirstKeyDelaySeconds` | `6` | Wait Before the First Key | Pause after the window appears. |
| `PrivatePopupKey` | `enter` | Key for the Pop-Up | The key that clears the pop-up message some clients show before the login page: `enter` or `escape` (radio buttons on the Private Servers page). |
| `PrivateEntersBefore` | `1` | Enter/Escape Presses for the Pop-Up | How many times that key is pressed (`0` = none). |
| `PrivatePauseAfterPopupMs` | `1500` | Pause After the Pop-Up | Milliseconds. |
| `PrivatePauseStepMs` | `400` | Pause Between Steps | Milliseconds. |
| `PrivateTabs` | `1` | Tabs Between the Two Boxes | Tab presses between username and password. |
| `PrivateClearBackspaces` | `0` | Backspaces to Clear a Box | Removes old text (for example a remembered username) before typing. `0` = none. |
| `PrivateEnterAfterPassword` | `1` | Press Enter After the Password | Logs in. |
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

## Launcher Modes and automation

**Launcher Mode** (Basic page) decides how the manager gets through Arc's login. Either way Arc runs and signs in for real - the manager never bypasses Arc's own login.

| Mode | What happens |
|---|---|
| **Hidden Arc Mode** (default) | Arc's window is hidden throughout the login process (it may flicker very briefly on your screen). The manager types the login, clicks **Play**, and closes Arc the instant the launcher / patcher is detected. **The game's launcher / patcher window is hidden too** (kept off-screen while **Start** is clicked for you, until the game client starts); there is no separate setting for this. A pop-up reading **Obtaining ARC / PWI TOKEN Now** is shown meanwhile, and disappears the moment the launcher / patcher is detected. |
| **Show Arc Mode** | Arc's window is shown, and so is the launcher / patcher (it is never hidden in this mode). With *Auto-fill* on, the login is typed into it (the old pop-up method; its timing is on *Advanced > Show Arc Mode*). With *Auto-click Play (arc)* also on, **Play** is clicked for you too; otherwise you click it yourself. |

**Starting the game.** In Hidden Arc Mode (always) or in Show Arc Mode with *Auto-click Start (launcher/patcher)* on, the manager keeps clicking **Start** on the launcher / patcher until it succeeds, then waits for the game client. A second pop-up, **Starting Game**, is shown meanwhile and closes the instant the game client (`elementclient.exe` or `elementclient_64.exe`) is detected (or on CANCEL / timeout); at its bottom it shows *(Check for updates [manually] if this fails)* - if the start fails, the game client may simply be out of date (see *Updating the game client (manual)*). With the option off, press **Start** yourself; the manager still recognises the game client. The moment the game client starts, the launcher / patcher that sign-in started is **force-closed** (it can otherwise linger for a long time); this has no setting. It is skipped while another account is still signing in or waiting for its client, so that account's launcher is never closed by mistake.

**Advanced page sub-tabs**

- **Shared Settings** (opens first): settings used by both modes - *Game wait after close*, *Rename duration*, *Reset status after*, *Click Start every*, *Give up clicking after*.
- **Hidden Arc Mode**: the timing of the hidden sign-in. Greyed out while Show Arc Mode is selected.
- **Show Arc Mode**: the timing of the visible auto-fill method, and *Give up after*. Greyed out while Hidden Arc Mode is selected.

### PWI must be the first game in Arc's library

The automatic **Play** click (always in Hidden Arc Mode, and in Show Arc Mode when *Auto-click Play (arc)* is on) is sent to a fixed spot on Arc's main window: the **first game in Arc's library list**. If **Perfect World International is not the first game there, a different Arc game may be started instead.** This matters if you also play other games through Arc.

Recommended: in Arc's library, **sort by "last played"** (if your version of Arc offers it) and make sure **PWI was the last game you played before using the manager**. After that the manager keeps it that way by itself, because every game it starts is PWI - until you start another game from Arc, which moves that game to the top. If in doubt, open Arc, check that PWI is first, and close it again. Show Arc Mode without *Auto-click Play (arc)* does not have this limit, since you click Play yourself.

Clicks are sent to the windows as messages, so they work even when a window is hidden or in the background. They use fixed positions measured on Arc's main window and on the game patcher (`984 x 744`); if a future Arc or patcher update moves its buttons, the automatic clicks may miss and you can simply click the button yourself (turn the matching *Auto-click* option off if it gets in the way).

---

## Private Servers

Many private servers do not use Arc: the game client logs in directly. Switch the manager to **PRIVATE Servers** (the switch at the
top of the main window) and it works as an account manager for them. The manager opens in whichever mode it was closed in. The official mode is not affected in any way.

**Set it up** (gear icon > **Private Servers**):

1. **Client or launcher location**: the program to start. Usually the server's game client (`elementclient.exe`), but it can
   also be a launcher or patcher. It is started with administrator rights, in its own folder.
2. **Command-Line Flags**: passed exactly as typed. The usual ones (`game:cpw nocheck startbypatcher console:1`) are filled in; change them if your server needs different flags. Never put your password here.
3. **Patcher Location** (optional, with its own **Command-Line Flags** box on the same line, empty by default): the private server's launcher / patcher. The green **Update Client** button opens it while PRIVATE Servers is selected, so you can update that server's client by hand. It is never started by SIGN IN.
4. **Process name(s)**: the real game client. If you start a launcher, the manager waits until one of these processes appears.
5. The **typing sequence**: Enter *or Escape* for the start-up pop-up (you choose the key, and how many presses; `0` if your client has none), a pause, the username, a
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
  (Turn on *Show Plain-Text Storage Notice* in the settings to be reminded at the bottom of the window.) The version number is shown at the bottom right of the main window.
- **No network access.** The program never connects to the internet. It does not send or upload anything, and it never checks whether the game client (or this program) is up to date. The **Update Client** button only opens the game's own patcher, which does its own downloading.
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
3. *Typing goes to the wrong box or too early* (Show Arc Mode): **Advanced > Show Arc Mode** - raise **Login delay**, or change the **Tabs** values. If Arc shows a message before its login page, use *Login pop-up and typing* on the same page.
4. *Game windows are not renamed*: check *Rename game windows to Notes*, that the row has a note, and raise
   **Rename duration** on a slow computer.
5. *The game will not start, or asks to be updated, after a game update*: the game client is out of date and updates are never detected automatically. Press the green **Update Client** button (set **Patcher Location** first if it asks) and let the patcher finish, then sign in again.
6. *Update Client says the Patcher Location is not set*: gear icon > Basic > **Patcher Location** (OFFICIAL) or gear icon > Private Servers > **Patcher Location** (PRIVATE), then **Browse...**.
7. *A different Arc game starts*: PWI is not the first game in Arc's library list - see *PWI must be the first game in Arc's library*.
8. *Hidden Arc Mode does not get past a step* (or a pop-up stays): see the log; raise the matching timeout on **Advanced > Hidden Arc Mode**, or switch to **Show Arc Mode** on the Basic page. *A launcher / patcher is invisible and seems stuck* (Hidden Arc Mode hides it): press **CANCEL** on the row (that closes it), or switch to **Show Arc Mode** to see what it is asking. *Start is not clicked*: check *Auto-click Start*, and raise **Give up clicking after** on **Advanced > Shared Settings**.
9. *Accounts file damaged*: the previous version is `accounts.txt.bak` in the same folder.
10. *Start over*: close the manager and delete `ArcManager.ini` (settings) - it is recreated with the defaults.

---

## Building from source

The C++ program is `main.cpp` plus a resource script and the small built-in Markdown viewer in `mdview\` (used for the F1 help).

**Tools:** [w64devkit](https://github.com/skeeto/w64devkit) **x86 (32-bit)** kit, so the result runs on every Windows
from XP to 11. Check with `gcc -dumpmachine` (it should say `i686-w64-mingw32`).

1. Put `w64devkit\bin` on your PATH (or open its terminal) and go to the project folder.
2. Run **`build.bat`** (or `make`). The first build also compiles the Markdown parser (about 40 small C files), so it takes a little longer; later builds are quick.
3. `ArcManager.exe` is created (in `bin\` when you use `build.bat`). Optionally open the folder as a project in the Eclipse C/C++ IDE.

Files: `main.cpp` (program), `ArcManager.rc` (icon, built-in background, **this README** as the F1 help, version information), `resource.h`
(ids **and version text**), `ArcManager.manifest` (administrator + visual styles), `res\` (icon and default background), `mdview\` (the Markdown viewer: `mdview.cpp`, `layout.cpp`, and the `cmark-gfm\` parser sources with its license).

### The built-in help (F1)
This `README.md` is compiled into `ArcManager.exe` as a resource, so **edit `README.md`, then rebuild** (the Makefile notices the change) and F1 shows the new text, nicely formatted (headings, lists, tables, code, links; you can select and copy text, and **Ctrl+A** / **Ctrl+C** work). Keep it plain ASCII (no curly quotes) and without the two characters `#` followed by `>` together, because the PowerShell version keeps a copy of the README in a comment block at the very end of `ArcManager.ps1` (between two README marker lines, right below the background picture block); after changing the README, replace the text between those two marker lines with the new README text.

### Changing the version information
Edit the clearly marked block at the top of **`resource.h`** (file description, product name, version text, numeric
version, copyright) and rebuild. The text is shown in *Properties > Details* of `ArcManager.exe`, in the log and at the
bottom right of the main window (the settings window shows the copyright). For the PowerShell version change `$AppVersion` near the top of `ArcManager.ps1`.

---

## Project layout

```
ArcManager.exe  (built)        C++ version
  main.cpp  ArcManager.rc  resource.h  ArcManager.manifest  build.bat  Makefile  res\  README.md (compiled into the .exe)
  mdview\  (built-in Markdown viewer for F1: mdview.cpp/.h, layout.cpp/.h, cmark-gfm\)
  (The PowerShell version has no such folder: it turns the same README into formatted rich text itself.)
ArcManager.ps1  StartArcManager.bat                           PowerShell version (the default background and this README are inside the script)
README.md
```

## Credits and license

Made by **Sparc343**.

**License:** *to be decided.*

The F1 help viewer uses the layout engine of **GhostReader** (by Sparc343) and the **cmark-gfm** Markdown parser
(Copyright (c) 2014, John MacFarlane and contributors; BSD 2-Clause license, see `mdview\cmark-gfm\COPYING`).
