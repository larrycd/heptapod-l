; Heptapod L Studio - Windows setup (per-user, no administrator rights)
Unicode true
SetCompressor /SOLID lzma
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define APPNAME "Heptapod L Studio"
!define VERSION "1.1.1"
!define PUBLISHER "Larry Dalton"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\HeptapodL"

Name "${APPNAME}"
OutFile "HeptapodL-Setup.exe"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\HeptapodL-Setup"
BrandingText "Heptapod L - a circular script by Larry Dalton"
VIProductVersion "1.1.1.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "Heptapod L Studio setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Heptapod L by Larry Dalton"

!define MUI_ICON "heptapodl.ico"
!define MUI_UNICON "heptapodl.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Heptapod L Studio ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "Heptapod L - a circular script by Larry Dalton.$\r$\n$\r$\nThis will:$\r$\n  - install Heptapod L Studio for your Windows account (no administrator rights needed)$\r$\n  - start it at sign-in and open it at http://localhost:8765/$\r$\n  - place the three Heptapod L infographics on your Desktop$\r$\n$\r$\nA PowerShell window shows the install checks. If any check fails, your previous version is restored automatically."
!define MUI_FINISHPAGE_TITLE "Heptapod L Studio is installed"
!define MUI_FINISHPAGE_TEXT "Heptapod L Studio is running at http://localhost:8765/ and starts automatically when you sign in.$\r$\n$\r$\nThe three infographics are on your Desktop:$\r$\n  Heptapod L - How It Works.png$\r$\n  Heptapod L - Positional Map.png$\r$\n  Heptapod L - Positional Map (Paper).png"
!define MUI_FINISHPAGE_LINK "Open Heptapod L Studio"
!define MUI_FINISHPAGE_LINK_LOCATION "http://localhost:8765/"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var PS
Var RES

Function .onInit
  SetShellVarContext current
FunctionEnd
Function un.onInit
  SetShellVarContext current
FunctionEnd

Section "Install"
  SetShellVarContext current
  ${If} ${RunningX64}
    ${DisableX64FSRedirection}
  ${EndIf}
  StrCpy $PS "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$PS" +3 0
    MessageBox MB_ICONSTOP "Windows PowerShell was not found ($PS). Heptapod L Studio needs Windows PowerShell 5.1."
    Abort "Windows PowerShell not found."

  ; package files
  SetOutPath "$INSTDIR"
  File "Install.ps1"
  File "Uninstall.ps1"
  File "heptapodl.ico"

  ; infographics on the Desktop
  DetailPrint "Placing the infographics on your Desktop..."
  SetOutPath "$DESKTOP"
  File "Heptapod L - Positional Map.png"
  File "Heptapod L - Positional Map (Paper).png"
  File "Heptapod L - How It Works.png"
  SetOutPath "$INSTDIR"

  ; run the verified PowerShell install (backup, port check, self-test, rollback)
  DetailPrint "Installing and verifying Heptapod L Studio (see the PowerShell window)..."
  Delete "$TEMP\HeptapodL-install-result.txt"
  ExecWait '"$PS" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install.ps1"'
  StrCpy $RES ""
  ClearErrors
  FileOpen $0 "$TEMP\HeptapodL-install-result.txt" r
  ${IfNot} ${Errors}
    FileRead $0 $RES
    FileClose $0
  ${EndIf}
  StrCpy $1 $RES 2
  ${If} $1 != "OK"
    ${If} $RES == ""
      StrCpy $RES "The PowerShell install did not report a result."
    ${EndIf}
    DetailPrint "Install failed: $RES"
    MessageBox MB_ICONSTOP "Heptapod L Studio was not installed.$\r$\n$\r$\n$RES$\r$\n$\r$\nYour previous version (if any) has been restored. The infographics are still on your Desktop."
    Abort "Heptapod L Studio was not installed."
  ${EndIf}
  DetailPrint "Install verified: engine, image decoder and self-test passed."

  ; shortcuts
  WriteINIStr "$SMPROGRAMS\Heptapod L Studio.url" "InternetShortcut" "URL" "http://localhost:8765/"
  WriteINIStr "$SMPROGRAMS\Heptapod L Studio.url" "InternetShortcut" "IconFile" "$INSTDIR\heptapodl.ico"
  WriteINIStr "$SMPROGRAMS\Heptapod L Studio.url" "InternetShortcut" "IconIndex" "0"
  WriteINIStr "$DESKTOP\Heptapod L Studio.url" "InternetShortcut" "URL" "http://localhost:8765/"
  WriteINIStr "$DESKTOP\Heptapod L Studio.url" "InternetShortcut" "IconFile" "$INSTDIR\heptapodl.ico"
  WriteINIStr "$DESKTOP\Heptapod L Studio.url" "InternetShortcut" "IconIndex" "0"

  ; uninstaller (Settings > Apps)
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\heptapodl.ico"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$LOCALAPPDATA\HeptapodStudio"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "URLInfoAbout" "http://localhost:8765/"
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  ${If} ${RunningX64}
    ${DisableX64FSRedirection}
  ${EndIf}
  ExecWait '"$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\Uninstall.ps1"'
  Delete "$SMPROGRAMS\Heptapod L Studio.url"
  Delete "$DESKTOP\Heptapod L Studio.url"
  DeleteRegKey HKCU "${UNINSTKEY}"
  Delete "$INSTDIR\Install.ps1"
  Delete "$INSTDIR\Uninstall.ps1"
  Delete "$INSTDIR\heptapodl.ico"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  MessageBox MB_ICONINFORMATION "Heptapod L Studio has been removed.$\r$\nThe infographics on your Desktop and earlier backups (HeptapodStudio-backup-*) were left in place."
SectionEnd
