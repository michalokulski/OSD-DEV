# Drivers Folder

Place any extra drivers here that you want injected into the WinPE/WinRE image at build time.

## How It Works

During the build, `Add-WindowsDriver` is called against the mounted `boot.wim` with `-Recurse`,
so every `.inf`-based driver found anywhere under this folder is automatically injected.

## Folder Structure

Organise by sub-folder for clarity — the build script will find everything recursively:

```
Drivers\
  NIC\
    Intel-I225\
      e2f68.inf
      e2f68.sys
      e2f68.cat
  Storage\
    Samsung-NVMe\
      samsungnvme.inf
      samsungnvme.sys
      samsungnvme.cat
  WiFi\
    Intel-AX201\
      netwtw10.inf
      netwtw10.sys
      ...
```

## Supported Driver Types

Any driver that ships as an `.inf` + `.sys` + optional `.cat` bundle works:

| Type | Examples |
|------|---------|
| Network (NIC/WiFi) | Intel I-series, Realtek RTL |
| Storage | NVMe, SATA AHCI, USB 3.x |
| USB 3 / USB4 | ASMedia, Intel xHCI |
| Chipset / HID | Required for touchscreen / pen input |
| Display | Basic VESA / vendor display adapters |

> **Note:** Do NOT place MSI installers or EXE installers here.
> Only `.inf`-based drivers are supported by `Add-WindowsDriver`.

## Skipping Driver Injection

- If this folder is empty (no `.inf` files), the build skips injection automatically with a warning.
- If this folder does not exist, it is also skipped silently.
- To use a different path: `.\Build-OSDCloud-Clean.ps1 -DriversPath "D:\MyDrivers"`
- To disable entirely: `.\Build-OSDCloud-Clean.ps1 -DriversPath ""`

## Finding Drivers

To export drivers from an existing Windows installation for use here:

```powershell
# Export all third-party drivers from the current machine
Export-WindowsDriver -Online -Destination "D:\ExportedDrivers"

# Then copy the ones you want into sub-folders here
```
