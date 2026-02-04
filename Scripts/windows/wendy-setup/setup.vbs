' Use WScript.Shell to safely read and update the PATH
Dim objShell, fso, regPath, currentPath, newDirectory, pathArray, newPath
Dim i, found
Dim pf, pf64, pf86

Set objShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

regPath = "HKLM\System\CurrentControlSet\Control\Session Manager\Environment"
' Determine install directory under Program Files; avoid SysWOW64 fallback
pf64 = objShell.ExpandEnvironmentStrings("%ProgramW6432%")
If pf64 <> "%ProgramW6432%" Then
    pf = pf64
Else
    pf = objShell.ExpandEnvironmentStrings("%ProgramFiles%")
End If
pf86 = objShell.ExpandEnvironmentStrings("%ProgramFiles(x86)%")

newDirectory = pf & "\Wendy Labs\Wendy Tools"
If Not fso.FolderExists(newDirectory) Then
    If pf86 <> "%ProgramFiles(x86)%" Then
        If fso.FolderExists(pf86 & "\Wendy Labs\Wendy Tools") Then
            newDirectory = pf86 & "\Wendy Labs\Wendy Tools"
        End If
    End If
End If
If Not fso.FolderExists(newDirectory) Then
    newDirectory = objShell.CurrentDirectory
End If
If Right(newDirectory, 1) = "\" Then newDirectory = Left(newDirectory, Len(newDirectory) - 1)

' Read current PATH
On Error Resume Next
currentPath = objShell.RegRead(regPath & "\Path")
On Error GoTo 0

If currentPath = "" Then
    currentPath = ""
End If

' Check if directory already exists in PATH (normalize and compare case-insensitive)
pathArray = Split(currentPath, ";")
found = False

For i = LBound(pathArray) To UBound(pathArray)
    Dim existing
    existing = Trim(pathArray(i))
    If Right(existing, 1) = "\" Then existing = Left(existing, Len(existing) - 1)
    If LCase(existing) = LCase(newDirectory) Then
        found = True
        Exit For
    End If
Next

If Not found Then
    ' Append the new directory
    If Len(currentPath) = 0 Then
        newPath = newDirectory
    Else
        If Right(currentPath, 1) = ";" Then
            newPath = currentPath & newDirectory
        Else
            newPath = currentPath & ";" & newDirectory
        End If
    End If
    Do While InStr(newPath, ";;") > 0
        newPath = Replace(newPath, ";;", ";")
    Loop
    
    ' Update registry
    objShell.RegWrite regPath & "\Path", newPath, "REG_EXPAND_SZ"
End If