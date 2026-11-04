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

For development: `swift run`. To package a DMG locally: `./scripts/make-dmg.sh`.

## Releases and updates

Every push to `main` runs [`.github/workflows/release.yml`](.github/workflows/release.yml). It builds a universal (Apple silicon + Intel) app, packages `DiskLens-<version>.dmg`, and publishes it as the latest GitHub release. The version is the contents of [`VERSION`](VERSION) plus the run number (for example `1.0.12`). Bump `VERSION` for a major or minor release.

In the app, **DiskLens → Check for Updates…** checks the latest release, shows its notes, downloads the DMG with a progress bar, then replaces the app and relaunches it. DiskLens also checks quietly on launch (you can turn this off in the update sheet) and shows an update card in the sidebar.

The updater reads GitHub's public releases API. If that API is rate-limited (60 anonymous calls per hour per IP, easy to hit behind a VPN or iCloud Private Relay), it falls back to github.com's `/releases/latest` redirect and the `DiskLens-<version>.dmg` asset name, which aren't rate-limited. To test against another feed, set `DISKLENS_UPDATE_URL` to a JSON file shaped like GitHub's `releases/latest` response.

## Code signing

macOS remembers permissions (Full Disk Access, folder access, controlling Finder) by an app's code signature. If every build is signed with the **same certificate**, those permissions survive updates. An ad-hoc signed build is identified by its exact binary, so macOS asks again after every update.

One-time setup:

```bash
./scripts/setup-signing.sh   # creates a self-signed cert in ~/.disklens-signing (login keychain untouched)
base64 -i ~/.disklens-signing/signing.p12 | gh secret set SIGNING_CERT_P12_BASE64
gh secret set SIGNING_CERT_PASSWORD < ~/.disklens-signing/p12-password.txt
```

`build-app.sh` uses that certificate automatically, and CI uses the secrets. Keep `~/.disklens-signing` backed up. If you lose it and make a new certificate, macOS will ask for permissions one more time.

The certificate is self-signed, not an Apple Developer ID, so the app isn't notarized. The first time someone opens a downloaded DMG copy, macOS will block it: right-click the app and choose **Open**, or allow it in **System Settings → Privacy & Security**. Updates installed by the app itself don't hit this.

Requires macOS 14+ and Xcode 15+.

## Full Disk Access

macOS hides some folders (Mail, Safari, Trash, device backups) unless the app has Full Disk Access. Grant it in **System Settings → Privacy & Security → Full Disk Access**, then reopen the app. Without it the app still works, but those folders aren't counted.

## How sizes are measured

Sizes are allocated bytes on disk (the same as `du`), via `lstat`. Hard links are counted once, scans stay on one volume, and when you scan `/` the APFS Data volume is counted once instead of twice through firmlinks.
