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

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// The redirect settings of the app's `HTTPClient.Configuration`. The wrapped client never follows a redirect:
/// `ApproovHTTPClient` follows it, so that it can protect each hop as a new request (SPEC 7.3).
struct ApproovRedirectPolicy: Equatable {
    let max: Int
    let allowCycles: Bool

    /// Reads the app's redirect settings, or nil when the app disallows redirects. `RedirectConfiguration.mode` is
    /// internal to AsyncHTTPClient, so it is read with `Mirror`. If its shape is not known, the AsyncHTTPClient
    /// default applies (at most 5 redirects, no cycles) and an error is logged.
    static func of(_ configuration: HTTPClient.Configuration.RedirectConfiguration) -> ApproovRedirectPolicy? {
        if let mode = Mirror(reflecting: configuration).children.first(where: { $0.label == "mode" })?.value {
            let modeMirror = Mirror(reflecting: mode)
            if modeMirror.displayStyle == .enum, modeMirror.children.isEmpty, String(describing: mode) == "disallow" {
                return nil
            }
            if let payload = modeMirror.children.first, payload.label == "follow" {
                let values = Mirror(reflecting: payload.value).children.map { $0.value }
                if values.count == 2, let max = values[0] as? Int, let allowCycles = values[1] as? Bool {
                    return ApproovRedirectPolicy(max: max, allowCycles: allowCycles)
                }
            }
        }
        ApproovService.log(.error, "ApproovHTTPClient: the redirect configuration cannot be read; at most 5 redirects are followed")
        return ApproovRedirectPolicy(max: 5, allowCycles: false)
    }
}

/// Counts the hops of one request as AsyncHTTPClient does: at most `max` redirects, and no URL twice unless
/// cycles are allowed.
struct ApproovRedirectTracker {
    private let policy: ApproovRedirectPolicy
    private var visited: [String]

    init(policy: ApproovRedirectPolicy, initialURL: String) {
        self.policy = policy
        self.visited = [initialURL]
    }

    mutating func redirect(to url: String) throws {
        guard visited.count <= policy.max else {
            throw HTTPClientError.redirectLimitReached
        }
        guard policy.allowCycles || !visited.contains(url) else {
            throw HTTPClientError.redirectCycleDetected
        }
        visited.append(url)
    }
}

/// The redirect rules of AsyncHTTPClient 1.10.2, which the wrapper applies itself.
enum ApproovRedirects {
    /// The response statuses that AsyncHTTPClient follows when they carry a `Location`.
    static let followedStatuses: Set<UInt> = [301, 302, 303, 304, 305, 307, 308]

    private static let webSchemes: Set<String> = ["http", "https"]
    private static let knownSchemes: Set<String> = ["http", "https", "unix", "http+unix", "https+unix"]

    /// The redirect target of a response: a followed status with a `Location`, resolved against the URL of the
    /// request. After an http or https request only an http or https target is followed, and never a file URL.
    static func target(status: HTTPResponseStatus, headers: HTTPHeaders, from url: URL) -> URL? {
        guard followedStatuses.contains(status.code), let location = headers.first(name: "Location"),
              let resolved = URL(string: location, relativeTo: url) else {
            return nil
        }
        let fromScheme = url.scheme?.lowercased() ?? ""
        let toScheme = resolved.scheme?.lowercased() ?? ""
        guard knownSchemes.contains(toScheme), !resolved.isFileURL else {
            return nil
        }
        if webSchemes.contains(fromScheme) && !webSchemes.contains(toScheme) {
            return nil
        }
        return resolved.absoluteURL
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.host == rhs.host && lhs.scheme == rhs.scheme && lhs.port == rhs.port
    }

    /// The method and headers of the next hop, and whether it keeps the body, as AsyncHTTPClient changes them.
    static func transform(method: HTTPMethod, headers: HTTPHeaders, from: URL, to: URL,
                          status: HTTPResponseStatus) -> (method: HTTPMethod, headers: HTTPHeaders, keepsBody: Bool) {
        let toGET = (status == .seeOther && method != .HEAD)
            || ((status == .movedPermanently || status == .found) && method == .POST)
        var nextMethod = method
        var nextHeaders = headers
        if toGET {
            nextMethod = .GET
            nextHeaders.remove(name: "Content-Length")
            nextHeaders.remove(name: "Content-Type")
        }
        if !isSameOrigin(from, to) {
            for name in ["Origin", "Cookie", "Authorization", "Proxy-Authorization"] {
                nextHeaders.remove(name: name)
            }
        }
        return (nextMethod, nextHeaders, !toGET)
    }

    /// The URL of the next hop and whether its query holds the app's own placeholders (SPEC 7.3). A target that is
    /// the URL that was sent is the app's URL again. Any other target is used exactly as the server sent it, and
    /// its query values are never looked up (T37-13a).
    static func nextURL(target: URL, wireURL: URL, appURL: URL, appQuery: Bool) -> (url: URL, appQuery: Bool) {
        if target.absoluteString == wireURL.absoluteString {
            return (appURL, appQuery)
        }
        return (target, false)
    }

    /// Whether an async request body can be sent again, as AsyncHTTPClient decides it. The body mode is internal,
    /// so it is read with `Mirror`. An unknown shape is not sent again.
    static func canBeSentAgain(_ body: HTTPClientRequest.Body?) -> Bool {
        guard let body else {
            return true
        }
        guard let mode = Mirror(reflecting: body).children.first(where: { $0.label == "mode" })?.value,
              let payload = Mirror(reflecting: mode).children.first, let label = payload.label else {
            return false
        }
        switch label {
        case "byteBuffer":
            return true
        case "sequence":
            let values = Array(Mirror(reflecting: payload.value).children)
            if let flag = values.first(where: { $0.label == "canBeConsumedMultipleTimes" })?.value as? Bool {
                return flag
            }
            return values.count >= 3 ? (values[1].value as? Bool ?? false) : false
        default:
            return false
        }
    }
}

/// One hop of an `HTTPClient.Request` as the app's request makes it: the app's headers, never the layer's.
struct ApproovRequestHop {
    var request: HTTPClient.Request
    var substituteQuery: Bool

    func following(status: HTTPResponseStatus, to target: URL, wireURL: URL) throws -> ApproovRequestHop {
        let next = ApproovRedirects.transform(method: request.method, headers: request.headers, from: wireURL,
                                              to: target, status: status)
        let url = ApproovRedirects.nextURL(target: target, wireURL: wireURL, appURL: request.url, appQuery: substituteQuery)
        // AsyncHTTPClient drops the request's TLS configuration on a redirect. The wrapper keeps it.
        let nextRequest = try HTTPClient.Request(url: url.url, method: next.method, headers: next.headers,
                                                 body: next.keepsBody ? request.body : nil,
                                                 tlsConfiguration: request.tlsConfiguration)
        return ApproovRequestHop(request: nextRequest, substituteQuery: url.appQuery)
    }
}

/// One hop of an `HTTPClientRequest` as the app's request makes it.
struct ApproovClientRequestHop {
    var request: HTTPClientRequest
    var substituteQuery: Bool

    func following(status: HTTPResponseStatus, to target: URL, wireURL: URL) -> ApproovClientRequestHop {
        let next = ApproovRedirects.transform(method: request.method, headers: request.headers, from: wireURL,
                                              to: target, status: status)
        let appURL = URL(string: request.url) ?? wireURL
        let url = ApproovRedirects.nextURL(target: target, wireURL: wireURL, appURL: appURL, appQuery: substituteQuery)
        var nextRequest = HTTPClientRequest(url: url.url.absoluteString)
        nextRequest.method = next.method
        nextRequest.headers = next.headers
        nextRequest.body = next.keepsBody ? request.body : nil
        return ApproovClientRequestHop(request: nextRequest, substituteQuery: url.appQuery)
    }
}
