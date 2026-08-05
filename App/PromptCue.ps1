Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Pure logic (prompt splitting, project file I/O, version comparison) lives in
# a separate file so it can be unit-tested without the GUI - see
# Tests/PromptCue.Tests.ps1 and App/AGENT_CONTEXT.md.
. (Join-Path $PSScriptRoot "PromptCue.Logic.ps1")

# A Form subclass that can register a system-wide (global) hotkey.
# Global means it fires even when a different window (e.g. a chat app) has focus.
Add-Type -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class HotkeyForm : Form
{
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public const int WM_HOTKEY = 0x0312;

    public event EventHandler NextHotkeyPressed;
    public event EventHandler BackHotkeyPressed;

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            int id = m.WParam.ToInt32();
            if (id == 1 && NextHotkeyPressed != null) NextHotkeyPressed(this, EventArgs.Empty);
            if (id == 2 && BackHotkeyPressed != null) BackHotkeyPressed(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }

    // --- Unicode key injection: types the exact character, bypassing the
    // keyboard layout entirely so no dead-key/diacritic composition can happen. ---
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public short wVk;
        public short wScan;
        public int dwFlags;
        public int time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public KEYBDINPUT ki;
        public long padding; // pad union to match native INPUT size on x64
    }

    private const int INPUT_KEYBOARD = 1;
    private const int KEYEVENTF_UNICODE = 0x0004;
    private const int KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void SendUnicodeChar(char c)
    {
        INPUT down = new INPUT();
        down.type = INPUT_KEYBOARD;
        down.ki.wVk = 0;
        down.ki.wScan = (short)c;
        down.ki.dwFlags = KEYEVENTF_UNICODE;

        INPUT up = down;
        up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

        INPUT[] inputs = new INPUT[] { down, up };
        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void SendVirtualKey(byte vk)
    {
        INPUT down = new INPUT();
        down.type = INPUT_KEYBOARD;
        down.ki.wVk = vk;
        down.ki.wScan = 0;
        down.ki.dwFlags = 0;

        INPUT up = down;
        up.ki.dwFlags = KEYEVENTF_KEYUP;

        INPUT[] inputs = new INPUT[] { down, up };
        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static INPUT MakeKeyInput(byte vk, bool keyUp)
    {
        INPUT inp = new INPUT();
        inp.type = INPUT_KEYBOARD;
        inp.ki.wVk = vk;
        inp.ki.wScan = 0;
        inp.ki.dwFlags = keyUp ? KEYEVENTF_KEYUP : 0;
        return inp;
    }

    // Holds modifierVk down, taps vk, releases modifierVk - e.g. Shift+Enter
    // to insert a line break inside a chat box without submitting it.
    public static void SendKeyCombo(byte modifierVk, byte vk)
    {
        INPUT[] inputs = new INPUT[]
        {
            MakeKeyInput(modifierVk, false),
            MakeKeyInput(vk, false),
            MakeKeyInput(vk, true),
            MakeKeyInput(modifierVk, true)
        };
        SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing

# ---------- storage setup ----------
$scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projDir    = Join-Path $scriptDir "Projects"
$configPath = Join-Path $scriptDir "config.json"
if (-not (Test-Path $projDir)) { New-Item -ItemType Directory -Path $projDir | Out-Null }

# ---------- update check ----------
$AppVersion = "1.2"
$UpdateVersionUrl = "https://raw.githubusercontent.com/mbahau/promptcue/main/App/version.txt"
$UpdateNotesUrl   = "https://raw.githubusercontent.com/mbahau/promptcue/main/App/release-notes.txt"
$UpdateScriptUrl  = "https://raw.githubusercontent.com/mbahau/promptcue/main/App/PromptCue.ps1"

function Check-ForUpdate {
    # Best-effort, silent on any failure (no internet, GitHub unreachable,
    # etc.) - an update check must never block the app from opening.
    try {
        $remoteVersion = (Invoke-RestMethod -Uri $UpdateVersionUrl -TimeoutSec 5).Trim()
        if (Test-UpdateAvailable -CurrentVersion $AppVersion -RemoteVersion $remoteVersion) {
            # Notes are a nice-to-have on top of the version check above - if
            # release-notes.txt is missing or unreachable, still show the
            # plain update prompt rather than skipping the update entirely.
            $notesText = ""
            try {
                $notes = (Invoke-RestMethod -Uri $UpdateNotesUrl -TimeoutSec 5).Trim()
                if ($notes) { $notesText = "`n`nWhat's new:`n$notes" }
            } catch { }

            $resp = [System.Windows.Forms.MessageBox]::Show(
                "A new version of PromptCue is available ($AppVersion -> $remoteVersion).$notesText`n`nUpdate now?",
                "PromptCue Update", "YesNo")
            if ($resp -eq "Yes") {
                $selfPath = $PSCommandPath
                Invoke-WebRequest -Uri $UpdateScriptUrl -OutFile $selfPath -UseBasicParsing -TimeoutSec 15
                [System.Windows.Forms.MessageBox]::Show(
                    "Updated to $remoteVersion. Close and reopen PromptCue to use the new version.",
                    "PromptCue Update") | Out-Null
            }
        }
    } catch {
        # No internet / repo unreachable / etc. - ignore and continue.
    }
}

Check-ForUpdate

function Get-ProjectNames {
    Get-ChildItem -Path $projDir -Filter "*.json" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName } | Sort-Object
}

function Seed-ExampleProjectIfNone {
    # Only seeds on a genuinely fresh install (no project files yet at all) -
    # never overwrites or competes with anything the user has already saved.
    if ((Get-ProjectNames).Count -gt 0) { return }
    $examplePrompts = @(
        "1. Open a chat window - or just Notepad, or any text editor - where you want to test this app.",
        "2. Press F2 to paste this next prompt into that window.",
        "3. Press F3 to paste the previous prompt again.",
        "4. Don't forget to minimize this app while demoing."
    )
    Save-ProjectFile -name "Example My Prompts" -prompts $examplePrompts -index 0
}

# Save-ProjectFile / Load-ProjectFile now live in PromptCue.Logic.ps1 (dot-sourced above).

# Config is a flat key/value file (LastProject, WalkthroughShown, ...). Reads
# merge onto a fresh hashtable and writes go through the same merge so one
# setter (e.g. Save-LastProject) never clobbers a key another setter wrote.
function Get-ConfigTable {
    $table = @{}
    if (Test-Path $configPath) {
        try {
            $json = Get-Content -Path $configPath -Raw | ConvertFrom-Json
            $json.PSObject.Properties | ForEach-Object { $table[$_.Name] = $_.Value }
        } catch { }
    }
    return $table
}

function Set-ConfigValue([string]$key, $value) {
    $table = Get-ConfigTable
    $table[$key] = $value
    $table | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Save-LastProject([string]$name) {
    Set-ConfigValue -key "LastProject" -value $name
}

function Get-LastProject {
    (Get-ConfigTable)["LastProject"]
}

function Get-WalkthroughShown {
    [bool](Get-ConfigTable)["WalkthroughShown"]
}

function Save-WalkthroughShown {
    Set-ConfigValue -key "WalkthroughShown" -value $true
}

# ---------- UI ----------
$form = New-Object HotkeyForm
$form.Text = "PromptCue"
$form.Size = New-Object System.Drawing.Size(600, 730)
$form.MinimumSize = New-Object System.Drawing.Size(500, 600)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

$lblProject = New-Object System.Windows.Forms.Label
$lblProject.Text = "Project:"
$lblProject.Location = New-Object System.Drawing.Point(10, 12)
$lblProject.Size = New-Object System.Drawing.Size(50, 20)
$form.Controls.Add($lblProject)

$cmbProject = New-Object System.Windows.Forms.ComboBox
$cmbProject.Location = New-Object System.Drawing.Point(65, 9)
$cmbProject.Size = New-Object System.Drawing.Size(220, 24)
$cmbProject.DropDownStyle = "DropDown"
$form.Controls.Add($cmbProject)

$btnLoadProject = New-Object System.Windows.Forms.Button
$btnLoadProject.Text = "Load"
$btnLoadProject.Location = New-Object System.Drawing.Point(290, 8)
$btnLoadProject.Size = New-Object System.Drawing.Size(60, 26)
$form.Controls.Add($btnLoadProject)

$btnSaveProject = New-Object System.Windows.Forms.Button
$btnSaveProject.Text = "Save"
$btnSaveProject.Location = New-Object System.Drawing.Point(355, 8)
$btnSaveProject.Size = New-Object System.Drawing.Size(60, 26)
$form.Controls.Add($btnSaveProject)

$btnDeleteProject = New-Object System.Windows.Forms.Button
$btnDeleteProject.Text = "Delete"
$btnDeleteProject.Location = New-Object System.Drawing.Point(420, 8)
$btnDeleteProject.Size = New-Object System.Drawing.Size(60, 26)
$form.Controls.Add($btnDeleteProject)

$lnkGuide = New-Object System.Windows.Forms.LinkLabel
$lnkGuide.Text = "Guide"
$lnkGuide.Location = New-Object System.Drawing.Point(500, 6)
$lnkGuide.Size = New-Object System.Drawing.Size(65, 14)
$lnkGuide.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lnkGuide.Anchor = "Top, Right"
$form.Controls.Add($lnkGuide)

$lnkAbout = New-Object System.Windows.Forms.LinkLabel
$lnkAbout.Text = "About"
$lnkAbout.Location = New-Object System.Drawing.Point(500, 21)
$lnkAbout.Size = New-Object System.Drawing.Size(65, 14)
$lnkAbout.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lnkAbout.Anchor = "Top, Right"
$form.Controls.Add($lnkAbout)

$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = "Prompts (multi-line OK - put --- on its own line between prompts):"
$lblInput.Location = New-Object System.Drawing.Point(10, 42)
$lblInput.Size = New-Object System.Drawing.Size(560, 20)
$lblInput.Anchor = "Top, Left, Right"
$form.Controls.Add($lblInput)

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Multiline = $true
$txtInput.ScrollBars = "Vertical"
$txtInput.Location = New-Object System.Drawing.Point(10, 65)
$txtInput.Size = New-Object System.Drawing.Size(560, 250)
$txtInput.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtInput.Anchor = "Top, Left, Right, Bottom"
$form.Controls.Add($txtInput)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Reset"
$btnStart.Location = New-Object System.Drawing.Point(10, 325)
$btnStart.Size = New-Object System.Drawing.Size(150, 30)
$btnStart.Anchor = "Bottom, Left"
$form.Controls.Add($btnStart)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Prompt 0 / 0"
$lblStatus.Location = New-Object System.Drawing.Point(180, 330)
$lblStatus.Size = New-Object System.Drawing.Size(200, 20)
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.Anchor = "Bottom, Left"
$form.Controls.Add($lblStatus)

$lblPreviewTitle = New-Object System.Windows.Forms.Label
$lblPreviewTitle.Text = "Preview (last delivered, or next up after a jump):"
$lblPreviewTitle.Location = New-Object System.Drawing.Point(10, 365)
$lblPreviewTitle.Size = New-Object System.Drawing.Size(400, 20)
$lblPreviewTitle.Anchor = "Bottom, Left"
$form.Controls.Add($lblPreviewTitle)

$txtPreview = New-Object System.Windows.Forms.TextBox
$txtPreview.Multiline = $true
$txtPreview.ReadOnly = $true
$txtPreview.ScrollBars = "Vertical"
$txtPreview.Location = New-Object System.Drawing.Point(10, 390)
$txtPreview.Size = New-Object System.Drawing.Size(560, 100)
$txtPreview.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtPreview.BackColor = [System.Drawing.Color]::LightYellow
$txtPreview.Anchor = "Bottom, Left, Right"
$form.Controls.Add($txtPreview)

$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = "Paste Next (F2)"
$btnNext.Location = New-Object System.Drawing.Point(10, 500)
$btnNext.Size = New-Object System.Drawing.Size(150, 40)
$btnNext.Anchor = "Bottom, Left"
$form.Controls.Add($btnNext)

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = "Paste Prev (F3)"
$btnBack.Location = New-Object System.Drawing.Point(170, 500)
$btnBack.Size = New-Object System.Drawing.Size(150, 40)
$btnBack.Anchor = "Bottom, Left"
$form.Controls.Add($btnBack)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = "Click into the target chat box once. Then F2 = paste next prompt`nthere, F3 = paste previous prompt again. Progress auto-saves."
$lblHint.Location = New-Object System.Drawing.Point(330, 500)
$lblHint.Size = New-Object System.Drawing.Size(250, 50)
$lblHint.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblHint.Anchor = "Bottom, Left, Right"
$form.Controls.Add($lblHint)

$chkSimulateTyping = New-Object System.Windows.Forms.CheckBox
$chkSimulateTyping.Text = "Simulate typing (instead of instant paste)"
$chkSimulateTyping.Location = New-Object System.Drawing.Point(10, 555)
$chkSimulateTyping.Size = New-Object System.Drawing.Size(300, 24)
$chkSimulateTyping.Checked = $true
$chkSimulateTyping.Anchor = "Bottom, Left"
$form.Controls.Add($chkSimulateTyping)

$lblJump = New-Object System.Windows.Forms.Label
$lblJump.Text = "Jump to #:"
$lblJump.Location = New-Object System.Drawing.Point(10, 595)
$lblJump.Size = New-Object System.Drawing.Size(65, 20)
$lblJump.Anchor = "Bottom, Left"
$form.Controls.Add($lblJump)

$numJump = New-Object System.Windows.Forms.NumericUpDown
$numJump.Location = New-Object System.Drawing.Point(80, 592)
$numJump.Size = New-Object System.Drawing.Size(60, 24)
$numJump.Minimum = 1
$numJump.Maximum = 1
$numJump.Anchor = "Bottom, Left"
$form.Controls.Add($numJump)

$btnJump = New-Object System.Windows.Forms.Button
$btnJump.Text = "Go"
$btnJump.Location = New-Object System.Drawing.Point(150, 590)
$btnJump.Size = New-Object System.Drawing.Size(90, 26)
$btnJump.Anchor = "Bottom, Left"
$form.Controls.Add($btnJump)

$lblTypo = New-Object System.Windows.Forms.Label
$lblTypo.Text = "Typo frequency: 3%"
$lblTypo.Location = New-Object System.Drawing.Point(10, 630)
$lblTypo.Size = New-Object System.Drawing.Size(200, 20)
$lblTypo.Anchor = "Bottom, Left"
$form.Controls.Add($lblTypo)

$lblTypoDefault = New-Object System.Windows.Forms.Label
$lblTypoDefault.Text = "(default: 3%)"
$lblTypoDefault.Location = New-Object System.Drawing.Point(210, 630)
$lblTypoDefault.Size = New-Object System.Drawing.Size(120, 20)
$lblTypoDefault.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblTypoDefault.ForeColor = [System.Drawing.Color]::Gray
$lblTypoDefault.Anchor = "Bottom, Left"
$form.Controls.Add($lblTypoDefault)

$trkTypo = New-Object System.Windows.Forms.TrackBar
$trkTypo.Location = New-Object System.Drawing.Point(10, 650)
$trkTypo.Size = New-Object System.Drawing.Size(560, 45)
$trkTypo.Minimum = 0
$trkTypo.Maximum = 80
$trkTypo.TickFrequency = 10
$trkTypo.Value = 3
$trkTypo.Anchor = "Bottom, Left, Right"
$form.Controls.Add($trkTypo)

$trkTypo.Add_Scroll({ $lblTypo.Text = "Typo frequency: $($trkTypo.Value)%" })

# ---------- state ----------
$script:prompts = @()
$script:index = 0
$script:currentProject = $null
$script:isTyping = $false

function Refresh-ProjectList {
    $names = @(Get-ProjectNames)
    $cmbProject.Items.Clear()
    foreach ($n in $names) { [void]$cmbProject.Items.Add($n) }
}

function Update-JumpRange {
    $numJump.Maximum = [Math]::Max(1, $script:prompts.Count)
    if ($numJump.Value -gt $numJump.Maximum) { $numJump.Value = $numJump.Maximum }
}

# Split-PromptBlocks now lives in PromptCue.Logic.ps1 (dot-sourced above).

function Reparse-PromptsKeepPosition {
    # The only place $script:prompts (what F2/F3 actually deliver) gets
    # updated from the textbox - called by Save. Editing the textbox alone
    # never changes what F2/F3 use; only a successful Save does.
    $blocks = @(Split-PromptBlocks $txtInput.Text)
    $script:prompts = $blocks
    if ($script:index -gt $script:prompts.Count) { $script:index = $script:prompts.Count }
    $lblStatus.Text = "Prompt $($script:index) / $($script:prompts.Count)"
    Update-JumpRange
}

function Do-Reset {
    # Repositions to prompt 0 on the currently active (last-saved) list.
    # Does not touch $script:prompts - it never reparses the textbox.
    if ($script:isTyping) { return }
    $script:index = 0
    $lblStatus.Text = "Prompt 0 / $($script:prompts.Count)"
    $txtPreview.Text = ""
    Persist-Progress
}

function Persist-Progress {
    if ($script:currentProject) {
        Save-ProjectFile -name $script:currentProject -prompts $script:prompts -index $script:index
    }
}

function Load-SelectedProject([string]$name) {
    $data = Load-ProjectFile -name $name
    if (-not $data) { return }
    $promptList = @($data.Prompts)
    $displayBlocks = $promptList | ForEach-Object { $_ -replace "`n", "`r`n" }
    $txtInput.Text = ($displayBlocks -join "`r`n---`r`n")
    $script:prompts = $promptList
    $script:index = [int]$data.Index
    if ($script:index -gt $promptList.Count) { $script:index = 0 }
    $script:currentProject = $name
    $cmbProject.Text = $name
    $lblStatus.Text = "Prompt $($script:index) / $($script:prompts.Count)"
    $txtPreview.Text = if ($script:index -gt 0) { $promptList[$script:index - 1] } else { "" }
    Update-JumpRange
    Save-LastProject -name $name
}

function Paste-Text($text) {
    # Puts the text on the clipboard, then sends Ctrl+V to whichever window
    # currently has focus (the target chat box), without stealing focus ourselves.
    [System.Windows.Forms.Clipboard]::SetText($text)
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait("^v")
}

$VK_BACK = 0x08
$VK_SHIFT = 0x10
$VK_RETURN = 0x0D

function Get-KeystrokeDelay {
    # Bursty timing: mostly quick, with occasional slower outliers -
    # a uniform random range alone reads as mechanical.
    if ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt 0.85) {
        return Get-Random -Minimum 15 -Maximum 45
    } else {
        return Get-Random -Minimum 90 -Maximum 220
    }
}

function Get-WordSpeedFactor([string]$word) {
    $lettersOnly = ($word -replace '[^a-zA-Z0-9]', '')
    $len = $lettersOnly.Length
    if ($len -le 3) { return 0.75 }       # short/common words: faster
    elseif ($len -ge 8) { return 1.3 }    # long/unfamiliar words: slower, more careful
    else { return 1.0 }
}

function Type-Text($text) {
    # Sends the text as raw Unicode key input (bypasses keyboard layout, so
    # no dead-key/diacritic issues), timed to feel like a real person typing:
    # - variable per-character delay with occasional slower keys
    # - a beat after spaces, a longer beat after punctuation
    # - longer "thinking" pauses every several words
    # - words are typed faster/slower depending on their length
    # - occasionally a letter is doubled and self-corrected with backspace
    $script:isTyping = $true
    try {
        Start-Sleep -Milliseconds 150

        $tokens = [regex]::Split($text, '(\s+)')
        $wordsSinceThink = 0
        $thinkThreshold = Get-Random -Minimum 6 -Maximum 10

        foreach ($token in $tokens) {
            if ($token -eq "") { continue }

            if ($token -match '^\s+$') {
                foreach ($ch in $token.ToCharArray()) {
                    if ($ch -eq "`n") {
                        # Line break within the prompt: Shift+Enter inserts a
                        # newline in most chat boxes without submitting.
                        [HotkeyForm]::SendKeyCombo($VK_SHIFT, $VK_RETURN)
                    } else {
                        [HotkeyForm]::SendUnicodeChar($ch)
                    }
                    Start-Sleep -Milliseconds (Get-KeystrokeDelay)
                }
                $wordsSinceThink++
                if ($wordsSinceThink -ge $thinkThreshold) {
                    Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 700)
                    $wordsSinceThink = 0
                    $thinkThreshold = Get-Random -Minimum 6 -Maximum 10
                } else {
                    Start-Sleep -Milliseconds (Get-Random -Minimum 40 -Maximum 120)
                }
                continue
            }

            $factor = Get-WordSpeedFactor $token
            $chars = $token.ToCharArray()
            $typoChance = $trkTypo.Value / 100.0

            for ($i = 0; $i -lt $chars.Length; $i++) {
                $ch = $chars[$i]
                [HotkeyForm]::SendUnicodeChar($ch)
                Start-Sleep -Milliseconds ([int]((Get-KeystrokeDelay) * $factor))

                if ($ch -match '[a-zA-Z]' -and (Get-Random -Minimum 0.0 -Maximum 1.0) -lt $typoChance) {
                    # Duplicate the letter, notice it, backspace it off, carry on.
                    [HotkeyForm]::SendUnicodeChar($ch)
                    Start-Sleep -Milliseconds (Get-Random -Minimum 80 -Maximum 150)
                    [HotkeyForm]::SendVirtualKey($VK_BACK)
                    Start-Sleep -Milliseconds (Get-Random -Minimum 60 -Maximum 130)
                }

                if ($ch -match '[,.!?;:]') {
                    Start-Sleep -Milliseconds (Get-Random -Minimum 150 -Maximum 400)
                }
            }
        }
    } finally {
        $script:isTyping = $false
    }
}

function Do-Jump([int]$targetNumber) {
    # Repositions only - does not paste/type anything. The prompt at
    # $targetNumber becomes "next up" for the following F2 press.
    if ($script:isTyping) { return }
    if ($script:prompts.Count -eq 0) { return }
    if ($targetNumber -lt 1 -or $targetNumber -gt $script:prompts.Count) { return }
    $script:index = $targetNumber - 1
    $lblStatus.Text = "Prompt $($script:index) / $($script:prompts.Count) (ready)"
    $txtPreview.Text = $script:prompts[$script:index]
    Persist-Progress
}

function Deliver-Text($text) {
    if ($chkSimulateTyping.Checked) { Type-Text $text } else { Paste-Text $text }
}

function Do-Next {
    if ($script:isTyping) { return }
    if ($script:prompts.Count -eq 0) { return }
    if ($script:index -ge $script:prompts.Count) {
        $lblStatus.Text = "Prompt $($script:prompts.Count) / $($script:prompts.Count) (done)"
        return
    }
    $current = $script:prompts[$script:index]
    Deliver-Text $current
    $script:index++
    $lblStatus.Text = "Prompt $($script:index) / $($script:prompts.Count)"
    $txtPreview.Text = $current
    Persist-Progress
}

function Do-Back {
    if ($script:isTyping) { return }
    if ($script:prompts.Count -eq 0) { return }
    if ($script:index -le 1) {
        $script:index = 0
        $lblStatus.Text = "Prompt 0 / $($script:prompts.Count)"
        $txtPreview.Text = ""
        Persist-Progress
        return
    }
    $script:index--
    $current = $script:prompts[$script:index - 1]
    Deliver-Text $current
    $lblStatus.Text = "Prompt $($script:index) / $($script:prompts.Count)"
    $txtPreview.Text = $current
    Persist-Progress
}

function Show-Walkthrough {
    # $script:wtIndex / $script:wtSteps so the inline Add_Click handlers below
    # (nested script blocks, not named functions) reliably see live state -
    # this file's convention elsewhere is $script: for exactly this reason.
    $script:wtIndex = 0
    $script:wtSteps = @(
        @{ Title = "Welcome to PromptCue"
           Body  = "PromptCue delivers a list of prepared prompts into another app's chat box, one at a time, so you don't have to copy and paste each one by hand. This quick guide covers the basics." },
        @{ Title = "Step 1: Enter your prompts"
           Body  = "Type or paste your prompts into the big text box. If you have more than one, put a line containing only ---`nbetween each prompt, on its own line." },
        @{ Title = "Step 2: Save your project"
           Body  = "Type a name in the Project box at the top, then click Save. This stores your prompt list so you can reload it later, and remembers your progress." },
        @{ Title = "Step 3: Click into the target chat box"
           Body  = "Before pressing F2 or F3, click once into the text box of the app you want the prompts delivered to (e.g. a chat window), so it has keyboard focus." },
        @{ Title = "Step 4: Deliver prompts with F2 / F3"
           Body  = "Press F2 (or Paste Next) to deliver the next prompt into that focused box. Press F3 (or Paste Prev) to redeliver the previous one. Use Jump to # to reposition without sending anything, and Reset to start over. Progress auto-saves." }
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "PromptCue Walkthrough"
    $dlg.Size = New-Object System.Drawing.Size(440, 320)
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"

    $lblStep = New-Object System.Windows.Forms.Label
    $lblStep.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblStep.ForeColor = [System.Drawing.Color]::Gray
    $lblStep.Location = New-Object System.Drawing.Point(15, 15)
    $lblStep.Size = New-Object System.Drawing.Size(200, 18)
    $dlg.Controls.Add($lblStep)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(15, 35)
    $lblTitle.Size = New-Object System.Drawing.Size(395, 26)
    $dlg.Controls.Add($lblTitle)

    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Location = New-Object System.Drawing.Point(15, 70)
    $lblBody.Size = New-Object System.Drawing.Size(395, 150)
    $dlg.Controls.Add($lblBody)

    $btnSkip = New-Object System.Windows.Forms.Button
    $btnSkip.Text = "Skip"
    $btnSkip.Location = New-Object System.Drawing.Point(15, 240)
    $btnSkip.Size = New-Object System.Drawing.Size(75, 28)
    $dlg.Controls.Add($btnSkip)

    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = "Back"
    $btnBack.Location = New-Object System.Drawing.Point(255, 240)
    $btnBack.Size = New-Object System.Drawing.Size(75, 28)
    $dlg.Controls.Add($btnBack)

    $btnNextStep = New-Object System.Windows.Forms.Button
    $btnNextStep.Location = New-Object System.Drawing.Point(335, 240)
    $btnNextStep.Size = New-Object System.Drawing.Size(75, 28)
    $dlg.Controls.Add($btnNextStep)
    $dlg.AcceptButton = $btnNextStep

    $script:wtRender = {
        $step = $script:wtSteps[$script:wtIndex]
        $lblStep.Text = "Step $($script:wtIndex + 1) of $($script:wtSteps.Count)"
        $lblTitle.Text = $step.Title
        $lblBody.Text = $step.Body
        $btnBack.Enabled = ($script:wtIndex -gt 0)
        $btnNextStep.Text = if ($script:wtIndex -eq $script:wtSteps.Count - 1) { "Finish" } else { "Next" }
    }

    $btnBack.Add_Click({
        if ($script:wtIndex -gt 0) { $script:wtIndex--; & $script:wtRender }
    })
    $btnNextStep.Add_Click({
        if ($script:wtIndex -lt $script:wtSteps.Count - 1) { $script:wtIndex++; & $script:wtRender }
        else { $dlg.Close() }
    })
    $btnSkip.Add_Click({ $dlg.Close() })

    & $script:wtRender
    [void]$dlg.ShowDialog($form)
}

function Show-AboutDialog {
    $DevEmail = "md.bahauddin@o9solutions.com"
    $RepoUrl  = "https://github.com/mbahau/promptcue/"

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "About PromptCue"
    $dlg.Size = New-Object System.Drawing.Size(470, 560)
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"

    $lblApp = New-Object System.Windows.Forms.Label
    $lblApp.Text = "PromptCue v$AppVersion"
    $lblApp.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblApp.Location = New-Object System.Drawing.Point(15, 15)
    $lblApp.Size = New-Object System.Drawing.Size(420, 26)
    $dlg.Controls.Add($lblApp)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "PromptCue delivers a prepared list of prompts one at a time into " +
        "another app's text box (e.g. an AI chat window), either by pasting or " +
        "by simulating human-like typing, so you don't have to manually " +
        "copy and paste each prompt yourself."
    $lblDesc.Location = New-Object System.Drawing.Point(15, 45)
    $lblDesc.Size = New-Object System.Drawing.Size(420, 60)
    $dlg.Controls.Add($lblDesc)

    $lblHowToTitle = New-Object System.Windows.Forms.Label
    $lblHowToTitle.Text = "How to use:"
    $lblHowToTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblHowToTitle.Location = New-Object System.Drawing.Point(15, 110)
    $lblHowToTitle.Size = New-Object System.Drawing.Size(200, 20)
    $dlg.Controls.Add($lblHowToTitle)

    $lblHowTo = New-Object System.Windows.Forms.Label
    $lblHowTo.Text =
        "1. Paste your prompts into the box, one per block, separated by`n" +
        "    a line containing only ---.`n" +
        "2. Click Save to store them under a project name.`n" +
        "3. Click once into the target chat box (e.g. your AI chat app).`n" +
        "4. Press F2 (Paste Next) to deliver the next prompt, or F3`n" +
        "    (Paste Prev) to redeliver the previous one.`n" +
        "5. Use Jump to # to reposition without sending anything, and`n" +
        "    Reset to start the current list over from the beginning."
    $lblHowTo.Location = New-Object System.Drawing.Point(15, 132)
    $lblHowTo.Size = New-Object System.Drawing.Size(420, 150)
    $dlg.Controls.Add($lblHowTo)

    $lblDev = New-Object System.Windows.Forms.Label
    $lblDev.Text = "Developer: MD Bahauddin"
    $lblDev.Location = New-Object System.Drawing.Point(15, 292)
    $lblDev.Size = New-Object System.Drawing.Size(420, 20)
    $dlg.Controls.Add($lblDev)

    $lblEmailCaption = New-Object System.Windows.Forms.Label
    $lblEmailCaption.Text = "Email:"
    $lblEmailCaption.Location = New-Object System.Drawing.Point(15, 322)
    $lblEmailCaption.Size = New-Object System.Drawing.Size(45, 20)
    $dlg.Controls.Add($lblEmailCaption)

    $lnkEmail = New-Object System.Windows.Forms.LinkLabel
    $lnkEmail.Text = $DevEmail
    $lnkEmail.Location = New-Object System.Drawing.Point(60, 322)
    $lnkEmail.Size = New-Object System.Drawing.Size(280, 20)
    $lnkEmail.Add_LinkClicked({ Start-Process "mailto:$DevEmail" })
    $dlg.Controls.Add($lnkEmail)

    $btnCopyEmail = New-Object System.Windows.Forms.Button
    $btnCopyEmail.Text = "Copy"
    $btnCopyEmail.Location = New-Object System.Drawing.Point(350, 319)
    $btnCopyEmail.Size = New-Object System.Drawing.Size(65, 24)
    $btnCopyEmail.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($DevEmail)
        $btnCopyEmail.Text = "Copied!"
        $copyTimer = New-Object System.Windows.Forms.Timer
        $copyTimer.Interval = 1200
        $copyTimer.Add_Tick({ $btnCopyEmail.Text = "Copy"; $copyTimer.Stop(); $copyTimer.Dispose() })
        $copyTimer.Start()
    })
    $dlg.Controls.Add($btnCopyEmail)

    $lblRepoCaption = New-Object System.Windows.Forms.Label
    $lblRepoCaption.Text = "Repository:"
    $lblRepoCaption.Location = New-Object System.Drawing.Point(15, 357)
    $lblRepoCaption.Size = New-Object System.Drawing.Size(80, 20)
    $dlg.Controls.Add($lblRepoCaption)

    $lnkRepo = New-Object System.Windows.Forms.LinkLabel
    $lnkRepo.Text = $RepoUrl
    $lnkRepo.Location = New-Object System.Drawing.Point(15, 379)
    $lnkRepo.Size = New-Object System.Drawing.Size(420, 20)
    $lnkRepo.Add_LinkClicked({ Start-Process $RepoUrl })
    $dlg.Controls.Add($lnkRepo)

    $lblContrib = New-Object System.Windows.Forms.Label
    $lblContrib.Text = "PromptCue is open source - contributions are welcome via pull request."
    $lblContrib.Location = New-Object System.Drawing.Point(15, 405)
    $lblContrib.Size = New-Object System.Drawing.Size(420, 32)
    $lblContrib.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblContrib.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblContrib)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(360, 445)
    $btnClose.Size = New-Object System.Drawing.Size(80, 28)
    $btnClose.DialogResult = "OK"
    $dlg.Controls.Add($btnClose)
    $dlg.AcceptButton = $btnClose

    [void]$dlg.ShowDialog($form)
}

# ---------- events ----------
$btnStart.Add_Click({ Do-Reset })
$btnNext.Add_Click({ Do-Next })
$btnBack.Add_Click({ Do-Back })
$btnJump.Add_Click({ Do-Jump ([int]$numJump.Value) })
$lnkAbout.Add_LinkClicked({ Show-AboutDialog })
$lnkGuide.Add_LinkClicked({ Show-Walkthrough })

$btnLoadProject.Add_Click({
    $name = $cmbProject.Text.Trim()
    if ($name) { Load-SelectedProject -name $name }
})

$btnSaveProject.Add_Click({
    $name = $cmbProject.Text.Trim()
    if (-not $name) {
        [System.Windows.Forms.MessageBox]::Show("Enter a project name first.", "PromptCue") | Out-Null
        return
    }
    try {
        Reparse-PromptsKeepPosition
        Save-ProjectFile -name $name -prompts $script:prompts -index $script:index
        $script:currentProject = $name
        Save-LastProject -name $name
        Refresh-ProjectList
        $cmbProject.Text = $name
        [System.Windows.Forms.MessageBox]::Show("Saved '$name' ($($script:prompts.Count) prompts).", "PromptCue") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Save failed: $($_.Exception.Message)", "PromptCue") | Out-Null
    }
})

$btnDeleteProject.Add_Click({
    $name = $cmbProject.Text.Trim()
    if (-not $name) { return }
    $safeName = ($name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $projDir "$safeName.json"
    if (Test-Path $path) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Delete project '$name'?", "Prompt Cycler", "YesNo")
        if ($confirm -eq "Yes") {
            Remove-Item $path -Force
            Refresh-ProjectList
            $cmbProject.Text = ""
        }
    }
})

# Buttons keep the dotted/dark focus rectangle after being clicked until focus
# moves elsewhere. Clear focus once each button's own click handler has already
# run, so a button only looks "active" while actually being interacted with.
foreach ($ctrl in $form.Controls) {
    if ($ctrl -is [System.Windows.Forms.Button]) {
        $ctrl.Add_Click({ $form.ActiveControl = $null })
    }
}

$form.Add_NextHotkeyPressed({ Do-Next })
$form.Add_BackHotkeyPressed({ Do-Back })

$VK_F2 = 0x71
$VK_F3 = 0x72

$form.Add_Load({
    [void][HotkeyForm]::RegisterHotKey($form.Handle, 1, 0, $VK_F2)
    [void][HotkeyForm]::RegisterHotKey($form.Handle, 2, 0, $VK_F3)

    Seed-ExampleProjectIfNone
    Refresh-ProjectList
    $last = Get-LastProject
    if (-not $last -and (Get-ProjectNames) -contains "Example My Prompts") {
        $last = "Example My Prompts"
    }
    if ($last -and (Get-ProjectNames) -contains $last) {
        Load-SelectedProject -name $last
    }

    if (-not (Get-WalkthroughShown)) {
        Save-WalkthroughShown
        Show-Walkthrough
    }
})

$form.Add_FormClosing({
    [void][HotkeyForm]::UnregisterHotKey($form.Handle, 1)
    [void][HotkeyForm]::UnregisterHotKey($form.Handle, 2)
})

[void]$form.ShowDialog()
