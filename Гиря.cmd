@echo off
REM ===========================================================================
REM  Гиря — быстрый запуск меню двойным кликом из проводника Windows.
REM ===========================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Girya.ps1" menu
pause
