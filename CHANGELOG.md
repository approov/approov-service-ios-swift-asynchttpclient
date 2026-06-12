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
