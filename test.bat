@echo off
rem Runs the scripted gore/combat test without taking over the desktop: an unfocusable window placed off-screen
rem (same as tools/run_test.sh). Screenshots + a log go to game\test_out.
set "OVR=%~dp0game\override.cfg"
if exist "%OVR%" (
  echo test.bat: %OVR% already exists; not touching it
  exit /b 1
)
(echo [display]& echo.& echo window/size/no_focus=true) > "%OVR%"
"%~dp0tools\godot\Godot_v4.7.2-stable_win64_console.exe" --path "%~dp0game" --windowed --resolution 1280x720 --position -4000,-4000 -- --autotest=%~dp0game\test_out
del "%OVR%"
