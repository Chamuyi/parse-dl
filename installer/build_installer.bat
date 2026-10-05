@echo off
REM Legacy double-click entry point.
REM The real build script is installer\build_installer.py (single source of VERSION).
REM This wrapper is ASCII-only on purpose: a .bat with Chinese text and no BOM
REM gets decoded as GBK by cmd.exe and garbles both output and filename args.
setlocal
REM Resolve python from PATH; fall back to the Windows launcher. Hardcoding a
REM per-machine absolute path here used to leak the build host's user name and
REM broke the script for everyone else.
where python >nul 2>nul
if %errorlevel%==0 (set "PYTHON=python") else (set "PYTHON=py -3")
"%PYTHON%" "%~dp0build_installer.py" %*
endlocal
