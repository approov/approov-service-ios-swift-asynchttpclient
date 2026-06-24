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
import NIOPosix

// Initialize the Approov service. Initialization can fail (bad config / SDK error), so guard it
// and fall back to bypass mode (empty config) rather than letting the app crash. See the README
// "INITIALIZING APPROOV SERVICE" section for the full pattern (device-ID + session correlation logging).
do {
    try ApproovService.initialize(config: "<config-string>")
} catch {
    // Continue UNPROTECTED — requests go out without Approov protection; the backend stays the enforcement point.
    try? ApproovService.initialize(config: "")
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let client = ApproovHTTPClient(eventLoopGroupProvider: .shared(group))

// Perform a request - Approov token, substitutions, and pinning are applied automatically
let response = try client.get(url: "https://api.example.com/hello").wait()
print(response.status)

try client.syncShutdown()
try group.syncShutdownGracefully()
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
| **No Network / Poor Network / MITM Detected** | Throw Exception | An `ApproovError.networkingError` is thrown. The request is marked as `.ShouldRetry`. |
| **Rejection** | Throw Exception | An `ApproovError.rejectionError` is thrown. The request is marked as `.ShouldFail`. |
| **No Approov Service / Unknown URL** | Proceed | The request is sent **without** an `Approov-Token`. |

## Customizing Request Handling with Mutators

You may want to modify this behavior to suit specific app requirements. A common use case is handling network failures or enforcing strict token presence.

### Example: Enforcing Token Presence (Block on NO_APPROOV_SERVICE)

The default behavior for statuses like `NO_APPROOV_SERVICE` is to proceed with the request without adding an Approov token. If you want to ensure that *only* requests with valid proof of attestation reach your backend API, you can enforce this with a custom mutator:

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
        return try ApproovServiceMutatorDefault.shared.handleInterceptorFetchTokenResult(approovResults, url: url)
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

1.  **Installation Message Signing**: Uses an installation-specific key (held in the device's Secure Enclave) to sign requests. This provides strong non-repudiation as the signing key is unique to that specific installation and never leaves the device.
2.  **Account Message Signing**: Uses a shared account-specific secret key (HMAC-SHA256) to sign requests. This key is delivered to the SDK only upon successful attestation.

By default, the `ApproovService` uses the class `ApproovServiceMutatorDefault`, which does no message signing. Even if you install `ApproovDefaultMessageSigning`, a signature is only added when:
- The request already has an `Approov-Token` header.
- A `SignatureParametersFactory` is configured (default or host-specific).

## Enable Message Signing with Default Settings

```swift
let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
ApproovService.setServiceMutator(signer)
```

## Custom Message Signing Parameters

```swift
let factory = SignatureParametersFactory()
    .setUseAccountMessageSigning() // or setUseInstallMessageSigning()
    .setAddCreated(true)
    .setExpiresLifetime(60)

let signer = ApproovDefaultMessageSigning()
    .setDefaultFactory(factory)
    .putHostFactory(hostName: "api.example.com", factory: factory)

ApproovService.setServiceMutator(signer)
```

---

# Token Binding

Token Binding allows you to bind the Approov token to a specific piece of data, such as an OAuth token or a user session identifier.

```swift
// Bind the Approov token to the Authorization header
ApproovService.bindHeader = "Authorization"
```

If the value of the binding header changes (e.g., a new OAuth token is received), the SDK automatically invalidates the current Approov token and fetches a new one with the updated binding on the next request.

---

# Use Approov Status as Token

If an actual token cannot be obtained, you can configure the service to send the Approov fetch status (e.g., `NO_NETWORK`, `MITM_DETECTED`, `NO_APPROOV_SERVICE`) as the token header value. This allows your backend to distinguish between different failure reasons.

```swift
// Enable status-as-token injection
ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
```

To ensure the request actually proceeds to the backend on these failure paths, you must use a custom `ApproovServiceMutator` that returns `true` for these statuses:

```swift
final class StatusAsTokenMutator: ApproovServiceMutator {
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
        let status = approovResults.status
        if status == .mitmDetected || status == .noApproovService || status == .success {
            return true
        }
        return try ApproovServiceMutatorDefault.shared.handleInterceptorFetchTokenResult(approovResults, url: url)
    }
}
ApproovService.setServiceMutator(StatusAsTokenMutator())
```

---

# Logging

You can customize the log level emitted by the `ApproovService` using the static property `loggingLevel`:

```swift
ApproovService.loggingLevel = .debug
```

Available levels are:
*   `.off`: Disables all logging from the `ApproovService` package.
*   `.error`: Only logs critical errors.
*   `.warning`: Logs warnings and errors.
*   `.info` (Default): Logs informative events, configuration receipts, and token states.
*   `.debug`: Logs highly verbose tracing information.
