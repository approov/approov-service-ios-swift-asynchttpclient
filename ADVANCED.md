# Advanced Options

A standard integration needs nothing on this page. It covers the options and details behind the [README](README.md), for when you need them.

## What each request carries

The package fetches an Approov token for each request it processes, and the result decides what the request carries:

| Request to | Token header | Trace header | Secure strings | Signature | Connection |
|---|---|---|---|---|---|
| A token-protected API, token obtained | the token | when the SDK gives one | substituted | when signing is installed | validated |
| A token-protected API, no token, request proceeds | empty, or the status name | when the SDK gives one | placeholders left as written | when signing is installed | validated |
| A secrets-only API (`-noApproovToken`) | none | none | substituted | none | validated |
| Any other host | none | none | placeholders left as written | none | OS trust |

Secure strings are substituted only into an https request. A cleartext request never gets one, and the package logs a warning that names each header or query parameter it left as written.

### Secrets-only APIs

An API that you added with `approov api -add <domain> -noApproovToken` needs no Approov token. Its connections are still validated against its keys, and its requests get their secure strings.

## What happens by default

The service mutator decides what happens when the token fetch does not succeed. `ApproovCloseFailureMutator.DEFAULT` is `CLOSE_FAILURE`, which keeps the 3.5.x decisions:

| Token fetch status | `CLOSE_FAILURE` | `ALWAYS_PROCEED` |
|---|---|---|
| `SUCCESS` | sends the token | sends the token |
| `NO_APPROOV_SERVICE` | sends an empty token header | sends an empty token header |
| `NO_NETWORK`, `POOR_NETWORK`, `MITM_DETECTED` | fails with `ApproovError.networkingError`, the user can retry | sends an empty token header |
| `REJECTED` and any other failure | fails with `ApproovError.rejectionError` or `permanentError` | sends an empty token header |
| `UNKNOWN_URL`, `UNPROTECTED_URL` | adds no Approov header | adds no Approov header |

A failure only affects your Approov API domains, the hosts in your pin set. A request to any other host whose token fetch fails is sent unchanged under both mutators. While the app has no configuration yet, for example on a first launch without a network, no host is in the pin set, so nothing is blocked.

### Secure string results

A secure string is fetched for each placeholder on a request to a token-protected or secrets-only API. Neither standard mutator fails a request because of a secure string:

* `SUCCESS` replaces the placeholder with the value.
* Any other status replaces the placeholder with the status name, after any required prefix, such as `Bearer REJECTED`, or `UNKNOWN_KEY` in a query parameter. Your backend sees why the secret is missing.

### Values a header or URL cannot carry

A header carries only tab and printable ASCII. A query value must come back unchanged from the URL. A secure string that cannot be carried leaves the placeholder as written, and the package logs a warning that names the header or query parameter, never the value.

### Errors your app can see

* A decision of `CLOSE_FAILURE` fails the request with an `ApproovError`, as in 3.5.x.
* A `URLError` that your own mutator throws reaches your app unchanged.
* Anything else that a mutator hook throws, an `ApproovError` that your code throws included, fails the request with `URLError(.unknown)` that names the hook. Your error is its underlying error (`NSUnderlyingErrorKey`).
* A configuration error fails the request with `URLError(.unknown)`: a required body digest that cannot be generated, an unsupported signature algorithm, or a client or request on which the package cannot validate the connection.
* A connection that fails validation fails with `URLError(.serverCertificateUntrusted)`, with the AsyncHTTPClient error as its underlying error.
* A redirect over your limit fails with `HTTPClientError.redirectLimitReached` or `redirectCycleDetected`, as in AsyncHTTPClient.

A failed request fails alone. The client and its other requests are not affected.

## Sending the status in the token header

With `ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)`, a request that proceeds without a token carries the token fetch status name, such as `NO_NETWORK` or `NO_APPROOV_SERVICE`, in place of the empty token, after any prefix. Under `CLOSE_FAILURE` this also lets `NO_NETWORK`, `POOR_NETWORK` and `MITM_DETECTED` go ahead with the status. `REJECTED` still fails. The status is never sent to a host that is not one of your Approov API domains.

## Message signing

Message signing is **off until you install it**. The signer, `ApproovDefaultMessageSigning`, is a service mutator. Give it a default factory and install it after `initialize`:

```swift
ApproovService.setServiceMutator(ApproovDefaultMessageSigning().setDefaultFactory(
    ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()))
```

After that, each request that carries the token header is signed with the install signature, `ecdsa-p256-sha256`. It uses a key that is unique to the app installation and held in the secure hardware of the device. Its dictionary member is `install`.

You can add the account signature, `hmac-sha256`, with `setUseInstallAndAccountMessageSigning()` on the factory. It uses a shared account key, which the app gets when it passes attestation. Its member is `account`. Both are members of the same `Signature` and `Signature-Input` headers, over the same covered components. If you send both, a device without secure hardware still produces a signature that your backend can verify. If one signature cannot be produced, the request goes ahead with the other, or unsigned. `setUseAccountMessageSigning()` and `setUseInstallMessageSigning()` select one.

The signer makes the `CLOSE_FAILURE` decisions. Installing another mutator, passing `nil` to `setServiceMutator`, or calling `initialize` removes it. To combine signing with your own decisions, call the signer's `handleInterceptorProcessedRequest` from your own mutator.

See [Installation Message Signing](https://approov.io/docs/latest/approov-usage-documentation/#installation-message-signing) and [Account Message Signing](https://approov.io/docs/latest/approov-usage-documentation/#account-message-signing).

### What the default signature covers

* the request method and the target URI, as described in [how the URL is signed](#how-the-url-is-signed)
* the `Approov-Token` header, and the `Approov-TraceID` header when it is present
* the `Authorization`, `Content-Length` and `Content-Type` headers, when they are present
* a SHA-256 `Content-Digest` of the body, when the body is in memory (a buffer, bytes or a string). A streamed body is not digested.
* a `created` time and a 15 second `expires`, both from `ApproovService.getServerAdjustedCurrentTimeMS()`, so they follow the Approov servers' clock, also when the device clock is wrong. If the Approov SDK does not give that time, the device clock is used and a warning is logged.

The package reads the body before the send only to compute the body digest. With a body digest, the closure of an `HTTPClient.Body.stream(length:)` body runs one more time, so each call must write the same bytes. Without a body digest, the package does not call the body closure.

### How the URL is signed

`@target-uri` is the URL that the request was made with, without the fragment. AsyncHTTPClient sends that URL as written. `@path` is `/` when the URL has no path. `@authority` is the lowercase host, with the port only when it is not the default port.

**Do not write the default port in a URL (`:443` for https, `:80` for http).** The package signs the port as written, but your backend, or an edge such as Cloudflare, rebuilds the URL without it, so the signature does not verify. A port that is not the default, such as `:8443`, verifies.

### Choosing the signatures and the covered components

```swift
let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
    .setUseInstallAndAccountMessageSigning()
    .setExpiresLifetime(60)
    .addOptionalHeaders(["X-Request-Id"])
let paymentsFactory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
    .setExpiresLifetime(5)

ApproovService.setServiceMutator(ApproovDefaultMessageSigning()
    .setDefaultFactory(factory)
    .putHostFactory(hostName: "payments.example.com", factory: paymentsFactory))
```

A host factory applies to requests to that host, matched without regard to case, a trailing dot or the port. The default factory applies to each other protected host. `try factory.setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: true)` makes the digest required: a body that cannot be digested then fails the request. `setBodyDigestConfig(nil, required: false)` turns the digest off.

## Header names

`setTokenHeader(header:prefix:)` sets the token header and an optional prefix, such as `"Authorization"` and `"Bearer "`. `setTraceIDHeader(header:)` sets the trace header, and `nil` turns it off. The 3.5.x property `approovTokenHeaderAndPrefix` still works and is deprecated.

## About the Approov account ID

The string that you pass to `initialize` looks like `#your-account#p6nZ...=`. It names your account and carries a fingerprint of the account's public key. It is not a secret, it does not change, and the same value serves each app in the account. Knowing it gives nothing.

## Bypass initialization

`ApproovService.initialize(config: "")` starts the package without Approov protection: an `ApproovHTTPClient` then works like a plain `HTTPClient`. A later `initialize` with your account ID turns protection on. After protection is on, an `initialize` with `""` is ignored.

## Initialize, then configure

Each `initialize` that is not ignored resets the configuration to its defaults: the header names, the status flag, the service mutator, the substitutions, the exclusions and the binding header. The logging level is kept. Make your configuration calls after `initialize`, and before the app sends protected requests. A setting applies to the requests processed after you make it.

## Token binding

Set `ApproovService.bindHeader` to the name of a header that your requests carry, such as `"Authorization"`, to bind the token to its value. Only a hash of the value is sent to Approov. When the value changes, the next token is bound to the new value. Do not mix `bindHeader` with direct `setDataHashInToken` calls.

## Secure strings

`addSubstitutionHeader(header:prefix:)` names a header whose value, after the prefix, is a secure string key. `addSubstitutionQueryParam(key:)` names a query parameter whose value is a key. The package replaces each with the secure string, as [secure string results](#secure-string-results) describes.

### Keys and values

A secure string key has a maximum of 64 characters (see [secure strings](https://approov.io/docs/latest/backend-integration/secure-strings/)). For a key in a query parameter, use only letters, digits, `.`, `_`, `~` and `-`. Each occurrence of a query parameter is substituted, and nothing else in the URL changes. A `+` in a substituted query value reaches a backend that form-decodes the query as a space. A value that a request cannot carry is still available with `fetchSecureString`.

## Excluding URLs

`addExclusionURLRegex(urlRegex:)` sends requests whose URL matches the pattern without Approov processing. Their connections are still validated. A pattern that does not compile is logged as an error and not added.

## Connection validation

The package validates the TLS connection to each domain that you added to Approov against the certificate public keys configured for the domain. For a domain with no keys of its own, it uses the Managed Trust Roots. This validation is certificate pinning. Hosts are matched without regard to case or a trailing dot.

A domain with no keys of its own and no Managed Trust Roots connects on OS trust, and the package logs one warning for each host. If the keys cannot be read, the connection is refused. A connection to an IP address, which has no server name, connects on OS trust, unless an IP address has keys configured. Then it is refused, because the package cannot tell which host it is.

The validation runs in the TLS handshake on Network.framework, once for each connection. Each request that reuses the connection relies on it. So the mutator's `handlePinningShouldProcessRequest(hostname:)` is asked once for each connection, with the host only, and its answer applies to each request on that connection, as in `approov-service-urlsession`. The keys are read in each handshake, so new keys apply to the next connection.

A refused connection fails with `URLError(.serverCertificateUntrusted)` at the connect timeout, because AsyncHTTPClient tries the connection again until then. To fail sooner, set a shorter `HTTPClient.Configuration.timeout.connect`.

The validation runs only on a `NIOTSEventLoopGroup`, and only with `.fullVerification`. While Approov is enabled, the client refuses each request with `URLError(.unknown)` in these cases:

* an `ApproovHTTPClient` made with an event loop group that is not a `NIOTSEventLoopGroup`, such as `MultiThreadedEventLoopGroup`
* a `delegateAndChannel` event loop preference with an event loop that is not a NIOTS event loop
* a client or request TLS configuration whose `certificateVerification` is not `.fullVerification`

In bypass mode, these clients work.

### WebSockets

WebSockets are not supported. AsyncHTTPClient has no WebSocket API. A request with an `Upgrade: websocket` header is sent unchanged: no Approov token, no secure string and no signature. Its connection is still validated. Do not put a secure string placeholder on such a request.

## Service mutators

A mutator changes the package's decisions. Implement `ApproovServiceMutator` and write only the hooks that you need. Each other hook keeps the `CLOSE_FAILURE` decision:

| Hook | Decides |
|---|---|
| `handleInterceptorShouldProcessRequest` | whether a request is processed |
| `handleInterceptorFetchTokenResult` | what a request carries for its token fetch status, or whether it fails |
| `handleInterceptorHeaderSubstitutionResult`, `handleInterceptorQueryParamSubstitutionResult` | whether a secure string is substituted |
| `handleInterceptorProcessedRequest` | final changes to the processed request, where signing happens |
| `handlePinningShouldProcessRequest` | whether the connection is validated |
| `handlePrecheckResult`, `handleFetchTokenResult`, `handleFetchSecureStringResult`, `handleFetchCustomJWTResult` | how the direct methods report a result |

To fail a request on your own terms, throw a `URLError` from a hook. Your app's error handling then sees an ordinary network failure. A request keeps the mutator it started with, across its redirects.

```swift
final class OwnHostsOnly: ApproovServiceMutator {
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
        if approovResults.status == .noApproovService {
            throw URLError(.cannotConnectToHost)
        }
        return try ApproovCloseFailureMutator.CLOSE_FAILURE.handleInterceptorFetchTokenResult(approovResults, url: url)
    }
}
ApproovService.setServiceMutator(OwnHostsOnly())
```

## Redirects

`ApproovHTTPClient` follows redirects itself, with the limits in your `redirectConfiguration`. The client inside it never follows one. Each hop is your request for its target, protected as a new request under the mutator that the request started with:

* a token is fetched for the target, and the target's keys apply
* secure strings are substituted only on a protected https target, and only from your own placeholders
* signatures cover the new method and target

Nothing that the package added to one hop reaches another origin. The target URL is used exactly as the server sent it, and the package never looks up the query values in a `Location`.

The method and the body change as in AsyncHTTPClient: a 303, and a 301 or 302 for a POST, become a GET without a body. A 307 or 308 sends the body again. An async request body that can be sent only once is not sent again: you get the redirect response. A delegate sees only the final response. Your request's `tlsConfiguration` is kept on each hop.

A request to a domain that is not in Approov, which redirects to one of your API domains, is protected at that hop.

`signRequest(_:)` output sent with a plain `HTTPClient` does not get this protection. Create that client with `redirectConfiguration: .disallow`.

## Requests held before they are sent

The package protects a request when the request starts. AsyncHTTPClient then sends it. The package cannot run code just before AsyncHTTPClient writes the request, so it does not refresh a token or a signature. A request that waits for a connection, for up to the connect timeout (10 seconds by default), carries the token and the signature of the time it started.

A signature expires 15 seconds after it is made, by default. Keep the connect timeout shorter than the signature lifetime, or set a longer lifetime with `setExpiresLifetime(_:)` on the factory.

## Multiple service layers

You can use more than one Approov package in the same app. The Approov SDK is initialized once: a later `initialize` with the same account ID is ignored, and one with a different account ID fails.

## Diagnostics

`ApproovService.setLoggingLevel(_:)` takes `.off`, `.error`, `.warning`, `.info` (the default) or `.debug`, and each line that the package writes follows it. The loggable token is written at `.debug` only.

`ApproovService.getLastARC()` returns the [Attestation Response Code](https://approov.io/docs/latest/approov-usage-documentation/#attestation-response-code) of the most recent fetch that the package made, and makes no fetch of its own. The `arc` claim of a loggable token is the same code. To decode one, ask the CLI for the decoding command once. It prints a `curl` command with your account's API key filled in and an `<arc>` placeholder:

```sh
approov token -showArcInfoCurl
```

Run it with the code in place of `<arc>`. The response lists the flags behind the result, for example `app-not-registered`.
