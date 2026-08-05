# PromptCue — Agent Context

Read this before making changes to `PromptCue.ps1`. It captures architecture
decisions, past bugs, and behavior that isn't obvious from the code alone.

## What this app is

A single-file Windows PowerShell + WinForms app for running live software
demos from a prepared list of prompts, without live-typing each one or
alt-tabbing to copy/paste. Press **F2** (a global hotkey — works no matter
which window has focus) to deliver the next prompt directly into whatever
chat/input box currently has keyboard focus. **F3** redelivers the previous
one. The app window itself never needs focus during the actual demo.

## Architecture

- Single script: `App/PromptCue.ps1`. No external dependencies beyond
  built-in .NET (`System.Windows.Forms`, `System.Drawing`).
- A C# type (`HotkeyForm`, defined via `Add-Type` at the top of the script)
  subclasses `Form` to P/Invoke `RegisterHotKey`/`UnregisterHotKey` and
  override `WndProc` to catch `WM_HOTKEY` — this is what makes F2/F3 global
  instead of only working while the app window has focus.
- Simulated typing uses `SendInput` with `KEYEVENTF_UNICODE` (raw Unicode
  injection), **not** `SendKeys`. `SendKeys` goes through virtual-key codes
  + Shift and combines with the active keyboard layout to produce dead-key
  diacritic composition (e.g. typing "Hi" became "Ḥi") — `SendInput` bypasses
  the keyboard layout entirely and avoids this.
- Newlines *inside* a prompt, when simulating typing, are sent as
  **Shift+Enter** (`SendKeyCombo`), on the assumption the target chat box
  uses that for "newline without submitting." This is unverified against any
  specific target UI and should be tested once per target before relying on
  it live.
- Projects (named prompt sets) are stored as one JSON file per project under
  `App/Projects/`, `{ Prompts: [...], Index: N }`. `App/config.json` just
  remembers the last-used project name for auto-load on startup.

## Prompt splitting — why it's line-based, not regex-split

`Split-PromptBlocks` splits the textbox content on a line containing only
`---`, and is deliberately implemented by iterating lines (not
`[regex]::Split`). This is load-bearing, not a style choice:

An earlier regex-split implementation (`[regex]::Split($text, '(?m)^[
\t]*---[ \t]*$')`) left the newline adjacent to the delimiter line attached
to whichever block it belonged to, in an ambiguous way. Since loading a
project re-joins blocks with `"\r\n---\r\n"` for display, and saving
re-splits that same text, each Load → edit-or-not → Save round trip added
one extra blank line at every prompt boundary — compounding indefinitely
across repeated save/load cycles, even with zero user edits. The line-based
version consumes exactly the delimiter line and nothing else, making the
round trip idempotent (load-then-save-with-no-edits changes nothing).

If you ever touch this function, verify round-trip idempotence: take a
multi-prompt textbox, Save, Load, Save again, and diff the resulting JSON —
it must be byte-identical.

## Save vs. the "active list" the hotkeys use

`$script:prompts` is the in-memory list F2/F3 actually deliver from. It is
**only** updated by `Reparse-PromptsKeepPosition`, called from the Save
button handler. Editing the textbox alone does nothing to it — by design,
per explicit user preference: F2/F3 must never pick up unsaved edits. The
`Reset` button (originally called "Set Active List", see below) does not
call this function; it only resets `$script:index` to 0 on whatever list is
currently active.

Do not reintroduce a path that updates `$script:prompts` from the textbox
without going through Save — that was the previous design and was
explicitly rejected.

## Naming history (so you don't reintroduce old names)

- App was originally "Prompt Cycler," renamed to **PromptCue**.
- The button that re-parses the textbox went through several names before
  being removed entirely: `Apply List` → `Refresh List` → `Set Active List`
  → (behavior removed, button repurposed as) `Reset`.

## Known limitations / unverified assumptions

- Shift+Enter-as-newline (see above) is assumed, not confirmed, for any
  given target chat UI.
- Simulated typing sends real per-character keystrokes; untested against
  autocomplete or input validation that reacts to rapid keystrokes in a
  specific target UI. The "Simulate typing" checkbox can be unchecked to
  fall back to instant clipboard paste if it ever misbehaves.
- F2/F3 are global system-wide while the app runs, which means they also
  intercept those keys everywhere else (e.g. Explorer's F2-rename) until the
  app is closed.
- Multiple stale instances of the app are easy to accumulate from repeated
  test launches, since editing the `.ps1` on disk has no effect on an
  already-running process (PowerShell parses the whole script once at
  launch). If behavior seems "not updated" after a code change, check for
  and close duplicate PromptCue windows/processes before assuming a code
  bug.

## Distribution & update mechanism

- This repo (`App/PromptCue.ps1`, `README.md`, `Run PromptCue.vbs`,
  `version.txt`) is the **distribution copy** — what an end user downloads
  and runs standalone, anywhere on their PC. It intentionally mirrors the
  same `App/` folder structure as the maintainer's local working copy.
- `version.txt` at the repo root holds the current version string. The app
  has a matching `$AppVersion` variable and a `Check-ForUpdate` function
  that runs at startup: it fetches `version.txt` from this repo's raw GitHub
  URL, and if it doesn't match `$AppVersion`, offers to download the latest
  `App/PromptCue.ps1` over itself. This check is wrapped in try/catch and
  fails silently (no internet, repo unreachable, etc.) — it must never block
  the app from opening.
- **To ship an update**: bump `$AppVersion` in `PromptCue.ps1`, bump
  `version.txt` to match, commit, push. Keep those two version strings in
  sync — the check is a simple string inequality, not semver-aware.
- No personal/user-specific data (`App/config.json`, `App/Projects/*.json`)
  is ever pushed here — those are per-user and stay local to whoever's
  running the app.
