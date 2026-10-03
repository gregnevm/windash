@echo off
rem Запуск WinDash з правами адміністратора (потрібні для керування службами)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0windash.ps1""'"
