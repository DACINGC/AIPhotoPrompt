@echo off
chcp 65001 >nul
title 提示词资料查看器
echo.
echo   正在启动 提示词资料查看器...
echo   (浏览器将自动打开; 关闭本窗口即停止服务)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0md-viewer\server.ps1"
echo.
echo   服务已停止。
pause
