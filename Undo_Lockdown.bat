@echo off
:: ==================================================================
:: LOCKDOWN UNDO - fully reverses Lockdown_Master.bat
::   - stops & deletes every WebFilter_* scheduled task
::   - kills the running USB/Store killer
::   - removes all browser filter policies (Chrome/Edge/Brave + Firefox/Zen)
::     from HKLM and from EVERY user hive
::   - removes the Store block, per-user installer block, USB policy, SRP,
::     the PowerShell ExecutionPolicy override, Run-key launchers and the
::     startup-delay tweak
::   - clears the deny-execute ACLs on Downloads/Desktop/Documents/etc
::   - deletes C:\ProgramData\BrowserFilter and the Startup-folder copy
:: Run as administrator. A reboot afterwards clears any last in-memory bits.
:: ==================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 2>nul
    if errorlevel 1 (
        echo Automatic elevation failed.
        echo Right-click this file and choose Run as administrator.
        pause
    )
    exit /b
)

setlocal enabledelayedexpansion
title Lockdown Undo
set "UNDO_VERSION=v2.1  (2026-10-22, matches Lockdown v15.9 - http/https block)"
set "TARGET_DIR=C:\ProgramData\BrowserFilter"

echo.
echo  ============================================================
echo    LOCKDOWN UNDO   %UNDO_VERSION%
echo    This will REMOVE the whole web filter and app lockdown
echo    from this PC (all users). Deleting the whole policy key
echo    clears the http/https blocklist and every allow entry.
echo  ============================================================
echo.
set /p go="Type YES to proceed: "
if /i not "%go%"=="YES" (echo Cancelled. & pause & exit /b)
echo.

:: ---- remember the restricted user (for ACL cleanup) before we delete files
set "target="
if exist "%TARGET_DIR%\config.txt" set /p target=<"%TARGET_DIR%\config.txt"
if defined target for /f "tokens=1" %%t in ("!target!") do set "target=%%t"

:: ================================================================
echo [1/8] Stopping and deleting scheduled tasks...
for %%T in (
    "WebFilter_Boot" "WebFilter_Logon" "WebFilter_Poll" "WebFilter_Wrapper"
    "WebFilter_Engine" "WebFilter_UsbWatch" "WebFilter_UsbGuard" "WebFilter_Denied"
    "WebFilter_UI_Logon" "WebFilter_ExplorerBounce"
    "WebFilter_EvtUnlock" "WebFilter_EvtReconnect" "WebFilter_EvtDisconnect" "WebFilter_EvtSessionLogon"
    "USB_Watch_System" "USB_Blocker_Task" "USB_Blocker_Logon" "Exempt_Filter"
) do (
    schtasks /end /tn "%%~T" >nul 2>&1
    schtasks /delete /tn "%%~T" /f >nul 2>&1
)
:: per-user logon tasks + any other WebFilter_* task
for /f "delims=" %%u in ('dir /b /ad C:\Users 2^>nul ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do schtasks /delete /tn "WebFilter_Logon_%%u" /f >nul 2>&1
for /f "tokens=*" %%T in ('schtasks /query /fo list 2^>nul ^| findstr /i "TaskName:" ^| findstr /i "WebFilter USB_Watch USB_Blocker"') do (
    set "tn=%%T"
    set "tn=!tn:TaskName:=!"
    set "tn=!tn: =!"
    schtasks /delete /tn "!tn!" /f >nul 2>&1
)

:: ================================================================
echo [2/8] Killing the running killer / popup processes...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -like '*BrowserFilter*' -or $_.CommandLine -like '*usb_watch*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
taskkill /f /fi "WINDOWTITLE eq WebFilterWatch" >nul 2>&1
taskkill /f /fi "WINDOWTITLE eq ACCESS DENIED" >nul 2>&1

:: ================================================================
echo [3/8] Removing machine-wide (HKLM) policies...
for %%V in ("SOFTWARE\Policies" "SOFTWARE\WOW6432Node\Policies") do (
    for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do (
        reg delete "HKLM\%%~V\%%~B\URLBlocklist" /f >nul 2>&1
        reg delete "HKLM\%%~V\%%~B\URLAllowlist" /f >nul 2>&1
        reg delete "HKLM\%%~V\%%~B" /v DownloadRestrictions /f >nul 2>&1
    )
    reg delete "HKLM\%%~V\Microsoft\Edge" /v SmartScreenEnabled /f >nul 2>&1
    reg delete "HKLM\%%~V\Microsoft\Edge" /v SmartScreenPuaEnabled /f >nul 2>&1
    reg delete "HKLM\%%~V\Microsoft\Edge" /v PreventSmartScreenPromptOverride /f >nul 2>&1
    reg delete "HKLM\%%~V\Microsoft\Edge" /v PreventSmartScreenPromptOverrideForFiles /f >nul 2>&1
    reg delete "HKLM\%%~V\Mozilla\Firefox\WebsiteFilter" /f >nul 2>&1
    reg delete "HKLM\%%~V\Zen" /f >nul 2>&1
)
:: PowerShell ExecutionPolicy override the lockdown added
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /v EnableScripts /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /v ExecutionPolicy /f >nul 2>&1
:: SRP (Software Restriction Policies) the lockdown may have written
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Safer" /f >nul 2>&1
:: Run-key launchers + startup-delay tweaks
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v WebFilter_UIHook /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v LockdownBoot /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoStartupDelay /f >nul 2>&1
reg delete "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /f >nul 2>&1

:: ================================================================
echo [4/8] Cleaning policies from every loaded user hive (HKU)...
for /f "tokens=2 delims=\" %%s in ('reg query HKU 2^>nul') do (
    if /i not "%%s"==".DEFAULT" (
        echo %%s| find /i "_Classes" >nul 2>&1 || call :clean_hive "HKU\%%s"
    )
)

:: ================================================================
echo [5/8] Cleaning policies from every OFFLINE user profile...
for /f "delims=" %%u in ('dir /b /ad C:\Users 2^>nul ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do (
    set "usid="
    for /f %%s in ('powershell -NoProfile -Command "(Get-LocalUser '%%u').SID.Value" 2^>nul') do set "usid=%%s"
    set "loaded=0"
    if defined usid (reg query "HKU\!usid!" >nul 2>&1 && set "loaded=1")
    if "!loaded!"=="0" (
        if exist "C:\Users\%%u\NTUSER.DAT" (
            reg load "HKU\UndoTmp" "C:\Users\%%u\NTUSER.DAT" >nul 2>&1
            if not errorlevel 1 (
                call :clean_hive "HKU\UndoTmp"
                reg unload "HKU\UndoTmp" >nul 2>&1
            )
        )
    )
)

:: ================================================================
echo [6/8] Clearing deny-execute ACLs from user folders...
for /f "delims=" %%u in ('dir /b /ad C:\Users 2^>nul ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do (
    for %%F in (
        "C:\Users\%%u\Downloads" "C:\Users\%%u\Desktop" "C:\Users\%%u\Documents"
        "C:\Users\%%u\AppData\Local\Temp"
        "C:\Users\%%u\OneDrive\Downloads" "C:\Users\%%u\OneDrive\Desktop" "C:\Users\%%u\OneDrive\Documents"
    ) do if exist "%%~F" icacls "%%~F" /remove:d "%%u" >nul 2>&1
)
for %%F in ("C:\Users\Public\Downloads" "C:\Users\Public\Desktop" "C:\Users\Public\Documents") do (
    if exist "%%~F" (
        if defined target icacls "%%~F" /remove:d "!target!" >nul 2>&1
    )
)

:: ================================================================
echo [7/8] Restoring lock/unlock auditing to default...
auditpol /set /subcategory:"Other Logon/Logoff Events" /success:disable /failure:disable >nul 2>&1

:: ================================================================
echo [8/8] Deleting the lockdown's files...
del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\WebFilter_UI.cmd" >nul 2>&1
rd /s /q "%TARGET_DIR%" >nul 2>&1

echo.
echo  ============================================================
echo    DONE. The lockdown has been removed.
echo    REBOOT now to clear anything still in memory.
echo  ============================================================
echo.
pause
endlocal
exit /b 0

:: ==================================================================
:clean_hive   (%~1 = hive root, e.g. HKU\S-1-5-21-... or HKU\UndoTmp)
reg delete "%~1\Software\Policies\Google\Chrome\URLBlocklist" /f >nul 2>&1
reg delete "%~1\Software\Policies\Google\Chrome\URLAllowlist" /f >nul 2>&1
reg delete "%~1\Software\Policies\Google\Chrome" /v DownloadRestrictions /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Edge\URLBlocklist" /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Edge\URLAllowlist" /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Edge" /v DownloadRestrictions /f >nul 2>&1
reg delete "%~1\Software\Policies\BraveSoftware\Brave\URLBlocklist" /f >nul 2>&1
reg delete "%~1\Software\Policies\BraveSoftware\Brave\URLAllowlist" /f >nul 2>&1
reg delete "%~1\Software\Policies\Mozilla\Firefox\WebsiteFilter" /f >nul 2>&1
reg delete "%~1\Software\Policies\Zen" /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\WindowsStore" /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Windows\Installer" /v DisableUserInstalls /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Windows\Installer" /v AlwaysInstallElevated /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Windows\RemovableStorageDevices" /f >nul 2>&1
reg delete "%~1\Software\Policies\Microsoft\Windows\Safer" /f >nul 2>&1
reg delete "%~1\Software\Microsoft\Windows\CurrentVersion\Run" /v USBWatch /f >nul 2>&1
reg delete "%~1\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /f >nul 2>&1
exit /b 0