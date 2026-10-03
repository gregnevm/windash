@echo off
rem Launch WinDash as administrator (needed to manage services)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0windash.ps1""'"
