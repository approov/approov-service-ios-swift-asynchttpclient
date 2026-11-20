# Approov Package for AsyncHTTPClient

![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-13%2B-000000?logo=apple&logoColor=white)
![SwiftPM](https://img.shields.io/github/v/tag/approov/approov-service-ios-swift-asynchttpclient?logo=swift&logoColor=white&label=SwiftPM&color=F05138)
![Message Signing](https://img.shields.io/badge/Message%20Signing-RFC%209421-1f6feb)
![Build](https://github.com/approov/approov-service-ios-swift-asynchttpclient/actions/workflows/build_and_test.yml/badge.svg)

This package adds [Approov](https://www.approov.io) to an iOS app that uses [AsyncHTTPClient](https://github.com/swift-server/async-http-client). After you initialize it, every request that your app makes through an `ApproovHTTPClient` carries an Approov token, and optionally a message signature, that your backend can check. Your backend then knows that each request came from a genuine, unmodified copy of your app.

The package also validates the TLS connection to each of your API domains, against the certificate public keys configured for that domain, or else the Managed Trust Roots that Approov maintains for your account. A connection that does not match is refused.

You need a trial or paid Approov account. The [Approov documentation](https://approov.io/docs/latest/) shows how to set up your account, register your app and check the integration. This page covers the essentials. Optional features are in [ADVANCED.md](ADVANCED.md), and every method is in [REFERENCE.md](REFERENCE.md).

## ADDING THE DEPENDENCY

Add the package with the Swift Package Manager. In Xcode, select **File > Add Package Dependencies**, enter `https://github.com/approov/approov-service-ios-swift-asynchttpclient.git`, and select version `3.7.0` or later. Add the `ApproovAsyncHTTPClient` product to your app target.

In a `Package.swift`:

```swift
.package(url: "https://github.com/approov/approov-service-ios-swift-asynchttpclient.git", from: "3.7.0")
```

The package needs iOS 13 or later. It depends on the [Approov iOS SDK](https://github.com/approov/approov-ios-sdk) and on the Approov fork of AsyncHTTPClient. The Swift Package Manager fetches both.

## INITIALIZING

Initialize `ApproovService` once, when your app starts, with your Approov account ID. Requests made before initialization are sent without Approov protection.

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
    // the value passed was not a complete, unaltered account ID; run without Approov rather than not at all
    os_log("Approov account ID rejected; starting in bypass mode: %@", error.localizedDescription)
    try? ApproovService.initialize(config: "")
}
// then configure, after initialize and before the app issues protected requests;
// only the settings your app uses, for example:
// ApproovService.setTokenHeader(header: "Authorization", prefix: "Bearer ")
// ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
```

Some notes on this example:

* `initialize` throws only if the account ID it receives is incomplete or altered. The `catch` block then starts the package in **bypass mode**, with `""`. In bypass mode, requests are sent without Approov protection, but your app still starts.
* Logging the device ID is optional. Approov identifies an installation only by its device ID. If you log it next to your own user or session ID, you can match the two later.
* Make your configuration calls (header names, message signing, secure strings and more) after `initialize`, and before the app sends protected requests. Each `initialize` resets the configuration to its defaults, so a setting made before it is lost. See [initialize, then configure](ADVANCED.md#initialize-then-configure).

### Your account ID

Your account ID is in your onboarding email. You can also get it at any time from the Approov CLI, which calls it the SDK config string:

```sh
approov sdk -getConfigString
```

The account ID is the same for every app in your account, and it is not a secret. You can keep it in your source code, or deliver it with your app's configuration. In both cases, the full value must reach the app unchanged, with its punctuation. More in [about the Approov account ID](ADVANCED.md#about-the-approov-account-id).

If another part of your app initializes Approov for you, that only sets the account ID. Your app must still make its own configuration calls after that `initialize`, because each `initialize` resets them.

## MAKING REQUESTS

Use an `ApproovHTTPClient` in place of an `HTTPClient`. It has the same initializers and request methods:

```swift
let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
let request = HTTPClientRequest(url: "https://api.example.com/shapes")
let response = try await client.execute(request, timeout: .seconds(30))
```

Create the client with `.createNew`, or with a shared `NIOTSEventLoopGroup`, and keep TLS certificate verification at `.fullVerification`. The package can validate the connection only in that configuration. While Approov is enabled, the client refuses each request in any other configuration. See [connection validation](ADVANCED.md#connection-validation).

For a transport that owns its own `HTTPClient`, `ApproovService.signRequest(_:)` returns a protected copy of a request. Create that client with `redirectConfiguration: .disallow`, or a redirect sends the protection to the next host.

### What gets sent

For a domain that you added to Approov, each request carries:

* the `Approov-Token` header, the proof that the app passed attestation
* the `Approov-TraceID` header, an optional debug value, when the SDK gives one

The connection is validated against the certificate public keys configured for the domain, or your account's Managed Trust Roots if it has none. If the validation fails, the request fails with `URLError(.serverCertificateUntrusted)` at the connect timeout (`HTTPClient.Configuration.timeout.connect`).

A domain that you added with `-noApproovToken` gets a validated connection and its secure strings, but no Approov headers. Requests to any other domain are sent unchanged.

If a secure string cannot be fetched, the fetch status name replaces its placeholder. A header then becomes, for example, `Api-Key: REJECTED` or `Api-Key: UNKNOWN_KEY`, and a required prefix stays in front of the status. Your backend can then see why the secret is missing.

### When the app cannot get a token

By default the mutator is `CLOSE_FAILURE`:

* If the Approov service cannot be reached (`NO_APPROOV_SERVICE`), the request is sent with an empty `Approov-Token` header.
* For any other failure, the request fails in the app with an `ApproovError`: `networkingError` for a problem that the user can retry, such as `NO_NETWORK`, and `rejectionError` or `permanentError` for the others.

To always send the request and let your backend decide, install `ALWAYS_PROCEED`. A request without a token is then sent with an empty `Approov-Token` header.

```swift
ApproovService.setServiceMutator(.ALWAYS_PROCEED)  // optional but recommended
```

To tell your backend why there is no token, turn on `setUseApproovStatusIfNoToken`. The token header then carries the status name, such as `NO_NETWORK`, in place of the empty token. Under `CLOSE_FAILURE` this also lets `NO_NETWORK`, `POOR_NETWORK` and `MITM_DETECTED` go ahead with the status. See [sending the status in the token header](ADVANCED.md#sending-the-status-in-the-token-header).

```swift
ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
```

If the token fetch fails for a host that is not one of your Approov API domains, the request is sent unchanged under both mutators. More in [what happens by default](ADVANCED.md#what-happens-by-default).

### Message signing

Message signing is off until you install it. The signer, `ApproovDefaultMessageSigning`, is a service mutator. Install it after `initialize`:

```swift
ApproovService.setServiceMutator(ApproovDefaultMessageSigning().setDefaultFactory(
    ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()))
```

Each request that carries the token header is then signed with the install signature. Do not write the default port (`:443` or `:80`) in a request URL, because the signature then does not verify on your backend. See [message signing](ADVANCED.md#message-signing).

### Redirects

`ApproovHTTPClient` follows redirects with your `redirectConfiguration`, and it protects each hop as a new request for its target. See [redirects](ADVANCED.md#redirects).

## VERIFYING

Run your app and make a request. To see what happened, turn on debug logging with `ApproovService.setLoggingLevel(.debug)` in a debug build. The package never logs a token. At debug level it logs the [loggable form](https://approov.io/docs/latest/approov-usage-documentation/#loggable-tokens) of each result. Its `arc` claim tells why attestation gave that result. [Diagnostics](ADVANCED.md#diagnostics) shows how to decode it.

Your account's [live metrics](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs) show the same results in aggregate, usually within a minute.

## UPGRADING FROM 3.5.x

Read the [changelog](CHANGELOG.md) for the full list of changes, and test your app and backend together.

### Code changes

* `prefetch()`, `proceedOnNetworkFail` and `substituteQueryParam(url:queryParameter:)` are removed. To send requests after a network failure, use `setServiceMutator(.ALWAYS_PROCEED)`. To substitute a query parameter, call `addSubstitutionQueryParam(key:)` once, and the package substitutes it in each request.
* `getDeviceID()` no longer throws, and it returns `String?`.
* `approovTokenHeaderAndPrefix`, `getMessageSignature(message:)` and `updateRequest(url:headers:)` are deprecated. Use `setTokenHeader(header:prefix:)`, `getAccountMessageSignature(message:)` and `ApproovHTTPClient`.
* Create `ApproovHTTPClient` with `.createNew` or a `NIOTSEventLoopGroup`, and keep certificate verification at `.fullVerification`.

### Changes you can see

* A failed token fetch only affects requests to your Approov API domains. A request to any other host is sent unchanged.
* A secure string that cannot be fetched no longer fails the request. The status name replaces the placeholder, such as `Api-Key: REJECTED`. If your backend checks the value it receives, it must expect these status values.
* A connection refused by validation fails with `URLError(.serverCertificateUntrusted)` instead of `HTTPClientError.connectTimeout`.
* Each redirect is protected afresh for its target.

## NEXT STEPS

1. [Add your API domains](https://docs.approov.io/getting-started/add-api-domains/) to Approov.
2. [Register your app](https://docs.approov.io/getting-started/add-app-signing-certificates/).
3. Set up token and signature checks on your backend, as the [Approov documentation](https://approov.io/docs/latest/) shows.

Custom header names, secure strings, token binding, excluding URLs and service mutators are in [ADVANCED.md](ADVANCED.md). Every method is in [REFERENCE.md](REFERENCE.md).
