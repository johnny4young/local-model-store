# LocalModelStore

A shared, verified on-disk store for local AI models on macOS. Apps from the same author use one model folder, so a model downloads once even when several apps need it.

Each app verifies every file against SHA-256 values compiled into its own binary. Nothing on disk is trusted.

> **Status:** in development. There is no release yet.

## Requirements

macOS 14 or iOS 17 or later, Swift 6.2 or later. No dependencies.

## License

[MIT](LICENSE). The origin of copied code is in [docs/PROVENANCE.md](docs/PROVENANCE.md).
