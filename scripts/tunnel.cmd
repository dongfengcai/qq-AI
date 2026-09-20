@echo off
setlocal enabledelayedexpansion
title DSH Tunnel - keep this window OPEN

rem ===========================================================================
rem  AstrBot / NapCat SSH tunnel with auto-reconnect
rem
rem  Keep this window open the whole time you need the panels.
rem  If the connection drops, it reconnects automatically after a few seconds.
rem  Close the window (or press Ctrl+C) to stop.
rem
rem  EDIT THE SERVER ADDRESS BELOW.
rem ===========================================================================

rem ---- server ---------------------------------------------------------------
set "SSH_USER=root"
set "SSH_HOST=8.163.95.90"
set "SSH_PORT=22"
rem ---------------------------------------------------------------------------

rem ---- local ports (change the LEFT number if a port is already in use) -----
set "LOCAL_ASTROBOT=6185"
set "LOCAL_NAPCAT=6099"
rem ---------------------------------------------------------------------------

rem ---- reconnect delay in seconds -------------------------------------------
set "RETRY_DELAY=5"
rem ---------------------------------------------------------------------------

if /i "%SSH_HOST%"=="CHANGE_ME" (
  echo.
  echo   [ERROR] Edit this file and set SSH_HOST to your server address.
  echo.
  pause
  exit /b 1
)

where ssh.exe >nul 2>nul
if errorlevel 1 (
  echo.
  echo   [ERROR] ssh.exe not found on PATH.
  echo   Install the Windows OpenSSH Client:
  echo     Settings ^> Apps ^> Optional features ^> Add a feature ^> OpenSSH Client
  echo.
  pause
  exit /b 1
)

set /a ATTEMPT=0

:loop
set /a ATTEMPT+=1
cls
echo.
echo   ==========================================================
echo     DSH tunnel  -  attempt !ATTEMPT!
echo   ==========================================================
echo.
echo     Server   : %SSH_USER%@%SSH_HOST%:%SSH_PORT%
echo     AstrBot  : http://127.0.0.1:%LOCAL_ASTROBOT%
echo     NapCat   : http://127.0.0.1:%LOCAL_NAPCAT%/webui
echo.
echo     Keep this window OPEN. Closing it kills the tunnel.
echo     Press Ctrl+C to stop.
echo.

ssh -N ^
    -o ServerAliveInterval=15 ^
    -o ServerAliveCountMax=3 ^
    -o TCPKeepAlive=yes ^
    -o ExitOnForwardFailure=yes ^
    -o ConnectTimeout=15 ^
    -p %SSH_PORT% ^
    -L %LOCAL_ASTROBOT%:127.0.0.1:6185 ^
    -L %LOCAL_NAPCAT%:127.0.0.1:6099 ^
    %SSH_USER%@%SSH_HOST%

set "CODE=%ERRORLEVEL%"

echo.
if "%CODE%"=="0" (
  echo   Tunnel closed.
) else (
  echo   Tunnel dropped ^(exit code %CODE%^).
)
echo   Reconnecting in %RETRY_DELAY% seconds...  ^(Ctrl+C to stop^)
timeout /t %RETRY_DELAY% /nobreak >nul
goto loop
