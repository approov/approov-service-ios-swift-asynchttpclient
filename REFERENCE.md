# Reference

The public methods of `ApproovService`, the `ApproovHTTPClient` client, and the classes that you use with them. Import the module:

```swift
import ApproovAsyncHTTPClient
```

The direct methods throw an `ApproovError` on failure. Its cases:

- `networkingError`: a temporary networking problem. Offer a retry.
- `rejectionError`: attestation was rejected. It carries the ARC and the rejection reasons when they are enabled.
- `permanentError`, `configurationError`, `initializationFailure`, `pinningError`, `runtimeError`: not retryable in normal flows.

What a request fails with is in [errors your app can see](ADVANCED.md#errors-your-app-can-see).

# ApproovService

## setLoggingLevel

```swift
static func setLoggingLevel(_ level: ApproovLogLevel)
```

Sets the level of the lines that the package logs: `.off`, `.error`, `.warning`, `.info` (the default) or `.debug`. Each `initialize` keeps it. `ApproovLogLevel` is the type of the level.

## initialize

```swift
static func initialize(config: String, comment: String? = nil) throws
```

Initializes the package with your Approov account ID (see [about the Approov account ID](ADVANCED.md#about-the-approov-account-id)). `""` starts bypass mode, in which requests go out without Approov protection. A second `initialize` with the same account ID is ignored. Each `initialize` that is not ignored resets the configuration to its defaults. `comment` is passed to the SDK. Throws `ApproovError.initializationFailure` if the value is not a complete, unaltered account ID, or if the SDK is already initialized with a different one.

## isInitialized

```swift
static func isInitialized() -> Bool
```

True after an `initialize` succeeded, bypass mode included.

## isApproovEnabled

```swift
static func isApproovEnabled() -> Bool
```

True when the package is initialized with an account ID, so that Approov protection is active.

## isApproovServiceEnabled

```swift
static func isApproovServiceEnabled() -> Bool
```

True after an `initialize` succeeded, bypass mode included: the package processes requests. The same as `isInitialized()`.

## isApproovProtectionEnabled

```swift
static func isApproovProtectionEnabled() -> Bool
```

True when Approov protection is active. The same as `isApproovEnabled()`. Check it after `initialize` before you treat Approov as active.

## bindHeader

```swift
static var bindHeader: String
```

The name of a header whose value the token is bound to, such as `"Authorization"`. `""` (the default) binds nothing. See [token binding](ADVANCED.md#token-binding).

## setTokenHeader

```swift
static func setTokenHeader(header: String, prefix: String?)
```

Sets the name of the token header (default `Approov-Token`) and a prefix for its value (default none), such as `"Authorization"` and `"Bearer "`.

## getTokenHeader

```swift
static func getTokenHeader() -> String
```

Returns the name of the token header.

## getTokenPrefix

```swift
static func getTokenPrefix() -> String
```

Returns the prefix of the token header value, `""` when there is none.

## setTraceIDHeader

```swift
static func setTraceIDHeader(header: String?)
```

Sets the name of the trace header (default `Approov-TraceID`). `nil` turns the trace header off.

## getTraceIDHeader

```swift
static func getTraceIDHeader() -> String?
```

Returns the name of the trace header, or `nil` when it is off.

## setUseApproovStatusIfNoToken

```swift
static func setUseApproovStatusIfNoToken(shouldUse: Bool)
```

When true, a request that proceeds without a token carries the token fetch status name in the token header. Default false. See [sending the status in the token header](ADVANCED.md#sending-the-status-in-the-token-header).

## getUseApproovStatusIfNoToken

```swift
static func getUseApproovStatusIfNoToken() -> Bool
```

Returns the value set with `setUseApproovStatusIfNoToken`.

## setServiceMutator

```swift
static func setServiceMutator(_ mutator: ApproovServiceMutator?)
```

Sets the service mutator, which makes the package's decisions. `nil` sets the default, `CLOSE_FAILURE`. A request keeps the mutator that it started with. See [service mutators](ADVANCED.md#service-mutators).

## getServiceMutator

```swift
static func getServiceMutator() -> ApproovServiceMutator
```

Returns the current service mutator.

## approovConfigString

```swift
static var approovConfigString: String? { get }
```

The Approov account ID that the package was initialized with, `""` in bypass mode, or `nil` before initialization.

## setDevKey

```swift
static func setDevKey(devKey: String)
```

Sets a development key, so that a debug build of the app passes attestation. See [using a development key](https://approov.io/docs/latest/approov-usage-documentation/#using-a-development-key).

## signRequest

```swift
static func signRequest(_ request: HTTPClient.Request) throws -> HTTPClient.Request
```

Returns a protected copy of a request, for a transport that owns its own `HTTPClient` and cannot use `ApproovHTTPClient`. A request that Approov does not apply to comes back unchanged. Create that client with `redirectConfiguration: .disallow`: a plain `HTTPClient` follows a redirect with this protection, also to another host. Throws `ApproovError` for a decision of the standard mutators (`networkingError` for a retry), a `URLError` that your mutator threw, and `URLError(.unknown)` for another hook failure or a configuration error. Catch `Error`.

## updateRequestWithApproov

```swift
static func updateRequestWithApproov(request: ApproovRequest) -> ApproovUpdateResponse
```

Protects an `ApproovRequest` and returns the result: the protected request, the decision (`ApproovFetchDecision`), the SDK status message, and the error for a decision to fail or retry. It does not throw. A request that the package already protected is first put back as the app wrote it.

## addSubstitutionHeader

```swift
static func addSubstitutionHeader(header: String, prefix: String?)
```

Names a header whose value, after `prefix`, is a secure string key. The package replaces the key with the secure string. See [secure strings](ADVANCED.md#secure-strings).

## removeSubstitutionHeader

```swift
static func removeSubstitutionHeader(header: String)
```

Removes a header added with `addSubstitutionHeader`.

## getSubstitutionHeaders

```swift
static func getSubstitutionHeaders() -> Dictionary<String, String>
```

Returns the substitution headers and their prefixes.

## addSubstitutionQueryParam

```swift
static func addSubstitutionQueryParam(key: String)
```

Names a query parameter whose value is a secure string key. The package replaces each occurrence with the secure string.

## removeSubstitutionQueryParam

```swift
static func removeSubstitutionQueryParam(key: String)
```

Removes a query parameter added with `addSubstitutionQueryParam`.

## getSubstitutionQueryParams

```swift
static func getSubstitutionQueryParams() -> Set<String>
```

Returns the substitution query parameters.

## addExclusionURLRegex

```swift
static func addExclusionURLRegex(urlRegex: String)
```

Sends requests whose URL matches the regular expression without Approov processing. Their connections are still validated. A pattern that does not compile is logged as an error and not added.

## removeExclusionURLRegex

```swift
static func removeExclusionURLRegex(urlRegex: String)
```

Removes a pattern added with `addExclusionURLRegex`.

## getExclusionURLRegexs

```swift
static func getExclusionURLRegexs() -> Dictionary<String, NSRegularExpression>
```

Returns the exclusion patterns.

## getDeviceID

```swift
static func getDeviceID() -> String?
```

Returns the Approov device ID of this installation, or `nil` when Approov protection is not active.

## setDataHashInToken

```swift
static func setDataHashInToken(data: String)
```

Binds the next tokens to a hash of `data`. Do not mix it with `bindHeader`.

## fetchToken

```swift
static func fetchToken(url: String) throws -> String
```

Fetches an Approov token for `url` and returns it. Throws `ApproovError`: `networkingError` for a retry, `rejectionError` for a rejection, `permanentError` for other failures and before initialization.

## setInstallAttributes

```swift
static func setInstallAttributes(_ attrs: String) throws
```

Sets the install attributes that the next tokens carry. Throws `ApproovError.permanentError` when Approov protection is not active. `setInstallAttrsInToken(attrs:)` is the 3.5.x name of the same method, and it throws the same.

## getAccountMessageSignature

```swift
static func getAccountMessageSignature(message: String) -> String?
```

Returns the base64 account signature of `message`, or `nil` when the account signing key is not available.

## getInstallMessageSignature

```swift
static func getInstallMessageSignature(message: String) -> String?
```

Returns the base64 install signature of `message`, or `nil` when the install key is not available.

## fetchSecureString

```swift
static func fetchSecureString(key: String, newDef: String?) throws -> String?
```

Fetches the secure string for `key`. With `newDef`, it sets a value for this installation, and `""` removes it. Returns `nil` when the key has no value. Throws `ApproovError`, as `fetchToken` does.

## fetchCustomJWT

```swift
static func fetchCustomJWT(payload: String) throws -> String
```

Fetches a custom JWT with the JSON `payload`. Throws `ApproovError`, as `fetchToken` does.

## precheck

```swift
static func precheck() throws
```

Checks whether the app passes attestation, without a token fetch for an API. Use it during development. Throws `ApproovError`: `rejectionError` with the ARC on a rejection, `networkingError` for a retry, `permanentError` otherwise.

## getLastARC

```swift
static func getLastARC() -> String
```

Returns the Attestation Response Code of the last fetch that the package made, or `""`. It makes no fetch of its own.

## getServerAdjustedCurrentTimeMS

```swift
static func getServerAdjustedCurrentTimeMS() throws -> Int64
```

Returns the current time in milliseconds, adjusted to the Approov servers' clock. If the SDK does not give that time, it returns the device clock and logs one warning. Throws `ApproovError.permanentError` when Approov protection is not active.

## Deprecated

| Deprecated | Use |
|---|---|
| `static var loggingLevel: ApproovLogLevel` | `setLoggingLevel(_:)` |
| `static var approovTokenHeaderAndPrefix` | `setTokenHeader(header:prefix:)`, `getTokenHeader()`, `getTokenPrefix()` |
| `static func getApproovTokenHeader() -> String` | `getTokenHeader()` |
| `static func setApproovTraceIDHeader(header: String?)` | `setTraceIDHeader(header:)` |
| `static func getApproovTraceIDHeader() -> String?` | `getTraceIDHeader()` |
| `static func getMessageSignature(message: String) -> String?` | `getAccountMessageSignature(message:)`, which it returns |
| `static func updateRequest(url: URL, headers: HTTPHeaders) throws -> (URL, HTTPHeaders)` | `ApproovHTTPClient`. A plain `HTTPClient` follows a redirect with the protection that it adds. |

# ApproovHTTPClient

A wrapper for AsyncHTTPClient's `HTTPClient`, with the same methods. It protects each request with Approov before the request is sent.

## init

```swift
convenience init(eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider,
                 configuration: HTTPClient.Configuration = HTTPClient.Configuration())
required init(eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider,
              configuration: HTTPClient.Configuration = HTTPClient.Configuration(),
              backgroundActivityLogger: Logger)
```

Use `.createNew`, or `.shared` with a `NIOTSEventLoopGroup`, and keep `certificateVerification` at `.fullVerification`. While Approov is enabled, the client refuses each request with `URLError(.unknown)` in any other configuration. The client follows redirects with `configuration.redirectConfiguration`. See [connection validation](ADVANCED.md#connection-validation) and [redirects](ADVANCED.md#redirects).

## get, post, patch, put, delete

```swift
func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
func post(url: String, body: HTTPClient.Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
func patch(url: String, body: HTTPClient.Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
func put(url: String, body: HTTPClient.Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
func delete(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
```

Each has a second form with a `logger: Logger` parameter.

## execute

```swift
func execute(_ method: HTTPMethod = .GET, url: String, body: HTTPClient.Body? = nil,
             deadline: NIODeadline? = nil, logger: Logger? = nil) -> EventLoopFuture<HTTPClient.Response>
func execute(_ method: HTTPMethod = .GET, socketPath: String, urlPath: String, body: HTTPClient.Body? = nil,
             deadline: NIODeadline? = nil, logger: Logger? = nil) -> EventLoopFuture<HTTPClient.Response>
func execute(_ method: HTTPMethod = .GET, secureSocketPath: String, urlPath: String, body: HTTPClient.Body? = nil,
             deadline: NIODeadline? = nil, logger: Logger? = nil) -> EventLoopFuture<HTTPClient.Response>
func execute(request: HTTPClient.Request, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
func execute(request: HTTPClient.Request, eventLoop: HTTPClient.EventLoopPreference,
             deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response>
func execute<Delegate: HTTPClientResponseDelegate>(request: HTTPClient.Request, delegate: Delegate,
             deadline: NIODeadline? = nil) -> ApproovHTTPClient.Task<Delegate, Delegate.Response>
func execute<Delegate: HTTPClientResponseDelegate>(request: HTTPClient.Request, delegate: Delegate,
             eventLoop: HTTPClient.EventLoopPreference, deadline: NIODeadline? = nil)
             -> ApproovHTTPClient.Task<Delegate, Delegate.Response>
func execute(_ request: HTTPClientRequest, deadline: NIODeadline, logger: Logger? = nil) async throws -> HTTPClientResponse
func execute(_ request: HTTPClientRequest, timeout: TimeAmount, logger: Logger? = nil) async throws -> HTTPClientResponse
```

The `HTTPClient.Request` forms also have a form with a `logger` parameter. A delegate gets only the final response of a redirect chain. The async forms do the Approov work off the Swift concurrency pool, and all the hops of one request share one deadline.

## shutdown, syncShutdown

```swift
func shutdown(queue: DispatchQueue = .global(), _ callback: @escaping (Error?) -> Void)
func syncShutdown() throws
```

Shut down the client, and its event loop group if the client created it.

## ApproovHTTPClient.Task

```swift
final class Task<Delegate: HTTPClientResponseDelegate, Response>
```

Returned by the `execute` forms with a delegate.

- `eventLoop: EventLoop`: the event loop of the delegate.
- `futureResult: EventLoopFuture<Delegate.Response>`: completes with the delegate's response, or the error.
- `wait() throws -> Delegate.Response`: waits for `futureResult`.
- `cancel()`: cancels the request, also between redirect hops.
- `runInBackground()`: `ApproovHTTPClient` calls it to start the request. Do not call it: a second call sends the request again.

## ApproovHTTPClient.EventLoopPreference

```swift
struct EventLoopPreference
```

The wrapper for `HTTPClient.EventLoopPreference`. `indifferent`, `delegate(on:)` and `delegateAndChannel(on:)` make a preference. `init(_ httpClientPreference: HTTPClient.EventLoopPreference)` maps the AsyncHTTPClient form, and keeps its event loop. `httpClientEventLoopPreference` maps it back. `preference` holds the `Preference` enum (`indifferent`, `delegate(on:)`, `delegateAndChannel(on:)`).

# Extension classes

## ApproovServiceMutator

```swift
protocol ApproovServiceMutator
```

Implement it to change the package's decisions. Each hook has a default, which makes the `CLOSE_FAILURE` decision: `handlePrecheckResult`, `handleFetchTokenResult`, `handleFetchSecureStringResult`, `handleFetchCustomJWTResult`, `handleInterceptorShouldProcessRequest`, `handleInterceptorFetchTokenResult`, `handleInterceptorHeaderSubstitutionResult`, `handleInterceptorQueryParamSubstitutionResult`, `handleInterceptorProcessedRequest` and `handlePinningShouldProcessRequest`. See [service mutators](ADVANCED.md#service-mutators).

## ApproovCloseFailureMutator

```swift
final class ApproovCloseFailureMutator: ApproovServiceMutator
```

The 3.5.x decisions. `ApproovCloseFailureMutator.CLOSE_FAILURE` and `.DEFAULT` are the instance. It is the default mutator.

## ApproovAlwaysProceedMutator

```swift
final class ApproovAlwaysProceedMutator: ApproovServiceMutator
```

Sends each request, with an empty token header (or the status) when there is no token. `ApproovAlwaysProceedMutator.ALWAYS_PROCEED` is the instance. `setServiceMutator(.ALWAYS_PROCEED)` installs it.

## ApproovServiceMutatorDefault

```swift
struct ApproovServiceMutatorDefault: ApproovServiceMutator
```

Deprecated. Its `shared` instance makes the `CLOSE_FAILURE` decisions. Use `ApproovCloseFailureMutator.CLOSE_FAILURE`.

## ApproovRequest

```swift
struct ApproovRequest
```

The request that the package and the mutator hooks work on: `url`, `method`, `headers` and `body` (`Data?`), and `init(url:method:headers:body:)`.

## ApproovUpdateResponse

```swift
struct ApproovUpdateResponse
```

The result of `updateRequestWithApproov`: `request`, `decision`, `sdkMessage` and `error`, each `public internal(set)`.

## ApproovFetchDecision

```swift
enum ApproovFetchDecision
```

`ShouldProceed` (send the protected request), `ShouldRetry` (a network failure the user can retry), `ShouldFail` (do not send the request) and `ShouldIgnore` (send the request unchanged).

## ApproovRequestMutations

```swift
class ApproovRequestMutations
```

What the package changed on a request, given to `handleInterceptorProcessedRequest`: `getTokenHeaderKey()` and `setTokenHeaderKey(_:)`, `getTraceIDHeaderKey()` and `setTraceIDHeaderKey(_:)`, `getSubstitutionHeaderKeys()` and `setSubstitutionHeaderKeys(_:)`, `getOriginalURL()`, `getSubstitutionQueryParamKeys()`, and `setSubstitutionQueryParamResults(originalURL:substitutionQueryParamKeys:)`. A header or query parameter is listed as substituted only when it got a real secure string.

## ApproovDefaultMessageSigning

```swift
class ApproovDefaultMessageSigning: ApproovServiceMutator
```

The message signer, a service mutator with the `CLOSE_FAILURE` decisions. See [message signing](ADVANCED.md#message-signing).

- `init()`, then `setDefaultFactory(_:)` for every protected host, and `putHostFactory(hostName:factory:)` for one host.
- `static func generateDefaultSignatureParametersFactory(baseParametersOverride: SignatureParameters? = nil) -> SignatureParametersFactory`: the default factory.
- `handleInterceptorProcessedRequest(_:changes:)` signs the request. `handleInterceptorFetchTokenResult(_:url:)` makes the `CLOSE_FAILURE` decision. `processedRequest(_:changes:)` is deprecated: use `handleInterceptorProcessedRequest`.
- Constants: `DIGEST_SHA256` (`"sha-256"`), `DIGEST_SHA512` (`"sha-512"`), `ALG_ES256` (`"ecdsa-p256-sha256"`, the install signature) and `ALG_HS256` (`"hmac-sha256"`, the account signature).

## SignatureParametersFactory

```swift
class SignatureParametersFactory
```

Builds the signature parameters for each request. Each method returns the factory, so that you can chain them.

- `setBaseParameters(_:)`: the base components, `@method` and `@target-uri` by default.
- `setBodyDigestConfig(_:required:) throws`: the body digest algorithm, or `nil` for none. Throws `ApproovError.permanentError` for an algorithm that is not `DIGEST_SHA256` or `DIGEST_SHA512`.
- `setUseInstallMessageSigning()`, `setUseAccountMessageSigning()`, `setUseInstallAndAccountMessageSigning()`: the signatures to send.
- `setAddCreated(_:)` and `setExpiresLifetime(_:)`: the `created` time, and the `expires` lifetime in seconds.
- `setAddApproovTokenHeader(_:)` and `setAddApproovTraceIDHeader(_:)`: cover the token and trace headers.
- `addOptionalHeaders(_:)`: headers to cover when they are present.

## ApproovLogLevel

```swift
enum ApproovLogLevel: Int, Comparable
```

`off`, `error`, `warning`, `info` and `debug`, for `setLoggingLevel(_:)`.

## ApproovPinningVerifier

```swift
static func verifyPinning(sec_protocol_metadata: sec_protocol_metadata_t) -> Bool
```

The connection validation that the package installs in AsyncHTTPClient. An app does not call it.
