# Advanced Options

The `approov-service-ios-swift-asynchttpclient` package works through an `ApproovHTTPClient`. After you call `initialize` with your account ID, the package adds an Approov token to each request to your API domains. The token is a signed JWT that provides proof of attestation, which your backend can check.

A standard integration of the Approov Service for AsyncHTTPClient needs nothing from this document. You add the dependency, initialize, and use an `ApproovHTTPClient`, as the [README](README.md) shows. The options below change the defaults, suitable for applications with specific needs. You can find every method used in this document in [REFERENCE.md](REFERENCE.md).

| What you need | Read |
| :--- | :--- |
| Understand what reaches your backend | [What each request carries](#what-each-request-carries), then [What happens by default](#what-happens-by-default) |
| Change what happens on a network failure | [What happens by default](#what-happens-by-default), then [Service mutators](#service-mutators) |
| Protect request contents with signatures | [Message signing](#message-signing), then [Account Message Signing](https://docs.approov.io/operations/message-signing/account/) |
| Replace an embedded API secret | [Secure strings](#secure-strings) |
| Configure startup or runtime activation | [Initialize, then configure](#initialize-then-configure), then [Bypass initialization](#bypass-initialization) |
| Investigate an unexpected result | [Diagnostics](#diagnostics), then [Errors your app can see](#errors-your-app-can-see) |

## What each request carries

What the package adds to a request depends on two things:

* the kind of host: a token-protected API domain, a secrets-only API domain, or a host not protected by Approov (one you have not added)
* the outcome of the attestation attempt for the request

Based on the attestation outcome and the kind of host, the package and its [service mutator](#service-mutators) decide what to add to the request. They also decide whether the request goes ahead at all.

| Request goes to | Outcome | What the package adds |
| :--- | :--- | :--- |
| a token-protected domain: an API domain you added to Approov | `SUCCESS` | the token header, and the trace header when the SDK gives a trace ID. Your secure strings, or the [status of each one that could not be fetched](#secure-strings). The signatures, once you install [message signing](#message-signing). A checked connection. |
| a secrets-only domain: an API domain you added with `approov api -add <domain> -noApproovToken` | `UNPROTECTED_URL` | your secure strings, or the status of each one that could not be fetched. A checked connection. No token or trace header, and no signatures. |
| a host not protected by Approov | `UNKNOWN_URL` | nothing. The connection relies on OS trust. |
| a token-fetch failure, to a host protected by Approov | a failure status | depends on the service mutator (see below) |
| a token-fetch failure, to a host not protected by Approov | a failure status | nothing (see below) |

A failure status means the app could not complete the attestation. For example, there was no network, or the app could not reach the Approov service. The [service mutator](#what-happens-by-default) then decides whether the request fails in the app or goes out. A request that goes out carries the `Approov-Token` header with an empty token after any prefix. If you turned on [setUseApproovStatusIfNoToken](#sending-the-status-in-the-token-header), it carries the status name instead. It has the trace header when the SDK gives a trace ID, and no secure strings.

For a host not protected by Approov, the request goes out unchanged, whatever the outcome. The standard mutators never fail it in the app. Only your own mutator can, by throwing from `handleInterceptorFetchTokenResult` (see [Service mutators](#service-mutators)).

The headers your backend may receive:

* `Approov-Token` carries the Approov token, or is empty (or holds the [status](#sending-the-status-in-the-token-header)) when no token could be fetched. Only your backend can tell from the token whether the app passed. See [Approov tokens](https://docs.approov.io/core-concepts/approov-tokens/architecture-and-security/).
* `Signature` and `Signature-Input` carry the signatures, once you install [message signing](#message-signing). `Content-Digest` carries the body digest that they cover.
* `Approov-TraceID` is an optional debug header. Your backend passes it through unchanged.

Whatever the attestation outcome, an `ApproovHTTPClient` checks the TLS connection to each domain you added, token-protected or secrets-only (see [Connection validation](#connection-validation)).

## What happens by default

The package processes a request when an `ApproovHTTPClient` runs it. It does this work on a background thread, off the event loop and off the Swift concurrency pool, because the token fetch blocks. For every request it processes, it fetches an Approov token for the request URL. It does not process a request before `initialize` or in [bypass mode](#bypass-initialization), a [WebSocket](#websockets) upgrade, or a request to an [excluded URL](#excluding-urls). It then applies the decisions of the installed [service mutator](#service-mutators). The package provides three standard ones:

* `.CLOSE_FAILURE` keeps the 3.5.x token decisions for your API domains. A failed token fetch fails the request in the app, with an `ApproovError` as in 3.5.x.
* `.ALWAYS_PROCEED` never fails a request because of its token fetch. Whatever the token fetch outcome, the package sends the request, and your backend decides. Your backend is then the enforcement point.
* `.DEFAULT` is the mutator installed out of the box. `setServiceMutator(nil)` puts it back, and so does each `initialize` that succeeds. `.DEFAULT` points to whatever the release considers default behaviour, which is currently `.CLOSE_FAILURE`.

To opt in to always proceeding:

```swift
ApproovService.setServiceMutator(.ALWAYS_PROCEED)
```

In the table below, "an Approov protected host" means one of the API domains you added to Approov, of either kind.

| Approov token fetch status | `CLOSE_FAILURE` (default) | `ALWAYS_PROCEED` |
| :--- | :--- | :--- |
| `SUCCESS` | proceeds with the token, any trace header, the secure strings and, with message signing installed, the signatures | same |
| `UNPROTECTED_URL` (secrets-only API) | proceeds with the secure strings only, no Approov headers | same |
| `UNKNOWN_URL` (host not protected by Approov) | proceeds untouched | same |
| `NO_APPROOV_SERVICE`, Approov protected host | proceeds with an empty token header (or the status), but no secure strings | same |
| `NO_NETWORK`, `POOR_NETWORK`, `MITM_DETECTED`, Approov protected host | fails with `ApproovError.networkingError`, which the user can retry. With `setUseApproovStatusIfNoToken(shouldUse: true)` it proceeds with the status in the token header instead | proceeds with an empty token header (or the status), but no secure strings |
| any other status (`REJECTED`, `INTERNAL_ERROR`, `BAD_URL`, ...), Approov protected host | fails with `ApproovError.permanentError` | proceeds with an empty token header (or the status), but no secure strings |
| any failure status, host not protected by Approov | proceeds untouched, and no standard mutator fails it | same |

"The status" in this table means the status name in the token header, after any prefix. A request that goes ahead after a failed token fetch also carries the trace header when the SDK gives a trace ID. The package signs it too, if you installed [message signing](#message-signing). If the SDK gives no pins map, no host counts as an Approov protected host.

`NO_APPROOV_SERVICE` means the app could not reach the Approov service or its failover.

These are the token fetch decisions only. Under either mutator, these still fail the request:

* a TLS connection that fails the check
* a client that cannot [check the connection](#connection-validation)
* an abort that your own hooks ask for
* a message signing configuration error

### Sending the status in the token header

With `ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)`, a request that proceeds without a token carries the status name, such as `NO_NETWORK`, after any prefix. Under `CLOSE_FAILURE` the network statuses then proceed instead of failing, and `REJECTED` still fails. A host not protected by Approov never receives the status.

### Errors your app can see

A request that fails reports its error through its future, or through an `async` `execute` that throws. `wait()` throws the same error.

* A `CLOSE_FAILURE` decision fails the request with an `ApproovError`, as in 3.5.x. Its message names the status and the URL without user info, query or fragment, for example `Approov token fetch for https://api.example.com/v1/items: NO_NETWORK`.
* A `URLError` that your own mutator throws reaches your app unchanged.
* A standard decision keeps its `ApproovError`, also when your mutator calls a standard mutator and passes its error on.
* If your mutator throws any other error, an `ApproovError` that your code makes included, the package wraps it in a `URLError` with code `.unknown`. Its message names the hook, for example `ApproovService: ApproovServiceMutator.handleInterceptorProcessedRequest failed: ...`. Your original error is in its `userInfo` under `NSUnderlyingErrorKey`.
* A configuration error fails the request with a `URLError` with code `.unknown`. These are the configuration errors:
  * a client that cannot [check the connection](#connection-validation)
  * a required body digest that the package cannot generate
  * an unsupported algorithm from a custom signing configuration
  * a token prefix that a header cannot carry
* A connection that fails the check fails with `URLError(.serverCertificateUntrusted)`.
* A redirect beyond your limits fails with the `HTTPClientError` that AsyncHTTPClient uses, such as `.redirectLimitReached` or `.redirectCycleDetected`.

A failed request fails alone. The client and its other requests are not affected.

The direct methods, such as `fetchToken(url:)` and `fetchSecureString(key:newDef:)`, throw an `ApproovError`. If your mutator throws another error from their hooks, they throw it as `ApproovError.permanentError`.

## Message signing

The signer, `ApproovDefaultMessageSigning`, adds RFC 9421 message signatures to every request that carries the Approov token header that the package added.

Message signing is **off unless you install it**. If you do not need signatures, keep the default and install nothing.

The signer is a service mutator. So installing another mutator, passing `nil` to `setServiceMutator`, or an `initialize` that succeeds removes it. The signer from `ApproovDefaultMessageSigning()` makes the standard decisions, the same as `CLOSE_FAILURE`. If those suit you, give it a default factory and install it right after `initialize`, as in the example. To sign under other decisions, such as `ALWAYS_PROCEED`, use [`combined(decisions:)`](#sign-with-other-decisions).

```swift
ApproovService.setServiceMutator(ApproovDefaultMessageSigning().setDefaultFactory(
    ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()))
```

A signer without a factory signs nothing. Once the signer is installed, the package signs every request that carries the Approov token header with the install signature, `ecdsa-p256-sha256`. It uses a key unique to the app installation. The key stays on the device, in secure hardware where the device has it. Its dictionary member is `install`.

You can add the account signature, `hmac-sha256`, with `setUseInstallAndAccountMessageSigning()` on the factory. It uses a shared account key, which the SDK receives when the app passes attestation. Its member is `account`. Both are members of the same `Signature` and `Signature-Input` headers, over the same covered components. If the package cannot produce one signature, the request goes ahead with the other, or unsigned. `setUseAccountMessageSigning()` and `setUseInstallMessageSigning()` select one signature only.

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

`putHostFactory(hostName:factory:)` sets a factory for one host. The package matches the host without regard to case or a trailing dot.

A request to a secrets-only API that the SDK reports as `UNPROTECTED_URL` carries no token header, and the package does not sign it. A request to an Approov protected host can go ahead after a failed token fetch. It then still carries the token header, empty or with the status. So the signer signs it too, over that value. A token header that your app set itself is not signed.

Your backend receives `Signature` and `Signature-Input` headers whose members include `install`, `account` or both. When the package cannot produce a signature, the request goes ahead with the other signature or unsigned. The package logs a missing install or account signature as a warning once per process, such as `ApproovService: install message signature unavailable, signed without it`. It logs a request sent unsigned as an error once per process, such as `ApproovService: no message signature could be produced, proceeding unsigned: ...`. It logs later occurrences at `.debug`.

Your backend verifies the signatures as [Installation Message Signing](https://docs.approov.io/operations/message-signing/installation/) and [Account Message Signing](https://docs.approov.io/operations/message-signing/account/) describe.

### Sign with other decisions

`ApproovDefaultMessageSigning.combined(decisions:)` returns a signer that adds both the install and the account signature. It makes the decisions of `decisions`: `.CLOSE_FAILURE`, `.ALWAYS_PROCEED`, `.DEFAULT` or a mutator of your own. `combined()` uses `.DEFAULT`, the same as `.CLOSE_FAILURE`. If the package cannot produce a signature, it leaves that signature out, and the request goes ahead with the other signature or unsigned. Your backend can check the install signature only if the Approov token carries the install public key. Turn that on for your account with `approov policy -setInstallPubKey on` (see [installation message signing](https://docs.approov.io/operations/message-signing/installation/)). Each call returns a new `ApproovDefaultMessageSigning`, so `setDefaultFactory(_:)` and `putHostFactory(hostName:factory:)` on it change only that signer.

```swift
ApproovService.setServiceMutator(ApproovDefaultMessageSigning.combined(decisions: .CLOSE_FAILURE))

ApproovService.setServiceMutator(ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED))
```

To sign with other settings under these decisions, give the signer your own factory. The decisions stay the same:

```swift
ApproovService.setServiceMutator(ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED)
    .setDefaultFactory(ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()))
```

With a mutator of your own as `decisions`, the signer passes every hook to your mutator. It then signs the request that your `handleInterceptorProcessedRequest` returns, so the signature covers the changes your mutator makes. When you write such a mutator:

* Keep your `handleInterceptorProcessedRequest` safe to repeat. The package calls it again for each redirect hop, so the package signs each hop again for its target.
* Let errors propagate. A required body digest that the package cannot generate then fails the request, as it does when the signer is installed on its own.

### What the default signature covers

* the request method and target URI, exactly as AsyncHTTPClient sends the request, without any fragment
* the token header, and the trace header when the package added one
* the `Authorization`, `Content-Length` and `Content-Type` headers, when present
* a SHA-256 `Content-Digest` of the body, when the package can read the body before the send (see [Body digest](#body-digest)). A [307 or 308 redirect](#redirects) keeps its digest.
* a `created` timestamp and a 15 second `expires`, from [getServerAdjustedCurrentTimeMS](REFERENCE.md#getserveradjustedcurrenttimems). After the app's first attestation this follows the Approov servers' clock, so a wrong device clock does not move them outside your backend's window

The signed target URI, and the authority if you cover it, leave out a default port: `:443` for `https` and `:80` for `http`. So `https://api.example.com:443/v1` and `https://api.example.com/v1` give the same signature. The authority is in lowercase.

The [SignatureParametersFactory](REFERENCE.md#signatureparametersfactory) methods change these choices.

### Body digest

The default factory adds a SHA-256 `Content-Digest` of the request body to the signature. The package reads the body before the send to compute it. It can read these bodies:

* `HTTPClient.Request`: a body with a known length whose closure writes all its bytes on the calling thread before its future completes. The in-memory bodies, such as `.byteBuffer`, `.bytes` and `.string`, do this. The package does not call the closure of a body without a length.
* `HTTPClientRequest`, for the `async` API: a `ByteBuffer` body, or a byte sequence body that can be sent more than once. The package does not read a streamed or one-shot body.

For a body digest, the package calls the closure of an `HTTPClient.Body.stream(length:)` body one more time before the send. AsyncHTTPClient then calls it for the send, and again for a 307 or 308 redirect. So each call must write the same bytes. Without a body digest, the package does not call the body closure before the send.

A body that the package cannot read has no digest, and the request goes ahead. A required body digest, set with `setBodyDigestConfig(_:required:)`, fails each request without a body that the package can read. To turn the digest off:

```swift
let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
    .setBodyDigestConfig(nil, required: false)
```

## Header names

You can change the name of the token header and the trace header, and the prefix in front of the token. By default, the token goes in `Approov-Token` with no prefix, and the trace ID in `Approov-TraceID`.

Change them when your backend expects the token in another header, such as `Authorization` with a `Bearer ` prefix, or does not want the trace header. Passing `nil` turns the trace header off.

```swift
ApproovService.setTokenHeader(header: "Authorization", prefix: "Bearer ")   // default "Approov-Token", no prefix
ApproovService.setTraceIDHeader(header: nil)                                // default "Approov-TraceID", nil disables
```

A header carries only tab and printable ASCII. A prefix with another character fails each request with a `URLError`. The older names `approovTokenHeaderAndPrefix`, `getApproovTokenHeader()`, `setApproovTraceIDHeader(header:)` and `getApproovTraceIDHeader()` still work and are deprecated. Each `initialize` that succeeds puts these back to their defaults, so set them after it.

## Bypass initialization

Initialize with an empty string instead of the account ID to start the package in bypass mode. In bypass mode the package is enabled but protects nothing: `isApproovServiceEnabled()` is `true` and `isApproovProtectionEnabled()` is `false`. In this mode:

* requests through an `ApproovHTTPClient` go out with no Approov processing. There is no token, signing, secure strings or Approov connection check, only OS trust.
* the methods that call the SDK do not call it. Those that return a result throw `ApproovError.permanentError` or return `nil`.
* a client that cannot [check the connection](#connection-validation) sends its requests.

Before any `initialize`, the package handles a request the same way as in bypass mode. It does not fail or hold the request.

Bypass mode is a starting or fallback state. Use it, for example, while your app fetches the account ID remotely. The README example also uses it as a guard, in case the account ID does not reach the app intact.

```swift
try ApproovService.initialize(config: "")
```

A later `initialize` with the account ID turns Approov on at runtime, if the SDK accepts it. Like each `initialize` that succeeds, it resets the configuration to its defaults, so make your configuration calls again after it. An `ApproovHTTPClient` you already created protects its requests from then on. A connection that is already open keeps serving requests without the Approov check until it closes (see [Connection validation](#connection-validation)).

Once protection is on, the package ignores an `initialize` with an empty string, and resets nothing. It logs `ApproovService already initialized with a valid config; ignoring empty configuration` at `.info`. The SDK rejects a later `initialize` with a different account ID or a different comment. The package then throws `ApproovError.initializationFailure`, and its state stays the same. See [initialize in the reference](REFERENCE.md#initializeconfigcomment).

## Initialize, then configure

You normally initialize the package once. Call `initialize` and handle any error it throws. It is synchronous. Then make every configuration call your app needs, such as:

* the token and trace headers, `bindHeader`, and `setUseApproovStatusIfNoToken`
* substitution headers and query parameters
* exclusion regular expressions
* the service mutator, and so message signing
* the logging level

Until your configuration calls run, requests use the defaults. A setting applies to requests that the package processes after you make it.

```swift
try ApproovService.initialize(config: "<your-approov-account-id>")
ApproovService.setServiceMutator(.ALWAYS_PROCEED)
```

Configure immediately after `initialize`, before the app sends protected requests. The [README](README.md#initializing) shows where to call `initialize`.

Each `initialize` that succeeds resets these settings to their defaults:

* the token and trace headers, and `bindHeader`
* `setUseApproovStatusIfNoToken`
* the substitutions and the exclusions
* the service mutator

It also clears `getLastARC()`. It keeps the logging level. The package loses any other setting made before `initialize`.

Two kinds of `initialize` change nothing: an empty account ID after protection is on, and a call that the SDK rejects (see [Bypass initialization](#bypass-initialization)). A repeat call with the same account ID and comment succeeds, for example from another Approov package in the same app. It resets this package's configuration too.

When the SDK initializes, `initialize` logs `ApproovService: Approov SDK initialized` at `.info`. When the SDK was already initialized with the same account ID and comment, it logs `ApproovService: Approov SDK already initialized` at `.info`.

### About the Approov account ID

The string you pass to `initialize` looks like `#your-account#p6nZ...=`. It names your account and ends with a hash of the account's public key, which the SDK checks. The same value serves every app in the account, and it is not a secret.

## Token binding

[Token binding](https://docs.approov.io/backend-integration/token-binding/) ties the Approov token to the value of a header on the request, typically an OAuth `Authorization` header. A token then cannot be replayed with different credentials.

There is no binding header by default. Set one when your requests carry a credential header, such as an OAuth `Authorization` header, whose value changes rarely, such as a long-lived OAuth token. Each new value makes the SDK fetch a new token from the Approov service.

```swift
ApproovService.bindHeader = "Authorization"
```

The package reads the value from the request. It finds the header without regard to case.

The SDK holds one binding value for the whole app. For each request that carries the binding header, the package sets that value and fetches the token in one locked step. So each token carries the value of its own request. While one request is in this step, other requests that carry the binding header wait. Requests without it do not wait.

The package binds each redirect hop again. Do not mix `bindHeader` with direct `setDataHashInToken(data:)` calls, because both set the same SDK value. The token your backend receives carries the `pay` claim.

## Secure strings

[Secure strings](https://docs.approov.io/backend-integration/secure-strings/) let you remove API keys and other secrets from your app. An app that passes attestation receives them at runtime from the Approov service. You put a placeholder in a request header or query parameter, and the package replaces it with the secret before it sends the request.

By default there are no substitution headers or query parameters, so a secure string placeholder goes out unchanged. Register the headers and query parameters whose values are secure string keys.

```swift
ApproovService.addSubstitutionHeader(header: "X-Api-Key", prefix: nil)         // whole value is the key
ApproovService.addSubstitutionHeader(header: "Authorization", prefix: "Bearer ") // value after the prefix is the key
ApproovService.addSubstitutionQueryParam(key: "api_key")
```

The package substitutes only on an https request to a secrets-only domain, or to a token-protected domain after a successful token fetch. If the secure string fetch for a value fails, the package writes the fetch status name in its place, such as `Api-Key: REJECTED`. The request goes ahead. `UNKNOWN_KEY` is the exception. Your account defines no secure string for that value, so the package leaves it as your app wrote it. Neither standard mutator fails a request because of a secure string.

The package matches header names without regard to case. It substitutes every occurrence of a query parameter on its own, and changes nothing else in the URL. On a redirect to another URL, it does not look up the query values that the server sent.

The package leaves a placeholder as written, and logs a warning that names the header or query parameter, in these cases:

* a cleartext request, or a token fetch that returns `BAD_URL`
* a secret that a header or the URL cannot carry unchanged. A header carries only tab and printable ASCII.

Your backend receives the secret in place of the key. When it does not, the value it receives gives the reason: a status name such as `REJECTED`, or the key itself. The package logs each fetch at `.debug`, such as `ApproovService: header substitution: X-Api-Key, REJECTED, ARC: <arc>` (see [Diagnostics](#diagnostics)).

## Excluding URLs

The package sends a request untouched, without a token fetch, if its URL contains a match for an exclusion regular expression. The expression is not anchored, and the package compares it with the full URL, query included. Use `^` and `$` to match the whole URL. The default `handleInterceptorShouldProcessRequest` applies the exclusions. A mutator that overrides it drops them, unless it calls `ApproovCloseFailureMutator.CLOSE_FAILURE.handleInterceptorShouldProcessRequest(request)`.

There are no exclusions by default. Use them for requests to your API domains that should not fetch a token, such as a health check.

```swift
ApproovService.addExclusionURLRegex(urlRegex: "^https://api\\.example\\.com/health.*")
```

Connection checks still apply to excluded requests on domains added to Approov. Each `initialize` that succeeds resets the exclusions.

`addExclusionURLRegex` logs the expression at `.debug`. The package logs an invalid regular expression as an error and adds nothing.

## Connection validation

An `ApproovHTTPClient` checks the TLS connection to each domain you added to Approov. It matches the domain without regard to case or a trailing dot. It checks against the certificate public keys configured for the domain. For a domain with none defined, it falls back to the Managed Trust Roots. With neither, the connection relies on OS trust, and the package logs one warning per host.

It is on by default for every domain you added to Approov. The OS first evaluates the certificate chain. The package then takes each certificate in the path that the OS built, trust anchor included. It compares the public key of each one with the keys for the domain. A certificate that the server sends outside that path cannot match. A request whose connection fails either check fails with `URLError(.serverCertificateUntrusted)`, at the connect timeout. If the SDK gives no pins, the package refuses the connection.

A host that you did not add to Approov connects on OS trust. A connection to an IP address also connects on OS trust, unless an IP address in your Approov configuration has keys. In that case the package refuses it, because it cannot tell which host it is. In [bypass mode](#bypass-initialization), every connection relies on OS trust. `signRequest(_:)` and `updateRequestWithApproov(request:)` do not check the connection.

A failure logs an error that names the host, such as `ApproovService: Pinning rejection for api.example.com`.

The package checks a connection once, in its TLS handshake, with the pins that the SDK has at that time. AsyncHTTPClient keeps connections in a pool, so an open connection keeps serving requests under its earlier check until it closes. To apply new pins to every connection at once, shut down the client and create a new one.

`handlePinningShouldProcessRequest(hostname:)` on your mutator can turn the check off for a host. The package asks the mutator that is installed when the connection opens. Its answer applies to every request that reuses the connection.

The check runs only on Network.framework, so it needs a `NIOTSEventLoopGroup`, `.fullVerification` and no proxy. While Approov is enabled, the client refuses each request with `URLError(.unknown)` in these cases:

* an `ApproovHTTPClient` made with an event loop group that is not a `NIOTSEventLoopGroup`, such as `MultiThreadedEventLoopGroup`
* a `delegateAndChannel` event loop preference with an event loop that is not a NIOTS event loop
* a client or request TLS configuration whose `certificateVerification` is not `.fullVerification`
* a client configuration with a proxy (`HTTPClient.Configuration.proxy`)

`.createNew` gives a group that the check can use. In bypass mode, these clients work. The client makes this test for each request, so such a client starts to refuse requests when a later `initialize` turns protection on.

### WebSockets

WebSockets are not supported. The package sends a request with `Upgrade: websocket` unchanged, with no Approov token or secure string. Do not put a secure string placeholder on one and expect the package to substitute it. The connection check still applies.

## Redirects

`ApproovHTTPClient` follows redirects itself, with the `redirectConfiguration` of your client configuration. It uses the redirect rules of AsyncHTTPClient, such as the limit, cycle detection, and the change to `GET` after a 303. It protects each hop as a new request for its target:

* Each hop starts from your app's request, not from the protected request of the previous hop. So no token, trace header, signature or secret that the package added reaches another host.
* The package fetches a token for the target URL of each hop. A redirect from any host into one of your API domains carries a token for that domain.
* On a redirect to another origin, AsyncHTTPClient rules remove the `Origin`, `Cookie`, `Authorization` and `Proxy-Authorization` headers.
* The package uses the target URL as the server sent it, and it does not look up its query values as secure strings.
* A 307 or 308 redirect keeps the body, and the package computes its `Content-Digest` again.
* A request keeps the mutator it started with, across its redirects.
* A request `tlsConfiguration` applies to each hop.

Your response delegate does not see the redirect responses, as with AsyncHTTPClient. With the `async` API, a body that AsyncHTTPClient can send only once ends the chain, and your app receives the redirect response. A `cancel()` on the task stops the next hop.

If you give the client `.disallow`, it does not follow redirects, and your app receives the redirect response.

## Service mutators

A service mutator, an `ApproovServiceMutator`, is the object that holds the package's decisions, such as whether a failed token fetch fails the request. It has one method for each decision, and the package asks the installed mutator at each decision point. The standard mutators and their decisions are in [What happens by default](#what-happens-by-default).

Write your own mutator when your app needs a decision that the standard ones do not make. Every method has a default, the `CLOSE_FAILURE` decision, so implement only what you need. A mutator of your own that should never abort a request delegates the token decisions to `ApproovAlwaysProceedMutator.ALWAYS_PROCEED`. A mutator you install applies to requests processed after the call.

The package's signer is also a mutator. To sign under decisions of your own, see [Sign with other decisions](#sign-with-other-decisions).

The hooks:

| Hook | Decides |
| :--- | :--- |
| `handleInterceptorShouldProcessRequest` | whether a request has Approov processing at all (by default, every request that is not excluded) |
| `handleInterceptorFetchTokenResult` | given the token fetch result, whether to send the request with its Approov headers, send it without them, or abort it |
| `handleInterceptorHeaderSubstitutionResult`, `handleInterceptorQueryParamSubstitutionResult` | whether to apply a secure string substitution |
| `handleInterceptorProcessedRequest` | final changes to the processed request. The signer signs after it |
| `handlePinningShouldProcessRequest(hostname:)` | whether Approov connection checks (Managed Trust Roots or configured public keys) apply to a host |
| `handlePrecheckResult`, `handleFetchTokenResult`, `handleFetchSecureStringResult`, `handleFetchCustomJWTResult` | how the direct methods turn a result into an error |

To fail a request on your own terms, throw a `URLError` from a hook. Your app's error handling then sees an ordinary network failure (see [Errors your app can see](#errors-your-app-can-see)). This mutator fails a request when the app cannot reach the Approov service, and keeps the `CLOSE_FAILURE` decisions for the other statuses:

```swift
import Approov
import ApproovAsyncHTTPClient
import Foundation

final class EnforceTokenMutator: ApproovServiceMutator {
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
        if approovResults.status == .noApproovService {
            // fail the request, so that only requests with a token reach the backend
            throw URLError(.cannotConnectToHost)
        }
        return try ApproovCloseFailureMutator.CLOSE_FAILURE.handleInterceptorFetchTokenResult(approovResults, url: url)
    }
}

ApproovService.setServiceMutator(EnforceTokenMutator())
```

The package also calls `handleInterceptorFetchTokenResult` after a failure for a host not protected by Approov. It ignores a standard decision there, but a `URLError` that your code throws fails that request too.

This mutator adds headers after the package processed the request. Install it with `combined(decisions:)` if the signature must cover them:

```swift
import ApproovAsyncHTTPClient
import Foundation

final class MetadataMutator: ApproovServiceMutator {
    func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                           changes: ApproovRequestMutations) throws -> ApproovRequest {
        var processed = request
        processed.headers.replaceOrAdd(name: "Client-Platform", value: "ios")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            processed.headers.replaceOrAdd(name: "App-Version", value: version)
        }
        return processed
    }
}

ApproovService.setServiceMutator(ApproovDefaultMessageSigning.combined(decisions: MetadataMutator()))
```

## Diagnostics

The package writes a diagnostic line for each token fetch, and for each secure string fetch.

The package writes these lines at debug level, which is off by default. The default level is `.info`. To write them, set the level in a debug build:

```swift
ApproovService.setLoggingLevel(.debug)
```

The levels are `.off`, `.error`, `.warning`, `.info` and `.debug`. Each level writes its own lines and the lines of the more severe levels. The package writes through `os_log`, so the lines appear in the Xcode console. `.off` silences the package completely. `initialize` does not change the level.

The package never logs a token. For each request it processes, it logs the [loggable form](https://docs.approov.io/core-concepts/approov-tokens/architecture-and-security/#loggable-tokens) of the result. Its `arc` claim, the [Attestation Response Code](https://docs.approov.io/app-integration/frontend/attestation/#attestation-response-code), tells why attestation gave that result. The direct methods, such as `fetchToken`, log only the status. For example:

```
ApproovService: updateRequest https://api.example.com/v1/items: {"did":"...","exp":1757400000,"arc":"IXPSB7TRK26LXE3M", ...,"sip":"a1b2c3"}
```

The line shows the scheme, host, any port that is not the default, and path of the request. It does not show user info, the query or the fragment, which can carry a substituted secure string or personal data.

At `.info`, the package logs each request that it sends without Approov processing, such as `ApproovService: excluded, forwarding: https://api.example.com/health`.

`ApproovService.getLastARC()` returns the ARC of the most recent fetch the package made, without making one of its own. It returns `""` before the first fetch, and when ARC is not enabled for the account.

To find the reasons behind an `arc`, see [decoding an Attestation Response Code](https://docs.approov.io/app-integration/frontend/attestation/#decoding-an-attestation-response-code). Your account's [metrics](https://docs.approov.io/operations/metrics-graphs/grafana-overview/) show the same results in aggregate. A [development signing certificate](https://docs.approov.io/operations/app-signing-certificates/development-and-testing/#development-app-signing-certificates) lets debug builds pass attestation.
