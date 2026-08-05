# Unit tests for the pure logic in App/PromptCue.Logic.ps1. Run with:
#   Invoke-Pester -Path ".\Tests\PromptCue.Tests.ps1"
# from the project root (Windows PowerShell 5.1 ships with Pester 3.4.0,
# which is what these tests target - no extra install required).
#
# These tests deliberately do NOT touch WinForms, hotkeys, or SendInput -
# that layer can't be meaningfully unit-tested. See App/AGENT_CONTEXT.md.

. (Join-Path $PSScriptRoot "..\App\PromptCue.Logic.ps1")

Describe "Split-PromptBlocks" {

    It "splits on a lone --- line into separate blocks" {
        $result = @(Split-PromptBlocks "first`n---`nsecond")
        $result.Count | Should Be 2
        $result[0] | Should Be "first"
        $result[1] | Should Be "second"
    }

    It "treats text with no --- as a single block" {
        $result = @(Split-PromptBlocks "just one prompt`nacross two lines")
        $result.Count | Should Be 1
        $result[0] | Should Be "just one prompt`nacross two lines"
    }

    It "preserves interior blank lines and trailing newlines exactly" {
        $text = "Hi`nas`n`nas`n"
        $result = @(Split-PromptBlocks $text)
        $result.Count | Should Be 1
        $result[0] | Should Be $text
    }

    It "tolerates leading/trailing spaces around the --- delimiter" {
        $result = @(Split-PromptBlocks "first`n  ---  `nsecond")
        $result.Count | Should Be 2
        $result[0] | Should Be "first"
        $result[1] | Should Be "second"
    }

    It "drops a block that is entirely blank" {
        $result = @(Split-PromptBlocks "first`n---`n`n---`nthird")
        $result.Count | Should Be 2
        $result[0] | Should Be "first"
        $result[1] | Should Be "third"
    }

    It "is idempotent across a Load/Save-style round trip (regression guard)" {
        # This is the exact bug class that shipped once: joining blocks back
        # together with "`r`n---`r`n" (as Load-SelectedProject does for
        # display) and re-splitting must not add or remove any newlines.
        $original = @("first prompt`nwith a blank line`n", "second prompt", "third`n`nprompt")
        $joined = ($original -join "`r`n---`r`n")
        $roundTripped = @(Split-PromptBlocks $joined)
        $roundTripped.Count | Should Be $original.Count
        for ($i = 0; $i -lt $original.Count; $i++) {
            $roundTripped[$i] | Should Be $original[$i]
        }

        # A second round trip must change nothing further.
        $joinedAgain = ($roundTripped -join "`r`n---`r`n")
        $roundTrippedAgain = @(Split-PromptBlocks $joinedAgain)
        for ($i = 0; $i -lt $original.Count; $i++) {
            $roundTrippedAgain[$i] | Should Be $original[$i]
        }
    }
}

Describe "Save-ProjectFile / Load-ProjectFile" {

    It "round-trips prompts and index exactly, byte-for-byte on content" {
        $tempDir = Join-Path $TestDrive "Projects"
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        $prompts = @("first`nwith blank line`n`n", "second prompt", "third")
        Save-ProjectFile -name "My Test Project" -prompts $prompts -index 2 -ProjDir $tempDir
        $loaded = Load-ProjectFile -name "My Test Project" -ProjDir $tempDir

        $loaded.Index | Should Be 2
        $loadedPrompts = @($loaded.Prompts)
        $loadedPrompts.Count | Should Be $prompts.Count
        for ($i = 0; $i -lt $prompts.Count; $i++) {
            $loadedPrompts[$i] | Should Be $prompts[$i]
        }
    }

    It "sanitizes unsafe filename characters in the project name" {
        $tempDir = Join-Path $TestDrive "Projects2"
        New-Item -ItemType Directory -Path $tempDir | Out-Null

        Save-ProjectFile -name 'Client: A/B Test?' -prompts @("x") -index 0 -ProjDir $tempDir
        (Get-ChildItem $tempDir -Filter "*.json").Count | Should Be 1
    }

    It "returns null when loading a project that doesn't exist" {
        $tempDir = Join-Path $TestDrive "Projects3"
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        Load-ProjectFile -name "Nonexistent" -ProjDir $tempDir | Should Be $null
    }

    It "does nothing when saving with a blank/whitespace name" {
        $tempDir = Join-Path $TestDrive "Projects4"
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        Save-ProjectFile -name "   " -prompts @("x") -index 0 -ProjDir $tempDir
        (Get-ChildItem $tempDir -Filter "*.json" -ErrorAction SilentlyContinue).Count | Should Be 0
    }
}

Describe "Test-UpdateAvailable" {

    It "returns false when versions match" {
        Test-UpdateAvailable -CurrentVersion "1.0" -RemoteVersion "1.0" | Should Be $false
    }

    It "returns true when the remote version differs" {
        Test-UpdateAvailable -CurrentVersion "1.0" -RemoteVersion "1.1" | Should Be $true
    }

    It "returns false when the remote version is empty (unreachable/blank file)" {
        Test-UpdateAvailable -CurrentVersion "1.0" -RemoteVersion "" | Should Be $false
    }

    It "returns false when the remote version is only whitespace" {
        Test-UpdateAvailable -CurrentVersion "1.0" -RemoteVersion "   " | Should Be $false
    }
}
