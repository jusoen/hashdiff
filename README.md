# HashDiff

A tiny Windows GUI to compare **two commits of a git repository** side-by-side in
**Beyond Compare** (or any folder diff tool). Peer tool to
[BranchDiff](../BranchDiff), which compares two *branches*.

Git commits aren't folders, so HashDiff exports each selected commit's tree into its own
temp folder (via `git archive`) and then hands the two folders to your diff tool for a
full **whole-tree** comparison.

## Requirements

- Windows + PowerShell (built in)
- `git` on your PATH
- A folder diff tool — **Beyond Compare** is auto-detected (including per-user installs
  under `%LOCALAPPDATA%\Programs\Beyond Compare 5`); any tool that accepts
  `tool.exe <leftFolder> <rightFolder>` works.

## Usage

From any terminal (cmd, PowerShell, the VS Code terminal), just run:

```
hashdiff
```

(The install folder is on your **user PATH**, so `hashdiff` works from anywhere.
Open a *new* terminal after install so it picks up the PATH change.)

- If your terminal's current directory is **inside a git repo**, that repo is
  pre-selected automatically; otherwise the **last repo you used** is shown.

Then:
1. Pick a **Branch:** — this scopes the list of commits (defaults to the checked-out
   branch). Tick **Include remote branches** to also list `origin/*`.
2. Choose **Commit A** and **Commit B** from the dropdowns (each shows
   `shorthash  date  subject`). The dropdowns are **editable** — you can also paste any
   commit hash or ref. A is the left/older side, B is the right/newer side by default;
   use **Swap A/B** to reverse.
3. If the **Diff tool** box is empty, **Browse...** to your `BCompare.exe`. It's remembered.
4. Click **Compare** → a progress bar shows while the commits are exported (the window
   stays responsive), then Beyond Compare opens a folder comparison of the two commit
   trees.

The launcher runs the app **detached and windowless**: you can close the terminal you
started it from and it keeps running, with no lingering PowerShell window. A brief flash
on launch is normal.

## Where settings live
`%APPDATA%\HashDiff\config.json` — diff-tool path, last repository, "include remotes",
last scope branch, and `commitLimit` (how many recent commits to list, default 200).

## How it works
- `git -C <repo> log -n <limit> --format="%h  %ad  %s" <branch>` populates the commit
  dropdowns; the first token of each row is the short hash.
- The picked/pasted commit-ish is normalised with
  `git -C <repo> rev-parse --short --verify <token>^{commit}`.
- `git -C <repo> archive --format=zip <sha>` + `System.IO.Compression.ZipFile`
  materialises each commit's tree into `…\Temp\HashDiff\<session>\<sha>`. This runs on a
  background runspace so the GUI stays responsive.
- The diff tool is launched on the two folders. Old session folders are cleaned up
  automatically on the next launch.

## Files
- `hashdiff.cmd` — launcher; run `hashdiff` from a terminal.
- `HashDiff.vbs` — detached/windowless launch helper used by `hashdiff.cmd`.
- `HashDiff.ps1` — the GUI app.
- `icon.ico` — the window/title-bar icon.
- `tools\generate-icon.ps1` — regenerates `icon.ico` (only if you want to tweak the art).

## Notes & limits
- Only **tracked** files are exported (no untracked/ignored files, no `.git`).
- For very large repos the full-tree export can take a moment and use temp disk space;
  it's cleaned up next run.
- Submodules are not recursed into (a `git archive` limitation).
