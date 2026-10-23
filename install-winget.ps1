#requires -Version 5.1
<#
.SYNOPSIS
    Installs WinGet (Microsoft.DesktopAppInstaller) on Windows IoT Enterprise LTSC,
    which ships without the Microsoft Store and therefore without WinGet.

.DESCRIPTION
    Follows the official Microsoft Learn procedure:
      "Using WinGet to Install Apps on Windows IoT Enterprise"
      https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/deployment/install-winget-windows-iot

    Order of operations, all logged and all backed up first:
      1. Preflight read-only survey of the machine.
      2. Backup: registry export + full appx/provisioned snapshot + PATH.
      3. Resolve the latest stable release from microsoft/winget-cli via the GitHub API.
      4. Download msixbundle + License1.xml into .\cache (reused only while the
         latest release is unchanged; this is NOT an offline install mode).
      5. Verify the bundle against the SHA256 that Microsoft publishes next to it,
         then verify its Authenticode signature belongs to Microsoft.
      6. Verify the framework dependencies named in the release's own manifest; fetch Dependencies.zip only if one is missing.
      7. Add-AppxPackage for the current (admin) account.
      8. Add-AppxProvisionedPackage -Online so every future user profile gets WinGet.
      9. Verify `winget --version` actually runs.
     10. Record everything into thay_doi_sys.md.

    Deviation from the doc, deliberately: the doc tells you to pull VCLibs from
    aka.ms and UI.Xaml from NuGet (renaming .nupkg to .zip by hand). This script
    uses DesktopAppInstaller_Dependencies.zip from the SAME GitHub release instead,
    because it is an official Microsoft asset whose versions are guaranteed to
    match the bundle being installed. It is only downloaded if a dependency is
    actually missing.

.PARAMETER DryRun
    Report exactly what would change without changing anything. No system writes,
    no large downloads.

.PARAMETER Scope
    AllUsers (default) = per-user install + provisioning, per the Microsoft doc.
    CurrentUser        = Add-AppxPackage only, no DISM provisioning.

.PARAMETER SkipHashCheck
    Install even if the published SHA256 cannot be verified. Use only if
    Microsoft changes the release asset naming and the lookup breaks. The
    Authenticode signature is still required and must belong to Microsoft.

.EXAMPLE
    .\install-winget.ps1 -DryRun

.EXAMPLE
    .\install-winget.ps1
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Elevated,
    [ValidateSet('AllUsers', 'CurrentUser')]
    [string]$Scope = 'AllUsers',
    [string]$LogFile,
    [switch]$SkipHashCheck
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $Root 'lib.ps1')

$CacheDir  = Join-Path $Root 'cache'
$BackupRoot= Join-Path $Root 'backup'
$LogRoot   = Join-Path $Root 'logs'
$ChangeLog = Join-Path $Root 'thay_doi_sys.md'
$PkgName   = 'Microsoft.DesktopAppInstaller'

# --------------------------------------------------------------------------
# Self-elevation. Add-AppxProvisionedPackage and Get-AppxPackage -AllUsers both
# need a real admin token; the interactive shell on this box does not have one.
# The elevated child writes to a log file that the parent then replays, so the
# caller still sees the full output.
# --------------------------------------------------------------------------
if (-not (Test-Admin)) {
    if (-not $LogFile) { $LogFile = Join-Path $LogRoot ('install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Write-Host ''
    Write-Host 'Cần quyền Administrator. Một hộp thoại UAC sẽ hiện ra - hãy bấm Yes.' -ForegroundColor Yellow
    Write-Host ''
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                   '-Elevated', '-Scope', $Scope, '-LogFile', "`"$LogFile`"")
    if ($DryRun)        { $childArgs += '-DryRun' }
    if ($SkipHashCheck) { $childArgs += '-SkipHashCheck' }
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
$backupDir = $null   # referenced by the catch block; must exist even if we fail before step 1
$Changes = @()       # human-readable list of what actually got modified
$UndoActions = @()   # precise revert instructions, persisted to backup\undo.json

try {
    # ------------------------------------------------------------------ 0
    Log '===============================================================' 'STEP'
    Log ('  INSTALL WINGET  -  ' + $(if ($DryRun) { 'DRY RUN (không sửa gì)' } else { 'RUN THẬT' })) 'STEP'
    Log '===============================================================' 'STEP'

    $os = Get-OsInfo
    Log ("OS      : {0} {1} build {2} ({3})" -f $os.ProductName, $os.DisplayVersion, $os.Build, $os.Arch)
    Log ("Edition : {0}" -f $os.EditionID)
    Log ("User    : {0}  (admin={1})" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, (Test-Admin))
    Log ("Scope   : {0}" -f $Scope)
    Log ("Thư mục : {0}" -f $Root)

    # Fail here rather than halfway through: picking the wrong dependency
    # architecture produces a confusing 0x80073CF3 later on.
    if (-not $os.TargetArch) {
        Log ('Không xác định được kiến trúc CPU: ' + $os.TargetArchLabel) 'ERR'
        Log 'WinGet chỉ phát hành cho x64, x86 và arm64.' 'ERR'
        throw ('Kiến trúc không hỗ trợ: ' + $os.TargetArchLabel)
    }
    Log ("Arch    : {0}  ->  phụ thuộc sẽ lấy bản {1}" -f $os.TargetArchLabel, $os.TargetArch)

    if ($os.EditionID -notmatch 'IoT|EnterpriseS|Enterprise') {
        Log ('EditionID "' + $os.EditionID + '" không phải LTSC/IoT. Script vẫn chạy được nhưng hãy cân nhắc dùng Microsoft Store thay thế.') 'WARN'
    }

    $before = Get-WingetState -IncludeProvisioned
    Write-Host ''
    Write-Host (Format-StateReport $before)

    if ($before.PerUser.Count -and $before.Provisioned.Count -and $before.WingetVersion) {
        Log ("WinGet đã cài sẵn và đang chạy ({0}). Không cần làm gì." -f $before.WingetVersion) 'OK'
        Log 'Muốn nâng cấp bản mới hơn: chạy .\restore-winget.ps1 rồi chạy lại script này.'
        exit 0
    }

    # ------------------------------------------------------------------ 1
    Write-Host ''
    Log '--- [1/8] BACKUP trạng thái hệ thống trước khi sửa ---' 'STEP'
    $backupDir = New-SystemBackup -BackupRoot $BackupRoot -Tag $RunTag -DryRun:$DryRun
    if (-not $DryRun) { $Changes += ('Tạo backup: ' + $backupDir) }

    # ------------------------------------------------------------------ 2
    Write-Host ''
    Log '--- [2/8] Lấy thông tin release mới nhất từ microsoft/winget-cli ---' 'STEP'
    try {
        $rel = Get-LatestWingetRelease
    } catch {
        Log ('Không gọi được GitHub API: ' + $_.Exception.Message) 'ERR'
        Log 'Thử lại sau, hoặc tải tay rồi dùng -SkipHashCheck với file trong .\cache' 'WARN'
        throw
    }
    if (-not $rel.Bundle)  { throw 'Release mới nhất không có asset .msixbundle - Microsoft có thể đã đổi cách đóng gói.' }
    if (-not $rel.License -and $Scope -eq 'AllUsers') {
        Log 'Không tìm thấy License1.xml trong release. Bước Add-AppxProvisionedPackage cần file này.' 'ERR'
        throw 'Thiếu License1.xml - không thể provision all-users.'
    }
    Log ("Release : {0}  (published {1})" -f $rel.Tag, $rel.Published)
    Log ("Bundle  : {0}  ({1} MB)" -f $rel.Bundle.name, [math]::Round($rel.Bundle.size / 1MB, 1))
    Log ("License : {0}" -f $(if ($rel.License) { $rel.License.name } else { 'n/a' }))
    Log ("Hash    : {0}" -f $(if ($rel.HashAsset) { $rel.HashAsset.name } else { 'NOT PUBLISHED' }))

    # ------------------------------------------------------------------ 3
    Write-Host ''
    Log '--- [3/8] Tải file về cache ---' 'STEP'
    if (-not (Test-Path $CacheDir)) {
        if ($DryRun) { Log "DRY-RUN: would create $CacheDir" 'DRY' } else { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    }
    $bundlePath  = Join-Path $CacheDir $rel.Bundle.name
    $licensePath = if ($rel.License) { Join-Path $CacheDir $rel.License.name } else { $null }

    if ($DryRun) {
        if ((Test-Path $bundlePath)) { Log ('DRY-RUN: bundle đã có sẵn trong cache, sẽ dùng lại: ' + $bundlePath) 'DRY' }
        else { Invoke-Download -Url $rel.Bundle.browser_download_url -OutFile $bundlePath -DryRun }
        if ($licensePath) { Invoke-Download -Url $rel.License.browser_download_url -OutFile $licensePath -DryRun }
    } else {
        # Reusing a previous download is safe because the SHA256 check in the
        # next step is what actually guarantees the file is correct.
        if ((Test-Path $bundlePath) -and (Get-Item $bundlePath).Length -eq $rel.Bundle.size) {
            Log ('  bundle: dùng lại file sẵn có trong cache (' + [math]::Round($rel.Bundle.size / 1MB, 1) + ' MB)') 'OK'
        } else {
            Log ('Đang tải ' + [math]::Round($rel.Bundle.size / 1MB, 1) + ' MB, có thể mất vài phút...')
            Invoke-Download -Url $rel.Bundle.browser_download_url -OutFile $bundlePath
            Log '  bundle: xong' 'OK'
        }
        if ($licensePath) {
            if (Test-Path $licensePath) { Log '  license: dùng lại file sẵn có trong cache' 'OK' }
            else {
                Invoke-Download -Url $rel.License.browser_download_url -OutFile $licensePath
                Log '  license: xong' 'OK'
            }
        }
    }

    # ------------------------------------------------------------------ 4
    Write-Host ''
    Log '--- [4/8] Kiểm tra toàn vẹn file (SHA256) ---' 'STEP'
    $ProgressPreference = 'SilentlyContinue'
    $expected = $null
    $hashTmp = if ($rel.HashAsset) { Join-Path $CacheDir $rel.HashAsset.name } else { $null }

    if ($rel.HashAsset) {
        if ($DryRun) {
            # Only ~65 bytes, so fetch it even in a dry run: you get to see the
            # exact value the real run will compare the bundle against.
            # DownloadString, not Invoke-WebRequest: IWR hands back a byte[] for
            # this asset, which turns the hash into a list of decimal codes.
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent', 'winget-installer-script')
                try { $raw = $wc.DownloadString($rel.HashAsset.browser_download_url) } finally { $wc.Dispose() }
                $expected = ($raw -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
            } catch { Log ('Không đọc được file hash: ' + $_.Exception.Message) 'WARN' }
        } else {
            try {
                Invoke-Download -Url $rel.HashAsset.browser_download_url -OutFile $hashTmp
                $expected = ((Get-Content $hashTmp -Raw) -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
            } catch { Log ('Không tải được file hash: ' + $_.Exception.Message) 'WARN' }
        }
    }

    # A SHA256 hex digest is exactly 64 characters. Anything else means the
    # asset is not what we think it is, so refuse to treat it as a valid hash.
    if ($expected -and $expected.Length -ne 64) {
        Log ('File hash không phải SHA256 hợp lệ (đọc được ' + $expected.Length + ' ký tự hex) - bỏ qua giá trị này.') 'WARN'
        $expected = $null
    }

    if (-not $expected) {
        if ($SkipHashCheck) {
            Log 'Không lấy được SHA256 chính chủ và -SkipHashCheck đang bật. Bỏ qua kiểm tra toàn vẹn.' 'WARN'
        } else {
            throw 'Không lấy được SHA256 chính chủ để đối chiếu. Chạy lại với -SkipHashCheck nếu bạn chấp nhận rủi ro.'
        }
    } elseif ($DryRun) {
        Log ('DRY-RUN: SHA256 chính chủ công bố = ' + $expected) 'DRY'
        Log 'DRY-RUN: would compare it to the downloaded bundle and ABORT + delete the file on mismatch' 'DRY'
    } else {
        $actual = Get-FileSha256 -Path $bundlePath
        if ($actual -eq $expected) {
            Log ('SHA256 KHỚP: ' + $actual) 'OK'
        } else {
            Log ('SHA256 LỆCH! mong đợi ' + $expected + ' nhưng nhận được ' + $actual) 'ERR'
            if (-not $SkipHashCheck) {
                Remove-Item $bundlePath -Force
                throw 'File tải về không khớp hash chính chủ - đã xoá, không cài đặt.'
            }
            Log '-SkipHashCheck được bật nên vẫn tiếp tục với file lệch hash, nhưng điều này KHÔNG an toàn.' 'WARN'
        }
    }

    # ------------------------------------------------------------------ 4b
    Write-Host ''
    Log '--- [4b] Kiểm tra chữ ký Authenticode ---' 'STEP'
    if ($DryRun -and -not (Test-Path $bundlePath)) {
        Log 'DRY-RUN: bundle chưa có trong cache - sẽ kiểm chữ ký Microsoft sau khi tải.' 'DRY'
    } else {
        Assert-MicrosoftSigned -Path $bundlePath
    }

    # ------------------------------------------------------------------ 5
    Write-Host ''
    Log '--- [5/8] Kiểm tra phụ thuộc theo manifest chính chủ ---' 'STEP'
    # The Microsoft Learn article hardcodes VCLibs + UI.Xaml, which matched WinGet
    # 1.4 but not current builds (1.29 needs Microsoft.WindowsAppRuntime.1.8 and
    # no longer lists UI.Xaml). Each release publishes an authoritative manifest,
    # so read that instead of hardcoding package names that will go stale.
    $depList = $null
    $manifestUrl = ('https://github.com/microsoft/winget-cli/releases/download/{0}/DesktopAppInstaller_Dependencies.json' -f $rel.Tag)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'winget-installer-script')
        try {
            # Assign the parsed json to a variable before reading from it; doing
            # both inside one pipeline expression nests arrays unpredictably.
            $manifestText = $wc.DownloadString($manifestUrl)
            $manifestObj = $manifestText | ConvertFrom-Json
            $depList = Get-PropSafe $manifestObj 'Dependencies'
        } finally { $wc.Dispose() }
        Log ('Manifest chính chủ: ' + $manifestUrl)
    } catch { Log ('Không đọc được manifest phụ thuộc: ' + $_.Exception.Message) 'WARN' }

    if (-not $depList) {
        Log ('Không có manifest - rơi về kiểm tra tối thiểu VCLibs.140.00.UWPDesktop ' + $os.TargetArch + '.') 'WARN'
        $depList = @([pscustomobject]@{ Name = 'Microsoft.VCLibs.140.00.UWPDesktop'; Version = '14.0.0.0' })
    }

    $missing = @()
    foreach ($d in @($depList)) {
        # Architecture must match the OS, not just "64-bit": on ARM64 an x64
        # framework package does not satisfy the arm64 WinGet build.
        $candidates = @(Get-AppxPackage -Name $d.Name | Where-Object { $_.Architecture -in @($os.TargetArchEnum, 'Neutral') })
        $ok = $false
        foreach ($c in $candidates) {
            try { if ([version]$c.Version -ge [version]$d.Version) { $ok = $true; break } } catch { }
        }
        if ($ok) {
            Log ('  ĐỦ   : ' + $d.Name + ' (yêu cầu >= ' + $d.Version + ')') 'OK'
        } else {
            $haveTxt = if ($candidates.Count) { ($candidates | ForEach-Object { $_.Version + ' ' + $_.Architecture }) -join ', ' } else { 'chưa cài' }
            Log ('  THIẾU: ' + $d.Name + ' (yêu cầu >= ' + $d.Version + '; hiện có: ' + $haveTxt + ')') 'WARN'
            $missing += $d.Name
        }
    }

    if (-not $missing.Count) {
        Log 'Mọi phụ thuộc đã đủ - không cần tải Dependencies.zip (~93 MB).' 'OK'
    } else {
        $depZip = Join-Path $CacheDir 'DesktopAppInstaller_Dependencies.zip'
        $depUrl = ('https://github.com/microsoft/winget-cli/releases/download/{0}/DesktopAppInstaller_Dependencies.zip' -f $rel.Tag)
        if ($DryRun) {
            Log ('DRY-RUN: would fetch DesktopAppInstaller_Dependencies.zip and Add-AppxPackage the ' + $os.TargetArch + ' build of: ' + ($missing -join ', ')) 'DRY'
            if (Test-Path $depZip) { Log ('DRY-RUN: zip đã có sẵn trong cache nên sẽ không tải lại: ' + $depZip) 'DRY' }
            Log 'DRY-RUN: would verify the zip against the SHA256 in DesktopAppInstaller_Dependencies.txt, then verify each .appx is signed by Microsoft' 'DRY'
        } else {
            if ((Test-Path $depZip) -and (Get-Item $depZip).Length -gt 0) {
                Log ('  dùng lại Dependencies.zip sẵn có trong cache (' + [math]::Round((Get-Item $depZip).Length / 1MB, 1) + ' MB)') 'OK'
            } else {
                Log '  đang tải DesktopAppInstaller_Dependencies.zip (~93 MB)...'
                Invoke-Download -Url $depUrl -OutFile $depZip
                Log '  tải xong' 'OK'
            }

            # The .appx files inside this zip get Add-AppxPackage'd straight into
            # the system, so the zip needs the same integrity check as the bundle.
            # Microsoft publishes DesktopAppInstaller_Dependencies.txt beside it.
            # Checked on cache reuse too: a tampered or truncated cached zip must
            # not be trusted just because it is already on disk.
            $depHashUrl = ($depUrl -replace '\.zip$', '.txt')
            $depExpected = $null
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent', 'winget-installer-script')
                try { $raw = $wc.DownloadString($depHashUrl) } finally { $wc.Dispose() }
                $depExpected = ($raw -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
            } catch { Log ('  không đọc được hash chính chủ của Dependencies.zip: ' + $_.Exception.Message) 'WARN' }
            if ($depExpected -and $depExpected.Length -ne 64) { $depExpected = $null }

            if (-not $depExpected) {
                if ($SkipHashCheck) {
                    Log '  không đối chiếu được SHA256 của Dependencies.zip và -SkipHashCheck đang bật.' 'WARN'
                } else {
                    throw 'Không lấy được SHA256 chính chủ của Dependencies.zip. Chạy lại với -SkipHashCheck nếu bạn chấp nhận rủi ro.'
                }
            } else {
                $depActual = Get-FileSha256 -Path $depZip
                if ($depActual -eq $depExpected) {
                    Log ('  SHA256 Dependencies.zip KHỚP: ' + $depActual) 'OK'
                } else {
                    Log ('  SHA256 Dependencies.zip LỆCH! mong đợi ' + $depExpected + ' nhưng nhận được ' + $depActual) 'ERR'
                    if (-not $SkipHashCheck) {
                        Remove-Item $depZip -Force
                        throw 'Dependencies.zip không khớp hash chính chủ - đã xoá, không cài phụ thuộc.'
                    }
                    Log '  -SkipHashCheck được bật nên vẫn tiếp tục với file lệch hash, nhưng điều này KHÔNG an toàn.' 'WARN'
                }
            }

            $depDir = Join-Path $CacheDir 'deps'
            if (Test-Path $depDir) { Remove-Item $depDir -Recurse -Force }
            Expand-Archive -Path $depZip -DestinationPath $depDir -Force

            $archFolder = Join-Path $depDir $os.TargetArch
            foreach ($name in ($missing | Select-Object -Unique)) {
                $f = @(Get-ChildItem $archFolder -Filter ($name + '_*_' + $os.TargetArch + '.appx') -ErrorAction SilentlyContinue | Select-Object -First 1)
                if (-not $f.Count) {
                    $f = @(Get-ChildItem $depDir -Recurse -Filter ($name + '_*.appx') -ErrorAction SilentlyContinue |
                           Where-Object { $_.FullName -like ('*\' + $os.TargetArch + '\*') } | Select-Object -First 1)
                }
                if (-not $f.Count) {
                    # List what the zip does contain: if Microsoft ever drops an
                    # architecture, that is the whole diagnosis in one line.
                    $have = @(Get-ChildItem $depDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                    throw ('Không tìm thấy appx ' + $os.TargetArch + ' cho ' + $name + ' trong Dependencies.zip. Zip chỉ có các thư mục: ' + ($have -join ', ') + '.')
                }
                Log ('  Add-AppxPackage ' + $f[0].Name)
                Assert-MicrosoftSigned -Path $f[0].FullName
                Add-AppxPackage -Path $f[0].FullName
                $Changes += ('Cài phụ thuộc: ' + $f[0].Name)
                Log ('  đã cài ' + $name) 'OK'
            }
        }
    }

    # ------------------------------------------------------------------ 6
    Write-Host ''
    Log '--- [6/8] Cài Microsoft.DesktopAppInstaller cho user hiện tại ---' 'STEP'
    $unlockKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'

    if ($before.PerUser.Count) {
        Log ('Đã có sẵn bản ' + ($before.PerUser[0].Version) + ' cho user này - bỏ qua Add-AppxPackage.') 'OK'
    } elseif ($DryRun) {
        Log ("DRY-RUN: Add-AppxPackage -Path `"{0}`"" -f $bundlePath) 'DRY'
    } else {
        $installed = $false
        try {
            Add-AppxPackage -Path $bundlePath
            $installed = $true
        } catch {
            $msg = $_.Exception.Message
            Log ('Add-AppxPackage thất bại lần 1: ' + $msg) 'WARN'

            if ($msg -match '0x80073CF3|depends on a framework|could not be found') {
                # Dependency validation, NOT a sideloading problem. Flipping
                # AllowAllTrustedApps here would loosen system security policy
                # for zero benefit, so fail loudly instead of "fixing" it.
                Log 'Đây là lỗi THIẾU FRAMEWORK PHỤ THUỘC (0x80073CF3), KHÔNG phải lỗi sideload.' 'ERR'
                Log 'Script sẽ không tự bật AllowAllTrustedApps vì không liên quan tới nguyên nhân này.' 'ERR'
                Log 'Xem lại bước 5 - manifest phụ thuộc của release này có thể đã thay đổi.' 'ERR'
                throw 'Thiếu framework phụ thuộc. Tên gói cần cài nằm trong thông báo lỗi ở trên.'
            }

            # 0x80073CFF / 0x800B0100 = deployment blocked because sideloading
            # of trusted apps is not enabled on this image.
            if ($msg -match '0x80073CFF|0x800B0100|0x800B0109|AllowAllTrustedApps|sideload') {
                Log 'Nguyên nhân đúng là sideloading chưa bật. Bật AllowAllTrustedApps rồi thử lại.' 'WARN'
                $keyCreated = -not (Test-Path $unlockKey)
                if ($keyCreated) { New-Item -Path $unlockKey -Force | Out-Null }
                $prev = Get-PropSafe (Get-ItemProperty $unlockKey -ErrorAction SilentlyContinue) 'AllowAllTrustedApps'
                Set-ItemProperty -Path $unlockKey -Name 'AllowAllTrustedApps' -Value 1 -Type DWord
                $Changes += ('Registry: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowAllTrustedApps = 1 (giá trị cũ: ' + $(if ($null -eq $prev) { 'chưa tồn tại' } else { $prev }) + ')')
                $UndoActions += [pscustomobject]@{
                    Kind           = 'RegValue'
                    Path           = $unlockKey
                    Name           = 'AllowAllTrustedApps'
                    ExistedBefore  = ($null -ne $prev)
                    OldValue       = $prev
                    KeyCreatedByUs = $keyCreated
                    Reason         = 'Bat sideload de cai Microsoft.DesktopAppInstaller'
                }
                # Persist immediately so the undo record survives a crash below.
                Save-UndoPlan -BackupDir $backupDir -Actions $UndoActions
                Add-AppxPackage -Path $bundlePath
                $installed = $true
            } else { throw }
        }
        if ($installed) { Log 'Add-AppxPackage: thành công' 'OK'; $Changes += ('Cài per-user: ' + $PkgName + ' ' + $rel.Tag) }
    }

    # ------------------------------------------------------------------ 7
    Write-Host ''
    Log '--- [7/8] Provision cho mọi user (Add-AppxProvisionedPackage) ---' 'STEP'
    if ($Scope -ne 'AllUsers') {
        Log 'Scope = CurrentUser nên bỏ qua bước provision.' 'WARN'
    } elseif ($before.Provisioned.Count) {
        Log ('Đã provision sẵn bản ' + ($before.Provisioned[0].Version) + ' - bỏ qua.') 'OK'
    } elseif ($DryRun) {
        Log ("DRY-RUN: Add-AppxProvisionedPackage -Online -PackagePath `"{0}`" -LicensePath `"{1}`"" -f $bundlePath, $licensePath) 'DRY'
    } else {
        try {
            Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -LicensePath $licensePath | Out-Null
            Log 'Provisioning: thành công' 'OK'
            $Changes += ('Provision all-users: ' + $PkgName + ' ' + $rel.Tag + ' (kèm License1.xml)')
        } catch {
            # The per-user install above already makes winget work for this
            # account, so a provisioning failure is a degradation, not a total
            # failure. Surface it loudly but keep going to verification.
            Log ('Provisioning THẤT BẠI: ' + $_.Exception.Message) 'ERR'
            Log 'winget vẫn dùng được cho user hiện tại, nhưng user tạo MỚI sau này sẽ không tự có.' 'WARN'
            $Changes += ('LỖI provisioning (đã ghi nhận, chưa khắc phục): ' + $_.Exception.Message)
            $script:ExitCode = 2
        }
    }

    # ------------------------------------------------------------------ 8
    Write-Host ''
    Log '--- [8/8] Kiểm tra kết quả ---' 'STEP'
    if ($DryRun) {
        Log 'DRY-RUN: would run `winget --version` and re-snapshot' 'DRY'
        $after = $before
    } else {
        # A freshly registered WindowsApps alias is not visible to the already
        # running process; re-read it from the registry-backed per-user PATH.
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        $ver = $null
        $tried = @()
        if (Test-Path $alias) { $tried += $alias }
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $tried += [string]$cmd.Source }
        foreach ($t in ($tried | Select-Object -Unique)) {
            # winget writes notices to stderr; under ErrorActionPreference=Stop
            # that would look like a failure, so relax it just for this call.
            $eapPrev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $raw = & $t --version 2>&1 } catch { $raw = $null }
            finally { $ErrorActionPreference = $eapPrev }
            if ($raw) {
                $ver = (@($raw) | Select-Object -First 1).ToString().Trim()
                if ($ver) { break }
            }
        }
        if ($ver) {
            Log ('winget.exe HOẠT ĐỘNG: ' + $ver) 'OK'
            Log ('Đường dẫn: ' + $alias) 'OK'
        } else {
            Log 'winget.exe KHÔNG chạy được. Microsoft cảnh báo nguyên nhân thường là thiếu VCLibs/UI.Xaml.' 'ERR'
            Log 'Mở PowerShell MỚI rồi thử lại; nếu vẫn lỗi, chạy .\check-status.ps1 để xem chi tiết.' 'WARN'
            $script:ExitCode = 1
        }
        Start-Sleep -Milliseconds 500
        $after = Get-WingetState -IncludeProvisioned
    }

    # ------------------------------------------------------- change log ----
    if (-not $DryRun) {
        Write-Host ''
        if ($UndoActions.Count) {
            Save-UndoPlan -BackupDir $backupDir -Actions $UndoActions
            Log ('Đã lưu undo.json (' + @($UndoActions).Count + ' hành động hoàn tác).') 'OK'
        }
        Log '--- Ghi nhật ký thay_doi_sys.md ---' 'STEP'
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' — ' + $(if ($DryRun) { 'DRY RUN cài WinGet (không sửa gì)' } else { 'Cài WinGet ' + $rel.Tag }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **Script**: `install-winget.ps1 -Scope ' + $Scope + $(if ($DryRun) { ' -DryRun' } else { '' }) + '`')
    [void]$sb.AppendLine('- **Máy**: ' + $os.ProductName + ' ' + $os.DisplayVersion + ' build ' + $os.Build + ' (' + $os.EditionID + ')')
    [void]$sb.AppendLine('- **Kiến trúc**: ' + $os.TargetArchLabel + ' — phụ thuộc cài bản `' + $os.TargetArch + '`')
    [void]$sb.AppendLine('- **Người chạy**: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    [void]$sb.AppendLine('- **Nguồn**: hướng dẫn chính chủ Microsoft Learn — *Using WinGet to Install Apps on Windows IoT Enterprise*')
    [void]$sb.AppendLine('- **Release**: [' + $rel.Tag + '](' + $rel.HtmlUrl + ') — tải từ `github.com/microsoft/winget-cli`')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Thay đổi trên hệ thống')
    if ($DryRun) {
        [void]$sb.AppendLine('_Dry run — không có thay đổi nào được thực hiện._')
    } elseif ($Changes.Count) {
        foreach ($c in $Changes) { [void]$sb.AppendLine('- ' + $c) }
    } else {
        [void]$sb.AppendLine('- Không có thay đổi (gói đã tồn tại sẵn).')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Trạng thái trước → sau')
    [void]$sb.AppendLine('| Mục | Trước | Sau |')
    [void]$sb.AppendLine('|---|---|---|')
    $fmt = { param($s) if ($s.Count) { ($s | ForEach-Object { $_.Version }) -join ', ' } else { 'không có' } }
    [void]$sb.AppendLine('| DesktopAppInstaller (user này) | ' + (& $fmt $before.PerUser)     + ' | ' + (& $fmt $after.PerUser)     + ' |')
    [void]$sb.AppendLine('| DesktopAppInstaller (all-users) | ' + (& $fmt $before.AllUsers)   + ' | ' + (& $fmt $after.AllUsers)   + ' |')
    [void]$sb.AppendLine('| DesktopAppInstaller (provisioned) | ' + (& $fmt $before.Provisioned) + ' | ' + (& $fmt $after.Provisioned) + ' |')
    [void]$sb.AppendLine('| `winget --version` | ' + $(if ($before.WingetVersion) { $before.WingetVersion } else { 'không chạy được' }) + ' | ' + $(if ($after.WingetVersion) { $after.WingetVersion } else { $(if ($DryRun) { '(dry run)' } else { 'không chạy được' }) }) + ' |')
    $slBefore = $(if ($before.SideloadPolicy) { $before.SideloadPolicy.AllowAllTrustedApps } else { 'khoá không tồn tại' })
    $slAfter  = $(if ($after.SideloadPolicy)  { $after.SideloadPolicy.AllowAllTrustedApps }  else { 'khoá không tồn tại' })
    [void]$sb.AppendLine('| AllowAllTrustedApps | ' + $slBefore + ' | ' + $slAfter + ' |')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Backup đã tạo')
    if ($DryRun) {
        [void]$sb.AppendLine('_Dry run — backup sẽ nằm ở `backup\' + $RunTag + '\`_')
    } else {
        [void]$sb.AppendLine('- Thư mục: `backup\' + $RunTag + '\`')
        [void]$sb.AppendLine('  - `reg_*.reg` — bản export các khoá registry có thể bị sửa (AppModelUnlock, Session Manager\Environment tức PATH máy, Policies\Appx, Policies\WindowsStore)')
        [void]$sb.AppendLine('  - `path-machine.txt`, `path-user.txt` — PATH trước khi sửa')
        [void]$sb.AppendLine('  - `state-before.json` — trạng thái WinGet đầy đủ trước khi sửa')
        [void]$sb.AppendLine('  - `appx-allusers.json` — toàn bộ gói appx của mọi user')
        [void]$sb.AppendLine('  - `appx-provisioned.json` — danh sách gói đã provision')
        if ($UndoActions.Count) {
            [void]$sb.AppendLine('  - `undo.json` — chỉ dẫn hoàn tác CHÍNH XÁC từng giá trị registry đã sửa (cần thiết vì `reg import` chỉ gộp chứ không xoá)')
        }
        [void]$sb.AppendLine('- File cài đặt giữ lại ở `cache\` để đỡ phải tải lại nếu release hiện hành không đổi (không dùng được để cài offline - xem `huongdan_toot-pack.md` muc 8.4)')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Cách khôi phục')
    [void]$sb.AppendLine('```powershell')
    [void]$sb.AppendLine('# Gỡ WinGet và nạp lại registry từ backup này:')
    [void]$sb.AppendLine('.\restore-winget.ps1 -BackupTag ' + $RunTag)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# Xem thử sẽ gỡ những gì, chưa sửa gì cả:')
    [void]$sb.AppendLine('.\restore-winget.ps1 -BackupTag ' + $RunTag + ' -DryRun')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> `restore-winget.ps1` **không** gỡ `Microsoft.VCLibs` / `Microsoft.UI.Xaml` vì các ứng dụng khác đang dùng chung. Thêm `-RemoveDependencies` nếu bạn chắc chắn muốn gỡ.')
    Add-ChangeLogEntry -Path $ChangeLog -Markdown $sb.ToString() -DryRun:$DryRun

    # ---------------------------------------------------------- summary ----
    Write-Host ''
    Log '===============================================================' 'STEP'
    if ($DryRun) {
        Log 'DRY RUN hoàn tất. KHÔNG có thay đổi nào trên hệ thống.' 'DRY'
        Log 'Chạy .\install-winget.ps1 (không kèm -DryRun) để cài thật.' 'DRY'
    } else {
        Log ('HOÀN TẤT. Exit code = ' + $script:ExitCode) $(if ($script:ExitCode -eq 0) { 'OK' } else { 'WARN' })
        Log ('Backup : ' + $backupDir)
        Log ('Nhật ký: ' + $ChangeLog)
        Log 'Mở PowerShell MỚI để dùng winget (PATH của phiên hiện tại chưa được nạp alias).'
    }
    Log '===============================================================' 'STEP'
}
catch {
    Log ('LỖI: ' + $_.Exception.Message) 'ERR'
    Log ('Tại  : ' + $_.InvocationInfo.PositionMessage) 'ERR'

    if (-not $DryRun) {
        # A failed run can still have already modified the system - for example
        # a registry write made before the failure. That must never go
        # undocumented, so persist the undo plan and a change-log entry here too.
        if ($UndoActions.Count -and $backupDir) {
            try {
                Save-UndoPlan -BackupDir $backupDir -Actions $UndoActions
                Log ('Đã lưu undo.json (' + @($UndoActions).Count + ' hành động hoàn tác) vào ' + $backupDir) 'WARN'
            } catch { Log ('Không lưu được undo.json: ' + $_.Exception.Message) 'ERR' }
        }
        if ($Changes.Count) {
            try {
                $sbFail = New-Object System.Text.StringBuilder
                [void]$sbFail.AppendLine('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' — CÀI WINGET THẤT BẠI (nhưng ĐÃ có thay đổi)')
                [void]$sbFail.AppendLine('')
                [void]$sbFail.AppendLine('- **Script**: `install-winget.ps1 -Scope ' + $Scope + '`')
                [void]$sbFail.AppendLine('- **Người chạy**: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
                [void]$sbFail.AppendLine('- **Kết quả**: THẤT BẠI, nhưng các thay đổi dưới đây ĐÃ xảy ra và cần được biết.')
                [void]$sbFail.AppendLine('')
                [void]$sbFail.AppendLine('### Lỗi')
                [void]$sbFail.AppendLine('```')
                [void]$sbFail.AppendLine(($_.Exception.Message -split "`n")[0])
                [void]$sbFail.AppendLine('```')
                [void]$sbFail.AppendLine('')
                [void]$sbFail.AppendLine('### Thay đổi ĐÃ xảy ra trên hệ thống')
                foreach ($c in $Changes) { [void]$sbFail.AppendLine('- ' + $c) }
                [void]$sbFail.AppendLine('')
                [void]$sbFail.AppendLine('### Backup / hoàn tác')
                [void]$sbFail.AppendLine('- Thư mục backup: `' + $(if ($backupDir) { Split-Path $backupDir -Leaf } else { 'không tạo được' }) + '`')
                if ($UndoActions.Count) {
                    [void]$sbFail.AppendLine('- `undo.json` đã được lưu, chứa chỉ dẫn hoàn tác chính xác từng giá trị registry.')
                    [void]$sbFail.AppendLine('')
                    [void]$sbFail.AppendLine('```powershell')
                    [void]$sbFail.AppendLine('.\restore-winget.ps1 -BackupTag ' + $RunTag + ' -Force')
                    [void]$sbFail.AppendLine('```')
                }
                [void]$sbFail.AppendLine('')
                [void]$sbFail.AppendLine('> Lưu ý: `reg import` chỉ GỘP giá trị chứ không xoá giá trị thừa, nên việc hoàn tác dựa vào `undo.json` chứ không dựa vào file `.reg`.')
                Add-ChangeLogEntry -Path $ChangeLog -Markdown $sbFail.ToString()
            } catch { Log ('Không ghi được nhật ký thay đổi: ' + $_.Exception.Message) 'ERR' }
        }
    }

    if (-not $DryRun -and $backupDir) {
        Log ('Backup vẫn còn ở ' + $backupDir + ' — có thể chạy restore-winget.ps1 -BackupTag ' + $RunTag) 'WARN'
    }
    $script:ExitCode = 1
}

exit $script:ExitCode
