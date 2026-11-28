# Approov Service for AsyncHTTPClient

![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-13%2B-000000?logo=apple&logoColor=white)
![SwiftPM](https://img.shields.io/github/v/tag/approov/approov-service-ios-swift-asynchttpclient?logo=swift&logoColor=white&label=SwiftPM&color=F05138)
![Message Signing](https://img.shields.io/badge/Message%20Signing-RFC%209421-1f6feb)
![Build](https://github.com/approov/approov-service-ios-swift-asynchttpclient/actions/workflows/build_and_test.yml/badge.svg)

This package adds [Approov](https://www.approov.io) to an iOS app that uses [`AsyncHTTPClient`](https://github.com/swift-server/async-http-client). After you initialize it, the package adds an Approov token to each request that your app sends to your API domains through an `ApproovHTTPClient`. The token, a signed JWT, provides proof of attestation. Your backend checks it to decide whether to accept or reject the request. A valid token shows that the request came from a genuine, unmodified copy of your app on a device that passed Approov's checks.

The package also checks the TLS connection to each of your API domains. A request goes ahead only if both the operating system and the [Managed Trust Roots](https://docs.approov.io/security-configuration/dynamic-pinning/#managed-trust-roots) configuration in your Approov account trust the connection. [Connection validation](ADVANCED.md#connection-validation) has the details.

## BEFORE YOU START

You need:

* an Approov account, trial or paid, and its [account ID](#your-account-id)
* your API domains [added to Approov](https://docs.approov.io/getting-started/add-api-domains/). The package adds a token only to requests to these domains.

Then follow the steps below. Each step makes the next one possible:

1. [Add the dependency](#adding-the-dependency). This gives your app `ApproovService` and `ApproovHTTPClient`.
2. [Initialize](#initializing) `ApproovService` with your account ID. This turns on Approov protection.
3. [Make your requests](#making-requests) through an `ApproovHTTPClient`. Your requests to your API domains then carry a token.
4. [Look in the debug log](ADVANCED.md#diagnostics) to see that each request receives a token.
5. [Register your app and check tokens on your backend](#next-steps). Until your backend checks the token, your API is not protected.

The [Approov package documentation](https://docs.approov.io/app-integration/packages/overview/) has more background. The [quickstart](https://github.com/approov/quickstart-ios-swift-asynchttpclient) has a step-by-step example app. Optional features are in [ADVANCED.md](ADVANCED.md). Every method is in [REFERENCE.md](REFERENCE.md).

## ADDING THE DEPENDENCY

### Swift Package Manager

In Xcode, choose `File > Add Package Dependencies...`, enter `https://github.com/approov/approov-service-ios-swift-asynchttpclient.git`, choose the dependency rule `Up to Next Major Version` from `3.7.0`, and add the `ApproovAsyncHTTPClient` product to your app target.

In a `Package.swift`, add the package and the product:

```swift
dependencies: [
    .package(url: "https://github.com/approov/approov-service-ios-swift-asynchttpclient.git", from: "3.7.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "ApproovAsyncHTTPClient", package: "approov-service-ios-swift-asynchttpclient")
        ]
    )
]
```

The package is available only through Swift Package Manager. It supports iOS 13 or later. It depends on the closed-source [Approov iOS SDK](https://github.com/approov/approov-ios-sdk) 3.7.0. It also depends on the [Approov fork of AsyncHTTPClient](https://github.com/approov/async-http-client), which runs the Approov connection check in the TLS handshake.

Next, [initialize the package](#initializing).

## INITIALIZING

Initialize `ApproovService` once, when your app starts, with your Approov account ID. Do this before your app sends its first request, for example in `application(_:didFinishLaunchingWithOptions:)`. If your app sends a request through an `ApproovHTTPClient` before `initialize`, the request goes out without Approov protection.

```swift
import ApproovAsyncHTTPClient
import os.log

do {
    // your Approov account ID, from your onboarding email or "approov sdk -getConfigString"
    try ApproovService.initialize(config: "<your-approov-account-id>")
    if ApproovService.isApproovServiceEnabled() && ApproovService.isApproovProtectionEnabled() {
        os_log("Approov initialized; deviceID=%@", ApproovService.getDeviceID() ?? "")
    }
} catch {
    // the value passed was not a valid account ID; run without Approov rather than not at all
    os_log("Approov account ID rejected; starting in bypass mode: %@", error.localizedDescription)
    try? ApproovService.initialize(config: "")
}
// then configure, after initialize (which resets the configuration) and before the
// app issues protected requests; only the settings your app uses, for example:
// ApproovService.setTokenHeader(header: "Authorization", prefix: "Bearer ")
// ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
```

About this example:

* `initialize` throws if the account ID is incomplete or changed. The `catch` block then starts the package in **bypass mode**, by initializing with `""`. In bypass mode the package sends requests without Approov protection. You can also use bypass mode as a feature flag: initialize with `""` to start your app without Approov.
* Logging the installation device ID is optional. Approov identifies an installation only by its device ID. Log it next to your own user or session ID for correlation.
* Make your configuration calls after `initialize`, before the app sends protected requests. Each `initialize` resets the configuration to its defaults, so the package loses a setting made before it. A setting applies only to requests sent after you make it. See [initialize, then configure](ADVANCED.md#initialize-then-configure).

### Your account ID

Your account ID is in your onboarding email. The Approov CLI also shows it at any time, and calls it the SDK config string:

```sh
approov sdk -getConfigString
```

The account ID is the same for every app in your account, and it is not a secret. You can keep it in your source code or deliver it with your app's configuration. The whole value must reach the app unchanged, including its punctuation. See [about the Approov account ID](ADVANCED.md#about-the-approov-account-id).

If the account ID is not available when the app starts, initialize with `""` first. Call `initialize` again when you have the account ID. See [bypass initialization](ADVANCED.md#bypass-initialization).

When the package is initialized, [make your requests](#making-requests) through an `ApproovHTTPClient`.

## MAKING REQUESTS

Use an `ApproovHTTPClient` wherever you would create an `HTTPClient`:

```swift
import ApproovAsyncHTTPClient
import AsyncHTTPClient

let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)

let request = HTTPClientRequest(url: "https://api.example.com/shapes")
let response = try await client.execute(request, timeout: .seconds(30))
print(response.status)
```

`ApproovHTTPClient` has the request methods of `HTTPClient`: `get`, `post`, `patch`, `put`, `delete`, and the `execute` functions in their future, delegate and `async` forms. When your app no longer needs the client, shut it down with `syncShutdown()` or `shutdown(queue:_:)`, as you do for an `HTTPClient`.

Create the client with `.createNew`, or with a shared `NIOTSEventLoopGroup`. Keep TLS certificate verification at `.fullVerification`, and do not set a proxy. The package can check the connection only in that configuration. While Approov is enabled, the client refuses each request with `URLError(.unknown)` in any other configuration. See [connection validation](ADVANCED.md#connection-validation).

For a transport that owns its own `HTTPClient`, call `ApproovService.signRequest(_:)`, which returns a protected copy of an `HTTPClient.Request`. `ApproovService.updateRequestWithApproov(request:)` does the same for an `ApproovRequest` and returns the decision. Give that client `.disallow` as its `redirectConfiguration`, because a plain `HTTPClient` follows a redirect with the protection of the first request. These methods do not check the connection. Both are in [REFERENCE.md](REFERENCE.md).

## CUSTOMIZING THE BEHAVIOUR

[ADVANCED.md](ADVANCED.md) explains how the package behaves and how to customize it:

* [What each request carries](ADVANCED.md#what-each-request-carries), and [what happens when a token fetch fails](ADVANCED.md#what-happens-by-default). By default, a request fails if the device has a network problem. It goes ahead with an empty token header if the app cannot reach the Approov service.
* [Service mutators](ADVANCED.md#service-mutators), which change those decisions. For example, a mutator can send requests without a valid token. It can also fail a request on chosen errors. Your app then receives the `URLError` that the mutator throws and decides what to do, for example retry or show a message.
* [Message signing](ADVANCED.md#message-signing), which you install with one call, for example `ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED)`
* [Header names](ADVANCED.md#header-names), [secure strings](ADVANCED.md#secure-strings), [token binding](ADVANCED.md#token-binding), [excluding URLs](ADVANCED.md#excluding-urls) and [redirects](ADVANCED.md#redirects)
* [Diagnostics](ADVANCED.md#diagnostics), which show the result of each token fetch in the log

Then continue with the [next steps](#next-steps).

## NEXT STEPS

1. [Register your app's signing certificate](https://docs.approov.io/getting-started/add-app-signing-certificates/), so that your release builds pass attestation.
2. [Check tokens on your backend](https://docs.approov.io/getting-started/integrate-backend/), and signatures if you installed message signing. This is the step that protects your API.
3. [Go live](https://docs.approov.io/getting-started/go-live/). Monitor first, then let your backend reject requests without a valid token.

## UPGRADING FROM 3.5.x

Read the [changelog](CHANGELOG.md) for the full list of changes. Test your app and backend together.

### Code changes

These changes came in 3.5.4. An app that already uses 3.5.4 needs no source change for 3.7.0.

* `getDeviceID()` returns `String?` and no longer throws. Remove the `try` and handle `nil`.
* `prefetch()` and `proceedOnNetworkFail` are removed. To send requests after a network failure, use `setServiceMutator(.ALWAYS_PROCEED)`.
* `substituteQueryParam(url:queryParameter:)` is removed. Call `addSubstitutionQueryParam(key:)` once, and the package substitutes the parameter in each request.
* While Approov is enabled, `ApproovHTTPClient` refuses each request with `URLError(.unknown)` when it cannot check the connection. This applies to an event loop group that is not a `NIOTSEventLoopGroup`, a `delegateAndChannel` event loop that is not a NIOTS loop, TLS without `.fullVerification`, or a proxy. See [connection validation](ADVANCED.md#connection-validation).
