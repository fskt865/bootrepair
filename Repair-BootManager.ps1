<#
.SYNOPSIS
    Inspects and repairs the Windows boot manager on a target disk.

.DESCRIPTION
    Automates the sequence normally done by hand in WinRE or on a bench machine:

        1. Enumerate disks and classify every partition (ESP / MSR / Windows / data).
        2. Locate the Windows installation and the system partition on the target disk.
        3. Temporarily mount the system partition (ESP is hidden and has no letter).
        4. Back up the existing BCD store to a timestamped file.
        5. Run bcdboot to rewrite the boot files and BCD from the target Windows' own
           \Windows\Boot payload (so the version always matches the install).
        6. For BIOS/MBR disks, rewrite the boot sector and mark the partition active.
        7. Verify by enumerating the resulting store, then unmount.

    This does NOT reimplement boot repair. It drives bcdboot / bootsect / bcdedit,
    which are the supported tools, and removes the manual diskpart steps where the
    mistakes actually happen.

.PARAMETER List
    Show an inventory of all disks and partitions, then exit. Read-only.

.PARAMETER DiskNumber
    The disk to repair. Get it from -List.

.PARAMETER Firmware
    Auto (default) picks UEFI for GPT disks and BIOS for MBR disks. Override with
    UEFI, BIOS, or All (writes both, useful for a drive that may be moved between
    machines).

.PARAMETER RebuildStore
    Delete the existing BCD before running bcdboot so a fresh store is created.
    Use when the store is corrupt rather than merely missing entries. The backup is
    taken first, always.

.PARAMETER Force
    Permit targeting the disk the running OS booted from. Refused by default.

.PARAMETER Locale
    Boot files locale passed to bcdboot. Default en-us.

.EXAMPLE
    .\Repair-BootManager.ps1 -List

.EXAMPLE
    .\Repair-BootManager.ps1 -DiskNumber 2 -WhatIf

.EXAMPLE
    .\Repair-BootManager.ps1 -DiskNumber 2 -RebuildStore

.NOTES
    Requires an elevated session. Run from WinRE/WinPE for a drive in its own
    machine, or attach the drive to a bench machine and target it by disk number.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$List,

    [switch]$Probe,

    [int]$DiskNumber = -1,

    [ValidateSet('Auto', 'UEFI', 'BIOS', 'All')]
    [string]$Firmware = 'Auto',

    [switch]$RebuildStore,

    [switch]$Force,

    [string]$Locale = 'en-us'
)

$ErrorActionPreference = 'Stop'

# Autoloading Storage while -WhatIf is set makes it narrate its own alias creation.
# Import-Module has no -WhatIf parameter, so suppress via the preference variable instead.
$savedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module Storage -Verbose:$false -ErrorAction SilentlyContinue
$WhatIfPreference = $savedWhatIf

$EspGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$MsrGuid = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$RecoveryGuid = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$BasicGuid = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

# --------------------------------------------------------------------------- #
# Output helpers
# --------------------------------------------------------------------------- #

function Write-Step  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Write-Info  { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run in an elevated PowerShell session.'
    }
}

# --------------------------------------------------------------------------- #
# diskpart plumbing - PowerShell cannot reliably letter a hidden ESP
# --------------------------------------------------------------------------- #

function Invoke-DiskPart {
    param([string[]]$Lines)

    $file = Join-Path $env:TEMP ("dp-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        Set-Content -Path $file -Value $Lines -Encoding ASCII
        $out = & diskpart.exe /s $file
        if ($LASTEXITCODE -ne 0) {
            throw "diskpart failed (exit $LASTEXITCODE):`n$($out -join [Environment]::NewLine)"
        }
        return $out
    }
    finally {
        if (Test-Path $file) { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}

function Get-FreeDriveLetter {
    # Walk backwards from Z so we never collide with anything the tech is using.
    $used = @()
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { $used += $_.Name.ToUpper() }
    Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { $used += ([string]$_.DriveLetter).ToUpper() }

    foreach ($c in [char[]](90..68)) {   # Z down to D
        if ($used -notcontains [string]$c) { return [string]$c }
    }
    throw 'No free drive letter available.'
}

function Mount-TargetPartition {
    param(
        [Parameter(Mandatory)][int]$Disk,
        [Parameter(Mandatory)][int]$Partition
    )

    $letter = Get-FreeDriveLetter
    Invoke-DiskPart @(
        "select disk $Disk",
        "select partition $Partition",
        "assign letter=$letter"
    ) | Out-Null

    if (-not (Test-Path "${letter}:\")) {
        throw "Assigned letter ${letter}: to disk $Disk partition $Partition but it is not accessible."
    }
    return $letter
}

function Dismount-TargetPartition {
    param(
        [Parameter(Mandatory)][int]$Disk,
        [Parameter(Mandatory)][int]$Partition,
        [Parameter(Mandatory)][string]$Letter
    )

    try {
        Invoke-DiskPart @(
            "select disk $Disk",
            "select partition $Partition",
            "remove letter=$Letter"
        ) | Out-Null
    }
    catch {
        Write-Warn "Could not release ${Letter}: - remove it manually with diskpart if it lingers."
    }
}

# --------------------------------------------------------------------------- #
# Inventory
# --------------------------------------------------------------------------- #

function Get-PartitionRole {
    param($Part, $Vol, [string]$Style)

    if ($Style -eq 'GPT') {
        switch ($Part.GptType) {
            $EspGuid      { return 'ESP' }
            $MsrGuid      { return 'MSR' }
            $RecoveryGuid { return 'Recovery' }
        }
    }
    else {
        # MBR: type 0xEF is an ESP on a hybrid layout; 0x27 is the recovery type.
        if ($Part.MbrType -eq 239) { return 'ESP' }
        if ($Part.MbrType -eq 39)  { return 'Recovery' }
        if ($Part.IsActive)        { return 'Active' }
    }

    if ($Vol -and $Vol.FileSystem -eq 'FAT32' -and $Part.Size -lt 2GB) { return 'ESP?' }
    return 'Data'
}

function Get-DiskInventory {
    param([int]$Only = -1)

    $disks = Get-Disk | Sort-Object Number
    if ($Only -ge 0) { $disks = $disks | Where-Object { $_.Number -eq $Only } }

    $result = @()
    foreach ($d in $disks) {
        $parts = @()
        foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)) {
            $vol = $null
            try { $vol = Get-Volume -Partition $p -ErrorAction Stop } catch { }

            $parts += [pscustomobject]@{
                Number      = $p.PartitionNumber
                Role        = Get-PartitionRole -Part $p -Vol $vol -Style $d.PartitionStyle
                DriveLetter = if ($p.DriveLetter) { [string]$p.DriveLetter } else { '' }
                FileSystem  = if ($vol) { $vol.FileSystem } else { '' }
                Label       = if ($vol) { $vol.FileSystemLabel } else { '' }
                SizeGB      = [math]::Round($p.Size / 1GB, 2)
                Raw         = $p
            }
        }

        $result += [pscustomobject]@{
            Number     = $d.Number
            Model      = $d.FriendlyName
            Style      = $d.PartitionStyle
            SizeGB     = [math]::Round($d.Size / 1GB, 2)
            Bus        = $d.BusType
            IsBootDisk = $d.IsBoot
            Partitions = $parts
        }
    }
    return $result
}

function Show-Inventory {
    param($Inventory, [switch]$Probe)

    foreach ($d in $Inventory) {
        $flag = ''
        if ($d.IsBootDisk) { $flag = '  <-- RUNNING OS' }
        Write-Host ''
        Write-Host ("Disk {0}  {1}  [{2}, {3} GB, {4}]{5}" -f `
            $d.Number, $d.Model, $d.Style, $d.SizeGB, $d.Bus, $flag) -ForegroundColor White

        if (-not $d.Partitions) {
            Write-Info '(no partitions)'
            continue
        }

        $rows = foreach ($p in $d.Partitions) {
            $row = [ordered]@{
                '#'      = $p.Number
                'Role'   = $p.Role
                'Ltr'    = $p.DriveLetter
                'FS'     = $p.FileSystem
                'Label'  = $p.Label
                'SizeGB' = $p.SizeGB
            }
            if ($Probe) {
                $row['Found'] = if (Test-WindowsPartition -Disk $d.Number -Partition $p) { 'Windows' } else { '' }
            }
            [pscustomobject]$row
        }
        $rows | Format-Table -AutoSize | Out-String | ForEach-Object { $_.TrimEnd() } | Write-Host
    }
    Write-Host ''
}

# --------------------------------------------------------------------------- #
# Detection
# --------------------------------------------------------------------------- #

function Test-WindowsPartition {
    param([int]$Disk, $Partition)

    if ($Partition.Role -in @('ESP', 'MSR', 'ESP?')) { return $false }
    if ($Partition.Raw.Size -lt 15GB) { return $false }
    if ($Partition.FileSystem -and $Partition.FileSystem -ne 'NTFS') { return $false }

    $letter = $Partition.DriveLetter
    $temp = $false
    if (-not $letter) {
        try { $letter = Mount-TargetPartition -Disk $Disk -Partition $Partition.Number; $temp = $true }
        catch { return $false }
    }

    try {
        return (Test-Path "${letter}:\Windows\System32\winload.exe") -or
               (Test-Path "${letter}:\Windows\System32\ntoskrnl.exe")
    }
    finally {
        if ($temp) { Dismount-TargetPartition -Disk $Disk -Partition $Partition.Number -Letter $letter }
    }
}

function Find-WindowsPartition {
    param([int]$Disk, $DiskInfo)

    foreach ($p in $DiskInfo.Partitions) {
        if (Test-WindowsPartition -Disk $Disk -Partition $p) { return $p }
    }
    return $null
}

function Find-SystemPartition {
    param($DiskInfo, [string]$Mode)

    if ($Mode -eq 'UEFI') {
        $esp = $DiskInfo.Partitions | Where-Object { $_.Role -eq 'ESP' } | Select-Object -First 1
        if (-not $esp) {
            $esp = $DiskInfo.Partitions | Where-Object { $_.Role -eq 'ESP?' } | Select-Object -First 1
            if ($esp) { Write-Warn "No partition carries the ESP type GUID; using the FAT32 partition $($esp.Number) as a probable ESP." }
        }
        return $esp
    }

    # BIOS: the small active partition, else the Windows partition itself.
    $sys = $DiskInfo.Partitions |
        Where-Object { $_.Raw.IsActive -and $_.FileSystem -eq 'NTFS' } |
        Sort-Object SizeGB |
        Select-Object -First 1
    return $sys
}

# --------------------------------------------------------------------------- #
# Repair steps
# --------------------------------------------------------------------------- #

function Backup-BcdStore {
    param([string]$SystemLetter, [string]$Mode)

    $candidates = @(
        "${SystemLetter}:\EFI\Microsoft\Boot\BCD",
        "${SystemLetter}:\Boot\BCD"
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $found = $false

    foreach ($src in $candidates) {
        if (Test-Path $src) {
            $dest = "$src.bak-$stamp"
            Copy-Item -LiteralPath $src -Destination $dest -Force
            Write-Ok "Backed up $src -> $(Split-Path $dest -Leaf)"
            $found = $true
        }
    }

    if (-not $found) {
        Write-Warn 'No existing BCD store found - nothing to back up (this is expected if the store was deleted).'
    }
    return $candidates | Where-Object { Test-Path $_ }
}

function Remove-BcdStore {
    param([string[]]$Stores)

    foreach ($s in $Stores) {
        Remove-Item -LiteralPath $s -Force
        Write-Ok "Removed $s (bcdboot will create a fresh store)"
    }
}

function Invoke-BcdBoot {
    param([string]$WindowsLetter, [string]$SystemLetter, [string]$Mode, [string]$Locale)

    $fw = switch ($Mode) {
        'UEFI' { 'UEFI' }
        'BIOS' { 'BIOS' }
        default { 'ALL' }
    }

    $argsList = @("${WindowsLetter}:\Windows", '/s', "${SystemLetter}:", '/f', $fw, '/l', $Locale)
    Write-Info "bcdboot $($argsList -join ' ')"

    $out = & bcdboot.exe @argsList 2>&1
    $out | ForEach-Object { Write-Info $_ }

    if ($LASTEXITCODE -ne 0) {
        throw "bcdboot failed with exit code $LASTEXITCODE."
    }
    Write-Ok 'Boot files and BCD written.'
}

function Repair-MbrBootSector {
    param([int]$Disk, $SystemPartition, [string]$SystemLetter)

    if (-not (Get-Command bootsect.exe -ErrorAction SilentlyContinue)) {
        Write-Warn 'bootsect.exe not found. Boot sector NOT rewritten.'
        Write-Warn 'It ships with Windows setup media / the ADK - run it from WinRE if the disk still will not boot.'
    }
    else {
        Write-Info "bootsect /nt60 ${SystemLetter}: /mbr"
        $out = & bootsect.exe /nt60 "${SystemLetter}:" /mbr 2>&1
        $out | ForEach-Object { Write-Info $_ }
        if ($LASTEXITCODE -ne 0) { Write-Warn "bootsect returned exit code $LASTEXITCODE." }
        else { Write-Ok 'Boot sector and MBR code rewritten.' }
    }

    if (-not $SystemPartition.Raw.IsActive) {
        Invoke-DiskPart @(
            "select disk $Disk",
            "select partition $($SystemPartition.Number)",
            'active'
        ) | Out-Null
        Write-Ok "Marked partition $($SystemPartition.Number) active."
    }
    else {
        Write-Info "Partition $($SystemPartition.Number) is already active."
    }
}

function Test-BcdStore {
    param([string]$SystemLetter, [string]$Mode)

    $store = if ($Mode -eq 'BIOS') { "${SystemLetter}:\Boot\BCD" } else { "${SystemLetter}:\EFI\Microsoft\Boot\BCD" }
    if (-not (Test-Path $store)) {
        $alt = if ($Mode -eq 'BIOS') { "${SystemLetter}:\EFI\Microsoft\Boot\BCD" } else { "${SystemLetter}:\Boot\BCD" }
        if (Test-Path $alt) { $store = $alt }
        else {
            Write-Warn "No BCD store found at $store after the repair."
            return $false
        }
    }

    Write-Info "Enumerating $store"
    $out = & bcdedit.exe /store $store /enum 2>&1
    $text = $out -join [Environment]::NewLine
    $out | ForEach-Object { Write-Info $_ }

    if ($text -match 'winload') {
        Write-Ok 'Store contains a Windows loader entry.'
        return $true
    }
    Write-Warn 'Store has no winload entry - the repair may not be complete.'
    return $false
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

Assert-Elevated

if ($List -or $DiskNumber -lt 0) {
    Write-Step 'Disk inventory'
    Show-Inventory -Inventory (Get-DiskInventory) -Probe:$Probe
    if (-not $Probe) { Write-Info 'Add -Probe to also mount each candidate partition and report which hold a Windows install.' }
    Write-Info 'Re-run with -DiskNumber <n> to repair a disk. Add -WhatIf to preview.'
    return
}

$inv = Get-DiskInventory -Only $DiskNumber
if (-not $inv) { throw "Disk $DiskNumber not found." }
$disk = $inv[0]

Write-Step "Target: disk $($disk.Number)  $($disk.Model)  [$($disk.Style), $($disk.SizeGB) GB]"

if ($disk.Style -eq 'RAW') {
    throw "Disk $DiskNumber is RAW (no partition table). There is no boot manager to repair - this is a partitioning/recovery problem, not a boot problem."
}

if ($disk.IsBootDisk -and -not $Force) {
    throw "Disk $DiskNumber is the disk the running OS booted from. Refusing without -Force. Repair it from WinRE, or attach it to another machine."
}
if ($disk.IsBootDisk) {
    Write-Warn 'Targeting the LIVE system disk because -Force was given.'
}

$mode = $Firmware
if ($mode -eq 'Auto') {
    $mode = if ($disk.Style -eq 'GPT') { 'UEFI' } else { 'BIOS' }
    Write-Info "Firmware mode auto-selected: $mode (from $($disk.Style) partition style)."
}

Write-Step 'Locating the Windows installation'
$winPart = Find-WindowsPartition -Disk $DiskNumber -DiskInfo $disk
if (-not $winPart) {
    Show-Inventory -Inventory $inv
    throw "No Windows installation found on disk $DiskNumber. Nothing to point a boot manager at."
}
Write-Ok "Windows found on partition $($winPart.Number) ($($winPart.SizeGB) GB, label '$($winPart.Label)')."

Write-Step 'Locating the system partition'
$sysPart = Find-SystemPartition -DiskInfo $disk -Mode $mode
if (-not $sysPart) {
    Show-Inventory -Inventory $inv
    if ($mode -eq 'UEFI') {
        throw @"
No EFI System Partition on disk $DiskNumber. bcdboot has nowhere to write.

If there is unallocated space, create one first (diskpart, elevated):
    select disk $DiskNumber
    create partition efi size=260
    format quick fs=fat32 label="System"
Then re-run this script. Creating partitions is deliberately not automated here -
it is destructive and depends on the layout in front of you.
"@
    }
    throw "No active system partition on disk $DiskNumber."
}
Write-Ok "System partition is partition $($sysPart.Number) ($($sysPart.Role), $($sysPart.FileSystem), $($sysPart.SizeGB) GB)."

$plan = @(
    "  Disk            : $DiskNumber ($($disk.Model))",
    "  Firmware mode   : $mode",
    "  Windows volume  : partition $($winPart.Number)",
    "  System volume   : partition $($sysPart.Number)",
    "  Rebuild store   : $([bool]$RebuildStore)"
) -join [Environment]::NewLine

Write-Host ''
Write-Host 'Planned repair:' -ForegroundColor White
Write-Host $plan
Write-Host ''

$target = "disk $DiskNumber (partition $($sysPart.Number))"
$action = "rewrite boot files and BCD for $mode"
if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    Write-Info 'No changes made.'
    return
}

# Mount both volumes for the duration of the repair.
$winLetter = $winPart.DriveLetter
$winTemp = $false
$sysLetter = $sysPart.DriveLetter
$sysTemp = $false

try {
    if (-not $winLetter) {
        $winLetter = Mount-TargetPartition -Disk $DiskNumber -Partition $winPart.Number
        $winTemp = $true
        Write-Info "Mounted Windows volume as ${winLetter}:"
    }
    if (-not $sysLetter) {
        $sysLetter = Mount-TargetPartition -Disk $DiskNumber -Partition $sysPart.Number
        $sysTemp = $true
        Write-Info "Mounted system volume as ${sysLetter}:"
    }

    Write-Step 'Backing up the existing BCD'
    $stores = Backup-BcdStore -SystemLetter $sysLetter -Mode $mode

    if ($RebuildStore -and $stores) {
        Write-Step 'Removing the corrupt store'
        Remove-BcdStore -Stores $stores
    }

    Write-Step 'Writing boot files (bcdboot)'
    Invoke-BcdBoot -WindowsLetter $winLetter -SystemLetter $sysLetter -Mode $mode -Locale $Locale

    if ($mode -eq 'BIOS' -or $mode -eq 'All') {
        Write-Step 'Repairing the MBR boot sector'
        Repair-MbrBootSector -Disk $DiskNumber -SystemPartition $sysPart -SystemLetter $sysLetter
    }

    Write-Step 'Verifying'
    $ok = Test-BcdStore -SystemLetter $sysLetter -Mode $mode

    Write-Host ''
    if ($ok) {
        Write-Host 'Boot manager repaired. Return the drive and boot it to confirm.' -ForegroundColor Green
    }
    else {
        Write-Host 'Repair ran but verification was inconclusive - check the output above.' -ForegroundColor Yellow
    }
}
finally {
    Write-Step 'Cleaning up'
    if ($sysTemp) { Dismount-TargetPartition -Disk $DiskNumber -Partition $sysPart.Number -Letter $sysLetter; Write-Info "Released ${sysLetter}:" }
    if ($winTemp) { Dismount-TargetPartition -Disk $DiskNumber -Partition $winPart.Number -Letter $winLetter; Write-Info "Released ${winLetter}:" }
}
