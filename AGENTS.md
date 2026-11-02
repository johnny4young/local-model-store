# AGENTS.md

LocalModelStore: a Swift package for a shared on-disk store of local AI models. The on-disk format is the real interface, because clients may not be Swift.

## Commands

```sh
swift build -Xswiftc -warnings-as-errors
swift test --parallel -Xswiftc -warnings-as-errors
swiftlint lint --strict --no-cache
scripts/check-repository-hygiene.sh
```

## Rules for every change

- **Scratch roots only.** Tests and tools never touch a real store. There is no default root or default consumer: both are always explicit.
- **Trust:** bytes are trusted only after hashing against the caller's compiled manifest. Directory names, manifests and claims on disk are never authority.
- **Locks save bytes; rename and hash give correctness.** A lost lock may waste a download and must never corrupt an install. Never delete a lock file. Open locks with `O_CLOEXEC`.
- **Format changes:** `docs/FORMAT.md` changes in the same commit. An incompatible change gets a new version directory.
- **Swift 6 strict concurrency**, warnings as errors. No `@unchecked Sendable` without a comment saying why it is safe.
- **No dependencies** beyond Foundation and CryptoKit. No daemon or XPC.
- **License:** MIT. Never copy code from GPL projects.
- **Commits:** Conventional Commits in English. Never add AI co-authorship or generated-by lines to commits, PRs, tags or releases.
- **Comments:** short, and only for the why. No ticket keys, PR numbers or incident stories in source.
- **Never loosen a test, budget or threshold** to reach green.
