@echo off
chcp 65001 >nul
setlocal EnableExtensions

rem ---------------------------------------------------------------------
rem  restore.bat - lop vo goi restore-winget.ps1 de click-chay duoc.
rem  Go WinGet (Microsoft.DesktopAppInstaller) va nap lai registry tu
rem  backup. Moi thao tac deu duoc ghi vao thay_doi_sys.md.
rem
rem  Tham so duoc chuyen nguyen van xuong script PowerShell, vi du:
rem     restore.bat -DryRun
rem     restore.bat -BackupTag 20261023-164150
rem     restore.bat -BackupTag 20261023-164150 -DryRun
rem     restore.bat -Force
rem  Khong co tham so = dung backup moi nhat, hoi xac nhan truoc khi go.
rem
rem  Mac dinh KHONG go Microsoft.VCLibs / Microsoft.UI.Xaml / WindowsAppRuntime
rem  vi ung dung khac tren may dung chung. Them -RemoveDependencies neu chac chan.
rem ---------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo === Go WinGet / khoi phuc he thong ===
echo Thu muc lam viec: %CD%
echo.

if exist "%~dp0backup" (
    echo Cac ban backup hien co trong backup\:
    for /d %%D in ("%~dp0backup\*") do echo     %%~nxD
    echo.
) else (
    echo [CANH BAO] Khong thay thu muc backup\ - khong co gi de khoi phuc registry.
    echo.
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-winget.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [OK] restore-winget.ps1 hoan tat, exit code 0.
    echo      Cai lai neu muon:  install.bat
) else (
    echo [LOI] restore-winget.ps1 thoat voi exit code %RC%.
    echo       Doc log trong thu muc logs\ - he thong co the dang o trang thai nua chung.
)
echo.
echo Nhat ky thay doi he thong: thay_doi_sys.md
echo.
pause
exit /b %RC%
