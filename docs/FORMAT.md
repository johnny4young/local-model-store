# On-disk format

The format is the real interface of this package, because clients may not be Swift. Everything below is relative to the store root.

## Root

`~/Library/Application Support/com.johnny4young.local-models/`, mode `0700`, excluded from Time Machine. The name is permanent, because Core ML ties compiled models to their path. A sandboxed process must fail rather than create a private store in its container.

```
store.json                          {"format":1}, for people and tools
v1.noindex/                         the format version is this directory
  models/<key>/
    manifest.json                   informational
    payload/                        what a loader receives; files 0444, directories 0755
  claims/<key>/<bundle-id>.json     declares that an app needs a model
  locks/<key>.lock                  serializes installs
  locks/<key>.use                   shared while a process has the model loaded
  staging/<uuid>/
  staging/<uuid>.owner
  trash/<uuid>/
```

`.noindex` keeps Spotlight out, as measured in `johnny4young/secreteo`, `docs/spikes/model-path-and-specialization.md`. An incompatible format gets a new version directory and leaves this tree alone, so `store.json` is never authority.

## Key

`<key>` is `<id>@<revision first 12>-<digest first 12>`.

- `id` matches `[a-z0-9._-]+`, up to 128 characters. Lowercase only, because volumes may be case-insensitive.
- `revision` matches `[A-Za-z0-9._-]+`, up to 128 characters.
- `digest` is the lowercase hex SHA-256 of the artifact list: one line `path NUL sha256 NUL sizeBytes LF` per artifact, sorted by bytes and concatenated.

The digest exists because two clients can pin the same revision with different file lists. Without it, each would repair away the other's files.

A manifest has at least one artifact. Artifact paths are relative, with no `.`, `..` or empty component, differ by more than case, spell each parent one way, and no path is a parent of another.

## Trust

Each client hashes against values compiled into its own signed binary. `manifest.json`, directory names and everything else on disk are hints. A model is verified only when every listed file is a regular file with the pinned size and hash, every parent is a real directory, every directory can be listed, nothing unlisted is present except a regular `.DS_Store`, and no file changed while it was hashed.

This protects against corruption and races between cooperating clients. It is not a boundary against a malicious process running as the same user.

## Locks

`locks/<key>.lock` serializes installs of one model.

- Take `flock(LOCK_EX)` before installing, opened with close-on-exec. The kernel releases it when the holder dies.
- Never delete a lock file.
- The lock saves bytes. It is not what keeps an install correct: rename and hash do that.
- The holder empties the file when it takes the lock, then writes `{"completedBytes":n,"totalBytes":m}` as it downloads, at most once per MiB. The contents are advisory.
- A waiter shows that progress and installs on its own after 2 minutes without a change. The result may waste bytes but stays correct.
- A volume with no `flock` runs the same way with no lock.

## Installing

1. Create and lock `staging/<uuid>.owner` atomically (`O_EXLOCK`), then create `staging/<uuid>/`.
2. Fill `staging/<uuid>/payload/`, from these sources in order: the current install, read-only seed directories, other installs that list the same hash, then a download. Clone with `clonefile` where possible, and copy on another volume. Never follow a symlink, at the source or on the way to it. Hash every file, and treat a bad source as absent.
3. Write `manifest.json`. Make files `0444` and directories `0755`, and flush with `F_BARRIERFSYNC`, or `fsync` where there is no barrier. A failed flush fails the install.
4. Verify the whole payload.
5. Commit with `renamex_np(staging/<uuid>, models/<key>, RENAME_EXCL)`. If the target exists, verify it: when it is good, discard your work. When it is damaged, check that it did not change during the hash, swap with `RENAME_SWAP` and delete the old copy.

Any client may delete a staging directory whose owner file it can lock, then the owner file, and any staging directory with no owner file.

## Claims

`claims/<key>/<bundle-id>.json` declares that an app needs a model. Release and Dev builds are separate consumers, each under its own bundle ID. Claims are declarative rather than counted, because a crash or a drag to the Trash would leak a count.

```json
{
  "consumer": "com.example.app",
  "displayName": "App",
  "firstClaimedAt": "2026-11-02T12:00:00Z",
  "lastUsedAt": "2026-11-02T12:00:00Z",
  "retiredAt": null
}
```

- Dates are RFC 3339 without fractional seconds. Ignore unknown keys. A file that does not decode still protects the model.
- Write with an atomic rename, at most once a day for `lastUsedAt`, and touch `claims/` afterward so watchers notice.
- Create or restore a claim only while holding the install lock, so a removal or a collection cannot miss it. Refreshing or retiring an existing claim needs no lock.
- When an update stops pinning a model, set `retiredAt`. A retired claim still protects the model for 14 days, so a rollback downloads nothing. Clear it, under the install lock, as soon as the model is used again.
- A claim is not consent. Each app asks before its own first use of a model.

## Leases

`locks/<key>.use` is held with `flock(LOCK_SH)` while a process has the model loaded. Take it before verifying. A deleter must get `LOCK_EX`. The kernel releases it when the holder dies.

On a volume with no `flock`, a lease protects nothing and says so. There, only an explicit removal deletes a model, and a collection leaves it alone.

A repair that replaces a model while its use lock is held moves the old copy to `trash/<key>~<uuid>` instead of deleting it, because a reader may hold a directory handle into it. A collection deletes that copy once `LOCK_EX` succeeds.

## Removing

1. Try the install lock without waiting, and drop the claims being removed.
2. If the install lock is busy, or live claims remain, stop. The bytes stay.
3. Try `LOCK_EX` on the use lock without waiting. If it is busy, stop, and a later collection finishes the job.
4. Rename `models/<key>` into `trash/<uuid>` while holding it, and drop every claim left for the key.
5. Release the install lock, then delete the bytes. A slow delete holding the lock would read as a stall.

A collection does this for every real directory in `models/` with no live claims. It also drops retired claims past their grace, drops claims for models that no longer exist while holding that key's install lock, and empties `trash/` and abandoned `staging/`. A symlink in `models/` is never a model.

## Uninstalling

The root is never part of an app's Homebrew `zap`, because removing one app must not cost another a download.
