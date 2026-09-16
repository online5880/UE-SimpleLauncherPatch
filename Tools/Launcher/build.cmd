@echo off
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:winexe /out:"%~dp0Launcher.exe" /r:System.Windows.Forms.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll "%~dp0Launcher.cs"
if errorlevel 1 (echo BUILD FAILED & exit /b 1)
echo BUILD OK: %~dp0Launcher.exe
