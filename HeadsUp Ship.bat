@echo off
title HeadsUp Ship
cd /d "%~dp0"
echo.
echo HeadsUp Ship
echo - Uses the version written in HeadsUp.toc (it does not change it)
echo - Creates HeadsUp-x.y.z.zip on the Desktop, with only the HeadsUp folder inside
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\ship.ps1"
echo.
if errorlevel 1 (
  echo FAILED. Check the messages above.
) else (
  echo OK. Check your Desktop for HeadsUp-*.zip
)
echo.
pause
