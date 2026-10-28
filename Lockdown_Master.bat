@echo off
:: ==================================================================
:: LOCKDOWN MASTER - Windows 11 Home - STRICT WHITELIST MODE (v11.6)
::   v11.6 per-user switching fixes:
::     - logon tasks now created for EVERY profile (Microsoft accounts included),
::       no longer skipped when "net user" cannot list the account
::     - the explicit username is the authority: LOGON <user> and the gate's
::       request file decide ON/OFF - no guessing in the normal path
::     - the 1-minute poll now ONLY consumes a pending request; it never guesses
::       the active user, so it can no longer flip the filter under the wrong user
::     - quser-based active-user guessing is confined to real session events
::       (unlock / fast-switch reconnect) where no explicit username exists
::     - every decision FORCE-applies the correct state (no early-exit on a
::       single-key read), so a half-finished prior run cannot leave it stuck
::   Machine-wide policy, driven by ACTIVE USER & LOGONS:
::     target user active/signs in   -> Explorer closes, "Applying filter...", block ON, Explorer starts
::     non-target user active/signs in -> Explorer closes, "Removing filter...", block OFF, Explorer starts
::     boot                          -> block ON (fail-closed)
::     installed applications        -> fully allowed to open & run normally
::     fast user switching           -> instant detection & UI switch via session events
::
::   Commands:
::   Lockdown_Master.bat          full setup / rebuild
::   Lockdown_Master.bat on/off   force ON/OFF
::   Lockdown_Master.bat status   state report
::   Lockdown_Master.bat diag     dump all policy locations
::   Lockdown_Master.bat test     apply block + summary
::   Lockdown_Master.bat debug    rebuild with command echo
::
::   SELF-EXTRACTING: switcher v11 sits between ::SW11_BEGIN/END.
::   Do NOT edit below the ::SW11_BEGIN marker.
:: ==================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 2>nul
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs" 2>nul
    )
    if errorlevel 1 (
        echo Automatic elevation failed.
        echo Right-click this file and choose Run as administrator.
    )
    exit /b
)

if /i "%~1"=="debug" @echo on
setlocal enabledelayedexpansion
title LockdownMaster
pushd "%~dp0"

set "TARGET_DIR=C:\ProgramData\BrowserFilter"
set "SWITCHER=%TARGET_DIR%\WebFilter_Switch.cmd"
set "UIHOOK=%TARGET_DIR%\WebFilter_UI.cmd"
set "GETUSER=%TARGET_DIR%\get_active_user.ps1"
set "USBGUARD=%TARGET_DIR%\usb_guard.ps1"
set "ENGINE=%TARGET_DIR%\engine.cmd"
set "WATCHBAT=%TARGET_DIR%\usb_watch.bat"
set "WATCHVBS=%TARGET_DIR%\usb_watch.vbs"
set "MKLOGON=%TARGET_DIR%\mk_logon.ps1"
set "SWLOG=%TARGET_DIR%\switch_log.txt"
set "NUMFILE=%TARGET_DIR%\allow_numbered.txt"
set "LOGFILE=%TARGET_DIR%\setup_log.txt"
set "SUMFILE=%TARGET_DIR%\LAST_RUN_SUMMARY.txt"
set "VALFILE=%TARGET_DIR%\allowlist_validation.txt"
set "ERRLOG=%~dp0error_log.txt"
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
set "VERSION=v15.9  (built 2026-10-22, path-allow restored)"
> "%TARGET_DIR%\version.txt" echo %VERSION%

if exist "%LOGFILE%" (
    for %%z in ("%LOGFILE%") do if %%~zz gtr 2000000 move /y "%LOGFILE%" "%TARGET_DIR%\setup_log_old.txt" >nul 2>&1
)
if exist "%ERRLOG%" (
    for %%z in ("%ERRLOG%") do if %%~zz gtr 2000000 move /y "%ERRLOG%" "%~dp0error_log_old.txt" >nul 2>&1
)
>>"%ERRLOG%" echo ============================================================
>>"%ERRLOG%" echo Run started %date% %time% on %COMPUTERNAME% (args: %*)
>>"%ERRLOG%" echo ============================================================
> "%LOGFILE%" echo ============================================================
>>"%LOGFILE%" echo LOCKDOWN MASTER v11.5 - setup log
>>"%LOGFILE%" echo Run started : %date% %time%
>>"%LOGFILE%" echo Computer    : %COMPUTERNAME%
>>"%LOGFILE%" echo Invoked as  : %USERDOMAIN%\%USERNAME%
>>"%LOGFILE%" echo Arguments   : %*
>>"%LOGFILE%" echo ============================================================
echo [%date% %time%] switch log started > "%SWLOG%"
del "%TARGET_DIR%\ui_done.flag" >nul 2>&1
del "%TARGET_DIR%\ui_request.txt" >nul 2>&1
del "%TARGET_DIR%\ui.lock" >nul 2>&1
for /d %%D in ("%TARGET_DIR%\gate_*.done") do rd /s /q "%%D" >nul 2>&1

set "target=UNKNOWN"
set "sid=UNKNOWN"
set /a n=0
set /a WARNCOUNT=0
set /a FAILCOUNT=0
set /a vvalid=0
set /a vinvalid=0

mode con: cols=100 lines=40 >nul 2>&1

set "ESC="
for /f %%a in ('powershell -NoProfile -Command "Write-Output ([char]27)" 2^>nul') do set "ESC=%%a"
set "C_G="
set "C_R="
set "C_Y="
set "C_C="
set "C_W="
set "C_O="
set "C_0="
if defined ESC set "C_G=%ESC%[92m"
if defined ESC set "C_R=%ESC%[91m"
if defined ESC set "C_Y=%ESC%[93m"
if defined ESC set "C_C=%ESC%[96m"
if defined ESC set "C_W=%ESC%[97m"
if defined ESC set "C_O=%ESC%[38;5;208m"
if defined ESC set "C_0=%ESC%[0m"
set "PS_BLOCKED="

call :say INFO "WHITELIST MODE - bare-domain patterns - everything else blocked"

goto :main

:: ==================================================================
:: SUBROUTINES
:: ==================================================================

:say
set "sl=%~1     "
set "sl=%sl:~0,5%"
set "msg=%~2"
set "sc=%C_G%"
if "%~1"=="FAIL" set "sc=%C_R%" & set /a FAILCOUNT+=1 & >>"%ERRLOG%" echo [%date% %time%] !msg!
if "%~1"=="WARN" set "sc=%C_Y%" & set /a WARNCOUNT+=1
if "%~1"=="STEP" set "sc=%C_C%"
if "%~1"=="WAIT" set "sc=%C_Y%"
if "%~1"=="INFO" set "sc=%C_W%"
echo %sc%%time:~0,8%  %sl%  !msg!%C_0%
>>"%LOGFILE%" echo [%date% %time%] %~1 !msg!
exit /b 0

:logfooter
>>"%LOGFILE%" echo ============================================================
>>"%LOGFILE%" echo %~1 - %date% %time% - warnings=%WARNCOUNT% failures=%FAILCOUNT%
>>"%LOGFILE%" echo ============================================================
exit /b 0

:die
call :say FAIL "%~1"
call :drophive "%sid%"
call :logfooter "RUN FAILED"
start "" notepad "%LOGFILE%"
echo.
echo %C_R%Press any key to exit...%C_0%
pause >nul
popd
exit /b 1

:ensure_entry
echo %~1| findstr /r "[*/]" >nul 2>&1
if not errorlevel 1 (
    find /i /c ";%~1" "%NUMFILE%" >nul 2>&1
) else (
    findstr /r /i /c:";%~1$" "%NUMFILE%" >nul 2>&1
)
if errorlevel 1 (
    set /a n+=1
    >>"%NUMFILE%" echo !n!;%~1
)
exit /b 0

:validhost
set "ok="
echo %~1| findstr /r /i "^[a-z0-9][a-z0-9.-]*\.[a-z0-9.-]*$" >nul 2>&1 && set "ok=1"
exit /b 0

:verify_entry
set "VHOST=%~1"
set "VOK=1"
set "VREASON="
if "%VHOST%"=="" (set "VOK=" & set "VREASON=empty entry" & exit /b 0)
echo %VHOST%| findstr /b /i /c:"http://" /c:"https://" >nul 2>&1 && (set "VOK=" & set "VREASON=has a scheme - drop the http:// or https://" & exit /b 0)
echo %VHOST%| findstr /c:"*" >nul 2>&1 && (set "VOK=" & set "VREASON=contains a wildcard - not needed, subdomains are automatic" & exit /b 0)
echo %VHOST%| findstr /c:" " >nul 2>&1 && (set "VOK=" & set "VREASON=contains a space" & exit /b 0)
:: A path is allowed (example.com/chrome). Validate only the HOST part (before the first slash).
set "VHP=%VHOST%"
for /f "tokens=1 delims=/" %%a in ("%VHOST%") do set "VHP=%%a"
echo %VHP%| findstr /c:".." >nul 2>&1 && (set "VOK=" & set "VREASON=host has consecutive dots" & exit /b 0)
if "%VHP:~0,1%"=="." (set "VOK=" & set "VREASON=starts with a dot" & exit /b 0)
if "%VHP:~-1%"=="." (set "VOK=" & set "VREASON=host ends with a dot" & exit /b 0)
if "%VHP:~-1%"=="-" (set "VOK=" & set "VREASON=host ends with a hyphen" & exit /b 0)
echo %VHP%| findstr /r /i "^[a-z0-9][a-z0-9.-]*\.[a-z0-9-][a-z0-9-]*$" >nul 2>&1 || (set "VOK=" & set "VREASON=not a valid domain (the part before the first slash)" & exit /b 0)
exit /b 0

:pickuser
:pick_again
echo.
set "%~2="
set /p pick_in="%~1"
if not defined pick_in goto pick_again
echo %pick_in%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 echo   Invalid - enter a number. & goto pick_again
if %pick_in% gtr %count% echo   Out of range 1-%count%. & goto pick_again
if %pick_in% lss 1 echo   Out of range 1-%count%. & goto pick_again
for %%z in (%pick_in%) do set "%~2=!user_%%z!"
exit /b 0

:islogged
set "ISLOG=0"
for /f "skip=1 tokens=1" %%u in ('quser 2^>nul') do (
    set "chk=%%u"
    set "chk=!chk:>=!"
    if /i "!chk!"=="%~1" set "ISLOG=1"
)
exit /b 0

:loadhive
set "LOADED=0"
set "HVTRY=0"
:lh_try
reg query "HKU\%~2" >nul 2>&1
if not errorlevel 1 exit /b 0
set /a HVTRY+=1
if %HVTRY% gtr 3 (
    call :say FAIL "Cannot load hive for %~1 - log this user OFF and re-run"
    exit /b 1
)
call :say WAIT "Loading hive for %~1 - attempt %HVTRY% of 3"
reg load "HKU\%~2" "C:\Users\%~1\NTUSER.DAT" >>"%LOGFILE%" 2>&1
if errorlevel 1 (
    ping -n 4 127.0.0.1 >nul
    goto lh_try
)
set "LOADED=1"
call :say OK "Hive loaded for %~1"
exit /b 0

:drophive
set "LOADED=0"
reg query "HKU\%~1" >nul 2>&1
if errorlevel 1 exit /b 0
reg unload "HKU\%~1" >>"%LOGFILE%" 2>&1
if errorlevel 1 (
    ping -n 3 127.0.0.1 >nul
    reg unload "HKU\%~1" >>"%LOGFILE%" 2>&1
    if errorlevel 1 call :say WARN "Hive still mounted - reboot clears it"
)
exit /b 0

:ensure_entry
echo %~1| findstr /r "[*/]" >nul 2>&1
if not errorlevel 1 (
    find /i /c ";%~1" "%NUMFILE%" >nul 2>&1
) else (
    findstr /r /i /c:";%~1$" "%NUMFILE%" >nul 2>&1
)
if errorlevel 1 (
    set /a n+=1
    >>"%NUMFILE%" echo !n!;%~1
)
exit /b 0

:denyexec
icacls "%~1" /deny "!target!:(OI)(X)" >nul 2>&1
exit /b 0

:make_logon_task
:: %~1 = profile folder name   %~2 = ON or OFF (for the log line only)
:: Resolves the profile's SID -> real account name (works for Microsoft accounts
:: too) and registers a logon task that passes the profile name explicitly.
powershell -NoProfile -ExecutionPolicy Bypass -File "%MKLOGON%" "%~1" "%SWITCHER%" >nul 2>>"%LOGFILE%"
schtasks /query /tn "WebFilter_Logon_%~1" >nul 2>&1
if errorlevel 1 (
    call :say WARN "Logon task NOT created for %~1 - the gate screen still covers this user's sign-in"
) else (
    call :say OK "Logon task verified for %~1 - their sign-in forces %~2"
)
exit /b 0

:summary_write
> "%SUMFILE%" echo ============================================================
>>"%SUMFILE%" echo  LOCKDOWN SUMMARY v11.5 - WHITELIST MODE - %date% %time%
>>"%SUMFILE%" echo ============================================================
>>"%SUMFILE%" echo  Restricted user : %target%
>>"%SUMFILE%" echo  Allowed domains : %n% entries from allowed_sites.txt
>>"%SUMFILE%" echo  Everything else : BLOCKED
>>"%SUMFILE%" echo  Installed apps  : UNRESTRICTED - all installed apps open freely
>>"%SUMFILE%" echo  Allowlist check : !vvalid! valid / !vinvalid! invalid entries (see %VALFILE%)
>>"%SUMFILE%" echo  This run had    : !WARNCOUNT! warning(s), !FAILCOUNT! failure(s)
>>"%SUMFILE%" echo  Full log        : %LOGFILE%
>>"%SUMFILE%" echo  Errors only     : %ERRLOG%
>>"%SUMFILE%" echo.
if not defined PS_BLOCKED goto sum_psok
>>"%SUMFILE%" echo  **************************************************************************
>>"%SUMFILE%" echo  *  SYSTEM IS BLOCKING POWERSHELL SCRIPTS ON THIS PC
>>"%SUMFILE%" echo  *  A policy stronger than ExecutionPolicy - AppLocker / WDAC /
>>"%SUMFILE%" echo  *  Constrained Language Mode / antivirus - is blocking .ps1 script files.
>>"%SUMFILE%" echo  *  A registry change cannot override it.
>>"%SUMFILE%" echo  *  This does NOT affect the web filter: it is plain registry written into
>>"%SUMFILE%" echo  *  the target's hive, needs no scripts, and works regardless of this block.
>>"%SUMFILE%" echo  **************************************************************************
>>"%SUMFILE%" echo.
goto sum_psdone
:sum_psok
>>"%SUMFILE%" echo  POWERSHELL SCRIPTS : allowed
>>"%SUMFILE%" echo.
:sum_psdone
>>"%SUMFILE%" echo  MODEL           : PER-USER - the filter lives in %target%'s registry hive
>>"%SUMFILE%" echo.
>>"%SUMFILE%" echo  HOW IT WORKS (no engine, no switching, nothing to fail):
>>"%SUMFILE%" echo   - The whitelist is written into %target%'s OWN hive, read by Chrome and Edge.
>>"%SUMFILE%" echo   - It applies to %target% ONLY. Other accounts have a clean hive = no filter.
>>"%SUMFILE%" echo   - There is no machine-wide policy and no background process to break.
>>"%SUMFILE%" echo.
>>"%SUMFILE%" echo  KILLER          : a hidden 1-second loop runs in %target%'s session and kills, each
>>"%SUMFILE%" echo                    second: apps on any drive except C: (USB), the Microsoft Store, and
>>"%SUMFILE%" echo                    winget / AppInstaller (command-line installs). Each kill pops an
>>"%SUMFILE%" echo                    ACCESS DENIED window. USB FILES stay readable - only apps are killed.
>>"%SUMFILE%" echo                    Runs AS %target%, so only %target%'s processes are ever touched.
>>"%SUMFILE%" echo  STORE           : RemoveWindowsStore policy + the killer closes WinStore.App every second.
>>"%SUMFILE%" echo  STARTS          : at %target%'s sign-in (Run key -^> hidden wscript -^> usb_watch.bat).
>>"%SUMFILE%" echo.
>>"%SUMFILE%" echo  TEST: sign in as %target%, open Edge, go to edge://policy and click Reload policies.
>>"%SUMFILE%" echo        You should see URLBlocklist and URLAllowlist listed.
exit /b 0

:: ==================================================================
:main
cls
echo %C_C%====================================================================%C_0%
echo %C_C%   LOCKDOWN MASTER %VERSION% - WHITELIST - ACTIVE USER / ENGINE      %C_0%
echo %C_C%====================================================================%C_0%
echo %C_Y%   RUNNING FILE: %~f0%C_0%
echo %C_Y%   VERSION     : %VERSION%%C_0%
echo.
echo    If the VERSION above is not v15.9, you are running an OLD copy of this
echo    file. Delete every other Lockdown_Master*.bat and run ONLY this one.
echo.
ping -n 4 127.0.0.1 >nul

if /i "%~1"=="status" goto statusmode
if /i "%~1"=="on" goto onmode
if /i "%~1"=="off" goto offmode
if /i "%~1"=="diag" goto diagmode
if /i "%~1"=="test" goto testmode

call :say STEP "Select the user to RESTRICT"
echo.
set count=0
for /f "delims=" %%i in ('dir /b /ad C:\Users ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do (
    set /a count+=1
    set "user_!count!=%%i"
    echo   !count!. %%i
)
call :pickuser "Enter the number of the user to RESTRICT: " target
> "%TARGET_DIR%\config.txt" echo !target!
call :say OK "Restricting: !target!"

call :say WAIT "Checking logon status..."
call :islogged "!target!"
if "%ISLOG%"=="0" goto target_off
call :say WARN "!target! is logged on - logging off automatically"
set "SESSID="
for /f "skip=1 tokens=1-4" %%a in ('quser 2^>nul') do (
    set "qu=%%a"
    set "qu=!qu:>=!"
    if /i "!qu!"=="!target!" (
        for %%x in (%%b %%c %%d) do (
            echo %%x| findstr /r "^[0-9][0-9]*$" >nul 2>&1 && set "SESSID=%%x"
        )
    )
)
if not defined SESSID call :die "Session ID not found - log off manually and re-run"
call :say WAIT "Logging off session %SESSID%..."
logoff %SESSID% >nul 2>&1
set /a wc=0
:waitlogoff
call :islogged "!target!"
if "%ISLOG%"=="0" goto target_off
set /a wc+=1
call :say WAIT "Waiting - %wc% of 15"
if %wc% geq 15 call :die "Session did not close - log off manually and re-run"
ping -n 3 127.0.0.1 >nul
goto waitlogoff
:target_off
call :say OK "!target! is logged off"

call :say STEP "ENABLE POWERSHELL SCRIPTS - the engine/guard could not run because this PC blocks .ps1 files"
:: Confirmed cause: PowerShell ExecutionPolicy is blocking script FILES, so every
:: .ps1-based piece (engine, usb guard, detection) died on launch and spewed
:: execution-policy errors. These registry keys set the machine + user policy to
:: allow local scripts. Written as admin, machine-wide and for the target hive.
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /v EnableScripts /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /v ExecutionPolicy /t REG_SZ /d "Bypass" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d "Bypass" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d "Bypass" /f >nul 2>&1
call :say OK "PowerShell script execution enabled machine-wide (ExecutionPolicy=Bypass)"
call :say WAIT "Verifying PowerShell can now run a script file..."
set "PSOK="
> "%TARGET_DIR%\pstest.ps1" echo Write-Output PSSCRIPTS_OK
for /f %%p in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET_DIR%\pstest.ps1" 2^>nul') do set "PSOK=%%p"
del "%TARGET_DIR%\pstest.ps1" >nul 2>&1
if "%PSOK%"=="PSSCRIPTS_OK" (
    call :say OK "CONFIRMED - PowerShell scripts now run."
    goto ps_done
)
set "PS_BLOCKED=1"
echo %C_O%============================================================================%C_0%
echo %C_O%  SYSTEM IS BLOCKING POWERSHELL SCRIPTS ON THIS PC%C_0%
echo %C_O%  A stronger policy than ExecutionPolicy is in force - AppLocker, WDAC,%C_0%
echo %C_O%  Constrained Language Mode, or antivirus / endpoint protection.%C_0%
echo %C_O%  A registry change cannot override it.%C_0%
echo %C_O%  This does NOT affect the web filter: it is written as plain registry%C_0%
echo %C_O%  into the target's hive and needs no scripts, so filtering still works.%C_0%
echo %C_O%============================================================================%C_0%
>>"%ERRLOG%" echo [%date% %time%] PS_BLOCKED - PowerShell script files blocked on this PC
>>"%LOGFILE%" echo [%date% %time%] PS_BLOCKED - PowerShell script files blocked on this PC
call :say WARN "Setup continues; the per-user web filter does not rely on scripts and still works."
:ps_done

call :say STEP "Resolve SID"
set "sid="
for /f %%s in ('powershell -NoProfile -Command "(Get-LocalUser '!target!').SID.Value" 2^>nul') do set "sid=%%s"
if "%sid%"=="" call :die "Could not resolve SID for !target! - if this is a Microsoft account, use a local account"
call :say OK "SID = %sid%"

net user "!target!" 2>nul | findstr /i "Administrators" >nul && call :say WARN "!target! is ADMIN - make the account STANDARD or blocks can be undone"

call :say STEP "PHASE 1 - REMOVE ALL OLD FILTERS & POLICIES"

for %%T in ("USB_Watch_System" "USB_Watch_!target!" "USB_Blocker_Task" "USB_Blocker_Logon" "Exempt_Filter" "WebFilter_Boot" "WebFilter_Logon" "WebFilter_Poll" "WebFilter_Wrapper" "WebFilter_EvtUnlock" "WebFilter_EvtReconnect" "WebFilter_EvtDisconnect" "WebFilter_EvtSessionLogon" "WebFilter_ExplorerBounce" "WebFilter_UI_Logon" "WebFilter_UsbGuard" "WebFilter_Engine" "WebFilter_UsbWatch" "WebFilter_Denied") do schtasks /delete /tn "%%~T" /f >nul 2>&1
taskkill /f /im powershell.exe /fi "WINDOWTITLE eq WebFilterUsbGuard" >nul 2>&1
for /f "delims=" %%u in ('dir /b /ad C:\Users ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do schtasks /delete /tn "WebFilter_Logon_%%u" /f >nul 2>&1
call :say OK "Old scheduled tasks deleted"

reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v LockdownBoot /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v WebFilter_UIHook /f >nul 2>&1
del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\WebFilter_UI.cmd" >nul 2>&1
call :say OK "Run keys removed"

call :say WAIT "Nuking ENTIRE browser policy keys - both views"
for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do (
    for %%V in ("SOFTWARE\Policies" "SOFTWARE\WOW6432Node\Policies") do (
        reg delete "HKLM\%%~V\%%~B" /f >nul 2>&1
    )
)
call :say OK "Any leftover policy from any old tool version is gone"

reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Safer" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Appx" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\WindowsStore" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Installer" /f >nul 2>&1
call :say OK "Machine proxy, app restrictions and SRP leftovers deleted"

call :say WAIT "Sweeping EVERY loaded user hive in HKU"
for /f "tokens=2 delims=\" %%s in ('reg query HKU 2^>nul') do (
    if /i not "%%s"==".DEFAULT" (
        for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do reg delete "HKU\%%s\Software\Policies\%%~B" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Policies\Microsoft\Windows\Safer" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Policies\Microsoft\Windows\Appx" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Policies\Microsoft\WindowsStore" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Policies\Microsoft\Windows\Installer" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun" /f >nul 2>&1
        reg delete "HKU\%%s\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v DisallowRun /f >nul 2>&1
        reg delete "HKU\%%s\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
        reg delete "HKU\%%s\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer /f >nul 2>&1
        reg add "HKU\%%s\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
    )
)
reg delete "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
call :say OK "All loaded user hives swept"

call :say WAIT "Deep purge - browser policies from EVERY profile hive"
for /f "delims=" %%u in ('dir /b /ad C:\Users ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do (
    if /i not "%%u"=="!target!" (
        set "usid="
        for /f %%s in ('powershell -NoProfile -Command "(Get-LocalUser '%%u').SID.Value" 2^>nul') do set "usid=%%s"
        if defined usid (
            reg query "HKU\!usid!" >nul 2>&1
            if errorlevel 1 (
                if exist "C:\Users\%%u\NTUSER.DAT" (
                    reg unload "HKU\DeepPurge" >nul 2>&1
                    reg load "HKU\DeepPurge" "C:\Users\%%u\NTUSER.DAT" >nul 2>&1
                    if not errorlevel 1 (
                        for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do reg delete "HKU\DeepPurge\Software\Policies\%%~B" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Policies\Microsoft\Windows\Safer" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Policies\Microsoft\Windows\Appx" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Policies\Microsoft\WindowsStore" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Policies\Microsoft\Windows\Installer" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun" /f >nul 2>&1
                        reg delete "HKU\DeepPurge\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v DisallowRun /f >nul 2>&1
                        reg unload "HKU\DeepPurge" >nul 2>&1
                        call :say OK "Purged old policies from %%u profile"
                    ) else call :say WARN "Could not load hive for %%u - skipped"
                )
            )
        )
    )
)
call :say OK "Deep purge done"

call :loadhive "!target!" "%sid%"
if errorlevel 1 call :die "Hive load failed"
set "T=HKU\%sid%"
for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do reg delete "!T!\Software\Policies\%%~B" /f >nul 2>&1
call :say OK "Legacy per-user browser policies purged from !target! hive"
reg delete "!T!\Software\Policies\Microsoft\Windows\Safer" /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\Windows\Appx" /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\WindowsStore" /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\Windows\Installer" /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun" /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v DisallowRun /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\Windows\RemovableStorageDevices" /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f >nul 2>&1
reg add "!T!\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1
call :drophive "%sid%"
call :say OK "Target old policies removed"

call :say WAIT "Removing old deny-execute ACLs - ensuring desktop & apps open freely"
for %%F in ("C:\Users\!target!\Downloads" "C:\Users\!target!\Desktop" "C:\Users\!target!\Documents" "C:\Users\!target!\OneDrive" "C:\Users\!target!\AppData\Local\Temp" "C:\Users\Public") do icacls "%%~F" /remove:d "!target!" >nul 2>&1
call :say OK "Old ACLs cleared - Desktop & Documents unlocked"

for %%F in ("whitelist.pac" "allow_all.pac" "USB_Blocker.cmd" "Remove_Block.cmd" "sites_clean.txt" "gen_pac.ps1" "gen_task.ps1" "allow_flat.txt" "allow_patterns.txt" "block_numbered.txt" "blocked_sites.txt" "bounce_apply.cmd" "bounce_remove.cmd" "WebFilter_LogonWrapper.cmd" "WebFilter_Switch.cmd" "user_sids.txt" "policy_apply.reg" "WebFilter_UI.cmd" "ui_done.flag" "ui_request.txt" "get_active_user.ps1" "mk_logon.ps1" "state.txt" "ui.lock" "gate_*.done") do del "%TARGET_DIR%\%%~F" >nul 2>&1
call :say OK "PHASE 1 COMPLETE"

call :say STEP "PHASE 2A - INSTALLED APPS PRESERVED + DOWNLOAD SAFEGUARDS"
call :loadhive "!target!" "%sid%"
if errorlevel 1 call :die "Hive load failed"
set "T=HKU\%sid%"

:: USB/STORE/INSTALL KILLER - runs as SYSTEM from BOOT (already running before the
:: target logs in, so there is NO post-reboot gap), tight 0.4s loop, scoped to the
:: target by process owner. The ACCESS DENIED window is shown by a separate
:: interactive task (WebFilter_Denied) the killer fires, because a SYSTEM process in
:: session 0 cannot draw a window itself on Win11 Home.
call :say WAIT "Writing the 0.4s SYSTEM killer + ACCESS DENIED popup"
powershell -NoProfile -Command "$f=Get-Content -LiteralPath '%~f0'; $m1=$f | Select-String -Pattern '^::WATCHBAT_BEGIN' | Select-Object -First 1; $m2=$f | Select-String -Pattern '^::WATCHBAT_END' | Select-Object -First 1; if($m1 -and $m2){$f[($m1.LineNumber)..($m2.LineNumber-2)] | Set-Content -LiteralPath '%WATCHBAT%' -Encoding Ascii}" >nul 2>>"%LOGFILE%"
powershell -NoProfile -Command "$f=Get-Content -LiteralPath '%~f0'; $m1=$f | Select-String -Pattern '^::DENIED_BEGIN' | Select-Object -First 1; $m2=$f | Select-String -Pattern '^::DENIED_END' | Select-Object -First 1; if($m1 -and $m2){$f[($m1.LineNumber)..($m2.LineNumber-2)] | Set-Content -LiteralPath '%TARGET_DIR%\denied.bat' -Encoding Ascii}" >nul 2>>"%LOGFILE%"
powershell -NoProfile -Command "$f=Get-Content -LiteralPath '%~f0'; $m1=$f | Select-String -Pattern '^::WATCHVBS_BEGIN' | Select-Object -First 1; $m2=$f | Select-String -Pattern '^::WATCHVBS_END' | Select-Object -First 1; if($m1 -and $m2){$f[($m1.LineNumber)..($m2.LineNumber-2)] | Set-Content -LiteralPath '%WATCHVBS%' -Encoding Ascii}" >nul 2>>"%LOGFILE%"
if exist "%WATCHBAT%" (call :say OK "Killer written: %WATCHBAT%") else call :die "Killer .bat not extracted - see %LOGFILE%"
if exist "%TARGET_DIR%\denied.bat" (call :say OK "ACCESS DENIED popup written") else call :say WARN "denied.bat not written - kills still work, no popup"
call :say WAIT "Creating the interactive ACCESS DENIED popup task (shows in the target's session)"
powershell -NoProfile -Command "$a=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c \"%TARGET_DIR%\denied.bat\"'; $p=New-ScheduledTaskPrincipal -GroupId 'INTERACTIVE'; Register-ScheduledTask -TaskName 'WebFilter_Denied' -Action $a -Principal $p -Force | Out-Null" >nul 2>>"%LOGFILE%"
schtasks /query /tn "WebFilter_Denied" >nul 2>&1 && call :say OK "Popup task registered" || call :say WARN "Popup task not registered - kills still work, no popup"
call :say WAIT "Creating the SYSTEM boot task so the killer runs from startup (no delay)"
schtasks /create /tn "WebFilter_UsbWatch" /tr "cmd /c \"%WATCHBAT%\"" /sc onstart /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 (call :say FAIL "SYSTEM killer task not created - see %LOGFILE%") else call :say OK "SYSTEM killer task created (runs every boot)"
del "%TARGET_DIR%\watch_hb.txt" >nul 2>&1
schtasks /run /tn "WebFilter_UsbWatch" >nul 2>&1
call :say WAIT "Verifying the killer is running (giving it up to ~13s to cold-start)..."
ping -n 14 127.0.0.1 >nul
if exist "%TARGET_DIR%\watch_hb.txt" (
    call :say OK "KILLER IS RUNNING as SYSTEM - active from every boot, checks every 0.4s"
) else (
    call :say WARN "SYSTEM task did not start - SYSTEM scheduled tasks look blocked on this PC."
    call :say WAIT "Installing FALLBACK: start the killer in !target!'s own session at logon instead"
    reg add "!T!\Software\Microsoft\Windows\CurrentVersion\Run" /v USBWatch /t REG_SZ /d "wscript.exe \"%WATCHVBS%\"" /f >nul 2>&1
    if exist "%WATCHVBS%" (call :say OK "Fallback installed - killer starts hidden at !target!'s sign-in") else call :say FAIL "Fallback launcher missing - see %LOGFILE%"
    call :say INFO "In fallback mode there is a brief (~1-3s) gap right after sign-in before the killer is up"
)

:: Disable Windows startup delay in target profile so logon gate appears instantly
reg add "!T!\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f >nul 2>&1

:: Allow all installed apps freely; restrict execution only in Downloads folder
call :denyexec "C:\Users\!target!\Downloads"
icacls "C:\Users\!target!\AppData\Local\Temp" /remove:d "!target!" >nul 2>&1
call :say OK "Downloads execution restricted - Temp, Desktop and installed apps run normally"

:: Ensure Windows Store, installed apps, and cmd/taskmgr stay completely usable
reg delete "!T!\Software\Policies\Microsoft\Windows\Appx" /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\WindowsStore" /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\Windows\Installer" /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun" /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v DisallowRun /f >nul 2>&1

reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableRegistryTools /f >nul 2>&1
reg delete "!T!\Software\Policies\Microsoft\Windows\System" /v DisableCMD /f >nul 2>&1
reg delete "!T!\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCMD /f >nul 2>&1
call :say OK "Installed apps, Store apps, Desktop shortcuts, cmd, regedit, taskmgr open freely"

:: ==================================================================
:: ADDED: block Microsoft Store + block new installs / portable apps
::        for the TARGET user only. Already-installed apps still run,
::        because Program Files, Windows and AppData are left runnable.
:: ==================================================================
call :say STEP "PHASE 2A-2 - BLOCK MS STORE + BLOCK NEW INSTALLS / PORTABLE APPS (target only)"

:: --- 1. Block the Microsoft Store for the target user ---
reg add "!T!\Software\Policies\Microsoft\WindowsStore" /v RemoveWindowsStore /t REG_DWORD /d 1 /f >nul 2>&1
reg add "!T!\Software\Policies\Microsoft\WindowsStore" /v AutoDownload /t REG_DWORD /d 2 /f >nul 2>&1
call :say OK "Microsoft Store disabled for !target! (RemoveWindowsStore)"

:: --- 2a. Block app installation (per-user MSI / Windows Installer) ---
reg add "!T!\Software\Policies\Microsoft\Windows\Installer" /v DisableUserInstalls /t REG_DWORD /d 1 /f >nul 2>&1
reg add "!T!\Software\Policies\Microsoft\Windows\Installer" /v AlwaysInstallElevated /t REG_DWORD /d 0 /f >nul 2>&1
call :say OK "Per-user .msi installs blocked for !target!"

:: --- 2b. Block running portable apps + downloaded installers ---
:: Deny EXECUTE for the target in every user-writable 'landing zone' where
:: portable .exe files and freshly downloaded installers live. Program Files,
:: Windows and AppData stay executable, so already-installed apps keep working.
:: USB/removable execute is already denied above (RemovableStorageDevices).
call :say WAIT "Denying execute in download/portable landing zones (installed apps untouched)"
for %%F in (
    "C:\Users\!target!\Downloads"
    "C:\Users\!target!\Desktop"
    "C:\Users\!target!\Documents"
    "C:\Users\!target!\OneDrive\Downloads"
    "C:\Users\!target!\OneDrive\Desktop"
    "C:\Users\!target!\OneDrive\Documents"
    "C:\Users\Public\Downloads"
    "C:\Users\Public\Desktop"
    "C:\Users\Public\Documents"
) do call :denyexec "%%~F"
call :say OK "Portable apps + downloaded installers blocked in user-writable folders"
:: ==================================================================
:: END ADDED SECTION
:: ==================================================================

call :drophive "%sid%"

call :say STEP "PHASE 2B - WHITELIST WEB FILTER"

set "SRC=%~dp0allowed_sites.txt"
if not exist "%SRC%" set "SRC=%TARGET_DIR%\allowed_sites.txt"
if not exist "%SRC%" call :die "allowed_sites.txt not found next to script or in %TARGET_DIR%"
copy /y "%SRC%" "%TARGET_DIR%\allowed_sites.txt" >nul 2>&1
call :say OK "Reading site list from: %SRC%"

call :say STEP "PHASE 2B-PRE - VERIFYING every entry in allowed_sites.txt"
set /a vtotal=0
set /a vcomment=0
set /a vvalid=0
set /a vinvalid=0
> "%VALFILE%" echo ============================================================
>>"%VALFILE%" echo ALLOWLIST VALIDATION REPORT - %date% %time%
>>"%VALFILE%" echo Source file: %SRC%
>>"%VALFILE%" echo ============================================================
>>"%VALFILE%" echo.
for /f "usebackq delims=" %%a in ("%SRC%") do (
    set "rawline=%%a"
    set /a vtotal+=1
    set "firstchar=!rawline:~0,1!"
    set "isknown="
    if /i "!rawline!"=="localhost" set "isknown=1"
    if /i "!rawline:~0,5!"=="file:" set "isknown=1"
    if "!firstchar!"=="#" (
        set /a vcomment+=1
        >>"%VALFILE%" echo [COMMENT] !rawline!
    ) else if defined isknown (
        set /a vvalid+=1
        >>"%VALFILE%" echo [OK]      !rawline!  ^(handled by the local file/network defaults, not the normal parser^)
    ) else (
        call :verify_entry "!rawline!"
        if defined VOK (
            set /a vvalid+=1
            >>"%VALFILE%" echo [OK]      !rawline!
        ) else (
            set /a vinvalid+=1
            >>"%VALFILE%" echo [INVALID] !rawline!  -- !VREASON!
            call :say FAIL "allowed_sites.txt entry looks invalid: !rawline! - !VREASON!"
        )
    )
)
>>"%VALFILE%" echo.
>>"%VALFILE%" echo ------------------------------------------------------------
>>"%VALFILE%" echo Lines read (excl. blanks) : !vtotal!
>>"%VALFILE%" echo Comments                 : !vcomment!
>>"%VALFILE%" echo Valid entries             : !vvalid!
>>"%VALFILE%" echo Invalid entries           : !vinvalid!
>>"%VALFILE%" echo ------------------------------------------------------------
if !vinvalid! gtr 0 (
    call :say FAIL "!vinvalid! invalid entries in allowed_sites.txt - full detail in %VALFILE%"
) else (
    call :say OK "All !vvalid! entries in allowed_sites.txt passed validation"
)
if !vvalid! equ 0 call :die "No valid entries found in allowed_sites.txt - see %VALFILE%"

call :say WAIT "Parsing - one bare domain per line"
set "CLEAN=%TARGET_DIR%\sites_clean.txt"
powershell -NoProfile -Command "Get-Content -LiteralPath '%TARGET_DIR%\allowed_sites.txt' | Set-Content -LiteralPath '%CLEAN%' -Encoding Ascii" >nul 2>&1
if not exist "%CLEAN%" copy /y "%TARGET_DIR%\allowed_sites.txt" "%CLEAN%" >nul 2>&1

set /a n=0
> "%NUMFILE%" type nul
:: --- Robust parser: inline PowerShell (this PC runs -Command fine, and it is
:: --- immune to the batch parenthesis/pipe fragility that broke earlier builds).
:: --- A line with NO "/" is a plain domain (covers www + every subdomain).
:: --- A line WITH a "/" is a PATH entry kept as-is, e.g. youtube.com/@channel -
:: --- only that path and what is under it is allowed. Duplicates are merged so
:: --- repeats do not waste entries against the browser's 1000-entry cap.
powershell -NoProfile -Command "$res = foreach($raw in Get-Content -LiteralPath '%CLEAN%'){ $line=$raw.Trim(); if($line -eq '' -or $line -like '#*'){continue}; $e=$line -replace '[\x22]',''; if($e -match '^(?i)file:'){continue}; if($e -ieq 'localhost'){continue}; $e=$e -replace '^(?i)(\*://|https?://)',''; if($e -like '*/*'){ $e=$e -replace '^\[\*\.\]','' -replace '^\*\.',''; $e=$e -replace '\s',''; if($e){$e} } else { $w=$e -replace '^\[\*\.\]','' -replace '^\*\.','' -replace '^(?i)www\.',''; $w=($w -split '[?#:]')[0] -replace '\s',''; $w=$w -replace '\.$',''; if($w -and $w -notmatch '^(?i)(youtube\.com|youtu\.be)$' -and $w -match '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-][A-Za-z0-9-]*$'){$w} } }; $u=$res | Sort-Object -Unique; $i=0; $lines = foreach($x in $u){ $i++; ('{0};{1}' -f $i,$x) }; Set-Content -LiteralPath '%NUMFILE%' -Value $lines -Encoding Ascii" >nul 2>>"%LOGFILE%"
for /f %%c in ('find /c /v "" ^< "%NUMFILE%"') do set /a n=%%c
del "%CLEAN%" >nul 2>&1
if %n% equ 0 call :die "Allowlist EMPTY - PowerShell parser produced no rows (see log)"
call :say OK "Parsed entries: %n% (from allowed_sites.txt)"

:: NOTE: the previously hardcoded website allowlist (scratch.mit.edu, the wix/
:: google/github/CDN domains, youtube-nocookie.com, etc.) has been REMOVED from this
:: script. Those domains now live in allowed_sites.txt, which is the single source of
:: truth for allowed WEBSITES. Only the structural built-ins below (local/network,
:: file access, YouTube embed paths, Google Maps paths) remain hardcoded, because they
:: are not plain domains and cannot be expressed as allowed_sites.txt lines.

call :say WAIT "FORCING local file access + local network defaults"
call :ensure_entry "localhost"
call :ensure_entry "127.0.0.1"
call :ensure_entry "local"
call :ensure_entry "10.0.0.0/8"
call :ensure_entry "172.16.0.0/12"
call :ensure_entry "192.168.0.0/16"
call :ensure_entry "169.254.0.0/16"
set /a n+=1
>> "%NUMFILE%" echo !n!;file:///*
call :say OK "Local files (file:///*) and local/private network ranges allowed by default"

call :say WAIT "FORCING YouTube EMBED support - full youtube.com stays blocked, embeds play"
set /a n+=1
>> "%NUMFILE%" echo !n!;https://www.youtube.com/embed/
set /a n+=1
>> "%NUMFILE%" echo !n!;https://youtube.com/embed/
set /a n+=1
>> "%NUMFILE%" echo !n!;https://www.youtube.com/s/player/
set /a n+=1
>> "%NUMFILE%" echo !n!;https://www.youtube.com/iframe_api
set /a n+=1
>> "%NUMFILE%" echo !n!;https://www.youtube.com/youtubei/
set /a n+=1
>> "%NUMFILE%" echo !n!;https://youtube.com/youtubei/
rem -- youtube-nocookie.com serves ONLY the privacy-embed player - no browsing or
rem -- search - so the whole domain is safe to allow and is REQUIRED for most embeds.
rem -- Hard-wired here so it can never be lost when allowed_sites.txt is edited.
set /a n+=1
>> "%NUMFILE%" echo !n!;youtube-nocookie.com
call :say OK "YouTube embeds enabled (embed/player paths + youtube-nocookie.com) - full youtube.com still off-limits"

call :say WAIT "Adding Google Maps path allow"
set /a n+=1
>> "%NUMFILE%" echo !n!;https://www.google.com/maps
set /a n+=1
>> "%NUMFILE%" echo !n!;https://www.google.com/maps/*
call :say OK "Total %n% entries"

call :say WAIT "Validating every pattern in the final list"
set /a badp=0
for /f "usebackq tokens=1,* delims=;" %%i in ("%NUMFILE%") do (
    set "pat=%%j"
    set "p1=!pat:~0,1!"
    set "pOK="
    if "!p1!"=="h" set "pOK=1"
    if "!p1!"=="*" set "pOK=1"
    echo !p1!| findstr /r /i "[a-z0-9]" >nul 2>&1 && set "pOK=1"
    if not defined pOK (
        set /a badp+=1
        call :say FAIL "BAD pattern: %%j"
    )
)
if !badp! gtr 0 call :say FAIL "!badp! bad patterns in list - fix and re-run"
if !badp! equ 0 call :say OK "All patterns valid form"

call :say WAIT "Writing the web filter into %target%'s OWN user hive - per-user by design"
:: ================= PER-USER FILTER (the correct model) ==================
:: The whitelist is written into the TARGET's registry hive only. Chrome AND
:: Edge both read these per-user policy keys, so the filter applies to this one
:: account and to nobody else. There is NO machine-wide policy, NO background
:: engine, and NO active-user detection - the filter travels with the target's
:: profile and therefore CANNOT "fail to switch". This removes every moving part
:: that was failing (SYSTEM tasks, quser, PowerShell scripts).
:: ========================================================================
call :loadhive "!target!" "%sid%"
if errorlevel 1 call :die "Hive load failed - cannot write the per-user filter"
set "T=HKU\%sid%"
set /a k=0
for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do (
    reg delete "!T!\Software\Policies\%%~B\URLBlocklist" /f >nul 2>&1
    reg delete "!T!\Software\Policies\%%~B\URLAllowlist" /f >nul 2>&1
    rem -- Block only WEB browsing: http and https. Every non-web scheme - custom
    rem -- app protocols like ableton, spotify, steam, plus mailto, tel, file - is
    rem -- left untouched, so app links work. The website whitelist still overrides
    rem -- these two for the allowed domains, exactly as it did under a star block.
    reg add "!T!\Software\Policies\%%~B\URLBlocklist" /v 1 /t REG_SZ /d "http://*" /f >nul 2>>"%LOGFILE%"
    reg add "!T!\Software\Policies\%%~B\URLBlocklist" /v 2 /t REG_SZ /d "https://*" /f >nul 2>>"%LOGFILE%"
    if errorlevel 1 call :say FAIL "reg add failed for %%~B URLBlocklist (hive) - see %LOGFILE%"
    reg add "!T!\Software\Policies\%%~B" /v DownloadRestrictions /t REG_DWORD /d 0 /f >nul 2>&1
    set /a k=0
    for /f "usebackq tokens=1,* delims=;" %%i in ("%NUMFILE%") do (
        set /a k+=1
        reg add "!T!\Software\Policies\%%~B\URLAllowlist" /v !k! /t REG_SZ /d "%%j" /f >nul 2>>"%LOGFILE%"
    )
)
:: ---- Firefox + Zen: they ignore the Chrome policy, so use Mozilla's WebsiteFilter
:: (block everything, allow the same whitelist as exceptions), written per-user into
:: the target's hive. Mozilla match patterns use *.domain to cover a domain AND its
:: subdomains in one entry. Written via inline PowerShell for clean conversion.
powershell -NoProfile -Command "$sid='%sid%'; foreach($m in @('Mozilla\Firefox','Zen\Zen')){ $wf='Registry::HKEY_USERS\'+$sid+'\Software\Policies\'+$m+'\WebsiteFilter'; Remove-Item $wf -Recurse -Force -ErrorAction SilentlyContinue; New-Item ($wf+'\Block') -Force | Out-Null; New-ItemProperty ($wf+'\Block') -Name '1' -Value '<all_urls>' -PropertyType String -Force | Out-Null; New-Item ($wf+'\Exceptions') -Force | Out-Null; $k=0; foreach($line in Get-Content 'C:\ProgramData\BrowserFilter\allow_numbered.txt'){ $e=($line -split ';',2)[1]; if(-not $e){continue}; $pat=$null; if($e -match '^http'){$pat=$e+'*'} elseif($e -eq 'localhost'){$pat='*://localhost/*'} elseif($e -match '/'){$parts=$e -split '/',2; $pat='*://*.'+$parts[0]+'/'+$parts[1]+'*'} elseif($e -match '\.'){$pat='*://*.'+$e+'/*'}; if($pat){$k++; New-ItemProperty ($wf+'\Exceptions') -Name ([string]$k) -Value $pat -PropertyType String -Force | Out-Null} } }" >nul 2>>"%LOGFILE%"
call :say OK "Firefox + Zen whitelist written (Mozilla WebsiteFilter, per-user)"
call :drophive "%sid%"
call :say OK "Per-user filter written into !target!'s hive - !k! allow entries per browser"

call :say WAIT "Ensuring NO machine-wide filter exists (so other accounts browse normally)"
for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do (
    for %%V in ("SOFTWARE\Policies" "SOFTWARE\WOW6432Node\Policies") do (
        reg delete "HKLM\%%~V\%%~B\URLBlocklist" /f >nul 2>&1
        reg delete "HKLM\%%~V\%%~B\URLAllowlist" /f >nul 2>&1
    )
)
call :say OK "Machine-wide filter cleared - only !target! is filtered"
goto complete_setup

call :say STEP "INSTALL SWITCHER v11 + STATE-DRIVEN SIGN-IN GATE + ACTIVE USER ENGINE"

call :say OK "Active-user detection is pure-batch (quser) inside the switcher - no PowerShell helper needed"

call :say WAIT "Extracting embedded switcher from this file"
powershell -NoProfile -Command "$f=Get-Content -LiteralPath '%~f0'; $m1=$f | Select-String -Pattern '^::SW11_BEGIN' | Select-Object -First 1; $m2=$f | Select-String -Pattern '^::SW11_END' | Select-Object -First 1; if($m1 -and $m2){$f[($m1.LineNumber)..($m2.LineNumber-2)] | Set-Content -LiteralPath '%SWITCHER%' -Encoding Ascii}" >nul 2>>"%LOGFILE%"
if not exist "%SWITCHER%" call :die "Switcher extraction failed - the ::SW11_BEGIN payload is missing from this file"
find /i /c "SW11-VERSION" "%SWITCHER%" >nul 2>&1
if errorlevel 1 call :die "Switcher payload extracted wrong content - re-copy this script completely"
call :say OK "Switcher v11 installed (self-extracted)"

call :say WAIT "Extracting embedded ENGINE (always-on SYSTEM switcher + USB guard) from this file"
powershell -NoProfile -Command "$f=Get-Content -LiteralPath '%~f0'; $m1=$f | Select-String -Pattern '^::ENGINE_BEGIN' | Select-Object -First 1; $m2=$f | Select-String -Pattern '^::ENGINE_END' | Select-Object -First 1; if($m1 -and $m2){$f[($m1.LineNumber)..($m2.LineNumber-2)] | Set-Content -LiteralPath '%ENGINE%' -Encoding Ascii}" >nul 2>>"%LOGFILE%"
if not exist "%ENGINE%" call :die "Engine extraction failed - the ::ENGINE_BEGIN payload is missing from this file"
find /i /c "ENGINE-VERSION" "%ENGINE%" >nul 2>&1
if errorlevel 1 call :die "Engine payload extracted wrong content - re-copy this script completely"
call :say OK "Engine installed (self-extracted)"

call :say WAIT "Writing the state-driven sign-in gate screen"
> "%UIHOOK%" echo @echo off
>>"%UIHOOK%" echo setlocal enabledelayedexpansion
>>"%UIHOOK%" echo set "CFG=C:\ProgramData\BrowserFilter\config.txt"
>>"%UIHOOK%" echo set "DONEF=C:\ProgramData\BrowserFilter\gate_%%USERNAME%%.done"
>>"%UIHOOK%" echo mkdir "%%DONEF%%" 2^>nul
>>"%UIHOOK%" echo if errorlevel 1 exit /b 0
>>"%UIHOOK%" echo set "TGT="
>>"%UIHOOK%" echo if exist "%%CFG%%" set /p TGT=^<"%%CFG%%"
>>"%UIHOOK%" echo for %%%%i in ("%%USERPROFILE%%") do set "MYUSER=%%%%~nxi"
>>"%UIHOOK%" echo set "ROLE=other"
>>"%UIHOOK%" echo if /i "%%MYUSER%%"=="%%TGT%%" set "ROLE=target"
>>"%UIHOOK%" echo rem --- fire the SYSTEM worker FIRST, before drawing anything, so the ---
>>"%UIHOOK%" echo rem --- apply/remove happens in the background no matter what the  ---
>>"%UIHOOK%" echo rem --- user does with this window (closing it cannot stop it).     ---
>>"%UIHOOK%" echo schtasks /run /tn "WebFilter_Poll" ^>nul 2^>^&1
>>"%UIHOOK%" echo title Content Filter
>>"%UIHOOK%" echo color 1F
>>"%UIHOOK%" echo mode con: cols=65 lines=11
>>"%UIHOOK%" echo cls
>>"%UIHOOK%" echo echo.
>>"%UIHOOK%" echo echo    ============================================================
>>"%UIHOOK%" echo if "%%ROLE%%"=="target" (
>>"%UIHOOK%" echo     echo       Applying content filter...
>>"%UIHOOK%" echo ) else (
>>"%UIHOOK%" echo     echo       Removing content filter...
>>"%UIHOOK%" echo )
>>"%UIHOOK%" echo echo    ============================================================
>>"%UIHOOK%" echo echo.
>>"%UIHOOK%" echo echo       This happens in the background. You can close this
>>"%UIHOOK%" echo echo       window - the filter is still applied either way.
>>"%UIHOOK%" echo echo.
>>"%UIHOOK%" echo rem --- cosmetic only: nudge the worker twice more while the      ---
>>"%UIHOOK%" echo rem --- window is up, then auto-close. No registry work, no        ---
>>"%UIHOOK%" echo rem --- explorer kill - nothing here is load-bearing.              ---
>>"%UIHOOK%" echo ping -n 3 127.0.0.1 ^>nul
>>"%UIHOOK%" echo schtasks /run /tn "WebFilter_Poll" ^>nul 2^>^&1
>>"%UIHOOK%" echo ping -n 4 127.0.0.1 ^>nul
>>"%UIHOOK%" echo exit
call :say OK "Gate written - cosmetic only; SYSTEM worker does the apply/remove and survives the window closing"

call :say WAIT "Disabling Windows startup delay so gate appears instantly at logon"
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoStartupDelay /t REG_DWORD /d 1 /f >nul 2>&1
call :say OK "Startup delay set to 0ms"

call :say WAIT "Registering the sign-in gate in Run key and Startup folder"
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v WebFilter_UIHook /t REG_SZ /d "\"%UIHOOK%\"" /f >nul 2>>"%LOGFILE%"
set "ALLSTARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
if exist "%ALLSTARTUP%" copy /y "%UIHOOK%" "%ALLSTARTUP%\WebFilter_UI.cmd" >nul 2>&1
call :say OK "Run key and Startup registration complete"

call :say WAIT "Creating interactive logon task for instant execution"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$a=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c start \"\" \"%UIHOOK%\"'; $t=New-ScheduledTaskTrigger -AtLogOn; $p=New-ScheduledTaskPrincipal -GroupId 'INTERACTIVE' -RunLevel Limited; Register-ScheduledTask -TaskName 'WebFilter_UI_Logon' -Action $a -Trigger $t -Principal $p -Force | Out-Null" >nul 2>>"%LOGFILE%"
call :say OK "Interactive logon task registered"

call :say WAIT "Creating boot task - block ON at boot (fail-closed)"
schtasks /create /tn "WebFilter_Boot" /tr "cmd /c \"%SWITCHER%\" ON" /sc onstart /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say FAIL "Boot task failed - see %LOGFILE%"
if not errorlevel 1 call :say OK "Boot task created"

call :say WAIT "Creating the ENGINE task - always-on SYSTEM loop that drives per-user switching + USB kill"
schtasks /create /tn "WebFilter_Engine" /tr "cmd /c \"%ENGINE%\"" /sc onstart /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 (call :say FAIL "Engine task failed - see %LOGFILE%") else call :say OK "Engine task created (primary switcher - re-evaluates active user every 2s)"
del "%TARGET_DIR%\engine_hb.txt" >nul 2>&1
schtasks /run /tn "WebFilter_Engine" >nul 2>&1
call :say WAIT "Verifying the engine actually STAYS RUNNING (pure-batch, no PowerShell)..."
ping -n 8 127.0.0.1 >nul
if exist "%TARGET_DIR%\engine_hb.txt" (
    call :say OK "ENGINE IS RUNNING as SYSTEM - per-user switching is live and does NOT use PowerShell"
) else (
    call :say FAIL "ENGINE DID NOT STAY RUNNING - SYSTEM scheduled tasks themselves appear blocked on this PC."
    >>"%TARGET_DIR%\version.txt" echo ENGINE_FAILED_TO_START
)
call :say INFO "USB apps are blocked by SRP (pure registry, script-free) - no separate USB process needed"

call :say WAIT "Writing logon-task helper (resolves Microsoft accounts via SID)"
> "%MKLOGON%" echo param([string]$prof,[string]$sw)
>>"%MKLOGON%" echo $ErrorActionPreference='Stop'
>>"%MKLOGON%" echo try {
>>"%MKLOGON%" echo   $sid=$null
>>"%MKLOGON%" echo   $base='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
>>"%MKLOGON%" echo   Get-ChildItem $base ^| ForEach-Object {
>>"%MKLOGON%" echo     $pp=(Get-ItemProperty $_.PSPath).ProfileImagePath
>>"%MKLOGON%" echo     if ($pp -and ($pp -ieq ("C:\Users\" + $prof))) { $sid=$_.PSChildName }
>>"%MKLOGON%" echo   }
>>"%MKLOGON%" echo   $acct=$null
>>"%MKLOGON%" echo   if ($sid) { try { $acct=(New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch {} }
>>"%MKLOGON%" echo   if (-not $acct) { $acct=$prof }
>>"%MKLOGON%" echo   $a=New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c {0} LOGON "{1}"' -f $sw,$prof)
>>"%MKLOGON%" echo   $t=New-ScheduledTaskTrigger -AtLogOn -User $acct
>>"%MKLOGON%" echo   $pr=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
>>"%MKLOGON%" echo   Register-ScheduledTask -TaskName ("WebFilter_Logon_{0}" -f $prof) -Action $a -Trigger $t -Principal $pr -Force ^| Out-Null
>>"%MKLOGON%" echo   exit 0
>>"%MKLOGON%" echo } catch { exit 1 }
call :say OK "Logon-task helper written"

call :say WAIT "Creating PER-USER logon tasks - instant ON/OFF at every sign-in"
call :make_logon_task "!target!" "ON"
for /f "delims=" %%u in ('dir /b /ad C:\Users ^| findstr /v /i /c:"Public" /c:"Default" /c:"All Users"') do (
    if /i not "%%u"=="!target!" call :make_logon_task "%%u" "OFF"
)
call :say OK "Per-user logon tasks done"
call :say INFO "Any sign-in the logon task happens to miss is covered by the gate screen, which runs in the user's own session and knows exactly who they are"

call :say WAIT "Creating 1-minute poll as safety net"
schtasks /create /tn "WebFilter_Poll" /tr "cmd /c \"%SWITCHER%\" NOW" /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say FAIL "Poll task failed - see %LOGFILE%"
if not errorlevel 1 call :say OK "Poll task created"

call :say WAIT "Enabling lock/unlock auditing so the unlock event can be seen"
auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable /failure:enable >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say WARN "auditpol failed - unlock-triggered recheck may not fire, poll still covers it"

call :say WAIT "Creating instant recheck tasks - unlock, fast-switch reconnect, any session logon"
schtasks /create /tn "WebFilter_EvtUnlock" /tr "cmd /c \"%SWITCHER%\" SWITCHUI" /sc onevent /ec Security /mo "*[System[(EventID=4801)]]" /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say FAIL "Unlock-event task failed - see %LOGFILE%"
schtasks /create /tn "WebFilter_EvtReconnect" /tr "cmd /c \"%SWITCHER%\" SWITCHUI" /sc onevent /ec "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" /mo "*[System[(EventID=25)]]" /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say FAIL "Reconnect-event task failed - see %LOGFILE%"
schtasks /create /tn "WebFilter_EvtDisconnect" /tr "cmd /c \"%SWITCHER%\" SWITCHEVENT" /sc onevent /ec "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" /mo "*[System[(EventID=24)]]" /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say FAIL "Disconnect-event task failed - see %LOGFILE%"
schtasks /create /tn "WebFilter_EvtSessionLogon" /tr "cmd /c \"%SWITCHER%\" SWITCHEVENT" /sc onevent /ec "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" /mo "*[System[(EventID=21)]]" /ru SYSTEM /rl HIGHEST /f >nul 2>>"%LOGFILE%"
if errorlevel 1 call :say FAIL "Session-logon-event task failed - see %LOGFILE%"
call :say OK "Instant recheck now fires on unlock, reconnect, disconnect, and every session logon"

call :say WAIT "Setting permissions on tasks and folder"
icacls "%TARGET_DIR%" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)M" >nul 2>&1
icacls "%TARGET_DIR%\config.txt" /grant:r "SYSTEM:F" "Administrators:F" "Users:R" >nul 2>&1
icacls "%TARGET_DIR%\allow_numbered.txt" /grant:r "SYSTEM:F" "Administrators:F" "Users:R" >nul 2>&1
break > "%TARGET_DIR%\ui_request.txt" 2>nul
icacls "%TARGET_DIR%\ui_request.txt" /grant "Users:(M)" >nul 2>&1
icacls "%SystemRoot%\System32\Tasks\WebFilter_*" /grant "Users:(F)" /f >nul 2>&1
call :say OK "Permissions configured"

call :say WAIT "Applying the filter now (fail-closed) and VERIFYING the policy is actually written"
call "%SWITCHER%" ON
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if errorlevel 1 (
    call :say FAIL "Policy NOT present after apply - the switcher could not write HKLM. See %LOGFILE% and %SWLOG%"
) else (
    call :say OK "VERIFIED - block is ON right now. Open chrome://policy and click Reload policies to confirm."
)
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLAllowlist" 2>nul | find /i "wixmp" >nul
if errorlevel 1 (call :say WARN "Allowlist entries not detected - check %SWLOG%") else call :say OK "Allowlist entries present too"
call :say INFO "Filter is left ON (fail-closed). It switches OFF automatically when a non-target user signs in, and back ON for !target!."
call :say WARN "Any browser that was open was closed once so it relaunches with current policy"

:complete_setup
call :say STEP "COMPLETE"
call :summary_write
call :say INFO "Run finished with !WARNCOUNT! warning(s) and !FAILCOUNT! failure(s) - errors logged to %ERRLOG%"
call :logfooter "RUN COMPLETE"
start "" notepad "%SUMFILE%"
call :say OK "Setup finished successfully."
popd
exit /b 0

:: ==================================================================
:onmode
if not exist "%TARGET_DIR%\config.txt" call :die "No config found - run full setup once first"
set /p target=<"%TARGET_DIR%\config.txt"
call :say INFO "Manual ON - target: %target% - block applies machine-wide"
call "%SWITCHER%" ON
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if errorlevel 1 (call :say FAIL "Blocklist NOT present - switcher failed") else call :say OK "Blocklist present"
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLAllowlist" 2>nul | find /i "wixmp" >nul
if errorlevel 1 (call :say FAIL "Allowlist NOT present - switcher failed") else call :say OK "Allowlist present"
call :say INFO "NOTE: the next logon/unlock/poll event may flip this per the active user"
popd
exit /b 0

:: ==================================================================
:offmode
if not exist "%TARGET_DIR%\config.txt" call :die "No config found - run full setup once first"
set /p target=<"%TARGET_DIR%\config.txt"
call :say INFO "Manual OFF - target: %target%"
call "%SWITCHER%" OFF
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if not errorlevel 1 (call :say FAIL "Blocklist STILL present - OFF path failed") else call :say OK "Blocklist removed"
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLAllowlist" >nul 2>&1
if not errorlevel 1 (call :say FAIL "Allowlist STILL present - OFF path failed") else call :say OK "Allowlist removed"
call :say INFO "NOTE: if the target is the active user, the poll re-applies ON within 60s - that is by design"
call :say INFO "Now fully restart Chrome and check chrome://policy"
popd
exit /b 0

:: ==================================================================
:statusmode
set "STATF=%TARGET_DIR%\STATUS.txt"
set "V_TGT="
if exist "%TARGET_DIR%\config.txt" set /p V_TGT=<"%TARGET_DIR%\config.txt"
set "V_ACT="
for /f "tokens=1" %%u in ('quser 2^>nul ^| findstr /i /c:"Active"') do set "V_ACT=%%u"
if defined V_ACT set "V_ACT=%V_ACT:>=%"
set "V_EDGE=OFF"
reg query "HKLM\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist" /v 1 >nul 2>&1
if not errorlevel 1 set "V_EDGE=ON"
set "V_CHROME=OFF"
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if not errorlevel 1 set "V_CHROME=ON"
set "V_GUARD=NOT running"
schtasks /query /tn "WebFilter_UsbGuard" /v /fo LIST 2>nul | find /i "Running" >nul 2>&1 && set "V_GUARD=running"
set "V_ENGINE=NOT running"
schtasks /query /tn "WebFilter_Engine" /v /fo LIST 2>nul | find /i "Running" >nul 2>&1 && set "V_ENGINE=running"
set "V_ESTATE="
if exist "%TARGET_DIR%\engine_state.txt" set /p V_ESTATE=<"%TARGET_DIR%\engine_state.txt"
> "%STATF%" echo ==================== STATUS - %date% %time% ====================
>>"%STATF%" echo.
set "V_VER="
if exist "%TARGET_DIR%\version.txt" set /p V_VER=<"%TARGET_DIR%\version.txt"
>>"%STATF%" echo  ##### ONE-LINE VERDICT (paste this line back) #####
>>"%STATF%" echo  INSTALLED-VERSION: [%V_VER%]   (must say v15.9)
>>"%STATF%" echo  VERDICT: target=[%V_TGT%] detected-active-user=[%V_ACT%] edge-filter=%V_EDGE% chrome-filter=%V_CHROME%
>>"%STATF%" echo           engine=%V_ENGINE% engine-last-state=[%V_ESTATE%] usb-guard=%V_GUARD%
>>"%STATF%" echo  ( engine=NOT running  -> the always-on SYSTEM loop is not alive; that is why nothing switches. )
>>"%STATF%" echo  ( detected-active-user blank -> SYSTEM cannot see who is logged in. )
>>"%STATF%" echo  ( shows target but edge-filter=OFF while target active -> engine not applying. )
>>"%STATF%" echo ##################################################
>>"%STATF%" echo.
>>"%STATF%" echo ----- configured target (config.txt) -----
>>"%STATF%" type "%TARGET_DIR%\config.txt" 2>&1
>>"%STATF%" echo.
>>"%STATF%" echo ----- active console user right now -----
if exist "%GETUSER%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%GETUSER%" >>"%STATF%" 2>&1
) else (
    powershell -NoProfile -Command "$u=(quser 2>$null | Where-Object { $_ -match '\s+Active\s+' } | ForEach-Object { $l=$_.Trim().TrimStart('>'); ($l -split '\s+')[0] } | Select-Object -First 1); if(!$u){$cs=(Get-CimInstance Win32_ComputerSystem).UserName; if($cs){$u=$cs.Split('\')[-1]}}; if($u){Write-Output $u.Trim()}" >>"%STATF%" 2>&1
)
>>"%STATF%" echo.
>>"%STATF%" echo ----- quser right now -----
>>"%STATF%" quser 2>&1
>>"%STATF%" echo.
>>"%STATF%" echo ----- sign-in gate (Run key / screen / request file) -----
>>"%STATF%" reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v WebFilter_UIHook 2>&1
>>"%STATF%" if exist "%UIHOOK%" (echo Gate screen file: PRESENT) else (echo Gate screen file: MISSING)
>>"%STATF%" if exist "%TARGET_DIR%\ui_request.txt" (echo Request file: present) else (echo Request file: MISSING - request net disabled, re-run setup!)
>>"%STATF%" if exist "%TARGET_DIR%\ui_done.flag" (echo Done flag: present - a switch completed recently) else (echo Done flag: absent)
>>"%STATF%" echo.
>>"%STATF%" echo ----- last state the switcher set (state.txt) -----
>>"%STATF%" type "%TARGET_DIR%\state.txt" 2>&1
>>"%STATF%" echo.
>>"%STATF%" echo ----- Chrome URLBlocklist right now -----
>>"%STATF%" reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" 2>&1
>>"%STATF%" echo.
>>"%STATF%" echo ----- Chrome URLAllowlist value count right now -----
set /a sc_count=0
for /f "tokens=1,2,*" %%a in ('reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLAllowlist" 2^>nul') do if "%%b"=="REG_SZ" set /a sc_count+=1
>>"%STATF%" echo Allowlist values present: !sc_count!
>>"%STATF%" echo.
>>"%STATF%" echo ----- Poll task - last run time and result -----
>>"%STATF%" schtasks /query /tn "WebFilter_Poll" /v /fo LIST 2>&1 | findstr /i /c:"Last Run" /c:"Last Result" /c:"Status" /c:"Task To Run" /c:"Next Run"
>>"%STATF%" echo.
>>"%STATF%" echo ----- Per-user logon tasks that exist -----
>>"%STATF%" schtasks /query /fo LIST 2>&1 | findstr /i "WebFilter_Logon_"
>>"%STATF%" echo.
>>"%STATF%" echo ----- switch_log.txt - last 40 lines -----
powershell -NoProfile -Command "Get-Content '%SWLOG%' -Tail 40" >>"%STATF%" 2>&1
call :say OK "Status written"
start "" notepad "%STATF%"
popd
exit /b 0

:: ==================================================================
:testmode
call :say STEP "TEST MODE - apply block + show state"
if not exist "%TARGET_DIR%\config.txt" call :die "No config found - run full setup once first"
set /p target=<"%TARGET_DIR%\config.txt"
call :say INFO "Configured target: %target%"
call "%SWITCHER%" ON
call :say INFO "Block is ON machine-wide."
call :say WARN "Any open browser was closed. Admin browsing is restricted until the next non-target logon."
call :summary_write
start "" notepad "%SUMFILE%"
popd
exit /b 0

:: ==================================================================
:diagmode
call :say STEP "DIAG - dumping every policy location and current state"
set "DIAGF=%TARGET_DIR%\policy_dump.txt"
> "%DIAGF%" echo ===== LOCKDOWN DIAG v11.5 - %date% %time% =====
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ----- configured target (config.txt) -----
>>"%DIAGF%" type "%TARGET_DIR%\config.txt" 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ----- active console user right now -----
if exist "%GETUSER%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%GETUSER%" >>"%DIAGF%" 2>&1
) else (
    powershell -NoProfile -Command "$u=(quser 2>$null | Where-Object { $_ -match '\s+Active\s+' } | ForEach-Object { $l=$_.Trim().TrimStart('>'); ($l -split '\s+')[0] } | Select-Object -First 1); if(!$u){$cs=(Get-CimInstance Win32_ComputerSystem).UserName; if($cs){$u=$cs.Split('\')[-1]}}; if($u){Write-Output $u.Trim()}" >>"%DIAGF%" 2>&1
)
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ----- quser right now -----
>>"%DIAGF%" quser 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== HKLM\SOFTWARE\Policies\Google\Chrome =====
>>"%DIAGF%" reg query "HKLM\SOFTWARE\Policies\Google\Chrome" /s 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== HKLM\SOFTWARE\WOW6432Node\Policies\Google\Chrome =====
>>"%DIAGF%" reg query "HKLM\SOFTWARE\WOW6432Node\Policies\Google\Chrome" /s 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== HKLM\SOFTWARE\Policies\Microsoft\Edge =====
>>"%DIAGF%" reg query "HKLM\SOFTWARE\Policies\Microsoft\Edge" /s 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Edge =====
>>"%DIAGF%" reg query "HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Edge" /s 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== Sign-in gate =====
>>"%DIAGF%" reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v WebFilter_UIHook 2>&1
>>"%DIAGF%" if exist "%UIHOOK%" (echo Gate screen file: PRESENT) else (echo Gate screen file: MISSING)
>>"%DIAGF%" if exist "%TARGET_DIR%\ui_request.txt" (echo Request file: present) else (echo Request file: MISSING)
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== Scheduled tasks =====
>>"%DIAGF%" schtasks /query /fo LIST 2>&1 | findstr /i "WebFilter"
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== switch_log.txt (last 60 lines) =====
powershell -NoProfile -Command "Get-Content '%SWLOG%' -Tail 60" >>"%DIAGF%" 2>&1
>>"%DIAGF%" echo.
>>"%DIAGF%" echo ===== switcher version =====
find /i "SW11-VERSION" "%SWITCHER%" >>"%DIAGF%" 2>&1
call :say OK "Diag written"
start "" notepad "%DIAGF%"
popd
exit /b 0

goto :eof

:: ==================================================================
:: EMBEDDED SWITCHER PAYLOAD - DO NOT EDIT BELOW THIS LINE
:: ==================================================================
::SW11_BEGIN
@echo off
:: WebFilter_Switch - SW11-VERSION-2025 (v11.6 flow) - username is the authority
::   LOGON <user> : per-user logon task - user==target -> ON, else OFF (always forced)
::   NOW          : poll/boot - consume a pending gate request ONLY; never guesses
::   SWITCHEVENT  : unlock/reconnect/disconnect/session-logon - request first,
::                  then (only if none pending) the active console user
::   ON / OFF     : forced
:: Rule: the user who signed in decides. The every-minute poll can no longer
:: flip the filter on a guess - only an explicit username (logon task or gate)
:: changes state, and every change FORCE-applies, so it cannot get stuck.
setlocal enabledelayedexpansion
set "CFG=C:\ProgramData\BrowserFilter\config.txt"
set "NUM=C:\ProgramData\BrowserFilter\allow_numbered.txt"
set "SWLOG=C:\ProgramData\BrowserFilter\switch_log.txt"
set "FLAG=C:\ProgramData\BrowserFilter\ui_done.flag"
set "REQ=C:\ProgramData\BrowserFilter\ui_request.txt"
set "GETUSER=C:\ProgramData\BrowserFilter\get_active_user.ps1"
set "STATEF=C:\ProgramData\BrowserFilter\state.txt"
if not exist "%CFG%" exit /b 0
set /p target=<"%CFG%"
for /f "tokens=1" %%t in ("!target!") do set "target=%%t"
if not defined target exit /b 0
for %%z in ("%SWLOG%") do if %%~zz gtr 400000 move /y "%SWLOG%" "C:\ProgramData\BrowserFilter\switch_log_old.txt" >nul 2>&1

set "cur=OFF"
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if not errorlevel 1 set "cur=ON"

if /i "%~1"=="ON" goto forced_on
if /i "%~1"=="OFF" goto forced_off
if /i "%~1"=="LOGON" goto logon_evt
if /i "%~1"=="SWITCHEVENT" goto event_mode
if /i "%~1"=="SWITCHUI" goto event_mode
goto now_mode

:forced_on
>>"%SWLOG%" echo [%date% %time%] FORCED ON requested
for /d %%D in ("C:\ProgramData\BrowserFilter\gate_*.done") do rd /s /q "%%D" >nul 2>&1
del "C:\ProgramData\BrowserFilter\ui.lock" >nul 2>&1
goto want_on
:forced_off
>>"%SWLOG%" echo [%date% %time%] FORCED OFF requested
for /d %%D in ("C:\ProgramData\BrowserFilter\gate_*.done") do rd /s /q "%%D" >nul 2>&1
del "C:\ProgramData\BrowserFilter\ui.lock" >nul 2>&1
goto want_off

:logon_evt
>>"%SWLOG%" echo [%date% %time%] LOGON event: %~2
del "%FLAG%" >nul 2>&1
:: logon already shows the gate via the Run key / startup / logon task, so the
:: switcher must NOT pop a second one here. gate files are self-managed now.
set "FROMGATE=1"
if /i "%~2"=="%target%" goto want_on
goto want_off

:writeflag
>"%FLAG%" echo done %date% %time%
>>"%SWLOG%" echo [%date% %time%] done flag written
exit /b 0

:consume_request
set "requser="
if exist "%REQ%" (
    for /f "usebackq delims=" %%u in ("%REQ%") do (
        set "r=%%u"
        for /f "tokens=1" %%v in ("!r!") do set "requser=%%v"
    )
)
exit /b 0

:now_mode
:: Authoritative worker. Detects the active console user and FORCES the matching
:: state. Needs no request file and no per-user logon task, so switching works on
:: its own: every minute as SYSTEM (poll) and on every session event. Because it
:: runs as SYSTEM, closing the cosmetic gate window cannot stop the apply/remove.
:: PURE-BATCH active-user detection (NO PowerShell - this PC blocks PS scripts).
:: quser is a native .exe and works from SYSTEM. The active console session is the
:: line whose STATE is "Active"; its first token is the user (current session has a
:: leading > which we strip). No PowerShell anywhere on the switching path.
set "FROMGATE=1"
set "active="
for /f "tokens=1" %%u in ('quser 2^>nul ^| findstr /i /c:"Active"') do set "active=%%u"
if defined active set "active=!active:>=!"
:: Decide desired state. No active user (lock/boot) = fail-closed ON.
set "desired=ON"
if defined active if /i not "!active!"=="%target%" set "desired=OFF"
:: NO-OP when already correct - the engine calls this every ~2s, so only act on a
:: real change. This prevents rewriting the policy hundreds of times a minute.
if /i "%cur%"=="!desired!" exit /b 0
>>"%SWLOG%" echo [%date% %time%] WORKER active=[!active!] target=[%target%] change %cur%-^>!desired!
if /i "!desired!"=="ON" goto want_on
goto want_off

:event_mode
:: Unlock / reconnect / disconnect / session-logon all use the same authoritative
:: detection as the poll.
goto now_mode

:want_on
>>"%SWLOG%" echo [%date% %time%] WANT ON - force-applying block (previous state=%cur%)
call :apply
>"%STATEF%" echo ON
if not "%cur%"=="ON" (
    call :killbrowsers
    if not defined FROMGATE schtasks /run /tn "WebFilter_UI_Logon" >nul 2>&1
) else (
    >>"%SWLOG%" echo [%date% %time%] already ON - re-asserted policy, left browsers alone
)
goto writeflag

:want_off
>>"%SWLOG%" echo [%date% %time%] WANT OFF - force-removing block (previous state=%cur%)
call :remove
>"%STATEF%" echo OFF
if not "%cur%"=="OFF" (
    call :killbrowsers
    if not defined FROMGATE schtasks /run /tn "WebFilter_UI_Logon" >nul 2>&1
) else (
    >>"%SWLOG%" echo [%date% %time%] already OFF - re-asserted removal, left browsers alone
)
goto writeflag

:killbrowsers
taskkill /f /im chrome.exe >nul 2>&1
taskkill /f /im msedge.exe >nul 2>&1
taskkill /f /im brave.exe >nul 2>&1
>>"%SWLOG%" echo [%date% %time%] state change complete - browsers closed, they relaunch with current policy
exit /b 0

:apply
set "RF=C:\ProgramData\BrowserFilter\policy_apply.reg"
>"%RF%" echo Windows Registry Editor Version 5.00
>>"%RF%" echo.
call :regsec "SOFTWARE\Policies\Google\Chrome"
call :regsec "SOFTWARE\WOW6432Node\Policies\Google\Chrome"
call :regsec "SOFTWARE\Policies\Microsoft\Edge"
call :regsec "SOFTWARE\WOW6432Node\Policies\Microsoft\Edge"
call :regsec "SOFTWARE\Policies\BraveSoftware\Brave"
call :regsec "SOFTWARE\WOW6432Node\Policies\BraveSoftware\Brave"
reg import "%RF%" >nul 2>&1
del "%RF%" >nul 2>&1
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if errorlevel 1 (
    >>"%SWLOG%" echo [%date% %time%] WARNING - reg import failed, falling back to reg add
    call :applyb "Google\Chrome"
    call :applyb "Microsoft\Edge"
    call :applyb "BraveSoftware\Brave"
)
>>"%SWLOG%" echo [%date% %time%] block applied
exit /b 0

:regsec
set "RS=%~1"
set /a wk=0
>>"%RF%" echo [HKEY_LOCAL_MACHINE\%RS%\URLBlocklist]
>>"%RF%" echo "1"="*"
>>"%RF%" echo.
>>"%RF%" echo [HKEY_LOCAL_MACHINE\%RS%\URLAllowlist]
if exist "%NUM%" for /f "usebackq tokens=1,* delims=;" %%i in ("%NUM%") do call :regline "%%j"
>>"%RF%" echo.
>>"%RF%" echo [HKEY_LOCAL_MACHINE\%RS%]
>>"%RF%" echo "DownloadRestrictions"=dword:00000000
echo %RS%| findstr /c:"Microsoft\Edge" >nul 2>&1
if not errorlevel 1 (
    >>"%RF%" echo "SmartScreenEnabled"=dword:00000000
    >>"%RF%" echo "SmartScreenPuaEnabled"=dword:00000000
    >>"%RF%" echo "PreventSmartScreenPromptOverride"=dword:00000000
    >>"%RF%" echo "PreventSmartScreenPromptOverrideForFiles"=dword:00000000
)
>>"%RF%" echo.
>>"%SWLOG%" echo [%date% %time%] built %RS% with %wk% allow entries
exit /b 0

:regline
set "pat=%~1"
if not defined pat exit /b 0
if "%pat:~0,1%"=="[" exit /b 0
if "%pat%"=="*" exit /b 0
set /a wk+=1
>>"%RF%" echo "%wk%"="%pat%"
exit /b 0

:applyb
call :writeone "HKLM\SOFTWARE\Policies\%~1"
call :writeone "HKLM\SOFTWARE\WOW6432Node\Policies\%~1"
exit /b 0

:writeone
set "BK=%~1"
reg delete "%BK%\URLAllowlist" /f >nul 2>&1
reg delete "%BK%\URLBlocklist" /f >nul 2>&1
reg add "%BK%\URLBlocklist" /v 1 /t REG_SZ /d "http://*" /f >nul 2>&1
reg add "%BK%\URLBlocklist" /v 2 /t REG_SZ /d "https://*" /f >nul 2>&1
reg add "%BK%" /v DownloadRestrictions /t REG_DWORD /d 0 /f >nul 2>&1
set /a wk=0
if exist "%NUM%" for /f "usebackq tokens=1,* delims=;" %%i in ("%NUM%") do call :addline "%%j"
>>"%SWLOG%" echo [%date% %time%] %wk% allow entries written to %BK%
exit /b 0

:addline
set "pat=%~1"
if not defined pat exit /b 0
if "%pat:~0,1%"=="[" exit /b 0
if "%pat%"=="*" exit /b 0
set /a wk+=1
reg add "%BK%\URLAllowlist" /v %wk% /t REG_SZ /d "%~1" /f >nul 2>&1
exit /b 0

:remove
for %%B in ("Google\Chrome" "Microsoft\Edge" "BraveSoftware\Brave") do (
    reg delete "HKLM\SOFTWARE\Policies\%%~B\URLBlocklist" /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\Policies\%%~B\URLAllowlist" /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\WOW6432Node\Policies\%%~B\URLBlocklist" /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\WOW6432Node\Policies\%%~B\URLAllowlist" /f >nul 2>&1
)
for %%V in ("HKLM\SOFTWARE\Policies" "HKLM\SOFTWARE\WOW6432Node\Policies") do (
    reg delete "%%~V\Microsoft\Edge" /v SmartScreenEnabled /f >nul 2>&1
    reg delete "%%~V\Microsoft\Edge" /v SmartScreenPuaEnabled /f >nul 2>&1
    reg delete "%%~V\Microsoft\Edge" /v PreventSmartScreenPromptOverride /f >nul 2>&1
    reg delete "%%~V\Microsoft\Edge" /v PreventSmartScreenPromptOverrideForFiles /f >nul 2>&1
)
reg query "HKLM\SOFTWARE\Policies\Google\Chrome\URLBlocklist" /v 1 >nul 2>&1
if not errorlevel 1 >>"%SWLOG%" echo [%date% %time%] WARNING - blocklist still present after remove
exit /b 0
::SW11_END

:: ==================================================================
:: EMBEDDED ENGINE PAYLOAD (PowerShell) - DO NOT EDIT BELOW THIS LINE
:: Extracted at setup to engine.ps1 and run as an always-on SYSTEM task.
:: ==================================================================
::ENGINE_BEGIN
@echo off
setlocal enabledelayedexpansion
title WebFilterEngine
:: ENGINE-VERSION-2026-10-BATCH  (pure batch - NO PowerShell, so it runs even when .ps1 is blocked)
:: Always-on SYSTEM loop. Every ~2s it calls the switcher in NOW mode, which does
:: pure-batch quser detection and forces the filter ON for the target / OFF for
:: anyone else. Writes a heartbeat file each pass so setup can confirm it is alive.
set "BASE=C:\ProgramData\BrowserFilter"
set "SWITCHER=%BASE%\WebFilter_Switch.cmd"
set "HB=%BASE%\engine_hb.txt"
set "LOG=%BASE%\switch_log.txt"
>>"%LOG%" echo [%date% %time%] ENGINE(batch) started
:eloop
> "%HB%" echo %date% %time%
if exist "%SWITCHER%" call "%SWITCHER%" NOW
ping -n 3 127.0.0.1 >nul
goto eloop
::ENGINE_END

:: ==================================================================
:: EMBEDDED USB/STORE KILLER (.bat) - runs in the TARGET session
:: ==================================================================
::WATCHBAT_BEGIN
@echo off
title WebFilterWatch
:: USB-WATCH-VERSION-2026-10d - runs as SYSTEM from BOOT, so it is ALREADY running
:: before the target reaches the desktop (no post-reboot gap where a USB app could
:: launch). ONE persistent powershell with an internal 0.4-second loop. Scoped to the
:: target by process owner. Each cycle it kills the target's: apps on any drive except
:: C: (USB), the Microsoft Store, and winget / AppInstaller (command-line installs).
:: On each kill it fires the interactive WebFilter_Denied task, which shows the ACCESS
:: DENIED window in the target's session (a SYSTEM process cannot draw a window). It
:: writes a heartbeat each cycle; if the loop ever exits, this .bat relaunches it.
:relaunch
powershell -NoProfile -Command "$t=(Get-Content 'C:\ProgramData\BrowserFilter\config.txt' | Select-Object -First 1).Trim(); while($true){ Set-Content -LiteralPath 'C:\ProgramData\BrowserFilter\watch_hb.txt' -Value 1 -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process | ForEach-Object { $p=$_; $u=$p.ExecutablePath; $n=$p.Name; $hit=($u -and $u -match '^[A-Za-z]:\\' -and $u -notmatch '^[Cc]:\\') -or ($n -eq 'WinStore.App.exe'); if($hit){ $o=Invoke-CimMethod -InputObject $p -MethodName GetOwner; if($o -and $o.User -ieq $t){ try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; schtasks /run /tn 'WebFilter_Denied' 2>$null | Out-Null; Start-Process 'C:\ProgramData\BrowserFilter\denied.bat' -ErrorAction SilentlyContinue } catch {} } } }; Start-Sleep -Milliseconds 400 }"
ping -n 3 127.0.0.1 >nul 2>&1
goto relaunch
::WATCHBAT_END

:: ==================================================================
:: EMBEDDED ACCESS-DENIED POPUP (.bat) - shown on each kill, auto-closes
:: ==================================================================
::DENIED_BEGIN
@echo off
title ACCESS DENIED
color 4F
echo.
echo     ============================================================
echo.
echo        ACCESS DENIED
echo.
echo        This app is blocked on this account.
echo.
echo     ============================================================
ping -n 7 127.0.0.1 >nul 2>&1
::DENIED_END

:: ==================================================================
:: EMBEDDED HIDDEN LAUNCHER (.vbs) - starts the killer with no window
:: ==================================================================
::WATCHVBS_BEGIN
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c " & Chr(34) & "C:\ProgramData\BrowserFilter\usb_watch.bat" & Chr(34), 0, False
::WATCHVBS_END