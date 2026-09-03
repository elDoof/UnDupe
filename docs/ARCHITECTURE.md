# Architecture

Notes on how UnDupe is put together and why it makes the choices it does. The
[README](../README.md) covers what the app is and how to build it; this is for
anyone changing the code.

## The two-layer split

The package enforces a hard boundary. `UnDupeCore` is a library with no UI
dependency — Foundation, CryptoKit, Security, and the BSD syscalls. `UnDupe` is
the SwiftUI app that consumes it. All filesystem, scanning, hashing, and deletion
logic lives in the engine; the views own no policy.

The practical rule: if a change makes a view decide *what* is safe to delete
rather than *how* to present it, it belongs in the engine instead.

## Reading the disk quickly

`FastDirectoryScanner` wraps `getattrlistbulk(2)`. One syscall returns the name,
type, flags, inode and allocated size for many directory entries at once, instead
of a `readdir` plus a `stat` per file. That single decision is where the speed
comes from.

The reply buffer is parsed with **unaligned loads in a fixed attribute order** —
`RETURNED_ATTRS → NAME → OBJTYPE → FLAGS → FILEID → ALLOCSIZE`, ascending bit
order. Changing the requested attribute set means changing the parse order to
match. This is the most fragile file in the project; treat it accordingly. Note
that `ATTR_CMN_RETURNED_ATTRS` imports as `UInt32` while the rest import as
`Int32`, so they must be cast before being OR-ed together.

`ScanEngine` builds the tree on top of it. Top-level subdirectories are walked in
parallel via `DispatchQueue.concurrentPerform`; each subtree is a tight
synchronous recursion. Progress is reported from worker threads and throttled to
30 ms, so callers must hop to the main queue themselves. Cancellation is a locked
flag checked at directory boundaries.

Only directories and regular files become nodes. FIFOs, sockets and device files
are skipped — a later hashing read on one can block forever on a foreign-formatted
external drive.

## Staying inside one volume

`VolumeBoundary` enumerates mount points with `getmntinfo(3)` and returns every
mount *except* the scan root. Without it, scanning `/` descends into every
external drive under `/Volumes` and every auxiliary APFS volume under
`/System/Volumes`.

A same-device (`du -x` style) check would be wrong here. macOS firmlinks `/Users`
and `/Applications` into `/` on the *same* device without a nested mount, so
keying on device number would either split the System+Data volume apart or
double-count `/System/Volumes/Data`. Keying on mount points is exact.

`ScanExclusions` treats three kinds of directory as opaque zero-byte leaves —
shown, but not crawled:

1. foreign mount points from `VolumeBoundary`;
2. anything flagged `SF_DATALESS` via `ATTR_CMN_FLAGS`;
3. anything under `~/Library/CloudStorage`.

(2) and (3) are cloud placeholders. Descending into the File Provider filesystem
is orders of magnitude slower than APFS and can trigger on-demand downloads.
Those files hold no local bytes, so reporting zero is also the honest answer.

## Finding duplicates

`DuplicateFinder` is a three-stage funnel: group by size → hash the first 4 KB →
hash the whole file with SHA-256. A file is never fully hashed without a size
*and* prefix match. Stages run in parallel across size groups.

Stage one applies four filters, each for a reason:

- **Minimum size (1 MB default).** Below this the reclaimable space isn't worth
  the review time.
- **`ProtectedPaths.isDeletable`.** Without it, a whole-volume scan buries the
  user in hundreds of thousands of `/System` and app-bundle copies they could
  never remove anyway.
- **Absolute path de-duplication**, so a file never matches itself when two scans
  overlap (a home folder and a subfolder of it) or a volume is scanned twice.
- **`(deviceID, inode)` de-duplication**, so hard links to one physical file
  collapse to a single representative. Trashing one link frees nothing, so
  surfacing them as reclaimable duplicates would be a lie.

Each file's hashing runs inside an `autoreleasepool`, and the streaming hash
drains per 1 MB chunk. Without that, a parallel group of large media files
accumulates every autoreleased `FileHandle` chunk until the group finishes — the
cause of a memory blow-up on external drives that was measured in tens of GB.

## Deleting safely

`SafeDelete` is the only code in the project that removes anything, and
`ProtectedPaths` is the guard in front of it. Every path in and out of the app
goes through both.

- Removal is always `FileManager.trashItem`, never `unlink`.
- `ProtectedPaths` refuses `/System`, `/Library`, `/Applications`, `/usr`, bundle
  internals, the home root, and more.
- A set of duplicates never loses its last remaining copy — enforced in the
  selection model, not just the dialog.

There are exactly two deliberate carve-outs, and both are narrow:

**Whole-app uninstall.** `ProtectedPaths.isUninstallableApp` lets a complete
third-party `.app` reach the Trash even though `/Applications` and `.app` bundles
are otherwise refused. It requires the path to *be* an `.app`, not be nested
inside another bundle, not live under `/System`, not carry a `com.apple.*`
identifier, and never be UnDupe itself. Leftover files are not covered — they
live under `~/Library` and pass the normal guard.

**Permanent deletion.** `SafeDelete.deletePermanently` skips the Trash. It is
reachable only from the Automatic Cleanup sheet's opt-in switch, is confined to
the allowlisted regenerable caches and logs, is default-off, and still runs the
`ProtectedPaths` guard.

Deletion is also **undoable for one step**. `TrashResult` records where an item
landed in the Trash (`trashItem(at:resultingItemURL:)`), `SafeDelete.putBack`
moves it home, and `FileNode.reattach(to:)` is the exact inverse of
`detachFromParent()` so the map's totals return to what they were. The undo is
single-level on purpose and is discarded whenever the tree it points into is
replaced.

## Updating

`Updates/` implements self-update against GitHub Releases. The security model is
the important part:

> An update is installed only if it is validly code-signed by the same Apple
> Developer team that signed the copy already running.

The expected team identifier is read from the running bundle at runtime rather
than hard-coded, so the rule cannot drift, and an unsigned local build correctly
refuses to update itself. HTTPS proves only that the bytes came from GitHub; the
signature check is what proves who built them, so a compromised account or a
proxied download still cannot install anything.

The order of operations is deliberate: download → mount → copy out of the image →
**verify the copy** → atomic `replaceItemAt`. Verifying the staged copy rather
than the mounted image guarantees the bytes that were checked are the bytes that
will run. Draft releases, pre-releases, non-HTTPS links, unparseable tags and
downgrades are all refused before anything is downloaded.

## The disk map

`TreemapLayout` is pure geometry: a tree in, `[TreemapTile]` out, with nested
rectangles, depth and hue. It implements the **squarified** treemap algorithm
(Bruls, Huizing & van Wijk): fill a strip along the shorter side of the free
space for as long as adding one more item improves the row's worst aspect ratio.
Squarifying is the whole point — naive slice-and-dice produces slivers nobody can
read or click.

Two behaviours look like bugs and are not:

1. Tiles thinner than 3 pt are **dropped**, so a file that is a rounding error of
   the volume simply isn't drawn.
2. `drawableChildren` walks *past* any directory holding a single subdirectory,
   so `Chrome.app › Contents › Frameworks › Chrome Framework.framework` — all four
   the same size — collapses to one tile. Without it, most of an `/Applications`
   map is stacked `Contents` headers.

`TreemapView` renders into a `Canvas` and hit-tests by walking the tile list
**backwards**: tiles are emitted parent-before-child, so the last match is the
deepest.

`SunburstView` is the alternate style behind the map-style toggle, with its own
polar hit-testing. Both views take an **identical binding surface**
(`root`/`focus`/`hovered`/`selected`/`onTrash`) so switching between them is a
pure view substitution. Keep it that way.

Because both are a single `Canvas` with no per-tile views, the right-click menu
derives its target from the hover hit-test — there is no per-tile view to attach
a menu to, and SwiftUI's context menu does not report where the click landed. An
AppKit `rightMouseDown` overlay was tried and rejected: to receive right-clicks it
must be hit-testable, which means it also swallows the left-click the tap gesture
needs.

## Threading

`AppModel` and `CleanupModel` are plain `ObservableObject`s, not actors. Heavy
work runs on `DispatchQueue.global`, and **every `@Published` mutation is wrapped
in `DispatchQueue.main.async`**. Because `FileNode` is a reference type whose
mutations aren't observable, the models call `objectWillChange.send()` by hand
after mutating the tree.

## Build and distribution

There is no `.xcodeproj`. `Scripts/build-app.sh` assembles the bundle from a
SwiftPM build, then optionally signs, notarizes and packages it.

- Two entitlements files, deliberately. The distribution one is an empty dict;
  the debug one adds `get-task-allow`, which the notary service rejects — which
  is exactly why it lives in a separate file. Neither may gain `app-sandbox`: a
  disk scanner has to read what it is asked about, and Full Disk Access is
  user-granted through TCC rather than entitled.
- Never write `--` inside a comment in an entitlements plist. `codesign` hands
  the file to a strict XML parser that rejects a double hyphen in a comment, and
  the only symptom is an opaque `AMFIUnserializeXML: syntax error`.
- No `--deep` on the Developer ID path. The bundle is one statically-linked
  executable with no nested code, and `--deep` is deprecated for signing.
- The app icon is generated, not an asset catalog: `Scripts/make-icon.swift` is a
  standalone CoreGraphics renderer that draws every iconset size and calls
  `iconutil`. `build-app.sh` regenerates it when missing.

Signing locally has a side benefit: a stable Developer ID signature keeps the
Full Disk Access grant across rebuilds, whereas an ad-hoc signature changes the
cdhash every build and TCC forgets the app each time.

## Known limitations

Hard links are counted once per link in directory **totals**, so a hard-link-heavy
tree such as `/usr` reads about 1.5% above `du`. The duplicate finder does not
have this problem. Applying the same `(device, inode)` collapse to the size
accumulation would need a seen-inode set shared across the concurrent subtree
build, which is the remaining planned fix.

The disk map is drawn on a `Canvas` and is not yet reachable by VoiceOver. The
inspector and every list view are.
