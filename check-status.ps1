#requires -Version 5.1
<#
.SYNOPSIS
    Read-only survey of this machine: OS edition, WinGet/App Installer presence,
    dependencies, sideloading policy, blocking group policy, network reachability.

.DESCRIPTION
    Changes nothing. Safe to run as many times as you like. Use it before
    install-winget.ps1 to understand the starting point, and after to confirm
    the result. Add -Snapshot to also write a state json under .\backup so two
    runs can be diffed.

    Without an elevated shell the all-users and provisioned views come back
    empty - that is a permission limit, not a real absence. The report says so
    explicitly. Add -Elevate to relaunch as admin for the full picture.

.EXAMPLE
    .\check-status.ps1

.EXAMPLE
    .\check-status.ps1 -Elevate -Snapshot
#>

[CmdletBinding()]
param(
    [switch]$Elevate,
    [switch]$Elevated,
    [switch]$Snapshot,
    [string]$LogFile
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $Root 'lib.ps1')

if ($Elevate -and -not (Test-Admin)) {
    if (-not $LogFile) { $LogFile = Join-Path (Join-Path $Root 'logs') ('check-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated', '-LogFile', "`"$LogFile`"")
    if ($Snapshot) { $childArgs += '-Snapshot' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $childArgs -Wait -PassThru
    if (Test-Path $LogFile) { Get-Content $LogFile -Encoding UTF8 | Write-Host }
    exit $p.ExitCode
}

Initialize-Log $LogFile
$BackupRoot = Join-Path $Root 'backup'
$issues = @()

function Section { param([string]$Title) Write-Host ''; Log ('=== ' + $Title + ' ===') 'STEP' }

# ------------------------------------------------------------------ OS ------
Section '1. Hệ điều hành'
$os = Get-OsInfo
Log ('ProductName    : ' + $os.ProductName)
Log ('EditionID      : ' + $os.EditionID)
Log ('DisplayVersion : ' + $os.DisplayVersion)
Log ('Build          : ' + $os.Build)
Log ('Architecture   : ' + $os.Arch)
Log ('Process arch   : ' + $env:PROCESSOR_ARCHITECTURE)
if ($os.TargetArch) {
    Log ('Kiến trúc đích : ' + $os.TargetArchLabel + '  ->  install-winget.ps1 sẽ lấy phụ thuộc bản `' + $os.TargetArch + '`') 'OK'
} else {
    Log ('Kiến trúc đích : ' + $os.TargetArchLabel) 'ERR'
    $issues += 'Không nhận diện được kiến trúc CPU. WinGet chỉ phát hành cho x64, x86 và arm64 nên install-winget.ps1 sẽ từ chối chạy.'
}
if ($os.EditionID -match 'IoTEnterpriseS|EnterpriseS') {
    Log 'Đây là bản LTSC/IoT: KHÔNG có Microsoft Store nên WinGet phải cài bằng sideload. Đúng trường hợp script này xử lý.' 'OK'
} else {
    $issues += 'EditionID không phải LTSC/IoT - cân nhắc cài WinGet qua Microsoft Store.'
}

# ------------------------------------------------------------- permissions --
Section '2. Quyền'
Log ('User hiện tại  : ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Log ('Đã elevate     : ' + (Test-Admin))
if (-not (Test-Admin)) {
    Log 'Chưa elevate: mục all-users và provisioned bên dưới sẽ trống. Chạy .\check-status.ps1 -Elevate để xem đầy đủ.' 'WARN'
    $issues += 'Chạy với quyền admin để có báo cáo đầy đủ.'
}
$admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue)
Log ('Thành viên nhóm Administrators: ' + (($admins | ForEach-Object { $_.Name }) -join ', '))
$uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
Log ('EnableLUA=' + (Get-PropSafe $uac 'EnableLUA' '?') + '  ConsentPromptBehaviorAdmin=' + (Get-PropSafe $uac 'ConsentPromptBehaviorAdmin' '?'))

# -------------------------------------------------------- winget state ------
Section '3. WinGet / App Installer'
$state = Get-WingetState -IncludeProvisioned
Write-Host (Format-StateReport $state)

if ($state.WingetVersion) {
    Log ('Kết luận: winget ĐANG HOẠT ĐỘNG, bản ' + $state.WingetVersion) 'OK'
} else {
    Log 'Kết luận: winget CHƯA dùng được.' 'WARN'
    $issues += 'WinGet chưa hoạt động - chạy .\install-winget.ps1'
    if (-not $state.PerUser.Count) { $issues += 'Thiếu Microsoft.DesktopAppInstaller cho user hiện tại.' }
    if ((Test-Admin) -and -not $state.Provisioned.Count) { $issues += 'Chưa provision all-users: user tạo mới sau này sẽ không có WinGet.' }
}

# ---------------------------------------------------------- dependencies ----
Section ('4. Phụ thuộc bắt buộc (' + $os.TargetArch + ')')
# Quick reference only. install-winget.ps1 reads the release's own manifest, so
# this list must not include packages (such as UI.Xaml) that the current WinGet
# no longer requires - otherwise a missing optional package looks like a blocker.
$requiredDeps = @(
    'Microsoft.VCLibs.140.00',
    'Microsoft.VCLibs.140.00.UWPDesktop',
    'Microsoft.WindowsAppRuntime.1.8'
)
if (-not $os.TargetArchEnum) {
    Log 'Bỏ qua mục này vì không nhận diện được kiến trúc CPU.' 'WARN'
} else {
    foreach ($dep in $requiredDeps) {
        # So khớp đúng kiến trúc hệ thống: trên ARM64 thì gói x64 không thay thế được.
        $found = @($state.Dependencies | Where-Object { $_.Name -eq $dep -and $_.Architecture -eq $os.TargetArchEnum })
        if ($found.Count) {
            Log ($dep.PadRight(40) + ' ' + $os.TargetArch.PadRight(6) + ': ' + $found[0].Version) 'OK'
        } else {
            Log ($dep.PadRight(40) + ' ' + $os.TargetArch.PadRight(6) + ': THIẾU') 'WARN'
            $issues += ('Thiếu ' + $dep + ' ' + $os.TargetArch + ' - install-winget.ps1 sẽ tự cài từ Dependencies.zip.')
        }
    }
}
Log 'Danh sách trên chỉ để tham khảo; install-winget.ps1 đọc manifest của release để biết gói nào thực sự cần.'

# -------------------------------------------------------------- sideload ----
Section '5. Chính sách sideload'
if ($state.SideloadPolicy) {
    Log ('AllowAllTrustedApps               = ' + $state.SideloadPolicy.AllowAllTrustedApps)
    Log ('AllowDevelopmentWithoutDevLicense = ' + $state.SideloadPolicy.AllowDevelopmentWithoutDevLicense)
    if ($state.SideloadPolicy.AllowAllTrustedApps -ne 1) {
        Log 'Chưa bật tường minh. Gói do Microsoft ký thường vẫn cài được; nếu không, install-winget.ps1 sẽ tự bật và ghi log.' 'WARN'
    }
} else {
    Log 'Khoá AppModelUnlock không tồn tại.' 'WARN'
}

# ------------------------------------------------------- blocking policy ----
Section '6. Group policy có thể chặn'
$polKeys = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
)
$policyBlocker = $false
foreach ($k in $polKeys) {
    if (Test-Path $k) {
        $props = @((Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
        if ($props.Count) {
            Log ('KEY ' + $k)
            foreach ($p in $props) {
                Log ('     ' + $p.Name + ' = ' + $p.Value)
                if ($p.Name -in @('RemoveWindowsStore', 'DisableStoreApps', 'TurnOffWindowsStore', 'DisableWindowsConsumerFeatures') -and $p.Value) {
                    $policyBlocker = $true
                    $issues += ('Policy ' + $k + '\' + $p.Name + ' = ' + $p.Value + ' có thể gây cản trở.')
                }
            }
        } else { Log ('KEY ' + $k + ' : tồn tại nhưng rỗng') }
    } else { Log ('KEY ' + $k + ' : không tồn tại') }
}
if (-not $policyBlocker) { Log 'Không thấy policy nào chặn cài App Installer.' 'OK' }

# -------------------------------------------------------------- network ----
Section '7. Kết nối tới nguồn tải chính chủ'
$urls = @(
    @{ Name = 'GitHub API (lấy release mới nhất)'; Url = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'; Head = $true },
    @{ Name = 'GitHub download (tải msixbundle)'; Url = 'https://github.com'; Head = $true },
    @{ Name = 'aka.ms (link rút gọn Microsoft)'; Url = 'https://aka.ms'; Head = $true }
)
foreach ($u in $urls) {
    try {
        $r = Invoke-WebRequest -Uri $u.Url -Method Head -TimeoutSec 15 -UseBasicParsing
        Log ('OK  ' + $u.Name + ' -> HTTP ' + $r.StatusCode)
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code) { Log ('OK  ' + $u.Name + ' -> HTTP ' + $code + ' (máy chủ phản hồi, dùng được)') }
        else { Log ('ERR ' + $u.Name + ' -> ' + $_.Exception.Message) 'ERR'; $issues += ('Không kết nối được ' + $u.Url) }
    }
}
$dl = Join-Path $Root 'cache'
if (Test-Path $dl) {
    $cached = @(Get-ChildItem $dl -File -ErrorAction SilentlyContinue)
    if ($cached.Count) {
        Log ('Đã có sẵn trong cache\: ' + (($cached | ForEach-Object { $_.Name + ' (' + [math]::Round($_.Length / 1MB, 1) + ' MB)' }) -join ', '))
    }
}

# --------------------------------------------------------------- space -----
Section '8. Dung lượng trống'
Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'") | ForEach-Object {
    $free = [math]::Round($_.FreeSpace / 1GB, 2)
    Log ($_.DeviceID + ' trống ' + $free + ' GB / tổng ' + [math]::Round($_.Size / 1GB, 2) + ' GB')
    if ($free -lt 2) { $issues += ('Ổ ' + $_.DeviceID + ' chỉ còn ' + $free + ' GB - cần ít nhất ~2 GB để cài WinGet.') }
}

# ------------------------------------------------------------- backups -----
Section '9. Backup hiện có'
if (Test-Path $BackupRoot) {
    $bks = @(Get-ChildItem $BackupRoot -Directory | Sort-Object Name -Descending)
    if ($bks.Count) { $bks | Select-Object -First 10 | ForEach-Object { Log ('  ' + $_.Name + '  (' + @(Get-ChildItem $_.FullName -File).Count + ' file)') } }
    else { Log '  (thư mục backup rỗng)' 'WARN' }
} else { Log '  Chưa có thư mục backup - sẽ được tạo khi chạy install-winget.ps1' 'WARN' }

if ($Snapshot) {
    $snapDir = Join-Path $BackupRoot ('snapshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    Write-Utf8Bom (Join-Path $snapDir 'state.json') ($state | ConvertTo-Json -Depth 4)
    Log ('Đã ghi snapshot: ' + (Join-Path $snapDir 'state.json')) 'OK'
}

# ------------------------------------------------------------ summary ------
Write-Host ''
Log '===============================================================' 'STEP'
Log '  TÓM TẮT' 'STEP'
Log '===============================================================' 'STEP'
if ($issues.Count) {
    Log ('Phát hiện ' + $issues.Count + ' vấn đề cần lưu ý:') 'WARN'
    $i = 0
    foreach ($s in ($issues | Select-Object -Unique)) { $i++; Log ('  ' + $i + '. ' + $s) 'WARN' }
    Write-Host ''
    Log 'Đề xuất: chạy  .\install-winget.ps1 -DryRun  để xem trước kế hoạch, rồi chạy  .\install-winget.ps1  để cài.'
} else {
    Log 'Không phát hiện vấn đề gì. WinGet đã sẵn sàng dùng.' 'OK'
    Log 'Thử:  winget search <tên ứng dụng>'
}
