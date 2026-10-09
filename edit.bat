@echo off
rem Opens the project in the Godot editor.
start "" "%~dp0tools\godot\Godot_v4.7.2-stable_win64.exe" -e --path "%~dp0game"
