Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\App\PromptCue.ps1"
objShell.Run "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """", 0, False
