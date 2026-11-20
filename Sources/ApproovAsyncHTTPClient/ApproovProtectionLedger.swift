// ApproovService for integrating Approov into apps using AsyncHTTPClient
// (https://github.com/swift-server/async-http-client).
//
// MIT License
//
// Copyright (c) 2016-present, Critical Blue Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation
import NIOConcurrencyHelpers
import NIOHTTP1

/// What the layer installed on the requests it protected (T37-38, SPEC 7.3). A protected request that comes back
/// to the layer, such as `signRequest` output passed to `ApproovHTTPClient`, is put back as the app wrote it before
/// it is protected again. So a secure string is never looked up with a secret as its key, and the request carries
/// one token header and one signature. The ledger keeps a SHA-256 digest of each installed value, never the value,
/// with the app's own value. It keeps the most recent `capacity` entries.
final class ApproovProtectionLedger {
    static let shared = ApproovProtectionLedger()
    static let capacity = 1024

    private struct AppValue {
        let value: String?
    }

    private let lock = NIOLock()
    private var headers: [String: AppValue] = [:]
    private var urls: [String: URL] = [:]
    private var order: [String] = []

    private static func digest(_ value: String) -> String {
        ApproovPinningVerifier.sha256(data: Data(value.utf8)).base64EncodedString()
    }

    private static func headerKey(_ name: String, _ value: String) -> String {
        "h:" + name.lowercased() + "\n" + digest(value)
    }

    private static func urlKey(_ url: URL) -> String {
        "u:" + digest(url.absoluteString)
    }

    /// Records each header value and the URL that `protected` carries and `original`, the app's request, does not.
    func record(original: ApproovRequest, protected: ApproovRequest) {
        var installed: [(String, AppValue)] = []
        for (name, value) in protected.headers where !original.headers[name].contains(value) {
            installed.append((Self.headerKey(name, value), AppValue(value: original.headers.first(name: name))))
        }
        let urlChanged = protected.url.absoluteString != original.url.absoluteString
        if installed.isEmpty && !urlChanged {
            return
        }
        let protectedURLKey = Self.urlKey(protected.url)
        lock.withLock {
            for (key, appValue) in installed where headers.updateValue(appValue, forKey: key) == nil {
                order.append(key)
            }
            if urlChanged, urls.updateValue(original.url, forKey: protectedURLKey) == nil {
                order.append(protectedURLKey)
            }
            while order.count > Self.capacity {
                let oldest = order.removeFirst()
                headers[oldest] = nil
                urls[oldest] = nil
            }
        }
    }

    /// Puts back as the app wrote it each header value and the URL that the layer installed. A header that the app
    /// did not have is removed.
    func restore(_ request: ApproovRequest) -> ApproovRequest {
        if lock.withLock({ headers.isEmpty && urls.isEmpty }) {
            return request
        }
        var fields: [(String, String)] = []
        var changed = false
        for (name, value) in request.headers {
            let key = Self.headerKey(name, value)
            if let appValue = lock.withLock({ headers[key] }) {
                changed = true
                if let value = appValue.value {
                    fields.append((name, value))
                }
            } else {
                fields.append((name, value))
            }
        }
        var restored = request
        if changed {
            restored.headers = HTTPHeaders(fields)
        }
        let key = Self.urlKey(request.url)
        if let appURL = lock.withLock({ urls[key] }) {
            restored.url = appURL
        }
        return restored
    }

    func resetForTesting() {
        lock.withLock {
            headers = [:]
            urls = [:]
            order = []
        }
    }
}
