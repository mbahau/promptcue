Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# A Form subclass that can register a system-wide (global) hotkey.
# Global means it fires even when a different window (e.g. the o9 chat) has focus.
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
$AppVersion = "1.0"
$UpdateVersionUrl = "https://raw.githubusercontent.com/mbahau/promptcue/main/version.txt"
$UpdateScriptUrl  = "https://raw.githubusercontent.com/mbahau/promptcue/main/PromptCue.ps1"

function Check-ForUpdate {
    # Best-effort, silent on any failure (no internet, GitHub unreachable,
    # etc.) - an update check must never block the app from opening.
    try {
        $remoteVersion = (Invoke-RestMethod -Uri $UpdateVersionUrl -TimeoutSec 5).Trim()
        if ($remoteVersion -and $remoteVersion -ne $AppVersion) {
            $resp = [System.Windows.Forms.MessageBox]::Show(
                "An update is available ($AppVersion -> $remoteVersion). Update now?",
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

function Save-ProjectFile([string]$name, [string[]]$prompts, [int]$index) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $safeName = ($name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $projDir "$safeName.json"
    $obj = @{ Prompts = @($prompts); Index = $index }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Load-ProjectFile([string]$name) {
    $safeName = ($name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $projDir "$safeName.json"
    if (-not (Test-Path $path)) { return $null }
    Get-Content -Path $path -Raw | ConvertFrom-Json
}

function Save-LastProject([string]$name) {
    @{ LastProject = $name } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Get-LastProject {
    if (Test-Path $configPath) {
        try { return (Get-Content -Path $configPath -Raw | ConvertFrom-Json).LastProject } catch { return $null }
    }
    return $null
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
$lblHint.Text = "Click into the o9 chat box once. Then F2 = paste next prompt`nthere, F3 = paste previous prompt again. Progress auto-saves."
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

function Split-PromptBlocks([string]$text) {
    # Prompts are separated by a line containing only "---". Split line-by-line
    # so the delimiter line is consumed exactly, with no ambiguity about which
    # side of it a newline belongs to. (The previous regex-split approach left
    # the newline next to the delimiter attached to a block; on the next
    # Load->display->Save round trip that stray newline plus the newline added
    # by re-joining with "---" would double up, so blank lines silently grew
    # by one on each save/load cycle - this version is round-trip idempotent.)
    $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"
    $blocks = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^[ \t]*---[ \t]*$') {
            $blocks.Add(($current -join "`n"))
            $current = New-Object System.Collections.Generic.List[string]
        } else {
            $current.Add($line)
        }
    }
    $blocks.Add(($current -join "`n"))
    $blocks | Where-Object { $_.Trim() -ne "" }
}

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
    # currently has focus (the o9 chat box), without stealing focus ourselves.
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

# ---------- events ----------
$btnStart.Add_Click({ Do-Reset })
$btnNext.Add_Click({ Do-Next })
$btnBack.Add_Click({ Do-Back })
$btnJump.Add_Click({ Do-Jump ([int]$numJump.Value) })

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

    Refresh-ProjectList
    $last = Get-LastProject
    if ($last -and (Get-ProjectNames) -contains $last) {
        Load-SelectedProject -name $last
    }
})

$form.Add_FormClosing({
    [void][HotkeyForm]::UnregisterHotKey($form.Handle, 1)
    [void][HotkeyForm]::UnregisterHotKey($form.Handle, 2)
})

[void]$form.ShowDialog()
