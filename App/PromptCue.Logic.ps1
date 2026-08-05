# Pure, GUI-free logic extracted from PromptCue.ps1 so it can be unit-tested
# in isolation (see Tests/PromptCue.Tests.ps1). PromptCue.ps1 dot-sources this
# file. Nothing in here may reference WinForms, hotkeys, or SendInput - if a
# function needs any of that, it belongs in PromptCue.ps1, not here.

function Split-PromptBlocks([string]$text) {
    # Prompts are separated by a line containing only "---". Split line-by-line
    # so the delimiter line is consumed exactly, with no ambiguity about which
    # side of it a newline belongs to. (An earlier regex-split approach left
    # the newline next to the delimiter attached to a block; on the next
    # Load->display->Save round trip that stray newline plus the newline added
    # by re-joining with "---" would double up, so blank lines silently grew
    # by one on each save/load cycle - this version is round-trip idempotent.
    # See Tests/PromptCue.Tests.ps1 for the idempotency test that guards this.)
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

function Save-ProjectFile([string]$name, [string[]]$prompts, [int]$index, [string]$ProjDir = $projDir) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $safeName = ($name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $ProjDir "$safeName.json"
    $obj = @{ Prompts = @($prompts); Index = $index }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Load-ProjectFile([string]$name, [string]$ProjDir = $projDir) {
    $safeName = ($name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $ProjDir "$safeName.json"
    if (-not (Test-Path $path)) { return $null }
    Get-Content -Path $path -Raw | ConvertFrom-Json
}

function Test-UpdateAvailable([string]$CurrentVersion, [string]$RemoteVersion) {
    # Deliberately a plain string-inequality check, not semver-aware - keep
    # $AppVersion and version.txt as simple strings that are bumped together.
    # An empty/whitespace remote version (e.g. an unreachable/empty file)
    # must never be treated as "update available".
    if ([string]::IsNullOrWhiteSpace($RemoteVersion)) { return $false }
    return $RemoteVersion -ne $CurrentVersion
}
