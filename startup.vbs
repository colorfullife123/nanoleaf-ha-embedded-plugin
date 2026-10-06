Option Explicit
Dim shell, files, folder, script, arguments, command, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
folder = files.GetParentFolderName(WScript.ScriptFullName)
script = files.BuildPath(folder, "launch.ps1")
arguments = ""
If WScript.Arguments.Count > 0 Then
    Select Case LCase(WScript.Arguments(0))
        Case "--hidden": arguments = " -Hidden"
        Case "--repair": script = files.BuildPath(folder, "repair.ps1")
        Case Else: WScript.Quit 2
    End Select
End If
command = """" & shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe") & """" & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """" & arguments
' wscript.exe has no console. SW_HIDE is applied when creating PowerShell,
' rather than waiting for PowerShell to hide a console that is already visible.
result = shell.Run(command, 0, True)
WScript.Quit result
