' Detached, windowless launcher used by hashdiff.cmd.
'
' Run by wscript.exe (a GUI host with no console). It starts PowerShell THROUGH
' conhost.exe, which forces a classic console host (bypassing Windows Terminal, which
' ignores -WindowStyle Hidden) so the app's console is genuinely hidden. Because
' wscript launches it fully detached, you can close the terminal you started it from
' and the app keeps running.
'
' Arg 0 (optional): the directory to detect a git repo from (the launching terminal's
' current directory). Falls back to wscript's current directory.
' Args 1 and 2 (optional): commit hashes/refs for Commit A and Commit B.
Option Explicit
Dim fso, sh, scriptDir, ps1, launchDir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\HashDiff.ps1"
If WScript.Arguments.Count >= 1 Then
    launchDir = WScript.Arguments(0)
Else
    launchDir = sh.CurrentDirectory
End If
cmd = "conhost.exe powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden" & _
      " -File """ & ps1 & """ -LaunchDir """ & launchDir & """"
' Quotes are stripped because git refs cannot contain them and they would break the command line.
If WScript.Arguments.Count >= 2 Then
    cmd = cmd & " -CommitA """ & Replace(WScript.Arguments(1), """", "") & """"
End If
If WScript.Arguments.Count >= 3 Then
    cmd = cmd & " -CommitB """ & Replace(WScript.Arguments(2), """", "") & """"
End If
' 0 = hidden window, False = don't wait
sh.Run cmd, 0, False
