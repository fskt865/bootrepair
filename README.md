# bootrepair

`Repair-BootManager.ps1` — rebuilds the Windows boot manager on a target drive.

It drives the supported Microsoft tools (`bcdboot`, `bootsect`, `bcdedit`, `diskpart`).
It does not reimplement boot repair. What it removes is the manual part where the
mistakes actually happen: finding the ESP, giving it a letter, remembering to back up
the store first, and typing the right `bcdboot` arguments for the right firmware mode.

## What it does

1. Enumerates disks and classifies every partition (ESP / MSR / Recovery / Windows / data).
2. Finds the Windows installation on the target disk by probing for `winload.exe`.
3. Finds the system partition — ESP by type GUID on GPT, the small active NTFS partition on MBR.
4. Temporarily assigns drive letters (the ESP is hidden and has none).
5. **Backs up the existing BCD** to `BCD.bak-<timestamp>` next to the original.
6. Runs `bcdboot <Win>:\Windows /s <Sys>: /f <UEFI|BIOS|ALL>` — which copies boot files from
   the *target* install's own `\Windows\Boot`, so the boot manager version always matches.
7. On MBR: rewrites the boot sector with `bootsect /nt60 ... /mbr` and marks the partition active.
8. Verifies by enumerating the resulting store and checking for a `winload` entry.
9. Releases the temporary drive letters, even on failure.

## Usage

Elevated PowerShell. Start read-only:

```bash
powershell -ExecutionPolicy Bypass -File .\Repair-BootManager.ps1 -List
```

Add `-Probe` to also report which partitions actually contain Windows (this mounts
candidates briefly, read-only):

```bash
powershell -ExecutionPolicy Bypass -File .\Repair-BootManager.ps1 -List -Probe
```

Preview the repair without writing anything:

```bash
powershell -ExecutionPolicy Bypass -File .\Repair-BootManager.ps1 -DiskNumber 2 -WhatIf
```

Repair:

```bash
powershell -ExecutionPolicy Bypass -File .\Repair-BootManager.ps1 -DiskNumber 2
```

Corrupt store rather than a missing entry — delete and recreate (backup still taken first):

```bash
powershell -ExecutionPolicy Bypass -File .\Repair-BootManager.ps1 -DiskNumber 2 -RebuildStore
```

## Parameters

| Parameter | Effect |
|---|---|
| `-List` | Inventory only, no changes. |
| `-Probe` | With `-List`, mount candidates and flag which hold Windows. |
| `-DiskNumber <n>` | Disk to repair. |
| `-Firmware Auto\|UEFI\|BIOS\|All` | `Auto` picks UEFI for GPT, BIOS for MBR. `All` writes both — useful for a drive that may move between machines. |
| `-RebuildStore` | Delete the BCD before `bcdboot` so a fresh store is built. |
| `-Force` | Allow targeting the disk the running OS booted from. Refused otherwise. |
| `-Locale` | Boot files locale for `bcdboot`. Default `en-us`. |
| `-WhatIf` / `-Confirm` | Standard PowerShell. `-WhatIf` stops before any write. |

## Two ways to run it

**Bench machine (preferred).** Pull the drive, attach it by USB or SATA, run the script
against its disk number. `bcdboot` writes a BCD that references the Windows volume by
GUID/disk signature, so it still resolves after the drive goes back in the machine.

**WinRE / WinPE on the customer machine.** Shift-restart → Troubleshoot → Command Prompt,
then `powershell` and run the script. Needed when the drive can't be removed (soldered,
BitLocker-bound to that TPM, RAID member).

## Safety

- Refuses the live boot disk unless `-Force`.
- Always backs up the existing BCD before touching it.
- `-WhatIf` shows the full plan and exits before any write.
- Never creates, formats, resizes, or deletes a partition. If the ESP is missing entirely
  the script stops and prints the `diskpart` commands to create one — that decision stays
  with the tech, because it depends on the layout in front of you.

## What it will not fix

The boot manager is one failure point of several. If this runs clean and the drive still
won't boot, the problem is elsewhere:

- **BitLocker** — an encrypted volume needs its recovery key; probing for `winload.exe`
  will fail on a locked volume and the script will report no Windows found.
- **Dying media** — bad sectors under `\Windows\Boot` or the ESP. Check SMART first; if the
  drive is failing, image it before writing anything to it.
- **Corrupt system files** — boot manager fine, `winload` loads, then a stop code. That's
  `sfc` / `DISM` territory.
- **Firmware NVRAM** — UEFI boot entry deleted at the firmware level. `bcdboot` writes the
  file, but the machine's own boot menu still needs the entry. Fix in BIOS setup.
- **Wrong firmware mode** — a GPT disk in a machine booting CSM/legacy will never boot no
  matter how correct the ESP is. Switch the machine to UEFI.

## Requirements

Windows 10/11 or WinRE/WinPE, elevated. `bcdboot`, `bcdedit`, `diskpart` are in
`System32` everywhere. `bootsect.exe` is present on current Windows 11 builds and on
Windows setup media; if it's missing, the script warns and skips the boot-sector rewrite
rather than failing.
