#requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls WinGet (Microsoft.DesktopAppInstaller) and/or restores the
    registry state captured by install-winget.ps1.

.DESCRIPTION
    Menu-driven when started without arguments:
      1. Uninstall WinGet only - registry left untouched.
      2. Uninstall WinGet and restore the registry from a backup (default).
      3. Restore the registry only and keep WinGet (-KeepPackage).

    Direct-argument runs bypass the menu and default to mode 2.

    Package-removal path:
      1. Locate the backup folder (newest, or the one named by -BackupTag).
      2. Show exactly what will be removed, then wait unless -Force.
      3. Remove-AppxProvisionedPackage so new user profiles stop getting WinGet.
      4. Remove-AppxPackage -AllUsers so every existing account loses it.
      5. Replay undo.json, then re-import the backed-up .reg files.
      6. Verify the machine is back to the recorded "before" state.
      7. Optionally clear cache\ (-CleanCache).
      8. Record everything into thay_doi_sys.md.

    On some LTSC/IoT images (24H2) DesktopAppInstaller ships as an inbox app
    marked NonRemovable=True. Windows rejects every Remove-AppxPackage call
    with 0x80070032 "part of Windows". The script detects this up front and
    refuses to uninstall - only registry restore (-KeepPackage) is possible.
    This is a Windows limit, not a script failure.

    Microsoft.VCLibs, Microsoft.UI.Xaml and WindowsAppRuntime are deliberately
    NOT removed by default: they are shared framework packages that other apps
    on this machine already depend on. Pass -RemoveDependencies only if you
    know this box had none before.

    cache\ holds downloaded installers only; it is never removed unless you ask
    (-CleanCache or answer y at the end). backup\ is NEVER deleted.

.PARAMETER KeepPackage
    Restore the registry but keep Microsoft.DesktopAppInstaller installed.

.PARAMETER CleanCache
    Delete the downloaded files in cache\ after a successful run. Backups are
    not touched.

.PARAMETER RegistryScope
    Changed (default) re-imports only AppModelUnlock, the sole key the installer
    touches. All re-imports every key in the backup, including PATH - use that
    only if nothing else modified the environment since the backup was taken.
    None skips registry restore entirely (uninstall-only).

.PARAMETER Force
    Do not ask for the YES confirmation and do not prompt about cache cleanup.

.EXAMPLE
    .\uninstall_restore.ps1
    # opens the interactive menu

.EXAMPLE
    .\uninstall_restore.ps1 -DryRun

.EXAMPLE
    .\uninstall_restore.ps1 -BackupTag 20261023-160512 -Force

.EXAMPLE
    .\uninstall_restore.ps1 -KeepPackage -BackupTag 20261023-160512
#>

[CmdletBinding()]
param(
    [string]$BackupTag,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Elevated,
    [switch]$RemoveDependencies,
    [switch]$KeepPackage,
    [switch]$CleanCache,
    [ValidateSet('Changed', 'All', 'None')]
    [string]$RegistryScope = 'Changed',
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $Root 'lib.ps1')

$BackupRoot = Join-Path $Root 'backup'
$CacheDir   = Join-Path $Root 'cache'
$LogRoot    = Join-Path $Root 'logs'
$ChangeLog  = Join-Path $Root 'thay_doi_sys.md'
$PkgName    = 'Microsoft.DesktopAppInstaller'

function Show-CacheBackupSummary {
    $cacheFiles = @()
    $cacheBytes = 0
    if (Test-Path $CacheDir) {
        $cacheFiles = @(Get-ChildItem $CacheDir -File -Force -ErrorAction SilentlyContinue)
        $sum = (Get-ChildItem $CacheDir -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($sum) { $cacheBytes = $sum }
    }
    if ($cacheBytes -gt 0) {
        Log ('Cache   : ' + $CacheDir + '  (' + [math]::Round($cacheBytes / 1MB, 1) + ' MB)')
        foreach ($f in ($cacheFiles | Sort-Object Name)) {
            Log ('  ' + $f.Name + '  (' + [math]::Round($f.Length / 1MB, 1) + ' MB)')
        }
    } else {
        Log ('Cache   : ' + $CacheDir + '  (trống)')
    }

    $backups = @()
    if (Test-Path $BackupRoot) {
        $backups = @(Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'snapshot-*' } |
            Sort-Object Name -Descending)
    }
    if ($backups.Count) {
        $bkBytes = 0
        foreach ($b in $backups) {
            $sum = (Get-ChildItem $b.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($sum) { $bkBytes += $sum }
        }
        Log ('Backup  : ' + $backups.Count + ' bản trong ' + $BackupRoot + '  (' +
            [math]::Round($bkBytes / 1MB, 1) + ' MB, mới nhất ' + $backups[0].Name + ')') 'OK'
        foreach ($b in ($backups | Select-Object -First 5)) {
            $sum = (Get-ChildItem $b.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if (-not $sum) { $sum = 0 }
            Log ('  ' + $b.Name + '  (' + [math]::Round($sum / 1MB, 1) + ' MB)')
        }
        if ($backups.Count -gt 5) { Log ('  ... và ' + ($backups.Count - 5) + ' bản cũ hơn') }
    } else {
        Log ('Backup  : ' + $BackupRoot + '  (chưa có bản nào)') 'WARN'
    }

    if (Test-Path $LogRoot) {
        $logs = @(Get-ChildItem $LogRoot -File -Filter '*.log' -ErrorAction SilentlyContinue)
        Log ('Logs    : ' + $logs.Count + ' file trong ' + $LogRoot)
    }
}

function Test-WingetSystemPackage {
    $pkg = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue)
    return (@($pkg | Where-Object { $_.NonRemovable }).Count -gt 0)
}

function Select-BackupTag {
    $backups = @()
    if (Test-Path $BackupRoot) {
        $backups = @(Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'snapshot-*' } |
            Sort-Object Name -Descending)
    }
    if (-not $backups.Count) { return $null }

    Write-Host ''
    Write-Host 'Các bản backup có thể dùng:'
    $shown = @($backups | Select-Object -First 10)
    for ($i = 0; $i -lt $shown.Count; $i++) {
        $mark = if ($i -eq 0) { '  (mới nhất)' } else { '' }
        Write-Host ('  {0}. {1}{2}' -f ($i + 1), $shown[$i].Name, $mark)
    }
    if ($backups.Count -gt $shown.Count) { Write-Host ('  ... và ' + ($backups.Count - $shown.Count) + ' bản cũ hơn') }

    $ans = ''
    try { $ans = ([string](Read-Host ('Nhập số thứ tự hoặc tag backup, Enter = ' + $backups[0].Name))).Trim() } catch { }
    if (-not $ans) { return $backups[0].Name }
    if ($ans -match '^\d+$') {
        $idx = [int]$ans - 1
        if ($idx -ge 0 -and $idx -lt $shown.Count) { return $shown[$idx].Name }
        Write-Host 'Số thứ tự nằm ngoài danh sách.' -ForegroundColor Yellow
        return $null
    }
    $match = @($backups | Where-Object { $_.Name -eq $ans })
    if ($match.Count) { return $match[0].Name }
    Write-Host ('Không tìm thấy backup "' + $ans + '".') -ForegroundColor Yellow
    return $null
}

# The menu runs before elevation so the UAC prompt only appears after the user
# has chosen what to do. Any argument at all bypasses the menu.
if ($PSBoundParameters.Count -eq 0) {
    Write-Host ''
    Write-Host '=== WinGet: gỡ / khôi phục hệ thống ===' -ForegroundColor Cyan
    Show-CacheBackupSummary

    $protectedPkg = Test-WingetSystemPackage
    if ($protectedPkg) {
        Write-Host ''
        Write-Host 'LƯU Ý: WinGet trên máy này là thành phần hệ thống của Windows' -ForegroundColor Yellow
        Write-Host '(Microsoft.DesktopAppInstaller, NonRemovable=True).' -ForegroundColor Yellow
        Write-Host 'Windows từ chối gỡ gói này (lỗi 0x80070032 "part of Windows"),' -ForegroundColor Yellow
        Write-Host 'nên KHÔNG thể uninstall bằng AppX. Chỉ có thể khôi phục registry.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  1. Khôi phục registry, GIỮ WinGet'
        Write-Host '  0. Hủy'
        $choice = ''
        try { $choice = ([string](Read-Host 'Chọn [0]')).Trim() } catch { }
        if (-not $choice) { $choice = '0' }
        if ($choice -ne '1') { Write-Host 'Đã hủy, không làm gì.'; exit 0 }
        $RegistryScope = 'Changed'
        $KeepPackage = $true
    } else {
        Write-Host ''
        Write-Host 'Chọn thao tác:'
        Write-Host '  1. Gỡ WinGet, KHÔNG đụng registry'
        Write-Host '  2. Gỡ WinGet + khôi phục registry từ backup (mặc định)'
        Write-Host '  3. Chỉ khôi phục registry, GIỮ WinGet'
        Write-Host '  0. Hủy'
        $choice = ''
        try { $choice = ([string](Read-Host 'Chọn [0]')).Trim() } catch { }
        if (-not $choice) { $choice = '0' }
        switch ($choice) {
            '1' { $RegistryScope = 'None';  $KeepPackage = $false }
            '2' { $RegistryScope = 'Changed'; $KeepPackage = $false }
            '3' { $RegistryScope = 'Changed'; $KeepPackage = $true }
            default { Write-Host 'Đã hủy, không làm gì.'; exit 0 }
        }
    }

    if ($RegistryScope -ne 'None') {
        $hasBackup = $false
        if (Test-Path $BackupRoot) {
            $found = @(Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'snapshot-*' })
            $hasBackup = ($found.Count -gt 0)
        }
        if (-not $hasBackup) {
            if ($KeepPackage) {
                Write-Host 'Không có backup - không có gì để khôi phục. Hủy.' -ForegroundColor Yellow
                exit 0
            }
            Write-Host 'Không có backup - sẽ chỉ gỡ gói, không khôi phục được registry.' -ForegroundColor Yellow
            $RegistryScope = 'None'
        } else {
            $picked = Select-BackupTag
            if ($picked) { $BackupTag = $picked }
            else { Write-Host 'Không chọn được backup hợp lệ - hủy.' -ForegroundColor Yellow; exit 1 }
        }
    }
}

if ($KeepPackage -and $RegistryScope -eq 'None') {
    Write-Host '-KeepPackage cần khôi phục registry, không dùng được với -RegistryScope None.' -ForegroundColor Red
    exit 1
}
if ($KeepPackage -and $RemoveDependencies) {
    Write-Host 'Không thể vừa giữ gói vừa gỡ framework phụ thuộc.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Admin)) {
    if (-not $LogFile) { $LogFile = Join-Path $LogRoot ('uninstall_restore-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Write-Host ''
    Write-Host 'Cần quyền Administrator. Một hộp thoại UAC sẽ hiện ra - hãy bấm Yes.' -ForegroundColor Yellow
    Write-Host ''
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                   '-Elevated', '-RegistryScope', $RegistryScope, '-LogFile', "`"$LogFile`"")
    if ($DryRun)             { $childArgs += '-DryRun' }
    if ($Force)              { $childArgs += '-Force' }
    if ($RemoveDependencies) { $childArgs += '-RemoveDependencies' }
    if ($KeepPackage)        { $childArgs += '-KeepPackage' }
    if ($CleanCache)         { $childArgs += '-CleanCache' }
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
$cacheRemoved = $false

function Remove-CacheContents {
    if (-not (Test-Path $CacheDir)) { Log 'cache\ không tồn tại - không có gì để xoá.' 'OK'; return }
    $items = @(Get-ChildItem $CacheDir -Force -ErrorAction SilentlyContinue)
    if (-not $items.Count) { Log 'cache\ đã trống.' 'OK'; return }
    $sum = (Get-ChildItem $CacheDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    foreach ($item in $items) {
        try { Remove-Item $item.FullName -Recurse -Force }
        catch {
            Log ('  không xoá được ' + $item.FullName + ': ' + $_.Exception.Message) 'WARN'
            $script:ExitCode = 1
        }
    }
    Log ('Đã xoá cache\ (' + [math]::Round($sum / 1MB, 1) + ' MB). backup\ không bị đụng tới.') 'OK'
    $script:Changes += ('Xoá cache: ' + [math]::Round($sum / 1MB, 1) + ' MB')
    $script:cacheRemoved = $true
}

try {
    Log '===============================================================' 'STEP'
    Log ('  UNINSTALL / RESTORE WINGET  -  ' + $(if ($DryRun) { 'DRY RUN (không sửa gì)' } else { 'RUN THẬT' })) 'STEP'
    Log '===============================================================' 'STEP'
    Log ('Chế độ  : ' + $(if ($KeepPackage) { 'chỉ khôi phục registry, giữ WinGet' } elseif ($RegistryScope -eq 'None') { 'gỡ WinGet, không đụng registry' } else { 'gỡ WinGet + khôi phục registry' }))
    Write-Host ''
    Show-CacheBackupSummary

    # -------------------------------------------------- locate the backup --
    $backupDir = $null
    if ($BackupTag -and $BackupTag -like 'snapshot-*') {
        throw ('"' + $BackupTag + '" là snapshot của check-status.ps1, không phải backup registry.')
    }
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
    elseif ($KeepPackage) { throw 'Không có backup nào để khôi phục registry (-KeepPackage).' }
    else { Log 'Không tìm thấy backup nào. Vẫn gỡ được gói, nhưng sẽ không khôi phục được registry.' 'WARN' }

    $before = Get-WingetState -IncludeProvisioned
    Write-Host ''
    Write-Host (Format-StateReport $before)

    # Inbox (LTSC/IoT 24H2) DesktopAppInstaller is marked NonRemovable. Every
    # Remove-AppxPackage attempt fails with 0x80070032 "part of Windows", so
    # refuse up front instead of producing a half-finished uninstall.
    $pkgEntries = @(@($before.PerUser) + @($before.AllUsers) | Where-Object { $_.Name -eq $PkgName })
    $systemPackage = (@($pkgEntries | Where-Object { $_.NonRemovable }).Count -gt 0)
    if ($systemPackage) {
        Log 'Microsoft.DesktopAppInstaller là thành phần hệ thống của Windows (NonRemovable=True) - Windows không cho gỡ gói này (0x80070032).' 'WARN'
    }
    if ($systemPackage -and -not $KeepPackage) {
        Log 'KHÔNG THỂ uninstall WinGet trên máy này: gói nằm trong Windows và bị bảo vệ.' 'ERR'
        Log 'Không thực hiện thay đổi nào (kể cả registry).' 'ERR'
        Log 'Nếu chỉ muốn hoàn tác registry: .\uninstall_restore.ps1 -KeepPackage  (menu chọn 3).' 'ERR'
        if ($DryRun) {
            Log 'DRY-RUN: dừng tại đây - chạy thật sẽ từ chối và không sửa gì.' 'DRY'
            exit 0
        }
        Log '===============================================================' 'STEP'
        Log 'DỪNG: không có thay đổi nào được thực hiện.' 'ERR'
        Log '===============================================================' 'STEP'
        exit 1
    }

    $store = @(Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction SilentlyContinue)
    if ($store.Count) {
        Log 'Microsoft Store có mặt trên máy. WinGet có thể do Store quản lý - sau khi gỡ, Store có thể tự cài lại bản của nó.' 'WARN'
    }
    if (-not $backupDir -and -not $KeepPackage) {
        Log 'Không có backup do tool-pack tạo: máy này có thể đã có WinGet từ trước, không phải do tool-pack cài. Gỡ vẫn được nhưng không khôi phục được registry.' 'WARN'
    }
    if ($KeepPackage) {
        Log 'Chỉ khôi phục registry: gói WinGet được giữ. Nếu gói đang cần AllowAllTrustedApps, việc hoàn tác giá trị đó có thể ảnh hưởng lần cập nhật sau.' 'WARN'
    }

    # ------------------------------------------------------- removal list --
    $targets = @()
    $provTargets = @()
    $depTargets = @()
    if (-not $KeepPackage) {
        # -AllUsers returns one entry per account; removing by PackageFullName
        # once is enough, and a second attempt would fail with "not installed".
        $targets = @($before.AllUsers | Where-Object { $_.Name -eq $PkgName } | Sort-Object PackageFullName -Unique)
        if (-not $targets.Count) { $targets = @($before.PerUser | Where-Object { $_.Name -eq $PkgName } | Sort-Object PackageFullName -Unique) }
        $provTargets = @($before.Provisioned | Where-Object { $_.DisplayName -eq $PkgName } | Sort-Object DisplayName -Unique)
        if ($RemoveDependencies) {
            $depTargets = @(Get-AppxPackage | Where-Object { $_.Name -match '^Microsoft\.VCLibs|^Microsoft\.UI\.Xaml|^Microsoft\.WindowsAppRuntime' })
        }
    }

    Write-Host ''
    Log '--- Những thứ sẽ bị gỡ ---' 'STEP'
    if ($KeepPackage) {
        Log '  gói WinGet  : GIỮ LẠI (-KeepPackage)'
        if ($systemPackage) { Log '  lý do       : gói hệ thống NonRemovable=True - Windows không cho gỡ' 'WARN' }
        Log '  dependency  : GIỮ LẠI'
    } else {
        if ($provTargets.Count) { $provTargets | ForEach-Object { Log ('  provisioned : ' + $_.DisplayName + ' ' + $_.Version + ' ' + $_.Architecture) } }
        else { Log '  provisioned : không có' }
        if ($targets.Count) { $targets | ForEach-Object { Log ('  all-users   : ' + $_.PackageFullName) } }
        else { Log '  all-users   : không có' }
        if ($depTargets.Count) { $depTargets | ForEach-Object { Log ('  dependency  : ' + $_.Name + ' ' + $_.Version + ' ' + $_.Architecture) 'WARN' } }
        else { Log '  dependency  : GIỮ LẠI (VCLibs/UI.Xaml/WindowsAppRuntime đang được app khác dùng chung)' }
    }
    Log ('  registry    : scope=' + $RegistryScope)
    Log ('  cache       : ' + $(if ($CleanCache) { 'XOÁ sau khi xong' } else { 'giữ lại' }))
    Log '  backup      : KHÔNG BAO GIỜ bị xoá'

    # No packages to remove is NOT a reason to bail out: the install may have
    # failed partway through after already writing to the registry, and that
    # still needs undoing.
    $hasPackages = [bool]($provTargets.Count -or $targets.Count)
    if (-not $KeepPackage -and -not $hasPackages) { Log 'Không có gói DesktopAppInstaller nào để gỡ - chỉ hoàn tác registry nếu có.' 'WARN' }

    if ($hasPackages -and -not $DryRun -and -not $Force) {
        Write-Host ''
        $ans = Read-Host 'Gõ YES để tiến hành gỡ, bất kỳ phím nào khác để huỷ'
        if ($ans -ne 'YES') { Log 'Đã huỷ theo yêu cầu người dùng.' 'WARN'; exit 0 }
    }

    # ------------------------------------------------------- provisioning --
    Write-Host ''
    Log '--- [1/4] Gỡ provisioning ---' 'STEP'
    if ($KeepPackage) {
        Log 'KeepPackage - bỏ qua bước gỡ provisioning.' 'OK'
    } else {
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
    }

    # ------------------------------------------------------------- package --
    Write-Host ''
    Log '--- [2/4] Gỡ gói DesktopAppInstaller ---' 'STEP'
    if ($KeepPackage) {
        Log 'KeepPackage - giữ nguyên gói và framework.' 'OK'
    } else {
        foreach ($t in $targets) {
            if ($DryRun) { Log ('DRY-RUN: Remove-AppxPackage -AllUsers -Package ' + $t.PackageFullName) 'DRY'; continue }
            try {
                Remove-AppxPackage -AllUsers -Package $t.PackageFullName
                Log ('  đã gỡ: ' + $t.PackageFullName) 'OK'
                $Changes += ('Gỡ gói: ' + $t.PackageFullName)
            } catch {
                Log ('  KHÔNG gỡ được ' + $t.PackageFullName + ': ' + $_.Exception.Message) 'ERR'
                if ($_.Exception.Message -match 'part of Windows|0x80070032') {
                    Log '  Windows bảo vệ gói này (thành phần hệ thống) - không thể gỡ bằng AppX. Đây là giới hạn của Windows.' 'ERR'
                } else {
                    Log '  Nếu báo "being used by another process", hãy đóng mọi cửa sổ terminal đang chạy winget rồi thử lại.' 'WARN'
                }
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
        if ($KeepPackage) {
            if ($after.WingetVersion) { Log ('WinGet vẫn hoạt động sau khi khôi phục registry: ' + $after.WingetVersion) 'OK' }
            else {
                Log 'WinGet KHÔNG chạy được sau khi khôi phục registry. Xem trạng thái ở trên.' 'ERR'
                $script:ExitCode = 1
            }
            Log 'Gói được giữ lại theo -KeepPackage nên không tính là sót.' 'OK'
        } else {
            if ($after.PerUser.Count -or $after.AllUsers.Count -or $after.Provisioned.Count) {
                Log 'Vẫn còn dấu vết của DesktopAppInstaller. Xem danh sách ở trên.' 'WARN'
                $script:ExitCode = 1
            } else {
                Log 'Đã gỡ sạch Microsoft.DesktopAppInstaller.' 'OK'
            }
        }
        if ($backupDir -and (Test-Path (Join-Path $backupDir 'state-before.json'))) {
            Write-Utf8Bom (Join-Path $backupDir 'state-after-restore.json') ($after | ConvertTo-Json -Depth 4)
            Log ('Đã ghi state-after-restore.json vào ' + $backupDir + ' để bạn tự đối chiếu.') 'OK'
        }
    }

    # ------------------------------------------------------- cache cleanup --
    if ($DryRun) {
        if ($CleanCache) { Log 'DRY-RUN: would delete downloaded files in cache\ (backup\ stays untouched)' 'DRY' }
    } elseif ($script:ExitCode -eq 0) {
        $cacheSum = 0
        if (Test-Path $CacheDir) {
            $cacheSum = (Get-ChildItem $CacheDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if (-not $cacheSum) { $cacheSum = 0 }
        }
        if ($CleanCache) {
            Remove-CacheContents
        } elseif (-not $Force -and $cacheSum -gt 0 -and [Environment]::UserInteractive) {
            Write-Host ''
            $ans = Read-Host ('Xoá cache\ (' + [math]::Round($cacheSum / 1MB, 1) + ' MB)? backup\ không bị đụng tới. [y/N]')
            if ($ans -match '^[yY]') { Remove-CacheContents }
            else { Log 'Giữ nguyên cache\.' 'OK' }
        } else {
            Log 'Giữ nguyên cache\. Dùng -CleanCache để xoá.' 'OK'
        }
    }

    # ------------------------------------------------------- change log ----
    $scriptArgs = '-RegistryScope ' + $RegistryScope
    if ($KeepPackage)        { $scriptArgs += ' -KeepPackage' }
    if ($RemoveDependencies) { $scriptArgs += ' -RemoveDependencies' }
    if ($CleanCache)         { $scriptArgs += ' -CleanCache' }
    if ($DryRun)             { $scriptArgs += ' -DryRun' }

    $logTitle = if ($DryRun) { 'DRY RUN gỡ / khôi phục registry (không sửa gì)' }
                elseif ($KeepPackage) { 'Khôi phục registry (giữ WinGet)' }
                else { 'Gỡ WinGet / khôi phục hệ thống' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' — ' + $logTitle)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **Script**: `uninstall_restore.ps1 ' + $scriptArgs.Trim() + '`')
    [void]$sb.AppendLine('- **Người chạy**: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    [void]$sb.AppendLine('- **Backup đối chiếu**: `' + $(if ($backupDir) { Split-Path $backupDir -Leaf } else { 'không có' }) + '`')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Thay đổi trên hệ thống')
    if ($DryRun) { [void]$sb.AppendLine('_Dry run — không có thay đổi nào được thực hiện._') }
    elseif ($Changes.Count) { foreach ($c in $Changes) { [void]$sb.AppendLine('- ' + $c) } }
    else { [void]$sb.AppendLine('- Không có thay đổi.') }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Đã giữ lại (không gỡ)')
    if ($KeepPackage) {
        [void]$sb.AppendLine('- `Microsoft.DesktopAppInstaller` — giữ lại theo `-KeepPackage`' + $(if ($systemPackage) { ' (và vì là thành phần hệ thống `NonRemovable=True`, Windows không cho gỡ).' } else { '.' }))
        [void]$sb.AppendLine('- `Microsoft.VCLibs.140.00.UWPDesktop`, `Microsoft.UI.Xaml.2.8`, `Microsoft.WindowsAppRuntime.1.8` — gói framework dùng chung.')
    } elseif ($RemoveDependencies) {
        [void]$sb.AppendLine('- Không — `-RemoveDependencies` được bật nên VCLibs/UI.Xaml/WindowsAppRuntime cũng bị gỡ.')
    } else {
        [void]$sb.AppendLine('- `Microsoft.VCLibs.140.00.UWPDesktop`, `Microsoft.UI.Xaml.2.8`, `Microsoft.WindowsAppRuntime.1.8` — gói framework dùng chung, ứng dụng khác trên máy vẫn cần.')
    }
    if ($cacheRemoved) { [void]$sb.AppendLine('- `cache\` — đã xoá theo yêu cầu.') }
    else { [void]$sb.AppendLine('- File tải về trong `cache\` — giữ để đỡ tải lại nếu release không đổi (không cài offline được). Dùng `-CleanCache` nếu muốn dọn ổ đĩa.') }
    [void]$sb.AppendLine('- Toàn bộ thư mục `backup\` — KHÔNG BAO GIỜ bị xoá bởi script này.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Cài lại')
    if ($KeepPackage) {
        [void]$sb.AppendLine('_Không cần — gói WinGet vẫn được giữ._')
    } else {
        [void]$sb.AppendLine('```powershell')
        [void]$sb.AppendLine('.\install-winget.ps1          # dùng lại cache nếu release không đổi; vẫn cần mạng để gọi GitHub API')
        [void]$sb.AppendLine('```')
    }
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
