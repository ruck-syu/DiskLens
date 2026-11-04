# DiskLens

A native SwiftUI macOS app for seeing what's using your disk and cleaning it up safely.

- **Overview**: usage ring for each volume (used / purgeable / free) and quick actions.
- **Explorer**: interactive squarified treemap with a sorted list. Click a folder to zoom in, use the breadcrumbs or ⌘↑ to go back, and right-click to open, reveal, or trash an item.
- **Cleanup**: finds caches, logs, Xcode DerivedData, device support files, simulator caches, package-manager caches (npm, pnpm, Bun, Gradle, Cargo, Go), archives, device backups and Downloads. "Safe" categories are preselected; "Review" categories are not.
- **Large Files**: a sortable, filterable table of files above a size you pick.

Everything you delete goes to the **Trash**, so you can restore it until you empty the Trash.

## Build

```bash
./scripts/build-app.sh      # → build/DiskLens.app
open build/DiskLens.app
```

For development: `swift run`.

Requires macOS 14+ and Xcode 15+.

## Full Disk Access

macOS hides some folders (Mail, Safari, Trash, device backups) unless the app has Full Disk Access. Grant it in **System Settings → Privacy & Security → Full Disk Access**, then reopen the app. Without it the app still works, but those folders aren't counted.

## How sizes are measured

Sizes are allocated bytes on disk (the same as `du`), via `lstat`. Hard links are counted once, scans stay on one volume, and when you scan `/` the APFS Data volume is counted once instead of twice through firmlinks.
