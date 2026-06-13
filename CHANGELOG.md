# Changelog

All notable changes to this package will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [3.5.4] - 2026-06-13

### Added
- Completed full integration of Approov service layer v3 features: service mutator, bypass mode, trace ID, fallback token, secure string/query parameter substitutions, HTTP message signing (RFC 9421 signature builders and default request signers), and dynamic TLS pinning.
- Added localized testing framework with a full 35-test suite utilizing the native Mini-SDK.
- Excluded vendored message signing license files from the target build source to prevent SwiftPM warnings.

### Changed
- Refactored `ApproovService` to handle multi-threaded state access safely with locks.
- Changed Package.swift to swift-tools-version 5.8 with support for structured headers, exact SDK dependencies, and conditional local Mini-SDK path setup.
- Updated dynamic pinning to execute `Approov.getPins("public-key-sha256")` exactly once per handshake.

### Fixed
- Pinning now matches Approov pins against the operating-system-validated certificate path rather than the raw chain presented by the peer. Previously, extra certificates supplied by the server that were not part of the validated trust path were still considered during pin matching, which could allow an attacker holding any CA-trusted certificate for the host to append the legitimate pinned certificate as a decoy and defeat pinning.
- Documented the dynamic pinning update model in `REFERENCE.md`: pins are enforced per TLS handshake and apply immediately to all new connections, while connections already pooled under a previous pin set are re-pinned when they cycle.
- Body digest computation for the `EventLoopFuture` (`HTTPClient.Request`) API now buffers multi-chunk in-memory bodies in full; previously the `signRequest` path retained only the final chunk, producing an incorrect `Content-Digest`.
- One-shot and chunked streaming request bodies are now skipped for body-digest computation rather than being consumed or partially digested, so streaming uploads are no longer corrupted and signing proceeds without a body digest. Body extraction for the synchronous API is consolidated into a single shared implementation.
- `setBodyDigestConfig(nil, required:)` now fully disables body-digest generation; previously a digest algorithm configured earlier (including the default factory's SHA-256) persisted and digests continued to be generated.
- Closed a race in `ApproovHTTPClient.Task` where a `cancel()` arriving while the request was being set up could be lost, allowing the request to execute uncancelled. The wrapped task is now stored and re-checked for cancellation under a single lock.
