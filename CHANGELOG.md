# Changelog

All notable changes to this package will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [3.7.0] - Unreleased

### Added
- `SignatureParametersFactory.setUseInstallAndAccountMessageSigning()` signs with the install and the account key, as two members of one `Signature` dictionary. The default factory signs with the install key only.
- `ApproovService.getServerAdjustedCurrentTimeMS()` gives the time adjusted to the Approov servers' clock.
- `ApproovCloseFailureMutator.CLOSE_FAILURE` (the default), `ApproovAlwaysProceedMutator.ALWAYS_PROCEED` and `DEFAULT`, the named service mutators.
- `setLoggingLevel(_:)` sets the logging level. `OFF` silences the layer.
- `setTokenHeader(header:prefix:)`, `getTokenHeader()`, `getTokenPrefix()`, `setTraceIDHeader(header:)` and `getTraceIDHeader()`, the header names that every 3.7.x layer uses.
- `isApproovServiceEnabled()`, `isApproovProtectionEnabled()` and `setInstallAttributes(_:)`.
- Completed full integration of Approov service layer v3 features: service mutator, bypass mode, trace ID, fallback token, secure string/query parameter substitutions, HTTP message signing (RFC 9421 signature builders and default request signers), and dynamic TLS pinning.
- Added localized testing framework with a full 35-test suite utilizing the native Mini-SDK.
- Excluded vendored message signing license files from the target build source to prevent SwiftPM warnings.

### Changed
- Message signature `created` and `expires` follow the Approov servers' clock, so a device with a wrong clock still signs inside the backend's window.
- A request that proceeds after a token fetch failure is signed over its token header (empty, or the status). Only the token header that the layer added is signed: a token header the app set itself is not.
- With both signatures selected, a signature that cannot be produced is left out and the other is sent.
- `@authority` is the lowercase host with a non-default port. A host factory matches the host without regard to case or a trailing dot.
- **Breaking:** a token fetch failure for a host that is not an Approov API domain no longer fails the request: it goes out untouched. A failure that proceeds to an API domain carries the token header with an empty token, or the status with `setUseApproovStatusIfNoToken`, and the trace header when the SDK supplied one.
- **Breaking:** a secure string fetch never fails the request. A status other than `SUCCESS` is written into the placeholder, keeping a required prefix. Secure strings are substituted only on https to an API domain, including a secrets-only API (`UNPROTECTED_URL`). Every occurrence of a substitution query parameter is substituted.
- **Breaking:** an error that a service mutator hook throws is a `URLError`: a `URLError` passes unchanged, and any other error becomes `URLError(.unknown)` with the original as the underlying error. The `CLOSE_FAILURE` decisions keep `ApproovError`. A required body digest that cannot be generated and an unsupported signature algorithm fail with `URLError(.unknown)`.
- Error messages name the status as the SDK enum does (`REJECTED`, `NO_NETWORK`).
- `getLastARC()` returns the ARC of the last fetch the layer made and makes no fetch of its own.
- **Breaking:** `getMessageSignature(message:)` returns `String?` and no longer throws. It returns the account signature, as `getAccountMessageSignature` does.
- The token and the secure string log lines are written at DEBUG only, and log lines no longer carry a URL query, a fragment or a pin.
- **Breaking:** a connection that Approov pinning rejects fails with `URLError(.serverCertificateUntrusted)`, with the AsyncHTTPClient error as the underlying error. It still fails at the connect deadline (`HTTPClient.Configuration.timeout.connect`), because AsyncHTTPClient retries the connection until then.
- **Breaking:** while Approov protection is on, `ApproovHTTPClient` refuses a request with `URLError(.unknown)` when pinning cannot run: an event loop group that is not a NIOTS group, a `delegateAndChannel` event loop that is not a NIOTS loop, or a client or request TLS configuration without `.fullVerification`.
- A host with no pins and no Managed Trust Roots now connects on OS trust, with one warning for each host while the pins do not change. Pin lookup ignores case and a trailing dot. A connection without SNI (to an IP address) no longer fails, unless an IP address has Approov pins.
- `ApproovHTTPClient` follows redirects itself, with the app's `redirectConfiguration`. The wrapped `HTTPClient` never follows one. Each hop is the app's request for its target, protected as a new request under the service mutator that the request started with: a token fetched for the target, the target's pins, secure strings only on a protected channel, and signatures over the new method and target. Nothing that the layer added reaches another origin. The target URL is used exactly as the server sent it, and its query values are never looked up.
- A request that the layer already protected (for example `signRequest` output passed to `ApproovHTTPClient`) is put back as the app wrote it before it is protected again.
- Refactored `ApproovService` to handle multi-threaded state access safely with locks.
- Changed Package.swift to swift-tools-version 5.8 with support for structured headers, exact SDK dependencies, and conditional local Mini-SDK path setup.
- `Package.swift` `releaseTAG` is now a `dev` placeholder, stamped with the release version by the `tag-release` CI job at tag time (was a hardcoded literal), keeping it in lock-step with the runtime user-property string.
- Updated dynamic pinning to execute `Approov.getPins("public-key-sha256")` exactly once per handshake.

### Deprecated
- `ApproovDefaultMessageSigning.processedRequest`. Use `handleInterceptorProcessedRequest`.
- `ApproovServiceMutatorDefault`. Use `ApproovCloseFailureMutator.DEFAULT` or `.CLOSE_FAILURE`.
- `signRequest(_:)` and `updateRequest(url:headers:)`. A plain `HTTPClient` follows a redirect with the protection that they add, also to another host. Use `ApproovHTTPClient`.
- `loggingLevel`, `approovTokenHeaderAndPrefix`, `getApproovTokenHeader()`, `setApproovTraceIDHeader(header:)`, `getApproovTraceIDHeader()` and `getMessageSignature(message:)`.

### Removed
- **Breaking:** `prefetch()`, `proceedOnNetworkFail` and `setFailureCacheTTL(ttl:)`. The layer no longer caches token fetch failures. To proceed on a network failure, use a service mutator.

### Fixed
- Pinning now matches pins only against the certificate path that trust evaluation built. A decoy certificate that the server appends no longer satisfies a pin, and a managed trust root pin (`*`) now matches when the server does not send its root. The URLSession layer pins the same path.
- A request whose own `tlsConfiguration` does not use `.fullVerification` now fails with `URLError(.unknown)` when Approov is enabled. Before, it completed the TLS handshake without the Approov pin check.
- A redirect no longer carries the Approov token, the trace ID, the signatures, `Content-Digest` or substituted secure strings to the next hop. Before, AsyncHTTPClient followed the redirect with all of them, also to another host.
- A redirect hop keeps the request's own `tlsConfiguration`. AsyncHTTPClient dropped it.
- `ApproovHTTPClient.EventLoopPreference(_:)` now keeps the event loop of a `.delegate(on:)` or `.delegateAndChannel(on:)` preference. Before, it changed every such preference to `.indifferent`, so the delegate ran on an event loop that the caller did not ask for.
- The async `execute` functions now run the Approov update on a global Dispatch queue. Before, the blocking token fetch ran on the Swift concurrency pool and could stop all async work in the app on a slow network.
- The body digest for the async API now reads the body from `readerIndex`. Before, a buffer with a moved `readerIndex` gave no `Content-Digest`, or a failure when the digest was required.
- A stream body that writes from another thread, or after the digest extraction returned, no longer uses the `EmbeddedEventLoop` off its thread, which NIO reports as API misuse. Such a body is not digested. A body closure must be repeatable, because AsyncHTTPClient also calls it again on a 307 or 308 redirect.
- `@target-uri` no longer includes a `#fragment`, and `@path` is `/` for a URL with no path.
- The query parameter substitution error no longer includes the URL, which contained the secure string.
- Message signing now fully conforms to the cross-layer fail-open policy (core-project-approov#564): a signature-base build failure and a `Signature`/`Signature-Input` serialization failure now log at error level and proceed **unsigned** instead of aborting the request, matching the existing install/account/base64/ASN.1 fail-open paths. Only a required body digest that cannot be generated and an unsupported algorithm still fail closed.
- Documented the dynamic pinning update model in `REFERENCE.md`: pins are enforced per TLS handshake and apply immediately to all new connections, while connections already pooled under a previous pin set are re-pinned when they cycle.
- Body digest computation for the `EventLoopFuture` (`HTTPClient.Request`) API now buffers multi-chunk in-memory bodies in full; previously the `signRequest` path retained only the final chunk, producing an incorrect `Content-Digest`.
- One-shot and chunked streaming request bodies are now skipped for body-digest computation rather than being consumed or partially digested, so streaming uploads are no longer corrupted and signing proceeds without a body digest. Body extraction for the synchronous API is consolidated into a single shared implementation.
- `setBodyDigestConfig(nil, required:)` now fully disables body-digest generation; previously a digest algorithm configured earlier (including the default factory's SHA-256) persisted and digests continued to be generated.
- Closed a race in `ApproovHTTPClient.Task` where a `cancel()` arriving while the request was being set up could be lost, allowing the request to execute uncancelled. The wrapped task is now stored and re-checked for cancellation under a single lock.
- `fetchToken`, `fetchSecureString`, `fetchCustomJWT`, and `precheck` now guarantee that only `ApproovError` escapes: an error thrown by a custom service mutator is wrapped as `ApproovError.permanentError`, matching the documented throwing contract.
- Invalid exclusion URL regular expressions passed to `addExclusionURLRegex` are now logged at error level (the exclusion is not registered), rather than being discarded with only a debug-level message.
- Message signing now uses `replaceOrAdd` for the `Signature`, `Signature-Input`, `Signature-Base-Digest`, and `Content-Digest` headers so that re-processing a request cannot emit duplicate header lines.
- RFC 9421 derived `@path` / `@request-target` components now use the on-wire percent-encoded path rather than the percent-decoded `URL.path`, so the server reconstructs the same signature base.
- Logging now distinguishes "service layer not initialized" from "initialized in bypass mode (empty config)" when an Approov-dependent method is invoked while the SDK is inactive.

### Documentation
- `REFERENCE.md`: documented that automatic (`bindHeader`) and manual (`setDataHashInToken`) token binding must not be mixed, that `precheck()` is intended for development-time verification (and throws `ApproovError`), and that the legacy `updateRequest(url:headers:)` overload assumes `GET` with no body.
