@echo off
chcp 65001 >nul
setlocal EnableExtensions

rem ---------------------------------------------------------------------
rem  install.bat - lop vo goi install-winget.ps1 de click-chay duoc.
rem  Moi thu (backup, tai file, cai dat, ghi thay_doi_sys.md) deu do
rem  install-winget.ps1 lam. File .bat nay khong sua gi tren he thong.
rem
rem  Tham so duoc chuyen nguyen van xuong script PowerShell, vi du:
rem     install.bat -DryRun
rem     install.bat -Scope CurrentUser
rem     install.bat -DryRun -SkipHashCheck
rem  Khong co tham so = cai that (all-users + provisioned).
rem ---------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo === Cai WinGet - xem chi tiet trong install-winget.ps1 ===
echo Thu muc lam viec: %CD%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-winget.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [OK] install-winget.ps1 hoan tat, exit code 0.
    echo      Kiem tra lai:  winget --version
) else (
    echo [LOI] install-winget.ps1 thoat voi exit code %RC%.
    echo       Doc log trong thu muc logs\ de biet loi o buoc nao.
    echo       Neu can hoan tac:  restore.bat
)
echo.
echo Nhat ky thay doi he thong: thay_doi_sys.md
echo.
pause
exit /b %RC%
