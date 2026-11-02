# Security Policy

## Reporting a vulnerability

Do not open a public issue for security problems. Use GitHub's [private vulnerability reporting](https://github.com/johnny4young/local-model-store/security/advisories/new) with details and reproduction steps.

## Threat model

The store protects against corruption and races between cooperating clients, truncated or tampered downloads, and disk rot, as long as each client hashes against values compiled into its own signed binary.

It is **not** a boundary against a malicious process running as the same user. Such a process can delete or corrupt files, which a client detects at its next verification. A window remains between verification and load. Core ML's compiled cache lives outside the store and is not covered.
