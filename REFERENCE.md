# Reference

This provides a reference for the public methods and properties defined on `ApproovService` and the types exposed by the Approov Service for AsyncHTTPClient. These are available when you import the module:

```swift
import ApproovAsyncHTTPClient
```

Most methods either throw an `ApproovError` or return an `ApproovUpdateResponse`. The error cases to be aware of are:

- `networkingError`: A temporary networking issue; offer a retry.
- `rejectionError`: Attestation rejected; includes ARC and rejection reasons if enabled.
- `permanentError` / `configurationError` / `initializationFailure`: Non-retryable in normal flows.

---

## ApproovService

### initialize(config:comment:)
Initializes the SDK with the config obtained using `approov sdk -getConfigString` or in the original onboarding email. In the vast majority of integrations, `initialize` should be called **once** during app startup. Each successful call resets all service-layer configuration (substitution headers, exclusion URL regexes, binding header, service mutator, `useApproovStatusIfNoToken`) to defaults.

The native SDK (3.5+) accepts a same-config re-initialization by returning `false`/`NO` without error, which this service layer handles gracefully. However, calling `initialize` again with the same config still resets the service-layer state, so there is no benefit to doing so in normal app flows with a single service layer.

```swift
try ApproovService.initialize(config: "<config-string>")
```

The package passes the optional `comment` to Approov for [initialization options](https://docs.approov.io/direct-sdk-integration/initialization-options/#sdk-initialization-options). Keep it `nil` otherwise.

```swift
try ApproovService.initialize(config: "<config-string>", comment: "options:no-install-key")
```

If an attempt is made to initialize with a **different** non-empty config, an `ApproovError.initializationFailure` is raised.

Passing an empty config string bypasses Approov SDK initialization. In that mode, the service layer still reports itself as initialized, but requests are forwarded as plain `HTTPClient` traffic without Approov token injection, message signing, secure strings, or pinning. A later call to `initialize()` with a valid non-empty config string will then enable the native Approov SDK at runtime.

### isInitialized()
Returns whether the service layer has been initialized.

```swift
let initialized = ApproovService.isInitialized()
```

### isApproovServiceEnabled() / isApproovProtectionEnabled()
`isApproovServiceEnabled()` returns true once any `initialize` succeeded, bypass mode included. `isApproovProtectionEnabled()` returns true once the Approov SDK is initialized and Approov protection is active.

```swift
let serviceEnabled = ApproovService.isApproovServiceEnabled()
let protectionEnabled = ApproovService.isApproovProtectionEnabled()
```

### isApproovEnabled()
Returns whether Approov protection is currently enabled (initialized with a valid, non-empty configuration string).

```swift
let enabled = ApproovService.isApproovEnabled()
```

### bindHeader
Sets a binding header that must be present on all requests using the Approov service. A hash of the header value is supplied to Approov so the issued token is bound to the value.

```swift
ApproovService.bindHeader = "Authorization"
let header = ApproovService.bindHeader
```

> **Important:** Automatic token binding (via `bindHeader`) and manual token binding (via `setDataHashInToken`) must **not** be mixed. Use one mechanism or the other. When `bindHeader` is set, the service layer reads that header from each outgoing request and supplies its hash to Approov, which will overwrite any value set manually with `setDataHashInToken`.

### setTokenHeader(header:prefix:) / getTokenHeader() / getTokenPrefix()
Sets the header that carries the Approov token, and an optional prefix such as `"Bearer "`. The default is `Approov-Token` with no prefix.

```swift
ApproovService.setTokenHeader(header: "Authorization", prefix: "Bearer ")
let header = ApproovService.getTokenHeader()
let prefix = ApproovService.getTokenPrefix()
```

### setTraceIDHeader(header:) / getTraceIDHeader()
Sets the header that carries the Approov trace ID. `nil` turns it off.

```swift
ApproovService.setTraceIDHeader(header: nil)
let traceHeader = ApproovService.getTraceIDHeader()
```

### approovTokenHeaderAndPrefix
Sets the header that the Approov token is added on, as well as an optional prefix String (such as "Bearer "). By default the token is provided on "Approov-Token" with no prefix.

```swift
ApproovService.approovTokenHeaderAndPrefix = (
    approovTokenHeader: "Approov-Token",
    approovTokenPrefix: ""
)
```

### getApproovTokenHeader()
Returns the name of the header used to carry the Approov token.

```swift
let header = ApproovService.getApproovTokenHeader()
```

### setApproovTraceIDHeader(header:)
Sets the header name used to carry the optional Approov TraceID. Pass `nil` to disable.

```swift
ApproovService.setApproovTraceIDHeader(header: "Approov-TraceID")
ApproovService.setApproovTraceIDHeader(header: nil)
```

### getApproovTraceIDHeader()
Returns the configured TraceID header name, or `nil` if disabled.

```swift
let header = ApproovService.getApproovTraceIDHeader()
```

### setUseApproovStatusIfNoToken(shouldUse:)
Sets a flag indicating if the Approov fetch status (e.g. `NO_NETWORK`, `MITM_DETECTED`) should be used as the token header value if the actual token fetch fails or returns an empty token.

```swift
ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
```

### getUseApproovStatusIfNoToken()
Returns the current setting for using the Approov status if no token is available.

```swift
let shouldUse = ApproovService.getUseApproovStatusIfNoToken()
```

### setLoggingLevel(_:)
Sets the service-layer logging level. This controls the verbosity of unified logging (`os_log`) output generated internally by the package.

Available levels: `.off`, `.error`, `.warning`, `.info`, `.debug`.

```swift
ApproovService.setLoggingLevel(.debug)
```

### setServiceMutator(_:)
Installs a service mutator to customize behavior at key points in the service flow. Pass `nil` to restore the default, `CLOSE_FAILURE`. `ALWAYS_PROCEED` sends each request, with an empty token header (or the status) when there is no token. A request keeps the mutator that it started with.

```swift
ApproovService.setServiceMutator(myMutator)
ApproovService.setServiceMutator(.ALWAYS_PROCEED)
ApproovService.setServiceMutator(nil)
```

### getServiceMutator()
Returns the currently active service mutator.

```swift
let mutator = ApproovService.getServiceMutator()
```

### setDevKey(devKey:)
Sets a development key indicating that the app is a development version.

```swift
ApproovService.setDevKey(devKey: "<dev-key>")
```

### updateRequest(url:headers:)
Updates a URL and `HTTPHeaders` collection with Approov protection and secure string substitutions. This is a synchronous blocking method.

```swift
let (updatedURL, updatedHeaders) = try ApproovService.updateRequest(url: url, headers: headers)
```

> **Note:** This legacy convenience overload only carries a URL and headers. It assumes the `GET` method and no body. If you use a custom service mutator that performs message signing, prefer `signRequest(_:)` or the `ApproovHTTPClient` execute path so the actual method and body are available for the signature base.

### signRequest(_:)
Convenience method that applies Approov protection to a `HTTPClient.Request` and returns the protected request directly. Note: This method is synchronous and may block briefly.

```swift
let protectedRequest = try ApproovService.signRequest(originalRequest)
```

> **Important: Dynamic Pinning:** `signRequest` does **not** apply dynamic TLS pinning. When you use `ApproovHTTPClient`, the client automatically validates TLS certificates using the `ApproovPinningVerifier`. A plain `HTTPClient` bypasses this. If you use `signRequest` with your own client, you are responsible for certificate pinning verification separately.

### updateRequestWithApproov(request:)
Updates an `ApproovRequest` with Approov protection (token, substitutions, etc.) and returns an `ApproovUpdateResponse` describing the decision and any error.

```swift
let response = ApproovService.updateRequestWithApproov(request: request)
```

### addSubstitutionHeader(header:prefix:)
Adds a header name to be subject to secure string substitution.

```swift
ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
```

### removeSubstitutionHeader(header:)
Removes a header previously added for substitution.

```swift
ApproovService.removeSubstitutionHeader(header: "Api-Key")
```

### getSubstitutionHeaders()
Returns the dictionary of headers currently subject to secure string substitution.

```swift
let headers = ApproovService.getSubstitutionHeaders()
```

### addSubstitutionQueryParam(key:)
Adds a query parameter key name to be subject to secure string substitution.

```swift
ApproovService.addSubstitutionQueryParam(key: "api_key")
```

### removeSubstitutionQueryParam(key:)
Removes a query parameter key name previously added.

```swift
ApproovService.removeSubstitutionQueryParam(key: "api_key")
```

### getSubstitutionQueryParams()
Returns the set of query parameter keys subject to secure string substitution.

```swift
let params = ApproovService.getSubstitutionQueryParams()
```

### addExclusionURLRegex(urlRegex:)
Adds an exclusion URL regular expression. Matching URLs bypass all Approov processing.

```swift
ApproovService.addExclusionURLRegex(urlRegex: "^https://example\\.com/unprotected/.*$")
```

### removeExclusionURLRegex(urlRegex:)
Removes a previously added exclusion URL regular expression.

```swift
ApproovService.removeExclusionURLRegex(urlRegex: "^https://example\\.com/unprotected/.*$")
```

### getExclusionURLRegexs()
Returns the current dictionary of exclusion URL regexes.

```swift
let regexs = ApproovService.getExclusionURLRegexs()
```

### getDeviceID()
Gets the device ID used by Approov.

```swift
let deviceId = ApproovService.getDeviceID()
```

### setDataHashInToken(data:)
Directly sets the data hash for subsequently fetched Approov tokens. This is the manual alternative to `bindHeader`; the two must not be mixed (see the note on `bindHeader`).

```swift
ApproovService.setDataHashInToken(data: "<data-to-hash>")
```

### fetchToken(url:)
Performs a token fetch for the given URL. Throws `ApproovError` if the fetch fails.

```swift
let token = try ApproovService.fetchToken(url: "https://example.com/api")
```

### setInstallAttributes(_:)
Sets the install attributes to include in the Approov token. It is the same as `setInstallAttrsInToken(attrs:)`.

```swift
try ApproovService.setInstallAttributes("{\"plan\":\"pro\"}")
```

### getServerAdjustedCurrentTimeMS()
Returns the current time in milliseconds, adjusted to the Approov servers' clock by the SDK.

```swift
let now = try ApproovService.getServerAdjustedCurrentTimeMS()
```

### setInstallAttrsInToken(attrs:)
Sets installation-specific attributes in the token.

```swift
try ApproovService.setInstallAttrsInToken(attrs: "my-attributes")
```

### getAccountMessageSignature(message:)
Gets the signature for the given message using the account-specific HMAC-SHA256 signing key.

```swift
let signature = ApproovService.getAccountMessageSignature(message: "message")
```

### getInstallMessageSignature(message:)
Gets the signature for the given message using the install-specific signing key.

```swift
let signature = ApproovService.getInstallMessageSignature(message: "message")
```

### getMessageSignature(message:)
*OBSOLETE* Use `getAccountMessageSignature` or `getInstallMessageSignature` instead.

### fetchSecureString(key:newDef:)
Fetches a secure string with the given key.

```swift
let value = try ApproovService.fetchSecureString(key: "api_key", newDef: nil)
```

### fetchCustomJWT(payload:)
Fetches a custom JWT with the given payload.

```swift
let jwt = try ApproovService.fetchCustomJWT(payload: "{\"claims\":{}}")
```

### precheck()
Performs a precheck to verify if the app will pass attestation. Internally this performs a secure string fetch with an `UNKNOWN_KEY`, which is treated as a success path. This is intended for **development-time** verification of an integration; it is not required in production flows. Throws `ApproovError` (e.g. `rejectionError` if the app fails attestation).

```swift
try ApproovService.precheck()
```

### getLastARC()
Gets the last Attestation Response Code.

```swift
let arc = ApproovService.getLastARC()
```

---

## ApproovHTTPClient

An `ApproovHTTPClient` manages the underlying `HTTPClient` and automatically injects Approov tokens, processes secure string substitutions, and validates connections using `ApproovPinningVerifier`.

### init(eventLoopGroupProvider:configuration:)
Creates an instance of `ApproovHTTPClient`.

```swift
let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
```

Use `.createNew`, or `.shared` with a `NIOTSEventLoopGroup`. Keep `certificateVerification` at `.fullVerification`, and do not set a proxy. While Approov is enabled, the client refuses each request with `URLError(.unknown)` in any other configuration. The client follows redirects with `configuration.redirectConfiguration`. See [connection validation](ADVANCED.md#connection-validation) and [redirects](ADVANCED.md#redirects).

### get / post / patch / put / delete
Convenience HTTP verbs returning `EventLoopFuture<HTTPClient.Response>`.

### execute(...)
Executes a request using custom `HTTPClient.Request` objects or custom delegates.

### shutdown(queue:_:) / syncShutdown()
Initiates shutdown of the client.

```swift
try client.syncShutdown()
```

---

## ApproovDefaultMessageSigning

A service mutator that signs requests that carry the Approov token header. See [message signing](ADVANCED.md#message-signing).

- `init()`: creates a signer with no factory. It makes the `CLOSE_FAILURE` decisions.
- `combined()`: returns a new signer whose default factory adds both the install and the account signature. It makes the `.DEFAULT` decisions. Install it with `setServiceMutator`.
- `combined(decisions:)`: as `combined()`, but it makes the decisions of `decisions`, for example `.CLOSE_FAILURE` or `.ALWAYS_PROCEED`. Each call returns a new signer.
- `setDefaultFactory(_:)`: the factory for each protected host without its own factory.
- `putHostFactory(hostName:factory:)`: the factory for one host.
- `generateDefaultSignatureParametersFactory(baseParametersOverride:)`: a factory with the default settings: install signature, `created`, a 15 second `expires`, and a SHA-256 body digest.

## SignatureParametersFactory

Each method returns the factory, so calls can be chained.

- `setUseInstallMessageSigning()`, `setUseAccountMessageSigning()`, `setUseInstallAndAccountMessageSigning()`: select the signatures.
- `setBodyDigestConfig(_:required:)`: the body digest algorithm, `DIGEST_SHA256`, `DIGEST_SHA512` or `nil` for none. With `required: true`, a body that cannot be digested fails the request. It throws for an unsupported algorithm.
- `setAddCreated(_:)` and `setExpiresLifetime(_:)`: the `created` and `expires` signature parameters.
- `setAddApproovTokenHeader(_:)` and `setAddApproovTraceIDHeader(_:)`: sign the token and trace headers.
- `addOptionalHeaders(_:)`: headers to sign when they are present.
- `setBaseParameters(_:)`: the base signature parameters.

---

## ApproovPinningVerifier

### verifyPinning(sec_protocol_metadata:)
Static helper used internally by the client's TLS configuration. Returns a boolean indicating if pinning check passed.

```swift
let isPinned = ApproovPinningVerifier.verifyPinning(sec_protocol_metadata: metadata)
```

### Dynamic Pinning Behavior

Approov pins are evaluated by the verifier **once per TLS handshake**. On each new connection the verifier calls `Approov.getPins("public-key-sha256")` to obtain the current pin set, so any dynamic pin update delivered by the Approov SDK takes effect immediately for **every connection established after the update**. If the presented certificate chain does not match the current pins, the handshake fails and that connection is never used.

Pins are matched against the certificate chain that the operating system actually validated (the path built to a trusted anchor), not the raw chain presented by the server. Extra certificates a peer includes that are not part of the validated path cannot satisfy a pin.

> **Note: pooled connections and pin updates:** `ApproovHTTPClient` reuses the connection pool managed by the underlying `HTTPClient`. Because pinning is enforced at handshake time, a connection that was already open and validated under a previous pin set continues to serve requests until it is closed and re-established (for example when it idles out of the pool or the server closes it). New pins are therefore guaranteed to be enforced on all *new* connections immediately, but an existing pooled connection may continue to be used briefly after a pin update. Applications that require all in-flight connections to re-pin immediately after a dynamic update should create a fresh `ApproovHTTPClient` (and shut down the previous one), which forces every subsequent connection to re-handshake under the current pins.
