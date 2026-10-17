@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\local\install.ps1" %*
set "task_exit=%errorlevel%"
echo.
if not "%task_exit%"=="0" echo Local build/install failed. Review the messages above.
pause
exit /b %task_exit%
