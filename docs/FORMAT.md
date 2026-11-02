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
  locks/<key>.lock
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

Artifact paths are relative, with no `.`, `..` or empty component, and differ by more than case.

## Trust

Each client hashes against values compiled into its own signed binary. `manifest.json`, directory names and everything else on disk are hints. A model is verified only when every listed file is a regular file with the pinned hash, every parent is a real directory, nothing unlisted is present except `.DS_Store`, and no file changed while it was hashed.

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
2. Fill `staging/<uuid>/payload/`, from these sources in order: the current install, read-only seed directories, other installs that list the same hash, then a download. Clone with `clonefile` where possible, and copy on another volume. Never follow a symlink. Hash every file, and treat a bad source as absent.
3. Write `manifest.json`. Make files `0444` and directories `0755`, and flush with `F_BARRIERFSYNC`.
4. Verify the whole payload.
5. Commit with `renamex_np(staging/<uuid>, models/<key>, RENAME_EXCL)`. If the target exists, verify it: when it is good, discard your work. When it is damaged, swap with `RENAME_SWAP` and delete the old copy.

Any client may delete a staging directory whose owner file it can lock, then the owner file, and any staging directory with no owner file.
