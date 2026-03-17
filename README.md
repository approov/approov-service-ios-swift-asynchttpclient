# Approov Service for AsyncHTTPClient

A wrapper for the [Approov SDK](https://github.com/approov/approov-ios-sdk) to enable easy integration when using [`AsyncHTTPClient`](https://github.com/swift-server/async-http-client) for making the API calls that you wish to protect with Approov. In order to use this you will need a trial or paid [Approov](https://www.approov.io) account.

Please see the [Quickstart](https://github.com/approov/quickstart-ios-swift-asynchttpclient) for example integration.

## Swift Package Manager Import

When adding this package with Swift Package Manager, import the module as:

```swift
import ApproovAsyncHTTPClient
import Approov
```

The primary client type is `ApproovHTTPClient`, while `ApproovService` provides lower-level configuration and direct SDK helper methods.

# Reference

Please see the [REFERENCE.md](REFERENCE.md) for more information on the Approov Service for AsyncHTTPClient.

# Usage

Please see the [USAGE.md](USAGE.md) for more information on how to use this wrapper.
