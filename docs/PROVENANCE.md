# Provenance

This package starts from a fresh git history. Each copied file is mapped to its origin here. Both source projects are MIT, by the same author.

## Repository bootstrap

| Path | Source | Change |
|---|---|---|
| `scripts/check-repository-hygiene.sh` | `johnny4young/secreteo` at `f8b1b5b` | Drops checks for app surfaces |
| `scripts/run-ci-swiftlint.sh`, `scripts/verify-ci-toolchain.sh` | `johnny4young/portavoz` at `cffa87bb` | Renamed scratch prefix |
| `.swiftlint.yml`, `.github/*` | `johnny4young/secreteo` at `f8b1b5b` | Package scope |

## Mechanism

Copied from an export of `johnny4young/portavoz@cffa87bb36f800108bd8e366bbaa153e2c9ec88f`, with `ModelStore` renamed to `LocalModelStore` and `ModelDescriptor` to `ModelManifest`.

| Path | Portavoz path | Seam |
|---|---|---|
| `Sources/LocalModelStore/LocalModelStore.swift`, `LocalModelStore+Support.swift` | `Sources/ModelStoreKit/ModelStore.swift` | No default root, explicit consumer, whole-model publication |
| `Sources/LocalModelStore/VerifiedModelLifecycle.swift` | `Sources/ModelStoreKit/VerifiedModelLifecycle.swift` | None |
| `Sources/LocalModelStore/ModelManifest.swift` | `Sources/ModelStoreKit/ModelRegistry.swift` | Artifact and descriptor types only; drops `tasks`, `folderName` and the catalog data |
| `Tests/LocalModelStoreTests/LocalModelStoreTests.swift` | `Tests/PortavozTests/TranscriptionTests.swift` | The store test class only; drops the default-root test |
| `Tests/LocalModelStoreTests/LocalModelStoreDownloadFailureTests.swift` | `Tests/PortavozTests/ModelStoreDownloadFailureTests.swift` | Drops the onboarding test |
