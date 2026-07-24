<#
.SYNOPSIS
    HashDiff - pick two commits on a branch in a git repo and open them in Beyond Compare
    (or any folder diff tool).

    Each selected commit's tree is exported to a temp folder via `git archive`, then the
    two folders are handed to the configured diff tool for a whole-tree comparison.

    Launch with `hashdiff` from any terminal (see hashdiff.cmd). If the terminal's
    directory is inside a git repo, that repo is pre-selected; otherwise the last repo
    you used is shown. Peer tool to BranchDiff (which diffs two branches).
.PARAMETER LaunchDir
    Directory to detect a git repo from (defaults to the current directory).
#>

param([string]$LaunchDir = (Get-Location).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Native theming so controls (and the marquee progress bar) render correctly.
# These are one-time-per-process calls that must run before any control is created;
# SetCompatibleTextRenderingDefault throws if a WinForms window already exists. That
# happens when the host reuses a PowerShell process across launches (e.g. the VS Code
# integrated terminal), so guard it - the styles are already set from the first run.
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

# No console-hiding here: the app is meant to be launched windowless via
# HashDiff.vbs (wscript -> conhost -> hidden PowerShell), so no console ever shows.

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:IconPath  = Join-Path $script:ScriptDir 'icon.ico'

# --------------------------------------------------------------------------
# Config (persisted to %APPDATA%\HashDiff\config.json)
# --------------------------------------------------------------------------
$script:ConfigDir  = Join-Path $env:APPDATA 'HashDiff'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'

function Load-Config {
    $defaults = [ordered]@{
        diffToolPath   = ''
        lastRepo       = ''
        includeRemotes = $false
        lastBranch     = ''
        commitLimit    = 200
    }
    if (Test-Path $script:ConfigPath) {
        try {
            $json = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in @($defaults.Keys)) {
                if ($json.PSObject.Properties.Name -contains $k -and $null -ne $json.$k) {
                    $defaults[$k] = $json.$k
                }
            }
        } catch { }   # corrupt config -> fall back to defaults
    }
    return $defaults
}

function Save-Config($cfg) {
    try {
        if (-not (Test-Path $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $cfg | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch { }   # never let a config write crash the app
}

# --------------------------------------------------------------------------
# Beyond Compare autodetection
# --------------------------------------------------------------------------
function Find-DiffTool {
    # BCompare.exe is the GUI launcher (preferred); BComp.exe is the console-wait variant.
    $roots = @(
        "$env:ProgramFiles\Beyond Compare 5"
        "$env:ProgramFiles\Beyond Compare 4"
        "$env:ProgramFiles\Beyond Compare 3"
        "${env:ProgramFiles(x86)}\Beyond Compare 5"
        "${env:ProgramFiles(x86)}\Beyond Compare 4"
        "$env:LOCALAPPDATA\Programs\Beyond Compare 5"
        "$env:LOCALAPPDATA\Programs\Beyond Compare 4"
    )
    foreach ($r in $roots) {
        foreach ($exe in @('BCompare.exe', 'BComp.exe')) {
            $c = Join-Path $r $exe
            if (Test-Path $c) { return $c }
        }
    }
    # Registry App Paths
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\BCompare.exe',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\BCompare.exe')) {
        try {
            $p = (Get-ItemProperty -Path $root -ErrorAction Stop).'(default)'
            if ($p -and (Test-Path $p)) { return $p }
        } catch { }
    }
    return ''
}

# --------------------------------------------------------------------------
# Git helpers
# --------------------------------------------------------------------------
function Test-GitRepo($repo) {
    if ([string]::IsNullOrWhiteSpace($repo) -or -not (Test-Path $repo)) { return $false }
    try {
        $out = & git -C $repo rev-parse --is-inside-work-tree 2>$null
        return ($LASTEXITCODE -eq 0 -and $out -match 'true')
    } catch { return $false }
}

# If $dir is inside a git work tree, return the repo's top-level folder (else $null).
function Get-RepoRoot($dir) {
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path $dir)) { return $null }
    try {
        $top = & git -C $dir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) {
            return ($top.Trim() -replace '/', '\')   # git prints forward slashes
        }
    } catch { }
    return $null
}

function Get-Branches($repo, $includeRemotes) {
    $gitArgs = @('-C', $repo, 'branch', '--format=%(refname:short)')
    if ($includeRemotes) { $gitArgs += '-a' }
    $branches = & git @gitArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $branches) { return @() }
    # Drop the symbolic "origin/HEAD -> origin/main" style entries
    return @($branches | Where-Object { $_ -and ($_ -notmatch '->') } | ForEach-Object { $_.Trim() })
}

# The checked-out branch name, or $null if detached / unavailable.
function Get-CurrentBranch($repo) {
    try {
        $b = & git -C $repo rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b -and $b.Trim() -ne 'HEAD') { return $b.Trim() }
    } catch { }
    return $null
}

# Recent commits on $ref as display strings "shorthash  date  subject" (newest first).
# The short hash is always the first whitespace-delimited token.
function Get-Commits($repo, $ref, $limit) {
    $gitArgs = @('-C', $repo, 'log', "-n", "$limit", '--date=short', '--format=%h  %ad  %s')
    if ($ref) { $gitArgs += $ref }
    $lines = & git @gitArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $lines) { return @() }
    return @($lines | Where-Object { $_ })
}

# Resolve a picked/pasted commit-ish (short/full hash, or ref) to a short sha, or $null.
function Get-CommitSha($repo, $token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    try {
        $sha = & git -C $repo rev-parse --short --verify --quiet "$token^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) { return $sha.Trim() }
    } catch { }
    return $null
}

function Get-SafeName($ref) {
    return ($ref -replace '[\\/:*?"<>|]', '_')
}

# Export work runs on a background runspace (see the Compare handler). The script
# block below is self-contained so it needs nothing from this scope. It exports each
# commit with `git archive` and extracts via System.IO.Compression.ZipFile, which is
# dramatically faster than PowerShell's Expand-Archive.
$script:ExportScript = {
    param($repo, $refA, $refB, $dirA, $dirB, $labelA, $labelB, $shared)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        function Export-One($repo, $ref, $dest) {
            $zip = [IO.Path]::Combine([IO.Path]::GetTempPath(), "hd_$([Guid]::NewGuid().ToString('N')).zip")
            try {
                & git -C $repo archive --format=zip -o $zip $ref 2>$null
                if ($LASTEXITCODE -ne 0) { throw "git archive failed for '$ref'" }
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
            } finally {
                if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
            }
        }
        $shared['Status'] = "Exporting '$labelA'..."
        Export-One $repo $refA $dirA
        $shared['Status'] = "Exporting '$labelB'..."
        Export-One $repo $refB $dirB
        $shared['Status'] = 'Launching diff tool...'
    } catch {
        $shared['Error'] = $_.Exception.Message
    } finally {
        $shared['Done'] = $true
    }
}

# --------------------------------------------------------------------------
# Temp cleanup (stale folders from previous sessions)
# --------------------------------------------------------------------------
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'HashDiff'
function Clear-StaleTemp {
    if (Test-Path $script:TempRoot) {
        Get-ChildItem $script:TempRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
}

# ==========================================================================
# GUI
# ==========================================================================
$cfg = Load-Config
if ([string]::IsNullOrWhiteSpace($cfg.diffToolPath)) {
    $cfg.diffToolPath = Find-DiffTool
}
$script:CommitLimit = [int]$cfg.commitLimit
if ($script:CommitLimit -le 0) { $script:CommitLimit = 200 }
Clear-StaleTemp

# Pre-select a repo: the one containing the launch directory, else the last one used.
$script:InitialRepo = Get-RepoRoot $LaunchDir
if ([string]::IsNullOrWhiteSpace($script:InitialRepo)) { $script:InitialRepo = [string]$cfg.lastRepo }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HashDiff'
$form.Size = New-Object System.Drawing.Size(620, 360)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
if (Test-Path $script:IconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }
}

function New-Label($text, $x, $y, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20)
    return $l
}

# --- Repo row ---
$form.Controls.Add((New-Label 'Repository:' 12 18 70))
$txtRepo = New-Object System.Windows.Forms.TextBox
$txtRepo.Location = New-Object System.Drawing.Point(88, 15)
$txtRepo.Size = New-Object System.Drawing.Size(420, 23)
$txtRepo.Text = [string]$script:InitialRepo
$form.Controls.Add($txtRepo)

$btnRepo = New-Object System.Windows.Forms.Button
$btnRepo.Text = 'Browse...'
$btnRepo.Location = New-Object System.Drawing.Point(516, 14)
$btnRepo.Size = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnRepo)

# --- Branch scope row ---
$form.Controls.Add((New-Label 'Branch:' 12 58 70))
$cmbBranch = New-Object System.Windows.Forms.ComboBox
$cmbBranch.Location = New-Object System.Drawing.Point(88, 55)
$cmbBranch.Size = New-Object System.Drawing.Size(420, 23)
$cmbBranch.DropDownStyle = 'DropDownList'
$form.Controls.Add($cmbBranch)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(516, 54)
$btnRefresh.Size = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnRefresh)

# --- Include remotes ---
$chkRemotes = New-Object System.Windows.Forms.CheckBox
$chkRemotes.Text = 'Include remote branches'
$chkRemotes.Location = New-Object System.Drawing.Point(88, 84)
$chkRemotes.Size = New-Object System.Drawing.Size(220, 22)
$chkRemotes.Checked = [bool]$cfg.includeRemotes
$form.Controls.Add($chkRemotes)

# --- Commit A ---
$form.Controls.Add((New-Label 'Commit A:' 12 116 70))
$cmbCommitA = New-Object System.Windows.Forms.ComboBox
$cmbCommitA.Location = New-Object System.Drawing.Point(88, 113)
$cmbCommitA.Size = New-Object System.Drawing.Size(420, 23)
$cmbCommitA.DropDownStyle = 'DropDown'   # editable: pick from list or paste a hash/ref
$form.Controls.Add($cmbCommitA)

$btnSwap = New-Object System.Windows.Forms.Button
$btnSwap.Text = 'Swap A/B'
$btnSwap.Location = New-Object System.Drawing.Point(516, 130)
$btnSwap.Size = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnSwap)

# --- Commit B ---
$form.Controls.Add((New-Label 'Commit B:' 12 151 70))
$cmbCommitB = New-Object System.Windows.Forms.ComboBox
$cmbCommitB.Location = New-Object System.Drawing.Point(88, 148)
$cmbCommitB.Size = New-Object System.Drawing.Size(420, 23)
$cmbCommitB.DropDownStyle = 'DropDown'
$form.Controls.Add($cmbCommitB)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($cmbCommitA, 'Pick a recent commit, or paste any commit hash / ref.')
$tip.SetToolTip($cmbCommitB, 'Pick a recent commit, or paste any commit hash / ref.')
$tip.SetToolTip($btnSwap, 'Swap Commit A and Commit B (reverses the diff direction).')

# --- Diff tool row ---
$form.Controls.Add((New-Label 'Diff tool:' 12 192 70))
$txtTool = New-Object System.Windows.Forms.TextBox
$txtTool.Location = New-Object System.Drawing.Point(88, 189)
$txtTool.Size = New-Object System.Drawing.Size(420, 23)
$txtTool.Text = [string]$cfg.diffToolPath
$form.Controls.Add($txtTool)

$btnTool = New-Object System.Windows.Forms.Button
$btnTool.Text = 'Browse...'
$btnTool.Location = New-Object System.Drawing.Point(516, 188)
$btnTool.Size = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($btnTool)

# --- Compare button ---
$btnCompare = New-Object System.Windows.Forms.Button
$btnCompare.Text = 'Compare'
$btnCompare.Location = New-Object System.Drawing.Point(88, 228)
$btnCompare.Size = New-Object System.Drawing.Size(120, 32)
$btnCompare.Font = New-Object System.Drawing.Font($btnCompare.Font, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnCompare)

# --- Progress (marquee; visible only while exporting) ---
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 30
$progress.Location = New-Object System.Drawing.Point(224, 232)
$progress.Size = New-Object System.Drawing.Size(372, 24)
$progress.Visible = $false
$form.Controls.Add($progress)

# --- Status ---
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 278)
$lblStatus.Size = New-Object System.Drawing.Size(584, 40)
$lblStatus.Text = ''
$form.Controls.Add($lblStatus)

function Set-Status($text, [bool]$isError = $false) {
    $lblStatus.ForeColor = if ($isError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkGreen }
    $lblStatus.Text = $text
    $lblStatus.Refresh()
}

# Repopulate the commit dropdowns from the selected branch's log.
function Refresh-Commits {
    $repo = $txtRepo.Text.Trim()
    $cmbCommitA.Items.Clear(); $cmbCommitB.Items.Clear()
    $cmbCommitA.Text = ''; $cmbCommitB.Text = ''
    if (-not (Test-GitRepo $repo)) { return }
    $ref = [string]$cmbBranch.SelectedItem
    $commits = @(Get-Commits $repo $ref $script:CommitLimit)   # @() guards StrictMode unrolling
    if ($commits.Count -eq 0) { Set-Status 'No commits found.' $true; return }
    foreach ($c in $commits) { [void]$cmbCommitA.Items.Add($c); [void]$cmbCommitB.Items.Add($c) }
    # Default: A = older (index 1 if available), B = newest (index 0) -> left older, right newer.
    if ($cmbCommitA.Items.Count -gt 1) { $cmbCommitA.SelectedIndex = 1 } elseif ($cmbCommitA.Items.Count -gt 0) { $cmbCommitA.SelectedIndex = 0 }
    if ($cmbCommitB.Items.Count -gt 0) { $cmbCommitB.SelectedIndex = 0 }
    $scope = if ($ref) { $ref } else { 'HEAD' }
    Set-Status "$($commits.Count) commits on '$scope'."
}

# Repopulate the branch scope list, then the commits.
function Refresh-Branches {
    $repo = $txtRepo.Text.Trim()
    $cmbBranch.Items.Clear()
    if (-not (Test-GitRepo $repo)) {
        if ($repo) { Set-Status "Not a git repository: $repo" $true }
        $cmbCommitA.Items.Clear(); $cmbCommitB.Items.Clear()
        return
    }
    $branches = @(Get-Branches $repo $chkRemotes.Checked)
    if ($branches.Count -eq 0) { Set-Status 'No branches found.' $true; return }
    foreach ($b in $branches) { [void]$cmbBranch.Items.Add($b) }
    # Default the scope to the checked-out branch when possible.
    $cur = Get-CurrentBranch $repo
    $idx = if ($cur) { $cmbBranch.Items.IndexOf($cur) } else { -1 }
    $cmbBranch.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    Refresh-Commits
}

# --- Event handlers ---
$btnRepo.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select a git repository'
    if ($txtRepo.Text -and (Test-Path $txtRepo.Text)) { $dlg.SelectedPath = $txtRepo.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtRepo.Text = $dlg.SelectedPath
        Refresh-Branches
    }
})

$btnTool.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Executables (*.exe)|*.exe|All files (*.*)|*.*'
    $dlg.Title = 'Select diff tool (e.g. BCompare.exe)'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtTool.Text = $dlg.FileName
    }
})

$btnRefresh.Add_Click({ Refresh-Branches })
$chkRemotes.Add_CheckStateChanged({ Refresh-Branches })
$cmbBranch.Add_SelectedIndexChanged({ Refresh-Commits })
$btnSwap.Add_Click({
    $tmp = $cmbCommitA.Text
    $cmbCommitA.Text = $cmbCommitB.Text
    $cmbCommitB.Text = $tmp
})

# Toggle the controls that shouldn't be touched mid-export.
function Set-Busy([bool]$busy) {
    foreach ($c in @($btnCompare, $btnRepo, $btnTool, $btnRefresh, $btnSwap, $cmbBranch, $cmbCommitA, $cmbCommitB, $chkRemotes, $txtRepo, $txtTool)) {
        $c.Enabled = -not $busy
    }
    $progress.Visible = $busy
}

$btnCompare.Add_Click({
    $repo = $txtRepo.Text.Trim()
    $tool = $txtTool.Text.Trim()

    if (-not (Test-GitRepo $repo))             { Set-Status 'Pick a valid git repository first.' $true; return }
    if (-not $tool -or -not (Test-Path $tool)) { Set-Status 'Set a valid diff tool path (Browse to BCompare.exe).' $true; return }

    # First whitespace token of each combo is the commit-ish (hash from the list, or a pasted hash/ref).
    $tokA = ($cmbCommitA.Text.Trim() -split '\s+')[0]
    $tokB = ($cmbCommitB.Text.Trim() -split '\s+')[0]
    if (-not $tokA -or -not $tokB) { Set-Status 'Select or paste two commits.' $true; return }

    $shaA = Get-CommitSha $repo $tokA
    if (-not $shaA) { Set-Status "Not a valid commit: '$tokA'." $true; return }
    $shaB = Get-CommitSha $repo $tokB
    if (-not $shaB) { Set-Status "Not a valid commit: '$tokB'." $true; return }
    if ($shaA -eq $shaB) { Set-Status 'Pick two different commits.' $true; return }

    $leftRef = $shaA;   $rightRef = $shaB
    $leftLabel = $shaA; $rightLabel = $shaB
    $finalMsg = "Comparing $shaA vs $shaB."

    $session = Join-Path $script:TempRoot ([DateTime]::UtcNow.Ticks.ToString())
    New-Item -ItemType Directory -Path $session -Force | Out-Null

    # State the polling timer (script scope) needs after the background work finishes.
    $script:cmpDirA     = Join-Path $session (Get-SafeName $leftLabel)
    $script:cmpDirB     = Join-Path $session (Get-SafeName $rightLabel)
    $script:cmpFinalMsg = $finalMsg
    $script:cmpTool     = $tool
    # Shared, thread-safe channel for status/result between the runspace and the UI.
    $script:cmpShared = [hashtable]::Synchronized(@{ Status = "Exporting '$leftLabel'..."; Done = $false; Error = $null })

    $script:cmpRs = [runspacefactory]::CreateRunspace()
    $script:cmpRs.ApartmentState = 'MTA'
    $script:cmpRs.Open()
    $script:cmpPs = [powershell]::Create()
    $script:cmpPs.Runspace = $script:cmpRs
    [void]$script:cmpPs.AddScript($script:ExportScript).AddArgument($repo).AddArgument($leftRef).
        AddArgument($rightRef).AddArgument($script:cmpDirA).AddArgument($script:cmpDirB).
        AddArgument($leftLabel).AddArgument($rightLabel).AddArgument($script:cmpShared)
    $script:cmpHandle = $script:cmpPs.BeginInvoke()

    Set-Busy $true
    Set-Status $script:cmpShared['Status']
    $script:cmpTimer.Start()
})

# Polls the background export without freezing the window. Reads only $script: state.
$script:cmpTimer = New-Object System.Windows.Forms.Timer
$script:cmpTimer.Interval = 150
$script:cmpTimer.Add_Tick({
    Set-Status $script:cmpShared['Status']
    if (-not $script:cmpShared['Done']) { return }
    $script:cmpTimer.Stop()
    try { $script:cmpPs.EndInvoke($script:cmpHandle) } catch { }
    $script:cmpPs.Dispose(); $script:cmpRs.Dispose()
    Set-Busy $false
    if ($script:cmpShared['Error']) {
        Set-Status "Error: $($script:cmpShared['Error'])" $true
    } else {
        try {
            Start-Process -FilePath $script:cmpTool -ArgumentList @("`"$($script:cmpDirA)`"", "`"$($script:cmpDirB)`"")
            Set-Status $script:cmpFinalMsg
        } catch {
            Set-Status "Could not launch diff tool: $($_.Exception.Message)" $true
        }
    }
})

# Persist config on close
$form.Add_FormClosing({
    $cfg.diffToolPath   = $txtTool.Text.Trim()
    $cfg.lastRepo       = $txtRepo.Text.Trim()
    $cfg.includeRemotes = $chkRemotes.Checked
    $cfg.lastBranch     = [string]$cmbBranch.SelectedItem
    Save-Config $cfg
})

# Populate on startup if a repo was remembered / detected.
if ($txtRepo.Text) {
    Refresh-Branches
    # Restore the last-used scope branch if it still exists.
    if ($cfg.lastBranch) {
        $li = $cmbBranch.Items.IndexOf([string]$cfg.lastBranch)
        if ($li -ge 0) { $cmbBranch.SelectedIndex = $li }
    }
} elseif (-not $txtTool.Text) {
    Set-Status 'Browse to a git repository to begin. (Beyond Compare not auto-detected - set the diff tool path.)' $true
}

[void]$form.ShowDialog()
