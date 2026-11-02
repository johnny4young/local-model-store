# On-disk format

The format is the real interface of this package, because clients may not be Swift. All paths are relative to the store root.

## Locks

`locks/<key>.lock`, where `<key>` is `<id>@<revision>`, serializes installs of one model.

- Take `flock(LOCK_EX)` before installing, opened with close-on-exec. The kernel releases it when the holder dies.
- Never delete a lock file.
- The lock saves bytes. It is not what keeps an install correct: every published file is hashed first.
- The holder empties the file when it takes the lock, then writes `{"completedBytes":n,"totalBytes":m}` as it downloads, at most once per MiB. The contents are advisory.
- A waiter shows that progress and installs on its own after 2 minutes without a change. The result may waste bytes but stays correct.
- A volume with no `flock` runs the same way with no lock.

## Staging

`staging/<uuid>/` is one writer's work directory, on the same volume as the models, and `staging/<uuid>.owner` is its lock.

- Create and lock the owner file atomically, then create the directory.
- Any client may delete a directory whose owner file it can lock, then the owner file. Any client may delete a directory with no owner file.
