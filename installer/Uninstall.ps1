# Heptapod L Studio - uninstall helper (run by the Windows uninstaller)
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match '\\HeptapodStudio\\server\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 1
$app = Join-Path $env:LOCALAPPDATA 'HeptapodStudio'
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'HeptapodStudio.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force }
