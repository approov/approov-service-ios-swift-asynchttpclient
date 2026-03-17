# Reference

This provides a reference for the main public APIs exposed by the Approov Service for AsyncHTTPClient. These are available when you import the Swift Package Manager module:

```swift
import ApproovAsyncHTTPClient
import Approov
```

## Main Types

- `ApproovHTTPClient`: High-level AsyncHTTPClient wrapper that applies Approov protection to requests.
- `ApproovService`: Static configuration and direct SDK helper API.
- `ApproovPinningVerifier`: Pin verification helper used by the service layer for dynamic pinning.

## Errors

Most throwing methods raise `ApproovError`. The main cases are:

- `networkingError`: A temporary networking issue; offer a retry.
- `rejectionError`: Attestation rejected; includes rejection details where available.
- `permanentError` / `configurationError` / `initializationFailure` / `runtimeError`: Non-retryable in normal flows.

## ApproovHTTPClient

`ApproovHTTPClient` mirrors the upstream AsyncHTTPClient API while automatically protecting requests with Approov.

### init(eventLoopGroupProvider:configuration:)
Creates an `ApproovHTTPClient` using the supplied event loop group provider and optional AsyncHTTPClient configuration.

```swift
let client = ApproovHTTPClient(eventLoopGroupProvider: .shared(group))
```

### get / post / patch / put / delete
Convenience methods for common HTTP verbs. These return `EventLoopFuture<HTTPClient.Response>`.

```swift
let response = try client.get(url: "https://api.example.com").wait()
let response = try client.post(url: "https://api.example.com").wait()
```

### execute(...)
`ApproovHTTPClient` also exposes the main `execute` overloads from AsyncHTTPClient for custom requests, including `HTTPClient.Request` and delegate-based execution. Use these when you need full request control.

```swift
let request = try HTTPClient.Request(url: "https://api.example.com", method: .GET)
let response = try client.execute(request: request).wait()
```

### syncShutdown / shutdown
Shuts down the wrapped AsyncHTTPClient.

```swift
try client.syncShutdown()
client.shutdown { error in
    print(error as Any)
}
```

## ApproovService

### initialize
Initializes the SDK with the config obtained using `approov sdk -getConfigString` or in the original onboarding email. Repeated calls with the same config are ignored when `comment` is `nil`. If `comment` is non-`nil`, the call is passed through to the underlying SDK again. If the SDK has already been initialized by another service layer, the corresponding SDK error is logged and ignored.

```swift
try ApproovService.initialize(config: "<config-string>")
try ApproovService.initialize(config: "<config-string>", comment: "reinit:example-option")
```

### proceedOnNetworkFail
Controls whether requests should proceed when Approov cannot fetch due to temporary network failures.

```swift
ApproovService.proceedOnNetworkFail = true
let proceed = ApproovService.proceedOnNetworkFail
```

### bindHeader
Sets the header whose value is hashed into the Approov token for token binding.

```swift
ApproovService.bindHeader = "Authorization"
let header = ApproovService.bindHeader
```

### approovTokenHeaderAndPrefix
Sets the header name used for the Approov token and an optional prefix.

```swift
ApproovService.approovTokenHeaderAndPrefix = (
    approovTokenHeader: "Approov-Token",
    approovTokenPrefix: ""
)
```

### setDevKey
Sets a development key used for development and testing flows.

```swift
ApproovService.setDevKey(devKey: "<dev-key>")
```

### prefetch
Starts an early background token fetch after initialization.

```swift
ApproovService.prefetch()
```

### updateRequest
Updates a URL and `HTTPHeaders` collection with Approov protection and secure string substitutions.

```swift
let (updatedURL, updatedHeaders) = try ApproovService.updateRequest(url: url, headers: headers)
```

### addSubstitutionHeader
Adds a header that should have its value treated as a secure string lookup key.

```swift
ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
ApproovService.addSubstitutionHeader(header: "Authorization", prefix: "Bearer ")
```

### removeSubstitutionHeader
Removes a header previously configured for secure string substitution.

```swift
ApproovService.removeSubstitutionHeader(header: "Api-Key")
```

### substituteQueryParam
Substitutes a single query parameter value in a URL using a secure string lookup.

```swift
let updatedURL = try ApproovService.substituteQueryParam(url: url, queryParameter: "api_key")
```

### addSubstitutionQueryParam
Adds a query parameter key for secure string substitution.

```swift
ApproovService.addSubstitutionQueryParam(key: "api_key")
```

### removeSubstitutionQueryParam
Removes a query parameter key previously added for substitution.

```swift
ApproovService.removeSubstitutionQueryParam(key: "api_key")
```

### addExclusionURLRegex
Adds an exclusion URL regular expression. Matching URLs bypass all Approov processing.

```swift
ApproovService.addExclusionURLRegex(urlRegex: "^https://example\.com/public/.*$")
```

### removeExclusionURLRegex
Removes a previously added exclusion URL regular expression.

```swift
ApproovService.removeExclusionURLRegex(urlRegex: "^https://example\.com/public/.*$")
```

### getDeviceID
Returns the device ID used by Approov for this app installation.

```swift
let deviceId = try ApproovService.getDeviceID()
```

### setDataHashInToken
Directly sets the data hash to be included in subsequently fetched Approov tokens.

```swift
ApproovService.setDataHashInToken(data: "<data-to-hash>")
```

### fetchToken
Fetches an Approov token for the supplied URL.

```swift
let token = try ApproovService.fetchToken(url: "https://api.example.com")
```

### getMessageSignature
Returns an account message signature if the feature is enabled and key material is available.

```swift
let signature = try ApproovService.getMessageSignature(message: "example-message")
```

### fetchSecureString
Fetches or defines a secure string.

```swift
let value = try ApproovService.fetchSecureString(key: "api_key", newDef: nil)
let defined = try ApproovService.fetchSecureString(key: "tenant-key", newDef: "secret-value")
```

### fetchCustomJWT
Fetches a custom JWT with the supplied JSON payload.

```swift
let jwt = try ApproovService.fetchCustomJWT(payload: "{\"claims\":{}}")
```

### precheck
Performs a precheck to determine if the app will pass attestation.

```swift
try ApproovService.precheck()
```

### getLastARC
Returns the last Attestation Response Code when available.

```swift
let arc = ApproovService.getLastARC()
```

## ApproovPinningVerifier

### verifyPinning(sec_protocol_metadata:)
Advanced pinning integration point for use with custom TLS handling.

```swift
let isPinned = ApproovPinningVerifier.verifyPinning(sec_protocol_metadata: metadata)
```
