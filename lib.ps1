#requires -Version 5.1
<#
    lib.ps1 - Shared helpers for install-winget.ps1 / uninstall_restore.ps1 / check-status.ps1

    Scope of this library: console display setup (UTF-8 + font), logging,
    system-state snapshot, registry backup, and the thay_doi_sys.md change log.
    No persistent system modification happens in here.
#>

Set-StrictMode -Version 2.0

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# Without this, PS 5.1 encodes console output using the OEM code page and every
# Vietnamese diacritic turns into '?'.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# Windows IoT ships without Windows Terminal, so scripts run in the legacy
# console, whose default font (Lucida Console or a raster font) has no
# Vietnamese glyphs - valid UTF-8 still renders as empty boxes. Point this
# window at Consolas; the change lasts only for this console session, nothing
# is written to the registry, and Windows Terminal already reports Consolas.
function Initialize-ConsoleFont {
    try {
        if ([Console]::IsOutputRedirected) { return }

        if (-not ('WingetConsoleFont' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WingetConsoleFont
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFO_EX
    {
        public uint cbSize;
        public uint nFont;
        public short dwFontSizeX;
        public short dwFontSizeY;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFO_EX lpConsoleCurrentFontEx);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFO_EX lpConsoleCurrentFontEx);
}
'@
        }

        $h = [WingetConsoleFont]::GetStdHandle(-11)
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr](-1)) { return }

        $cur = New-Object WingetConsoleFont+CONSOLE_FONT_INFO_EX
        $cur.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][WingetConsoleFont+CONSOLE_FONT_INFO_EX])
        if (-not [WingetConsoleFont]::GetCurrentConsoleFontEx($h, $false, [ref]$cur)) { return }

        $raster = (($cur.FontFamily -band 0x02) -eq 0)
        $badFace = ($cur.FaceName -eq 'Lucida Console' -or $cur.FaceName -eq 'Terminal' -or $cur.FaceName -eq '')
        if (-not $badFace -and -not $raster) { return }

        $new = $cur
        $new.FaceName = 'Consolas'
        $new.FontFamily = 54
        $new.FontWeight = 400
        if ($new.dwFontSizeY -le 0 -or $raster) { $new.dwFontSizeY = 16; $new.dwFontSizeX = 0 }
        [void][WingetConsoleFont]::SetCurrentConsoleFontEx($h, $false, [ref]$new)
    } catch { }
}

Initialize-ConsoleFont

$script:LogPath = $null

# ---------------------------------------------------------------- logging ----

function Initialize-Log {
    param([string]$Path)
    $script:LogPath = $Path
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $Path -Value '' -Encoding UTF8
    }
}

function Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','STEP','DRY')][string]$Level = 'INFO')
    $line = '[{0}] [{1,-4}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERR'  { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'OK'   { Write-Host $line -ForegroundColor Green }
        'STEP' { Write-Host $line -ForegroundColor Cyan }
        'DRY'  { Write-Host $line -ForegroundColor Magenta }
        default{ Write-Host $line }
    }
    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 }
}

function Write-Utf8Bom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# ------------------------------------------------------------------- state ----

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Set-StrictMode 2.0 throws on a missing property, and registry keys on this
# image routinely have the key present but the value unset. Read through this
# instead of touching the property directly.
function Get-PropSafe {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

# reg.exe writes "key not found" to stderr, which under $ErrorActionPreference
# = 'Stop' becomes a terminating error even though it is an expected outcome.
# Arguments go in as an array rather than one string handed to cmd.exe, so
# PowerShell does the quoting and key paths with spaces survive intact.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = if ($Arguments.Count) { & $Exe @Arguments 2>&1 } else { & $Exe 2>&1 }
        $text = if ($null -eq $out) { '' } else { (@($out) | ForEach-Object { "$_" }) -join "`r`n" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Runs a command whose stderr output is informational, not fatal.
function Invoke-Quiet {
    param([Parameter(Mandatory)][scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Block) } finally { $ErrorActionPreference = $prev }
}

# Which build of the dependency .appx files this machine needs.
# Folder = subfolder inside DesktopAppInstaller_Dependencies.zip and the
# filename suffix; Enum = what Get-AppxPackage reports in .Architecture
# (Windows.ApplicationModel.PackageArchitecture: X86 / X64 / Arm64 / Neutral).
function Get-TargetArchitecture {
    # PROCESSOR_ARCHITEW6432 is set only for a 32-bit process running on 64-bit
    # Windows, where PROCESSOR_ARCHITECTURE would misleadingly say x86.
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch ($a) {
        'AMD64' { return [pscustomobject]@{ Folder='x64';   Enum='X64';   ProcArch=$a; Label='x64 (AMD64)' } }
        'ARM64' { return [pscustomobject]@{ Folder='arm64'; Enum='Arm64'; ProcArch=$a; Label='ARM64' } }
        'x86'   { return [pscustomobject]@{ Folder='x86';   Enum='X86';   ProcArch=$a; Label='x86 (32-bit)' } }
    }
    return [pscustomobject]@{ Folder=$null; Enum=$null; ProcArch=$a; Label=('không nhận diện được (' + $a + ')') }
}

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $arch = Get-TargetArchitecture
    [pscustomobject]@{
        ProductName    = (Get-PropSafe $cv 'ProductName')
        EditionID      = (Get-PropSafe $cv 'EditionID')
        DisplayVersion = (Get-PropSafe $cv 'DisplayVersion')
        Build          = ('{0}.{1}' -f (Get-PropSafe $cv 'CurrentBuild'), (Get-PropSafe $cv 'UBR'))
        Arch           = $os.OSArchitecture
        TargetArch     = $arch.Folder
        TargetArchEnum = $arch.Enum
        TargetArchLabel= $arch.Label
    }
}

# Everything we care about, in one place. Used by check-status, install
# pre/post snapshots, and the restore verification.
function Get-WingetState {
    param([switch]$IncludeProvisioned)

    $pkgName = 'Microsoft.DesktopAppInstaller'

    $perUser = @(Get-AppxPackage -Name $pkgName)
    $allUsers = @()
    $provisioned = @()
    if (Test-Admin) {
        $allUsers = @(Get-AppxPackage -Name $pkgName -AllUsers)
        if ($IncludeProvisioned) {
            $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $pkgName })
        }
    }

    $depPattern = 'VCLibs\.140\.00|UI\.Xaml\.2\.8|WindowsAppRuntime\.1\.8'
    $deps = @(Get-AppxPackage | Where-Object { $_.Name -match $depPattern } |
        Select-Object Name, Version, Architecture)

    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'

    $version = $null
    $exe = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $exe -and (Test-Path $alias)) { $exe = $alias }
    if ($exe) {
        # winget can write progress notices to stderr; that must not abort a
        # caller running with ErrorActionPreference = Stop.
        $raw = Invoke-Quiet { & $exe --version 2>&1 }
        if ($LASTEXITCODE -eq 0 -and $raw) { $version = (@($raw) | Select-Object -First 1).ToString().Trim() }
    }

    $unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    $sideload = $null
    if (Test-Path $unlock) {
        $p = Get-ItemProperty $unlock
        $sideload = [pscustomobject]@{
            AllowAllTrustedApps               = (Get-PropSafe $p 'AllowAllTrustedApps'               '(chưa đặt)')
            AllowDevelopmentWithoutDevLicense = (Get-PropSafe $p 'AllowDevelopmentWithoutDevLicense' '(chưa đặt)')
        }
    }

    # Every collection is force-wrapped: piping an empty array through
    # Select-Object yields $null, and $null.Count throws under StrictMode 2.0.
    [pscustomobject]@{
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        IsAdmin          = (Test-Admin)
        PerUser          = @($perUser     | Select-Object Name, Version, Architecture, PackageFullName, NonRemovable)
        AllUsers         = @($allUsers    | Select-Object Name, Version, Architecture, PackageFullName, InstallLocation, NonRemovable)
        Provisioned      = @($provisioned | Select-Object DisplayName, Version, Architecture)
        Dependencies     = @($deps)
        WingetAliasPath  = $alias
        WingetAliasFound = (Test-Path $alias)
        WingetVersion    = $version
        SideloadPolicy   = $sideload
    }
}

function Format-StateReport {
    param($State)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("=== WinGet / App Installer state @ $($State.Timestamp) ===")
    [void]$sb.AppendLine("Running as admin      : $($State.IsAdmin)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Microsoft.DesktopAppInstaller")
    [void]$sb.AppendLine("  per-user (this acct): $(if ($State.PerUser.Count)      { ($State.PerUser      | ForEach-Object { "$($_.Version) $($_.Architecture)" }) -join ', ' } else { 'NOT INSTALLED' })")
    [void]$sb.AppendLine("  all-users           : $(if ($State.AllUsers.Count)     { ($State.AllUsers     | ForEach-Object { "$($_.Version) $($_.Architecture)" }) -join ', ' } else { 'NONE (or need admin)' })")
    [void]$sb.AppendLine("  provisioned         : $(if ($State.Provisioned.Count)  { ($State.Provisioned  | ForEach-Object { "$($_.Version) $($_.Architecture)" }) -join ', ' } else { 'NONE' })")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("winget.exe alias      : $($State.WingetAliasPath)")
    [void]$sb.AppendLine("  exists              : $($State.WingetAliasFound)")
    [void]$sb.AppendLine("  winget --version    : $(if ($State.WingetVersion) { $State.WingetVersion } else { 'FAILED / not runnable' })")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Required dependencies (per-user):")
    if ($State.Dependencies.Count) {
        foreach ($d in ($State.Dependencies | Sort-Object Name, Architecture)) {
            [void]$sb.AppendLine(("  {0,-38} {1,-18} {2}" -f $d.Name, $d.Version, $d.Architecture))
        }
    } else { [void]$sb.AppendLine("  NONE FOUND") }
    [void]$sb.AppendLine("")
    if ($State.SideloadPolicy) {
        [void]$sb.AppendLine("AppModelUnlock (HKLM):")
        [void]$sb.AppendLine("  AllowAllTrustedApps               = $($State.SideloadPolicy.AllowAllTrustedApps)")
        [void]$sb.AppendLine("  AllowDevelopmentWithoutDevLicense = $($State.SideloadPolicy.AllowDevelopmentWithoutDevLicense)")
    } else { [void]$sb.AppendLine("AppModelUnlock (HKLM): key absent") }
    return $sb.ToString()
}

# ---------------------------------------------------------------- versions ----

# Package versions are 4-part (1.29.380.0) while release tags are 3-part
# (v1.29.380). Only major.minor.patch is compared: .NET treats a missing
# revision as -1, so the same build would otherwise look older than itself.
function ConvertTo-WingetVersion {
    param([string]$Value)
    if (-not $Value) { return $null }
    $m = [regex]::Match($Value.Trim(), '^[vV]?\s*(\d+(?:\.\d+){0,3})')
    if (-not $m.Success) { return $null }
    $parts = @($m.Groups[1].Value.Split('.'))
    if ($parts.Count -gt 3) { $parts = @($parts[0], $parts[1], $parts[2]) }
    while ($parts.Count -lt 3) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}

function Compare-WingetVersion {
    param([string]$Installed, [string]$Latest)
    $i = ConvertTo-WingetVersion $Installed
    $l = ConvertTo-WingetVersion $Latest
    if ($null -eq $i -or $null -eq $l) { return 'unknown' }
    if ($i -lt $l) { return 'older' }
    if ($i -gt $l) { return 'newer' }
    return 'equal'
}

# ------------------------------------------------------------------ backup ----

# Registry keys we may touch. Exported before any modification so restore can
# put them back byte-for-byte.
$script:BackupRegKeys = @(
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock',
    'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\Appx',
    'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
)

function New-SystemBackup {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [string]$Tag = (Get-Date -Format 'yyyyMMdd-HHmmss'),
        [switch]$DryRun
    )

    $dir = Join-Path $BackupRoot $Tag
    if ($DryRun) {
        Log "DRY-RUN: would create backup folder $dir" 'DRY'
        foreach ($k in $script:BackupRegKeys) {
            Log ("DRY-RUN:   reg export `"{0}`"" -f $k) 'DRY'
        }
        Log "DRY-RUN:   snapshot appx-allusers.json / appx-provisioned.json / path.txt / state.json" 'DRY'
        return $dir
    }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Log "Backup folder: $dir" 'STEP'

    foreach ($k in $script:BackupRegKeys) {
        $safe = ($k -replace '[:\\]', '_')
        $out = Join-Path $dir ("reg_" + $safe + ".reg")
        # Probe with the PowerShell provider rather than `reg query`: it handles
        # spaces in key paths correctly. Absent keys are recorded as absent so
        # restore knows it may have to delete something it created.
        $psPath = $k -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\'
        if (Test-Path $psPath) {
            $exp = Invoke-Native 'reg.exe' @('export', $k, $out, '/y')
            if ($exp.ExitCode -eq 0) {
                Log "  exported  $k" 'OK'
            } else {
                Log ("  EXPORT FAILED $k -> " + $exp.Output.Trim()) 'ERR'
            }
        } else {
            Set-Content -Path ($out + '.absent.txt') -Value "Key absent at backup time: $k" -Encoding UTF8
            Log "  absent    $k (recorded)" 'WARN'
        }
    }

    # Machine + user PATH, kept separate so restore never merges the wrong scope.
    $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $up = [Environment]::GetEnvironmentVariable('Path', 'User')
    Set-Content -Path (Join-Path $dir 'path-machine.txt') -Value $mp -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'path-user.txt')    -Value $up -Encoding UTF8
    Log "  exported  PATH (machine + user)" 'OK'

    $state = Get-WingetState -IncludeProvisioned
    Write-Utf8Bom (Join-Path $dir 'state-before.json') ($state | ConvertTo-Json -Depth 4)
    Log "  exported  state-before.json" 'OK'

    @(Get-AppxPackage -AllUsers | Select-Object Name, Version, Architecture, PackageFullName, InstallLocation, NonRemovable) |
        ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $dir 'appx-allusers.json') -Encoding UTF8
    Log "  exported  appx-allusers.json ($(@(Get-AppxPackage -AllUsers).Count) packages)" 'OK'

    @(Get-AppxProvisionedPackage -Online | Select-Object DisplayName, Version, Architecture) |
        ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $dir 'appx-provisioned.json') -Encoding UTF8
    Log "  exported  appx-provisioned.json" 'OK'

    return $dir
}

# ------------------------------------------------------------- change log ----

function Add-ChangeLogEntry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Markdown,
        [switch]$DryRun
    )
    if ($DryRun) { Log "DRY-RUN: would append entry to $Path" 'DRY'; return }

    if (-not (Test-Path $Path)) {
        $header = @'
# thay_doi_sys.md

Nhật ký mọi thay đổi trên hệ thống máy này.

File này được các script tự động cập nhật. Mỗi lần cài đặt, sửa chữa hay gỡ bỏ
đều có một mục, kèm theo đường dẫn backup và lệnh restore tương ứng.

KHÔNG sửa tay các mục đã ghi — hãy thêm mục mới để giữ lịch sử nguyên vẹn.

---

'@
        Write-Utf8Bom $Path $header
    }
    $existing = [System.IO.File]::ReadAllText($Path)
    Write-Utf8Bom $Path ($existing.TrimEnd() + "`r`n`r`n" + $Markdown.Trim() + "`r`n")
    Log "Change log updated: $Path" 'OK'
}

# `reg import` only merges - it cannot delete a value that did not exist when
# the backup was taken. So every registry write is also recorded here as an
# explicit undo action, which uninstall_restore.ps1 replays.
function Save-UndoPlan {
    param([Parameter(Mandatory)][string]$BackupDir, [AllowEmptyCollection()]$Actions)
    if (-not $BackupDir) { return }
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $path = Join-Path $BackupDir 'undo.json'
    # -InputObject, not the pipeline form: piping a single-element array into
    # ConvertTo-Json unwraps it and writes a bare object instead of an array.
    Write-Utf8Bom $path (ConvertTo-Json -InputObject @($Actions) -Depth 5)
}

# --------------------------------------------------------------- download ----

function Get-LatestWingetRelease {
    param([string]$Repo = 'microsoft/winget-cli')
    $j = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $Repo) `
        -Headers @{ 'User-Agent' = 'winget-installer-script' } -TimeoutSec 30
    $bundle = $j.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
    $lic    = $j.assets | Where-Object { $_.name -like '*License*.xml' } | Select-Object -First 1

    # Microsoft names the checksum file after the bundle's base name, dropping
    # the .msixbundle extension: "<base>.txt". Accept the .msixbundle.txt
    # spelling too in case the convention changes.
    $hash = $null
    if ($bundle) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($bundle.name)
        $hash = $j.assets | Where-Object { $_.name -eq ($base + '.txt') -or $_.name -eq ($bundle.name + '.txt') } |
                Select-Object -First 1
    }

    [pscustomobject]@{
        Tag        = $j.tag_name
        Published  = $j.published_at
        HtmlUrl    = $j.html_url
        Bundle     = $bundle
        License    = $lic
        HashAsset  = $hash
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

# A matching SHA256 only proves the bytes match a hash published by the same
# origin. Authenticode is the independent check that says who actually signed
# the package, so it also catches a compromised release or a replaced cache file.
function Assert-MicrosoftSigned {
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '(không có chứng chỉ)' }
    if ($sig.Status -ne 'Valid') {
        throw ('Chữ ký Authenticode không hợp lệ cho ' + (Split-Path $Path -Leaf) + ': ' + $sig.Status)
    }
    if ($subject -notmatch 'CN=Microsoft Corporation') {
        throw ('File ' + (Split-Path $Path -Leaf) + ' được ký bởi "' + $subject + '" - không phải Microsoft Corporation, từ chối cài.')
    }
    Log ('Authenticode OK: ' + (Split-Path $Path -Leaf) + '  [' + $subject + ']') 'OK'
}

# WebClient is used instead of Invoke-WebRequest because PS 5.1's IWR buffers
# the whole 207 MB payload and is an order of magnitude slower.
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [switch]$DryRun
    )
    if ($DryRun) { Log ("DRY-RUN: would download {0} -> {1}" -f $Url, $OutFile) 'DRY'; return }
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'winget-installer-script')
    try { $wc.DownloadFile($Url, $OutFile) }
    finally { $wc.Dispose() }
}
