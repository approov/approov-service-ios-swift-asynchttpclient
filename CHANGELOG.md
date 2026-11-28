# Changelog

All notable changes to this package will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [3.7.0] - YYYY-MM-DD

### Changed
- Uses Approov iOS SDK 3.7.0. The minimum iOS version stays 13.0.
- The package logs a missing install or account signature as a warning once per process. It logs a request sent unsigned as an error once per process. It logs later occurrences at debug level.

### Added
- `ApproovDefaultMessageSigning.combined()` and `combined(decisions:)` give a signer that adds both the install and the account signature and makes the decisions you pass, for example `ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED)`. See [message signing](ADVANCED.md#sign-with-other-decisions).

### Fixed
- The signed target URI leaves out an explicit default port: `:443` for `https` and `:80` for `http`. So `https://api.example.com:443/v1` and `https://api.example.com/v1` give the same signature.
- Requests in flight at the same time with different binding header values each have a token bound to their own value.

## [3.5.4] - 2026-11-21

Changes since 3.5.3. Entries marked **Breaking** need a source change.

### Changed
- **Breaking:** `getDeviceID()` returns `String?` and no longer throws.
- **Breaking:** While Approov is enabled, `ApproovHTTPClient` refuses a request with `URLError(.unknown)` when it cannot validate the connection: an event loop group that is not a `NIOTSEventLoopGroup`, a `delegateAndChannel` event loop that is not a NIOTS loop, a client or request TLS configuration without `.fullVerification`, or a client configuration with a proxy. See [connection validation](ADVANCED.md#connection-validation).
- A connection that fails validation fails with `URLError(.serverCertificateUntrusted)` instead of `HTTPClientError.connectTimeout`. It still fails at the connect timeout.
- Hosts in the pin set are matched regardless of case and a trailing dot. A domain with no keys and no Managed Trust Roots connects on OS trust, with one warning. A connection to an IP address no longer fails, unless an IP address has keys configured.
- A failed token fetch only affects requests to your Approov API domains. A request to any other host is sent unchanged. A request that proceeds carries an empty token header, or the status name with `setUseApproovStatusIfNoToken(true)`, and the trace header when the SDK gives one.
- A failed secure string fetch no longer fails the request. The status name replaces the placeholder, such as `Api-Key: REJECTED`. Secure strings are substituted only on https to an Approov API domain, also one added with `-noApproovToken`. Every occurrence of a substitution query parameter is substituted.
- Error messages name the status as the SDK does, such as `REJECTED` or `NO_NETWORK`.
- `getLastARC()` returns the ARC of the last fetch the package made and makes no fetch of its own.
- `ApproovHTTPClient` follows redirects itself, with your `redirectConfiguration`, and protects each hop as a new request for its target. Nothing the package added reaches another origin. See [redirects](ADVANCED.md#redirects).
- A request that the package already protected, such as `signRequest` output, is put back as your app wrote it before it is protected again.
- The async `execute` functions do the Approov work off the Swift concurrency pool.
- Log lines follow `setLoggingLevel`. The loggable token and secure string results are logged at `DEBUG` only, and no log line carries a URL query, a fragment or a key value.
- WebSockets are not supported. A request with `Upgrade: websocket` is sent unchanged. See [WebSockets](ADVANCED.md#websockets).

### Added
- Service mutators: `setServiceMutator(_:)`, `getServiceMutator()`, `ApproovCloseFailureMutator.CLOSE_FAILURE` (the default), `ApproovAlwaysProceedMutator.ALWAYS_PROCEED` and `DEFAULT`. See [service mutators](ADVANCED.md#service-mutators).
- HTTP message signing (RFC 9421) with `ApproovDefaultMessageSigning` and `SignatureParametersFactory`, including `setUseInstallAndAccountMessageSigning()`. Signature times follow the Approov servers' clock. See [message signing](ADVANCED.md#message-signing).
- `setUseApproovStatusIfNoToken(shouldUse:)` and `getUseApproovStatusIfNoToken()`.
- `setTokenHeader(header:prefix:)`, `getTokenHeader()`, `getTokenPrefix()`, `setTraceIDHeader(header:)` and `getTraceIDHeader()`.
- `setLoggingLevel(_:)` and `ApproovLogLevel`. `OFF` silences the package.
- `isApproovServiceEnabled()`, `isApproovProtectionEnabled()`, `setInstallAttributes(_:)`, `getServerAdjustedCurrentTimeMS()`, `getAccountMessageSignature(message:)` and `getInstallMessageSignature(message:)`.
- `getSubstitutionHeaders()`, `getSubstitutionQueryParams()` and `getExclusionURLRegexs()`.
- `updateRequestWithApproov(request:)` and `signRequest(_:)`, for a transport that owns its own client.
- Bypass mode: `initialize(config: "")` sends requests without Approov protection.

### Deprecated
- `approovTokenHeaderAndPrefix`. Use `setTokenHeader(header:prefix:)`, `getTokenHeader()` and `getTokenPrefix()`.
- `getMessageSignature(message:)`, which now returns `String?` and no longer throws. Use `getAccountMessageSignature(message:)`.
- `updateRequest(url:headers:)`. A plain `HTTPClient` follows a redirect with the protection it adds. Use `ApproovHTTPClient`.

### Removed
- **Breaking:** `prefetch()` and `proceedOnNetworkFail`. To send requests after a network failure, use `setServiceMutator(.ALWAYS_PROCEED)`.
- **Breaking:** `substituteQueryParam(url:queryParameter:)`. Call `addSubstitutionQueryParam(key:)`, and the package substitutes the parameter in each request.

### Fixed
- Connection validation now matches only the certificate path that trust evaluation built. An unused certificate that a server adds no longer passes it, and a Managed Trust Roots key matches when the server does not send its root.
- A request TLS configuration without `.fullVerification` no longer skips connection validation.
- `ApproovHTTPClient.EventLoopPreference(_:)` keeps the event loop of a `.delegate(on:)` or `.delegateAndChannel(on:)` preference.
- A `cancel()` that arrived while a request was being set up could be lost.
