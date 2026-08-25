# UnDupe

A fast, native macOS app that shows what's actually using your disk — and safely
clears the duplicates.

![The UnDupe treemap](docs/treemap.png)

## Why

Most disk tools either take minutes to tell you something you already knew, or
they hand you a delete button with no way to judge what you're about to lose.
UnDupe is built around two ideas:

**Be fast enough to be worth opening.** The scanner reads directory metadata in
bulk through the `getattrlistbulk(2)` syscall rather than calling `stat()` on
every file, and walks top-level subtrees in parallel. About 37,000 files in
0.3 seconds.

**Never destroy anything.** Every deletion goes through a single guard and into
the Trash. System paths, app internals, and your home root are refused outright,
and a set of duplicates always keeps at least one copy — the safety is in the
engine, not in the confirmation dialog.

## Features

- **Treemap disk map** — every folder and file is a rectangle whose area is its
  share of the disk, nested and labelled in place. Click to zoom in, ⌃ to go
  back up. A radial sunburst view is available from the same toolbar.
- **Duplicate finder** — a three-stage funnel (size → 4 KB prefix hash → full
  SHA-256) that never fully hashes a file without a size *and* prefix match.
  Works across several scanned drives at once, and collapses hard links so it
  never offers you "space" that doesn't exist.
- **System cleanup** — startup items, extensions, caches and logs, and a bundle-ID
  based app uninstaller that finds an app's leftovers without guessing.
- **Honest totals** — if UnDupe can't read part of your disk, it says so rather
  than quietly reporting a smaller number.

## Install

Download the latest `UnDupe-<version>.dmg` from
[Releases](../../releases), open it, and drag UnDupe to Applications.

The app is signed with a Developer ID and notarized by Apple, so it opens with a
normal double-click — no right-click ▸ Open, no Gatekeeper warning.

Requires macOS 13 or later. Universal: Apple silicon and Intel.

### Full Disk Access

UnDupe is distributed outside the App Store and is deliberately **not
sandboxed**, because a disk scanner has to be able to read everything you ask it
about. To scan beyond your home folder, grant it access:

**System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ add UnDupe.**

Without the grant UnDupe still runs, but protected folders are skipped and the
app will tell you the totals are incomplete.

## Build from source

Requires the Xcode Command Line Tools. Full Xcode additionally enables `swift test`.

```bash
# Build and run
Scripts/build-app.sh release
open build/UnDupe.app

# Test
swift test

# Headless engine, for benchmarking against du
swift run undupe-scan ~/Downloads
```

### Release builds

```bash
Scripts/build-app.sh --sign      # Developer ID + hardened runtime
Scripts/build-app.sh --dist      # universal + sign + notarize + .dmg
```

`--dist` produces a signed, notarized, stapled disk image containing a universal
binary. Notarizing needs a `notarytool` keychain profile; the script prints the
exact command to create one if it's missing. See `Scripts/build-app.sh --help`.

## Architecture

The package enforces a two-layer split: a pure engine with no UI dependencies,
and a SwiftUI app that consumes it. All filesystem, scanning, and hashing logic
lives in the engine and stays out of the views.

```
Sources/
  UnDupeCore/          Engine — no UI imports
    FastDirectoryScanner    getattrlistbulk directory reader
    ScanEngine              parallel tree builder, progress, cancellation
    FileNode                the scanned tree
    DuplicateFinder         size → prefix → full-hash funnel
    ProtectedPaths          what must never be deleted
    SafeDelete              the only code path that removes anything
    FullDiskAccess          detects whether totals can be trusted
    JunkScanner, AppUninstaller, StartupItemsScanner, ExtensionsScanner
  UnDupe/              SwiftUI app
    Treemap/                squarified treemap geometry + view
    Sunburst/               radial map geometry + view
    Views/                  Home, Scan, Results, Duplicates, Cleanup
  undupe-scan/         Headless CLI for validating the engine against du
Tests/
  UnDupeCoreTests/     Deletion guard, scan outcomes
  UnDupeTests/         Treemap geometry and hit testing
```

### Notes on the tricky parts

**`FastDirectoryScanner`** parses the `getattrlistbulk` reply buffer with
unaligned loads in a fixed attribute order. Changing the requested attribute set
means changing the parse order to match — it is the most fragile file here.

**Scanning stays on one volume.** Mount points are enumerated via `getmntinfo(3)`
and everything outside the scan root is treated as an opaque leaf. A same-device
check would be wrong on modern macOS, where `/Users` is firmlinked into `/` on
the same device rather than mounted.

**Cloud placeholders are not crawled.** Anything flagged `SF_DATALESS` or living
under `~/Library/CloudStorage` is reported as a zero-byte leaf. Descending into
the File Provider filesystem is orders of magnitude slower than APFS and can
trigger on-demand downloads. Those files hold no local bytes, so zero is also
the honest answer.

## Known limitations

- Hard links are counted once per link in directory **totals**, so a hard-link
  heavy tree such as `/usr` can read about 1.5% above `du`. The duplicate finder
  does not have this problem — it de-duplicates by `(device, inode)`.
- The disk map is drawn on a `Canvas` and is not yet reachable by VoiceOver.
  The inspector and all list views are.
- There is no in-app update mechanism yet.
