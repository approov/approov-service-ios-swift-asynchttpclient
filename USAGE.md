# Usage

This document describes the features and functionality of the Approov Service for AsyncHTTPClient. It explains how to initialize the service, use the `ApproovHTTPClient` wrapper for protected requests, and configure optional features such as token binding, secure string substitution, exclusion rules, and direct SDK helper calls. For a basic integration example, please refer to the [Quickstart guide](https://github.com/approov/quickstart-ios-swift-asynchttpclient).

## Swift Package Manager Import

```swift
import ApproovAsyncHTTPClient
import Approov
```

## Basic Integration

For most integrations you initialize `ApproovService` once at app startup and then create an `ApproovHTTPClient` for your protected HTTP traffic.

```swift
import ApproovAsyncHTTPClient
import AsyncHTTPClient
import NIOPosix

try ApproovService.initialize(config: "<config-string>")

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let client = ApproovHTTPClient(eventLoopGroupProvider: .shared(group))

let response = try client.get(url: "https://api.example.com/hello").wait()
print(response.status)

try client.syncShutdown()
try group.syncShutdownGracefully()
```

The wrapper automatically applies Approov token fetching, secure string substitutions, and dynamic pinning to requests it processes.

## Manual Request Protection

If you need lower-level control, you can update a URL and headers yourself before sending the request through your own AsyncHTTPClient flow.

```swift
import ApproovAsyncHTTPClient
import NIOHTTP1

let url = URL(string: "https://api.example.com/v1/data?api_key=api-key-placeholder")!
var headers = HTTPHeaders()
headers.add(name: "Api-Key", value: "api-key-placeholder")

let (updatedURL, updatedHeaders) = try ApproovService.updateRequest(url: url, headers: headers)
```

`updateRequest(url:headers:)` is a blocking call and should not be made on the main/UI thread.

## Default Behavior

By default, the `ApproovService` processes requests based on the attestation status returned by the SDK. A successful fetch adds the configured Approov token header, and secure string substitutions are applied only when it is safe to continue.

| Approov Fetch Status | Action | Result |
| :--- | :--- | :--- |
| **Success** | Proceed | The request is sent with the configured Approov token header. |
| **No Network / Poor Network / MitM Detected** | Throw Exception | An `ApproovError.networkingError` is thrown unless `proceedOnNetworkFail` is enabled. |
| **No Approov Service / Unknown URL / Unprotected URL** | Proceed | The request is sent without an Approov token. |
| **Rejected / Other Permanent Errors** | Throw Exception | An `ApproovError.rejectionError` or `ApproovError.permanentError` is thrown. |

## Multiple Service Layers

It is possible to use more than one Approov service layer in the same app, for example the AsyncHTTPClient and URLSession packages together. The underlying Approov SDK can only be initialized once, so if another service layer later calls `ApproovService.initialize(...)` with the same configuration, the duplicate SDK initialization is detected and ignored.

In that case you may see a log entry similar to:

```text
ApproovService: Ignoring initialization error in Approov SDK: The operation couldn’t be completed. (Foundation._GenericObjCError error 0.)
```

This log is informational only. Execution continues and this condition is not surfaced as an exception. If a later initialization attempts to use a different configuration, that is still treated as a real configuration error.

## Reinitialization with a Comment

If you call `ApproovService.initialize(config:comment:)` with a non-`nil` comment, the service layer allows the initialization call to reach the underlying SDK again. This is useful for SDK options such as comments beginning with `reinit:` that trigger internal SDK reconfiguration.

```swift
try ApproovService.initialize(config: "<config-string>", comment: "reinit:example-option")
```

## Proceed on Network Failure

By default, transient network issues prevent the protected request from being sent because the app cannot safely obtain a token or secure strings. If you prefer to let requests continue without the Approov token in those cases, set:

```swift
ApproovService.proceedOnNetworkFail = true
```

Use this with caution because it may allow traffic to proceed before dynamic pins have been refreshed.

## Token Binding

[Token Binding](https://ext.approov.io/docs/latest/approov-usage-documentation/#token-binding) allows you to bind the Approov token to a specific header value, such as an OAuth token or session identifier.

```swift
ApproovService.bindHeader = "Authorization"
```

If the binding header value changes, the SDK automatically invalidates the previous Approov token and fetches a new one on the next protected request.

## Custom Approov Token Header

By default, the token is added as `Approov-Token` with no prefix. You can override both the header name and an optional prefix.

```swift
ApproovService.approovTokenHeaderAndPrefix = (
    approovTokenHeader: "Authorization",
    approovTokenPrefix: "Bearer "
)
```

## Secure String Header Substitution

Header substitution lets you use placeholder values in headers and have them replaced with secure strings fetched from Approov.

```swift
ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
ApproovService.addSubstitutionHeader(header: "Authorization", prefix: "Bearer ")
```

Once configured, any matching header value is treated as a secure string lookup key.

## Secure String Query Parameter Substitution

Query parameter substitution works similarly for URL query values.

```swift
ApproovService.addSubstitutionQueryParam(key: "api_key")
```

For example, a request like `https://api.example.com?api_key=my-placeholder` can have `my-placeholder` replaced with the secure string value returned by Approov.

## Exclusion URL Regexes

You can exclude selected URLs from all Approov processing.

```swift
ApproovService.addExclusionURLRegex(urlRegex: "^https://example\.com/public/.*$")
```

This should be used with extreme caution because excluded requests do not create a path for refreshing dynamic pins.

## Dynamic Pinning

Dynamic certificate pinning is enabled automatically during `ApproovService.initialize(...)`. The service layer installs `ApproovPinningVerifier.verifyPinning` into AsyncHTTPClient's TLS configuration so protected hosts can be verified against the latest Approov-managed pins.

For advanced integrations, the verifier is also available directly if you need to wire it into custom TLS handling.

## Direct SDK Helper Calls

The service layer also exposes direct helper methods for specific workflows:

- `try ApproovService.precheck()` to see whether the current app instance is likely to pass attestation.
- `let token = try ApproovService.fetchToken(url: "https://api.example.com")` when you need a token outside the normal request flow.
- `let value = try ApproovService.fetchSecureString(key: "api-key", newDef: nil)` to fetch or define secure strings.
- `let jwt = try ApproovService.fetchCustomJWT(payload: "{\"claim\":true}")` to fetch a custom JWT.
- `let signature = try ApproovService.getMessageSignature(message: "example-message")` for account message signing when enabled in the Approov account.
- `let arc = ApproovService.getLastARC()` to retrieve the last Attestation Response Code when meaningful.

## Real-World Pattern

A common pattern is to initialize once, configure binding and substitutions, and then reuse a single `ApproovHTTPClient` instance for all protected traffic.

```swift
import ApproovAsyncHTTPClient
import AsyncHTTPClient
import NIOHTTP1
import NIOPosix

try ApproovService.initialize(config: "<config-string>")
ApproovService.bindHeader = "Authorization"
ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
ApproovService.addSubstitutionQueryParam(key: "api_key")

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let client = ApproovHTTPClient(eventLoopGroupProvider: .shared(group))

var request = try HTTPClient.Request(url: "https://api.example.com/v1/data?api_key=my-key", method: .GET)
request.headers.add(name: "Authorization", value: "Bearer <oauth-token>")
request.headers.add(name: "Api-Key", value: "my-key")

let response = try client.execute(request: request).wait()
print(response.status)
```
