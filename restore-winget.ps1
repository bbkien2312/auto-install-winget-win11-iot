#requires -Version 5.1
<#
.SYNOPSIS
    Removes WinGet (Microsoft.DesktopAppInstaller) and restores the system state
    captured by install-winget.ps1.

.DESCRIPTION
    Undo path for install-winget.ps1:
      1. Locate the backup folder (newest, or the one named by -BackupTag).
      2. Show exactly what will be removed, then wait unless -Force.
      3. Remove-AppxProvisionedPackage so new user profiles stop getting WinGet.
      4. Remove-AppxPackage -AllUsers so every existing account loses it.
      5. Re-import the backed-up registry for AppModelUnlock.
      6. Verify the machine is back to the recorded "before" state.
      7. Record everything into thay_doi_sys.md.

    Microsoft.VCLibs and Microsoft.UI.Xaml are deliberately NOT removed by
    default: they are shared framework packages that other Store apps on this
    machine already depend on, and removing them can break those apps. Pass
    -RemoveDependencies only if you know this box had none before.

.PARAMETER RegistryScope
    Changed (default) re-imports only AppModelUnlock, the sole key the installer
    touches. All re-imports every key in the backup, including PATH - use that
    only if nothing else modified the environment since the backup was taken.

.EXAMPLE
    .\restore-winget.ps1 -DryRun

.EXAMPLE
    .\restore-winget.ps1 -BackupTag 20261023-160512 -Force
#>

[CmdletBinding()]
param(
    [string]$BackupTag,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Elevated,
    [switch]$RemoveDependencies,
    [ValidateSet('Changed', 'All', 'None')]
    [string]$RegistryScope = 'Changed',
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $Root 'lib.ps1')

$BackupRoot = Join-Path $Root 'backup'
$LogRoot    = Join-Path $Root 'logs'
$ChangeLog  = Join-Path $Root 'thay_doi_sys.md'
$PkgName    = 'Microsoft.DesktopAppInstaller'

if (-not (Test-Admin)) {
    if (-not $LogFile) { $LogFile = Join-Path $LogRoot ('restore-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Write-Host ''
    Write-Host 'Cần quyền Administrator. Một hộp thoại UAC sẽ hiện ra - hãy bấm Yes.' -ForegroundColor Yellow
    Write-Host ''
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                   '-Elevated', '-RegistryScope', $RegistryScope, '-LogFile', "`"$LogFile`"")
    if ($DryRun)             { $childArgs += '-DryRun' }
    if ($Force)              { $childArgs += '-Force' }
    if ($RemoveDependencies) { $childArgs += '-RemoveDependencies' }
    if ($BackupTag)          { $childArgs += @('-BackupTag', $BackupTag) }
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $childArgs -Wait -PassThru
    } catch {
        Write-Host ('Không elevate được: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    if (Test-Path $LogFile) { Get-Content $LogFile -Encoding UTF8 | Write-Host }
    Write-Host ''
    Write-Host ('Log đầy đủ: ' + $LogFile) -ForegroundColor Cyan
    exit $p.ExitCode
}

Initialize-Log $LogFile
$RunTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$ExitCode = 0
$Changes = @()

try {
    Log '===============================================================' 'STEP'
    Log ('  RESTORE / GỠ WINGET  -  ' + $(if ($DryRun) { 'DRY RUN (không sửa gì)' } else { 'RUN THẬT' })) 'STEP'
    Log '===============================================================' 'STEP'

    # -------------------------------------------------- locate the backup --
    $backupDir = $null
    if (Test-Path $BackupRoot) {
        if ($BackupTag) {
            $backupDir = Join-Path $BackupRoot $BackupTag
            if (-not (Test-Path $backupDir)) { throw ('Không tìm thấy backup "' + $BackupTag + '" trong ' + $BackupRoot) }
        } else {
            # snapshot-* folders written by check-status.ps1 -Snapshot contain only
            # state.json, not the registry exports restore needs, so they must not
            # win as the "newest backup".
            $candidates = @(Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'snapshot-*' } |
                Sort-Object Name -Descending)
            if ($candidates.Count) { $backupDir = $candidates[0].FullName }
        }
    }
    if ($backupDir) { Log ('Backup dùng để đối chiếu: ' + $backupDir) 'OK' }
    else { Log 'Không tìm thấy backup nào. Vẫn gỡ được gói, nhưng sẽ không khôi phục được registry.' 'WARN' }

    $before = Get-WingetState -IncludeProvisioned
    Write-Host ''
    Write-Host (Format-StateReport $before)

    # ------------------------------------------------------- removal list --
    $targets = @($before.AllUsers | Where-Object { $_.Name -eq $PkgName })
    if (-not $targets.Count) { $targets = @($before.PerUser | Where-Object { $_.Name -eq $PkgName }) }
    $provTargets = @($before.Provisioned | Where-Object { $_.DisplayName -eq $PkgName })

    $depTargets = @()
    if ($RemoveDependencies) {
        $depTargets = @(Get-AppxPackage | Where-Object { $_.Name -match '^Microsoft\.VCLibs|^Microsoft\.UI\.Xaml' })
    }

    Write-Host ''
    Log '--- Những thứ sẽ bị gỡ ---' 'STEP'
    if ($provTargets.Count) { $provTargets | ForEach-Object { Log ('  provisioned : ' + $_.DisplayName + ' ' + $_.Version + ' ' + $_.Architecture) } }
    else { Log '  provisioned : không có' }
    if ($targets.Count) { $targets | ForEach-Object { Log ('  all-users   : ' + $_.PackageFullName) } }
    else { Log '  all-users   : không có' }
    if ($depTargets.Count) { $depTargets | ForEach-Object { Log ('  dependency  : ' + $_.Name + ' ' + $_.Version + ' ' + $_.Architecture) 'WARN' } }
    else { Log '  dependency  : GIỮ LẠI (VCLibs/UI.Xaml đang được app khác dùng chung)' }
    Log ('  registry    : scope=' + $RegistryScope)

    # No packages to remove is NOT a reason to bail out: the install may have
    # failed partway through after already writing to the registry, and that
    # still needs undoing.
    $hasPackages = [bool]($provTargets.Count -or $targets.Count)
    if (-not $hasPackages) { Log 'Không có gói DesktopAppInstaller nào để gỡ - chỉ hoàn tác registry nếu có.' 'WARN' }

    if ($hasPackages -and -not $DryRun -and -not $Force) {
        Write-Host ''
        $ans = Read-Host 'Gõ YES để tiến hành gỡ, bất kỳ phím nào khác để huỷ'
        if ($ans -ne 'YES') { Log 'Đã huỷ theo yêu cầu người dùng.' 'WARN'; exit 0 }
    }

    # ------------------------------------------------------- provisioning --
    Write-Host ''
    Log '--- [1/4] Gỡ provisioning ---' 'STEP'
    foreach ($p in $provTargets) {
        if ($DryRun) { Log ('DRY-RUN: Remove-AppxProvisionedPackage -AllUsers -PackageName ' + $p.DisplayName) 'DRY'; continue }
        try {
            Remove-AppxProvisionedPackage -Online -AllUsers -PackageName $p.DisplayName | Out-Null
            Log ('  đã gỡ provisioned: ' + $p.DisplayName) 'OK'
            $Changes += ('Gỡ provisioning: ' + $p.DisplayName + ' ' + $p.Version)
        } catch {
            Log ('  KHÔNG gỡ được provisioned ' + $p.DisplayName + ': ' + $_.Exception.Message) 'ERR'
            $script:ExitCode = 1
        }
    }

    # ------------------------------------------------------------- package --
    Write-Host ''
    Log '--- [2/4] Gỡ gói DesktopAppInstaller ---' 'STEP'
    foreach ($t in $targets) {
        if ($DryRun) { Log ('DRY-RUN: Remove-AppxPackage -AllUsers -Package ' + $t.PackageFullName) 'DRY'; continue }
        try {
            Remove-AppxPackage -AllUsers -Package $t.PackageFullName
            Log ('  đã gỡ: ' + $t.PackageFullName) 'OK'
            $Changes += ('Gỡ gói: ' + $t.PackageFullName)
        } catch {
            Log ('  KHÔNG gỡ được ' + $t.PackageFullName + ': ' + $_.Exception.Message) 'ERR'
            Log '  Nếu báo "being used by another process", hãy đóng mọi cửa sổ terminal đang chạy winget rồi thử lại.' 'WARN'
            $script:ExitCode = 1
        }
    }

    if ($depTargets.Count) {
        foreach ($d in $depTargets) {
            if ($DryRun) { Log ('DRY-RUN: Remove-AppxPackage -AllUsers -Package ' + $d.PackageFullName) 'DRY'; continue }
            try {
                Remove-AppxPackage -AllUsers -Package $d.PackageFullName
                Log ('  đã gỡ dependency: ' + $d.Name + ' ' + $d.Architecture) 'OK'
                $Changes += ('Gỡ phụ thuộc: ' + $d.PackageFullName)
            } catch {
                Log ('  KHÔNG gỡ được dependency ' + $d.Name + ': ' + $_.Exception.Message) 'WARN'
                Log '  Thường là do vẫn còn app khác phụ thuộc vào nó - bỏ qua là an toàn.' 'WARN'
            }
        }
    }

    # ------------------------------------------------------------ registry --
    Write-Host ''
    Log '--- [3/4] Khôi phục registry ---' 'STEP'
    if ($RegistryScope -eq 'None') {
        Log 'RegistryScope=None nên bỏ qua toàn bộ khôi phục registry.' 'WARN'
    } else {
        # 3a. undo.json is the authoritative revert path: `reg import` merges, so
        #     it cannot remove a value that did not exist when the backup was made.
        $undoPath = if ($backupDir) { Join-Path $backupDir 'undo.json' } else { $null }
        if ($undoPath -and (Test-Path $undoPath)) {
            # Assign first, then wrap. Inlining @(Get-Content ... | ConvertFrom-Json)
            # produces a doubly-nested array, so each element ends up being an
            # Object[] instead of the action record.
            $undoRaw = Get-Content $undoPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $undo = @($undoRaw)
            Log ('undo.json: ' + $undo.Count + ' hành động hoàn tác.') 'STEP'
            foreach ($a in $undo) {
                if ((Get-PropSafe $a 'Kind') -ne 'RegValue') { Log ('  bỏ qua loại hành động không quen: ' + (Get-PropSafe $a 'Kind')) 'WARN'; continue }
                $p = Get-PropSafe $a 'Path'
                $n = Get-PropSafe $a 'Name'
                if (-not $p -or -not $n) { Log '  mục undo thiếu Path/Name - bỏ qua' 'WARN'; continue }
                $existed = [bool](Get-PropSafe $a 'ExistedBefore' $false)
                $old = Get-PropSafe $a 'OldValue'
                $cur = Get-PropSafe (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue) $n '__ABSENT__'

                if (-not $existed) {
                    if ($DryRun) { Log ('DRY-RUN: would DELETE ' + $p + '\' + $n + ' (hiện là ' + $cur + '; trước khi cài chưa tồn tại)') 'DRY'; continue }
                    if ($cur -eq '__ABSENT__') { Log ('  đã đúng trạng thái gốc (không tồn tại): ' + $p + '\' + $n) 'OK'; continue }
                    Remove-ItemProperty -Path $p -Name $n -Force
                    Log ('  đã XOÁ ' + $p + '\' + $n + ' (giá trị ' + $cur + ' là do script cài đặt tạo ra)') 'OK'
                    $Changes += ('Hoàn tác registry: xoá ' + $p + '\' + $n + ' (giá trị ' + $cur + ')')
                } else {
                    if ($DryRun) { Log ('DRY-RUN: would SET ' + $p + '\' + $n + ' = ' + $old + ' (hiện là ' + $cur + ')') 'DRY'; continue }
                    if ("$cur" -eq "$old") { Log ('  đã đúng giá trị gốc: ' + $p + '\' + $n + ' = ' + $old) 'OK'; continue }
                    Set-ItemProperty -Path $p -Name $n -Value $old
                    Log ('  đã đặt lại ' + $p + '\' + $n + ' = ' + $old) 'OK'
                    $Changes += ('Hoàn tác registry: ' + $p + '\' + $n + ' = ' + $old)
                }
            }
        } else {
            Log 'Không có undo.json: installer không sửa giá trị registry nào trong lần chạy đó.' 'WARN'
        }

        # 3b. reg import - broad safety net, restores everything that DID exist.
        if (-not $backupDir) {
            Log 'Không có thư mục backup nên bỏ qua reg import.' 'WARN'
        } else {
            $toImport = @(Get-ChildItem $backupDir -Filter 'reg_*.reg' -ErrorAction SilentlyContinue)
            if ($RegistryScope -eq 'Changed') { $toImport = @($toImport | Where-Object { $_.Name -match 'AppModelUnlock' }) }
            if (-not $toImport.Count) { Log 'Không có file .reg nào phù hợp để nạp lại.' 'WARN' }
            foreach ($f in $toImport) {
                if ($DryRun) { Log ('DRY-RUN: reg import ' + $f.Name + ' (chỉ GỘP giá trị, không xoá giá trị thừa)') 'DRY'; continue }
                $r = Invoke-Native 'reg.exe' @('import', $f.FullName)
                if ($r.ExitCode -eq 0) { Log ('  đã nạp lại: ' + $f.Name) 'OK'; $Changes += ('Khôi phục registry từ ' + $f.Name) }
                else { Log ('  NẠP THẤT BẠI: ' + $f.Name + ' -> ' + $r.Output.Trim()) 'ERR'; $script:ExitCode = 1 }
            }

            if ($RegistryScope -eq 'All') {
                foreach ($n in @('path-machine', 'path-user')) {
                    $pf = Join-Path $backupDir ($n + '.txt')
                    if (-not (Test-Path $pf)) { continue }
                    $val = (Get-Content $pf -Raw).TrimEnd("`r", "`n")
                    if ($DryRun) { Log ('DRY-RUN: restore PATH (' + $n + ')') 'DRY'; continue }
                    if ($n -eq 'path-machine') { [Environment]::SetEnvironmentVariable('Path', $val, 'Machine') }
                    else                       { [Environment]::SetEnvironmentVariable('Path', $val, 'User') }
                    Log ('  đã khôi phục PATH: ' + $n) 'OK'
                    $Changes += ('Khôi phục PATH từ ' + $n + '.txt')
                }
            }

            # Keys absent at backup time but present now were created by the installer.
            foreach ($absent in @(Get-ChildItem $backupDir -Filter '*.absent.txt' -ErrorAction SilentlyContinue)) {
                $key = ((Get-Content $absent.FullName -Raw) -replace '^Key absent at backup time:\s*', '').Trim()
                if (-not $key) { continue }
                $psPath = $key -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\'
                if ($DryRun) { Log ('DRY-RUN: key "' + $key + '" chưa tồn tại lúc backup - sẽ kiểm tra xem có bị bỏ sót không') 'DRY'; continue }
                if (Test-Path $psPath) {
                    Log ('Key "' + $key + '" chưa tồn tại lúc backup nhưng giờ ĐANG tồn tại. Nếu do script tạo ra, hãy xoá bằng: reg delete "' + $key + '" /f') 'WARN'
                    $Changes += ('CÒN SÓT: key ' + $key + ' hiện đang tồn tại dù lúc backup chưa có - cần kiểm tra tay')
                } else {
                    Log ('OK: "' + $key + '" vẫn không tồn tại, đúng như lúc backup.') 'OK'
                }
            }
        }
    }

    # ---------------------------------------------------------- verify ------
    Write-Host ''
    Log '--- [4/4] Kiểm tra lại ---' 'STEP'
    if ($DryRun) {
        Log 'DRY-RUN: would re-snapshot and compare against state-before.json' 'DRY'
        $after = $before
    } else {
        Start-Sleep -Milliseconds 500
        $after = Get-WingetState -IncludeProvisioned
        Write-Host ''
        Write-Host (Format-StateReport $after)
        if ($after.PerUser.Count -or $after.AllUsers.Count -or $after.Provisioned.Count) {
            Log 'Vẫn còn dấu vết của DesktopAppInstaller. Xem danh sách ở trên.' 'WARN'
            $script:ExitCode = 1
        } else {
            Log 'Đã gỡ sạch Microsoft.DesktopAppInstaller.' 'OK'
        }
        if ($backupDir -and (Test-Path (Join-Path $backupDir 'state-before.json'))) {
            Write-Utf8Bom (Join-Path $backupDir 'state-after-restore.json') ($after | ConvertTo-Json -Depth 4)
            Log ('Đã ghi state-after-restore.json vào ' + $backupDir + ' để bạn tự đối chiếu.') 'OK'
        }
    }

    # ------------------------------------------------------- change log ----
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' — ' + $(if ($DryRun) { 'DRY RUN gỡ WinGet (không sửa gì)' } else { 'Gỡ WinGet / khôi phục hệ thống' }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **Script**: `restore-winget.ps1 -RegistryScope ' + $RegistryScope + $(if ($RemoveDependencies) { ' -RemoveDependencies' } else { '' }) + $(if ($DryRun) { ' -DryRun' } else { '' }) + '`')
    [void]$sb.AppendLine('- **Người chạy**: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    [void]$sb.AppendLine('- **Backup đối chiếu**: `' + $(if ($backupDir) { Split-Path $backupDir -Leaf } else { 'không có' }) + '`')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Thay đổi trên hệ thống')
    if ($DryRun) { [void]$sb.AppendLine('_Dry run — không có thay đổi nào được thực hiện._') }
    elseif ($Changes.Count) { foreach ($c in $Changes) { [void]$sb.AppendLine('- ' + $c) } }
    else { [void]$sb.AppendLine('- Không có thay đổi.') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Đã giữ lại (không gỡ)')
    if ($RemoveDependencies) { [void]$sb.AppendLine('- Không — `-RemoveDependencies` được bật nên VCLibs/UI.Xaml cũng bị gỡ.') }
    else {
        [void]$sb.AppendLine('- `Microsoft.VCLibs.140.00.UWPDesktop`, `Microsoft.UI.Xaml.2.8` — gói framework dùng chung, ứng dụng khác trên máy vẫn cần.')
        [void]$sb.AppendLine('- File tải về trong `cache\` — giữ để đỡ tải lại nếu release không đổi (không cài offline được). Xoá tay nếu muốn dọn ổ đĩa.')
        [void]$sb.AppendLine('- Toàn bộ thư mục `backup\` — giữ làm lịch sử.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Cài lại')
    [void]$sb.AppendLine('```powershell')
    [void]$sb.AppendLine('.\install-winget.ps1          # dùng lại cache nếu release không đổi; vẫn cần mạng để gọi GitHub API')
    [void]$sb.AppendLine('```')
    Add-ChangeLogEntry -Path $ChangeLog -Markdown $sb.ToString() -DryRun:$DryRun

    Write-Host ''
    Log '===============================================================' 'STEP'
    if ($DryRun) { Log 'DRY RUN hoàn tất. KHÔNG có thay đổi nào trên hệ thống.' 'DRY' }
    else { Log ('HOÀN TẤT. Exit code = ' + $script:ExitCode) $(if ($script:ExitCode -eq 0) { 'OK' } else { 'WARN' }) }
    Log ('Nhật ký: ' + $ChangeLog)
    Log '===============================================================' 'STEP'
}
catch {
    Log ('LỖI: ' + $_.Exception.Message) 'ERR'
    Log ('Tại  : ' + $_.InvocationInfo.PositionMessage) 'ERR'
    $script:ExitCode = 1
}

exit $script:ExitCode
