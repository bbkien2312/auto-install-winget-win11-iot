@echo off
chcp 65001 >nul
setlocal EnableExtensions

rem ---------------------------------------------------------------------
rem  uninstall_restore.bat - lop vo goi uninstall_restore.ps1.
rem  Khong co tham so = mo menu:
rem     1. go WinGet, khong dung registry
rem     2. go WinGet + khoi phuc registry tu backup
rem     3. chi khoi phuc registry, giu WinGet
rem     0. huy
rem
rem  Tham so duoc chuyen nguyen van xuong script PowerShell, vi du:
rem     uninstall_restore.bat -DryRun
rem     uninstall_restore.bat -BackupTag 20261024-074650
rem     uninstall_restore.bat -BackupTag 20261024-074650 -Force
rem     uninstall_restore.bat -KeepPackage -BackupTag 20261024-074650
rem     uninstall_restore.bat -CleanCache
rem
rem  Neu WinGet la thanh phan he thong (NonRemovable=True) thi Windows
rem  tu choi go (0x80070032). Khi do script chi khoi phuc registry va
rem  bao ro; khong co thay doi nao bi ep buoc.
rem
rem  Mac dinh KHONG go Microsoft.VCLibs / Microsoft.UI.Xaml /
rem  Microsoft.WindowsAppRuntime vi ung dung khac tren may dung chung.
rem  Them -RemoveDependencies neu chac chan.
rem
rem  backup\ KHONG BAO GIO bi xoa. cache\ chi bi xoa khi co -CleanCache
rem  hoac khi ban tra loi y o cuoi.
rem ---------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo === WinGet: go / khoi phuc he thong ===
echo Thu muc lam viec: %CD%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_restore.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [OK] uninstall_restore.ps1 hoan tat, exit code 0.
    echo      Cai lai neu muon:  install.bat
) else (
    echo [LOI] uninstall_restore.ps1 thoat voi exit code %RC%.
    echo       Doc log trong thu muc logs\. Neu Windows tu choi go goi he thong,
    echo       script se ghi ro va khong thay doi gi.
)
echo.
echo Nhat ky thay doi he thong: thay_doi_sys.md
echo.
pause
exit /b %RC%
