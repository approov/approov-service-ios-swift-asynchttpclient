# Approov Service for AsyncHTTPClient

![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-13%2B-000000?logo=apple&logoColor=white)
![SwiftPM](https://img.shields.io/github/v/tag/approov/approov-service-ios-swift-asynchttpclient?logo=swift&logoColor=white&label=SwiftPM&color=F05138)
![Message Signing](https://img.shields.io/badge/Message%20Signing-RFC%209421-1f6feb)
![Build](https://github.com/approov/approov-service-ios-swift-asynchttpclient/actions/workflows/build_and_test.yml/badge.svg)

A wrapper for the [Approov SDK](https://github.com/approov/approov-ios-sdk) to enable easy integration when using [`AsyncHTTPClient`](https://github.com/swift-server/async-http-client) for making the API calls that you wish to protect with Approov. In order to use this you will need a trial or paid [Approov](https://www.approov.io) account.

This page provides the steps for integrating Approov into your app. Additionally, a step-by-step tutorial guide using our [Shapes App Example](https://github.com/approov/quickstart-ios-swift-asynchttpclient/blob/master/SHAPES-EXAMPLE.md) is also available.

To follow this guide you should have received an onboarding email for a trial or paid Approov account.

## ADDING APPROOV SERVICE DEPENDENCY
The Approov integration is available via the [Swift Package Manager](https://www.swift.org/package-manager/). This allows inclusion into the project by adding a dependency on the `ApproovAsyncHTTPClient` package in Xcode. In the search box of the add packages dialog, enter the URL of the git repository `https://github.com/approov/approov-service-ios-swift-asynchttpclient.git` and choose the version you wish to use.

The `ApproovAsyncHTTPClient` package is an open-source wrapper layer that allows you to easily use Approov with AsyncHTTPClient. It has a further dependency on the closed-source [`Approov` iOS SDK](https://github.com/approov/approov-ios-sdk).

Once added, import the module wherever you use it:

```swift
import ApproovAsyncHTTPClient
import Approov
```

The primary client type is `ApproovHTTPClient`, while `ApproovService` provides lower-level configuration and direct SDK helper methods.

## INITIALIZING APPROOV SERVICE
In order to use the `ApproovService` you must initialize it when your app is created, before constructing any `ApproovHTTPClient`. Initialization can fail (bad config, SDK error) and `initialize(config:)` is a throwing call, so wrap it in `do/catch` and make sure your app survives a failure rather than crashing:

```swift
import ApproovAsyncHTTPClient
import Foundation
import os

let log = Logger(subsystem: "com.yourcompany.yourapp", category: "approov")

// An app-generated id used to correlate this install/session across your own app logs and
// your backend. Use a UUID, or any session/user identifier you already have — it is NOT an
// Approov secret.
let correlationId = UUID().uuidString

do {
    try ApproovService.initialize(config: "<enter-your-config-string-here>")
    // Confirm Approov is actually active before treating it as enabled, then log identifiers
    // for correlation / observability.
    if ApproovService.isApproovEnabled() {
        let deviceID = ApproovService.getDeviceID() ?? "unknown"
        log.info("Approov initialized; deviceID=\(deviceID, privacy: .public) session=\(correlationId, privacy: .public)")
    } else {
        log.notice("Approov initialized in bypass mode (no protection); session=\(correlationId, privacy: .public)")
    }
} catch {
    // Initialization failed — log it and continue UNPROTECTED so the app still works.
    // Re-initializing with an empty config string enters bypass mode (initialized, but no
    // Approov token injection, pinning, or secret substitution).
    log.error("Approov init failed (session=\(correlationId, privacy: .public)); continuing unprotected: \(String(describing: error), privacy: .public)")
    try? ApproovService.initialize(config: "")
}
```

The `<enter-your-config-string-here>` is a custom string that configures your Approov account access. This will have been provided in your Approov onboarding email.

On success the example logs the Approov **device ID** (`getDeviceID()`) and an **app-generated session/correlation id** (a UUID, or any session/user identifier you use) so a given install can be correlated across your app logs, backend, and the Approov [Live Metrics](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs). If initialization fails, the example re-initializes with an empty config so the app keeps working — but those requests go out **without Approov protection**, so treat the backend as the enforcement point.

## USING APPROOV SERVICE
Once `ApproovService` is initialized, create an `ApproovHTTPClient` and use it as you would the standard `AsyncHTTPClient` `HTTPClient`. The wrapper automatically applies Approov token fetching, secure string substitution, message signing, and dynamic pinning to the requests it processes:

```swift
import ApproovAsyncHTTPClient
import AsyncHTTPClient
import NIOPosix

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let client = ApproovHTTPClient(eventLoopGroupProvider: .shared(group))

// Perform a request — the Approov-Token header, substitutions, and pinning are applied automatically.
let response = try client.get(url: "https://api.example.com/hello").wait()
print(response.status)

try client.syncShutdown()
try group.syncShutdownGracefully()
```

For API domains that are configured to be protected with an Approov token, this adds the `Approov-Token` header and pins the connection. This may also substitute header values when using secrets protection. Unprotected and excluded domains are forwarded unchanged.

### Error Messages
The `ApproovService` functions may throw an `ApproovError` to provide additional information:

* `permanentError`: Feature is not enabled or a configuration feature is unsupported.
* `rejectionError`: Attestation has been rejected. The `ARC` and `rejectionReasons` may contain specific device information that would help troubleshooting.
* `networkingError`: Generally can be retried since it is a temporary network issue.
* `pinningError`: Certificate pinning validation error.
* `configurationError`: Configuration feature is disabled or wrongly configured (e.g. attempting to initialize with a different configuration from a previous initialization).
* `initializationFailure`: ApproovService failed to initialize.

## CHECKING IT WORKS
Initially you won't have set which API domains to protect, so the wrapper will not add anything. It will have called Approov though and made contact with the Approov cloud service. You will see logging from Approov saying `UNKNOWN_URL`.

Your Approov onboarding email should contain a link allowing you to access [Live Metrics Graphs](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs). After you've run your app with Approov integration you should be able to see the results in the live metrics within a minute or so. At this stage you could even release your app to get details of your app population and the attributes of the devices they are running upon.

## NEXT STEPS
To actually protect your APIs and/or secrets there are some further steps. Approov provides two different options for protection:

* [API PROTECTION](https://github.com/approov/quickstart-ios-swift-asynchttpclient/blob/master/API-PROTECTION.md): You should use this if you control the backend API(s) being protected and are able to modify them to ensure that a valid Approov token is being passed by the app. An [Approov Token](https://approov.io/docs/latest/approov-usage-documentation/#approov-tokens) is a short-lived cryptographically signed JWT proving the authenticity of the call.

* [SECRETS PROTECTION](https://github.com/approov/quickstart-ios-swift-asynchttpclient/blob/master/SECRETS-PROTECTION.md): This allows app secrets, including API keys for 3rd party services, to be protected so that they no longer need to be included in the released app code. These secrets are only made available to valid apps at runtime.

Note that it is possible to use both approaches side-by-side in the same app.

---

## Useful Links

- [Approov SDK](https://github.com/approov/approov-ios-sdk)
- [AsyncHTTPClient Documentation](https://github.com/swift-server/async-http-client)
- [Approov Website](https://www.approov.io)
- [Quickstart Guide](https://github.com/approov/quickstart-ios-swift-asynchttpclient)
- [Shapes App Example](https://github.com/approov/quickstart-ios-swift-asynchttpclient/blob/master/SHAPES-EXAMPLE.md)
- [Changelog](CHANGELOG.md)
- [Reference Documentation](REFERENCE.md)
- [Usage Guide](USAGE.md)
