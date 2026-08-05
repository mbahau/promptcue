# PromptCue

> **If you are an AI coding agent** helping develop this project, read
> [`App/AGENT_CONTEXT.md`](App/AGENT_CONTEXT.md) first — it has the full
> architecture, bug history, and known-limitations context you need before
> making changes.

A small PowerShell app for running AI agent demos smoothly, without live-typing
each prompt (which is slow and error-prone in front of an audience). It cues
up each prompt for you — press a key, it's delivered.

## What it does

You save your demo prompts into a **named project** ahead of time, separated
by a `---` line. Each prompt can span multiple lines. During the demo, you
click once into the target chat box, then just
press **F2** whenever you're ready — the app delivers the next prompt directly
into the chat box for you, either as an instant paste or simulated as if you
were typing it live (character by character), your choice. Press **F3** to go
back and redeliver the previous prompt if a question interrupts your flow. You
don't touch the app window again, don't copy/paste manually, and don't retype
anything.

F2/F3 work as **global hotkeys** — they fire no matter which window is
focused, as long as the app is running in the background. That's what lets
you stay in the target chat the whole time.

Projects are saved to disk, so:
- Reopening the app later shows the same prompt list again — nothing is lost.
- You can keep **multiple projects** (e.g. one per demo/client) and switch
  between them from a dropdown.
- Your progress (which prompt you're currently on) is remembered per project,
  so if you close the app mid-demo and reopen it, it picks up where you left
  off.

## Folder structure

```
AI Demo Prompt Copy App/
├── Run PromptCue.vbs   <- double-click this to launch
├── README.md           <- you are here
└── App/                <- everything else lives here, no need to touch it
    ├── PromptCue.ps1    <- the app itself
    ├── config.json      <- remembers your last-used project
    └── Projects/        <- your saved prompt sets (one JSON file each)
```

## How to use it

1. Run the app: double-click **`Run PromptCue.vbs`** at the top of this
   folder. (No command line needed — this launches the app silently in the
   background.)

   If you ever need to run it manually instead, you can use:

   ```
   powershell -ExecutionPolicy Bypass -File "App\PromptCue.ps1"
   ```

2. **Create/save a project:**
   - Type a project name into the **Project** box at the top (e.g.
     `Client A Demo`).
   - Paste all your prompts into the big text box below. **Put a line with
     just `---` between prompts.** A prompt can span multiple lines - it's
     everything between one `---` and the next (or the start/end of the box).
     For example:
     ```
     Hi, I want to do the NPI Planning for item ChocoDream 31% Cocoa
     Almond Bar 3.6 oz
     ---
     Now show me the demand forecast for the same item
     ---
     What if we increase the price by 5%?
     ```
     That's 3 prompts, the first one spanning two lines.
   - Click **Save**. This creates the project and remembers it for next time.

3. **Load an existing project** (including automatically on next launch):
   - Pick it from the **Project** dropdown and click **Load**. Its prompts
     fill the text box and your last progress position is restored.
   - The app also auto-loads whichever project you used most recently when
     it starts up.

4. **Switch between projects:** just pick a different one from the dropdown
   and click **Load**. Save one project before loading another if you've
   made unsaved edits.

5. **Delete a project:** select it in the dropdown and click **Delete**
   (asks for confirmation first).

6. **Choose delivery style:** the **"Simulate typing"** checkbox controls how
   the prompt appears in the target chat box:
   - **Checked** (default): the prompt is typed to look like a real person
     typing it — variable speed per keystroke, a pause after spaces, a
     longer pause after punctuation, occasional "thinking" pauses every few
     words, longer/unfamiliar words typed a bit more carefully, and
     occasionally a letter gets doubled and self-corrected with a backspace
     (like a real typo).
   - **Unchecked**: the prompt is pasted instantly (old behavior) — use this
     if simulated typing ever misbehaves in the target chat box (see notes
     below).

   The **"Typo frequency"** slider (0-80%) sets, per letter typed, the
   chance of a doubled-letter/backspace self-correction. Default is 3%
   (occasional, subtle). As you raise it, typos show up more often and
   across more words — by the high end of the scale it becomes a very
   fumbly typist. Set it to 0% to disable typos entirely.

7. **Run the demo:**
   - Click into the **target chat input box** (not the app window) so it has
     keyboard focus.
   - Press **F2** → the next prompt is delivered directly into the target chat
     box (typed or pasted, per the checkbox above). Hit **Enter** to submit
     it (the app does not auto-submit, so you stay in control of pacing).
   - Press **F2** again for the next prompt, and so on.
   - Press **F3** to redeliver the previous prompt again if you need to
     revisit it.
   - While a prompt is being "typed" (simulate mode), F2/F3 presses are
     ignored until it finishes — wait for it to complete before advancing.
   - The status label (`Prompt 3 / 12`) and yellow preview box show where
     you are — glance at the app if you lose track.
   - **Jump to any prompt out of order:** type the prompt number into the
     **"Jump to #"** box and click **Go**. This only repositions — it does
     **not** paste or type anything by itself. It just makes that prompt
     "next up," shown in the preview box. Press **F2** (or **F3**) as usual
     when you're ready to actually deliver it. Useful if a question sends
     you out of sequence and you want to skip ahead or replay an earlier one
     without stepping through everything in between.

8. If you edit the prompt list in the text box, **F2/F3 keep delivering the
   old list until you click Save** — Save is the only action that both
   persists your edits to disk and makes them the active list F2/F3 use.
   The **Reset** button does not read the text box at all; it only moves you
   back to prompt 0 on whatever list is currently active.

## Notes / limitations

- Prompts are separated by a `---` line, not by every newline, so a prompt
  can freely span multiple lines.
- When **simulating typing**, a line break inside a prompt is sent as
  **Shift+Enter** (the common "new line without submitting" shortcut in most
  chat boxes). If the target chat box uses a different shortcut for that, a
  multi-line prompt might submit early or not break the line correctly —
  test one multi-line prompt once before relying on it live. Instant paste
  mode isn't affected by this; it pastes the whole block as-is.
- F2/F3 are global while this app is running — avoid using F2/F3 for anything
  else (e.g. Explorer's rename) during the demo, since this app will
  intercept them system-wide.
- The app must stay running (even minimized) for the hotkeys to work. Closing
  it unregisters F2/F3, but your project data and progress are saved to disk
  automatically, so nothing is lost.
- Projects are stored as JSON files in `App\Projects`. Deleting a project
  deletes its file permanently.
- Simulated typing sends real keystrokes one at a time into the target chat box.
  If the chat box has autocomplete, live validation, or similar behavior
  that reacts to fast keystrokes, it could occasionally misbehave — test it
  once against the actual target chat box before using it live. If it's ever
  unreliable, uncheck "Simulate typing" to fall back to instant paste.
- Requires Windows PowerShell (built into Windows, no installation needed).
