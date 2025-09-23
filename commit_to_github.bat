@echo off
echo Starting GitHub Auto-Monitor Script...
node "%~dp0commit_to_github.js" %*
pause