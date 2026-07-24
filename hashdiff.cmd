@echo off
REM HashDiff launcher. Type `hashdiff` from any terminal (cmd, PowerShell,
REM the VS Code terminal, ...). If the current directory is inside a git repo,
REM that repo is pre-selected; otherwise the last repo you used is shown.
REM
REM Delegates to HashDiff.vbs (via wscript) which launches the GUI fully detached and
REM windowless, so you can close this terminal and the app keeps running with no
REM lingering PowerShell window. "%CD%" tells it which directory to detect a repo from.
wscript.exe "%~dp0HashDiff.vbs" "%CD%"
