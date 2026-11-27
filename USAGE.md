# Usage

This document describes the features and functionality of the Approov Service for AsyncHTTPClient. It explains how to initialize the service, use the `ApproovHTTPClient` wrapper for protected requests, and configure optional features such as token binding, secure string substitution, exclusion rules, custom service mutators, and HTTP message signing. For a basic integration example, please refer to the [Quickstart guide](https://github.com/approov/quickstart-ios-swift-asynchttpclient).

## Swift Package Manager Import

```swift
import ApproovAsyncHTTPClient
```

## Basic Integration

For most integrations, you initialize `ApproovService` once at app startup and then create an `ApproovHTTPClient` for your protected HTTP traffic.

```swift
import ApproovAsyncHTTPClient
import AsyncHTTPClient

// Initialize the Approov service. Initialization can fail (bad config / SDK error), so guard it
// and fall back to bypass mode (empty config) rather than letting the app crash. See the README
// "Initializing Approov Service" section for the full pattern.
do {
    try ApproovService.initialize(config: "<config-string>")
} catch {
    // Continue without protection. Requests go out without Approov protection, so the backend is the enforcement point.
    try? ApproovService.initialize(config: "")
}

let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)

// Perform a request - Approov token, substitutions, and pinning are applied automatically
let response = try client.get(url: "https://api.example.com/hello").wait()
print(response.status)

try client.syncShutdown()
```

The wrapper automatically applies Approov token fetching, secure string substitutions, and dynamic pinning to requests it processes.

## Empty Config Initialization

You can initialize the `ApproovService` with an empty configuration string if you want to use the service layer without active Approov protection. This is useful when you want to bypass Approov processing (e.g., during development or testing against local staging environments).

```swift
// Initialize with an empty string to operate in bypass mode
try? ApproovService.initialize(config: "")
```

When initialized with an empty configuration, the service layer operates as a plain pass-through. It will not perform token injection, message signing, secure string substitution, or dynamic pinning. You can enable full Approov protection later in the application lifecycle by calling `ApproovService.initialize(config: config)` with a valid configuration string.

---

# Approov Service Mutator

The `ApproovServiceMutator` protocol allows you to customize the behavior of the Approov service layer at key points in the request lifecycle. By implementing a custom mutator, you can override specific methods to tailor the handling of attestations, network failures, and requests while retaining the default behavior for other cases.

## Why Use a Mutator?

- Centralize app-specific policy without modifying the library source code.
- Add telemetry/logging on rejections or network failures.
- Skip Approov processing for specific hosts or endpoints.
- Customize pinning decisions per request.
- Adjust behavior when token or secure string fetches fail.
- Implement HTTP message signing.

## Default Behavior

By default, the `ApproovService` processes requests based on the attestation status. The default behavior is summarized in the table below:

| Approov Fetch Status | Action | Result |
| :--- | :--- | :--- |
| **Success** | Proceed | The request is sent with the configured Approov token header. |
| **No Network / Poor Network / MITM Detected** | Fail | The request fails with `ApproovError.networkingError`. With `setUseApproovStatusIfNoToken(shouldUse: true)`, the request proceeds with the status name in the token header. |
| **No Approov Service** | Proceed | The request is sent with an empty `Approov-Token` header. |
| **Unknown URL / Unprotected URL** | Proceed | The request is sent **without** an `Approov-Token`. |
| **Any other status, such as Rejected** | Fail | The request fails with `ApproovError.permanentError`. |

This default is the `CLOSE_FAILURE` mutator. A failed token fetch only affects requests to your Approov API domains. A request to any other host is sent unchanged. To send every request and let your backend decide, install the `ALWAYS_PROCEED` mutator:

```swift
ApproovService.setServiceMutator(.ALWAYS_PROCEED)
```

## Customizing Request Handling with Mutators

You may want to modify this behavior to suit specific app requirements. A common use case is handling network failures or enforcing strict token presence.

### Example: Enforcing Token Presence (Block on NO_APPROOV_SERVICE)

The default behavior for statuses like `NO_APPROOV_SERVICE` is to proceed with the request with an empty Approov token header. If you want to ensure that *only* requests with valid proof of attestation reach your backend API, you can enforce this with a custom mutator:

```swift
import ApproovAsyncHTTPClient
import Approov

final class EnforceTokenMutator: ApproovServiceMutator {
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
        // If the service is not available, do not proceed.
        // We throw a networking error to trigger a retry.
        if approovResults.status == .noApproovService {
            throw ApproovError.networkingError(message: "Approov service unavailable. Will attempt connection again.")
        }

        // For all other statuses, use the default behavior.
        return try ApproovCloseFailureMutator.CLOSE_FAILURE.handleInterceptorFetchTokenResult(approovResults, url: url)
    }
}

// Install the mutator
ApproovService.setServiceMutator(EnforceTokenMutator())
```

### Example: Customizing Requests (Add Metadata Headers)

You can override `handleInterceptorProcessedRequest` to add additional headers or modify the request after Approov has processed it.

```swift
final class MyMutator: ApproovServiceMutator {
    func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                           changes: ApproovRequestMutations) throws -> ApproovRequest {
        var req = request
        req.headers.replaceOrAdd(name: "Client-Platform", value: "ios")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            req.headers.replaceOrAdd(name: "App-Version", value: version)
        }
        return req
    }
}
```

---

# Message Signing

It is possible to sign HTTP requests using Approov to ensure message integrity and authenticity. There are two types of message signing available:

1.  **Installation Message Signing**: Uses an installation-specific key to sign requests. The key is held in secure hardware where the device has it. The key is unique to the installation and does not leave the device.
2.  **Account Message Signing**: Uses a shared account-specific secret key (HMAC-SHA256) to sign requests. This key is delivered to the SDK only upon successful attestation.

The default mutator, `CLOSE_FAILURE`, does no message signing. Even if you install `ApproovDefaultMessageSigning`, a signature is only added when:
- The request already has an `Approov-Token` header.
- A `SignatureParametersFactory` is configured (default or host-specific).

## Enable Message Signing with Default Settings

```swift
let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
ApproovService.setServiceMutator(signer)
```

The signer makes the standard decisions, the same as `CLOSE_FAILURE`. To sign under other decisions, use [`combined(decisions:)`](#sign-with-other-decisions).

When a signature cannot be produced, the request goes ahead with the other signature or unsigned. The package logs a missing install or account signature as a warning once per process, such as `ApproovService: install message signature unavailable, signed without it`. It logs a request sent unsigned as an error once per process, such as `ApproovService: no message signature could be produced, proceeding unsigned: ...`. It logs later occurrences at `.debug`.

## Sign with Other Decisions

`ApproovDefaultMessageSigning.combined(decisions:)` returns a signer that adds both the install and the account signature. It makes the decisions of `decisions`: `.CLOSE_FAILURE`, `.ALWAYS_PROCEED`, `.DEFAULT` or a mutator of your own. `combined()` uses `.DEFAULT`, the same as `.CLOSE_FAILURE`. Your backend can use the install signature only if the Approov token carries the install public key. Turn that on for your account with `approov policy -setInstallPubKey on` (see [installation message signing](https://docs.approov.io/operations/message-signing/installation/)). Each call returns a new `ApproovDefaultMessageSigning`, so `setDefaultFactory(_:)` and `putHostFactory(hostName:factory:)` on it change only that signer.

```swift
ApproovService.setServiceMutator(ApproovDefaultMessageSigning.combined(decisions: .CLOSE_FAILURE))

ApproovService.setServiceMutator(ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED))
```

## Custom Message Signing Parameters

```swift
let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
    .setUseAccountMessageSigning() // or setUseInstallMessageSigning()
    .setAddCreated(true)
    .setExpiresLifetime(60)

let signer = ApproovDefaultMessageSigning()
    .setDefaultFactory(factory)
    .putHostFactory(hostName: "api.example.com", factory: factory)

ApproovService.setServiceMutator(signer)
```

## Target URI

The signature covers the target URI of the request as AsyncHTTPClient sends it, without the fragment and without the default port of the scheme. So `https://api.example.com:443/v1` and `https://api.example.com/v1` give the same signature.

## Body Digest

The default factory adds a SHA-256 `Content-Digest` of the request body to the signature. To compute it, the package reads the body before the send. The closure of an `HTTPClient.Body.stream(length:)` body then runs one more time, so each call must write the same bytes. Without a body digest, the package does not call the body closure before the send. To turn the digest off:

```swift
let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
    .setBodyDigestConfig(nil, required: false)
```

---

# Secure Strings

The package can replace a placeholder value in a header or a query parameter with a secure string from Approov. Add each header or query parameter that carries a placeholder. The package replaces the placeholder only on https to an Approov API domain. If the secure string fetch fails, the status name replaces the placeholder, such as `Api-Key: REJECTED`.

```swift
ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
ApproovService.addSubstitutionQueryParam(key: "api_key")
```

---

# Exclusions

To send some requests without Approov processing, add a regular expression for their URLs. The package sends a request whose URL matches the expression unchanged.

```swift
ApproovService.addExclusionURLRegex(urlRegex: "^https://example\\.com/unprotected/.*$")
```

---

# Token Binding

Token Binding allows you to bind the Approov token to a specific piece of data, such as an OAuth token or a user session identifier.

```swift
// Bind the Approov token to the Authorization header
ApproovService.bindHeader = "Authorization"
```

If the value of the binding header changes (e.g., a new OAuth token is received), the SDK automatically invalidates the current Approov token and fetches a new one with the updated binding on the next request.

The package finds the binding header without regard to case. Requests in flight at the same time with different binding values each have a token bound to their own value.

---

# Use Approov Status as Token

If an actual token cannot be obtained, you can configure the service to send the Approov fetch status (e.g., `NO_NETWORK`, `MITM_DETECTED`, `NO_APPROOV_SERVICE`) as the token header value. This allows your backend to distinguish between different failure reasons.

```swift
// Enable status-as-token injection
ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
```

With this setting, the default mutator lets `NO_NETWORK`, `POOR_NETWORK` and `MITM_DETECTED` proceed with the status name in the token header. A request after `NO_APPROOV_SERVICE` also carries the status name.

---

# Logging

You can customize the log level emitted by the `ApproovService` with `setLoggingLevel(_:)`:

```swift
ApproovService.setLoggingLevel(.debug)
```

Available levels are:
*   `.off`: Disables all logging from the `ApproovService` package.
*   `.error`: Only logs critical errors.
*   `.warning`: Logs warnings and errors.
*   `.info` (Default): Logs informative events, configuration receipts, and token states.
*   `.debug`: Logs highly verbose tracing information.

---

# Connection Validation

`ApproovHTTPClient` validates the connection against the Approov pins in the TLS handshake on Network.framework. The validation runs only on a `NIOTSEventLoopGroup`, only with `.fullVerification`, and only without a proxy. While Approov is enabled, the client refuses each request with `URLError(.unknown)` in these cases:

* an `ApproovHTTPClient` made with an event loop group that is not a `NIOTSEventLoopGroup`, such as `MultiThreadedEventLoopGroup`
* a `delegateAndChannel` event loop preference with an event loop that is not a NIOTS event loop
* a client or request TLS configuration whose `certificateVerification` is not `.fullVerification`
* a client configuration with a proxy (`HTTPClient.Configuration.proxy`)

In bypass mode, these clients work.

# Redirects

`ApproovHTTPClient` follows redirects itself, with your `redirectConfiguration`, and protects each hop as a new request for its target. Nothing that the package added reaches another origin.

# WebSockets

WebSockets are not supported. A request with `Upgrade: websocket` is sent unchanged.
