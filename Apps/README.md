# Apps

Place pre-downloaded application archives here to skip the live download during the build.

The build script checks this folder **before** hitting the internet, so any file placed here takes priority over the built-in download URLs.

## Supported files

| File(s) | Used for |
|---------|----------|
| `WinXShell*.7z` or `WinXShell*.zip` | WinXShell portable shell |

## How it works

The build script scans for matching filenames (e.g. `WinXShell*.7z`) using a wildcard, picks the most recently modified match, and copies it into the build cache automatically. No parameter changes needed.

## Notes

- Only the `README.md` in this folder is tracked by Git. All other files are ignored.
- Archives are consumed read-only — the originals are never modified.
