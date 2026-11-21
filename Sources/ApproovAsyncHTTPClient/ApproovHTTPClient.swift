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
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTLS
import NIOTransportServices


// Based on https://github.com/swift-server/async-http-client/tree/main/Sources/AsyncHTTPClient/HTTPClient.swift
public class ApproovHTTPClient {

    let httpClientDelegate: HTTPClient

    /// Why Approov pinning cannot run on this client, or nil when it can.
    let pinningUnavailableReason: String?

    /// The app's redirect settings, or nil when the app disallows redirects. The wrapped client never follows a
    /// redirect: this client follows it and protects each hop as a new request.
    let redirectPolicy: ApproovRedirectPolicy?

    internal static let loggingDisabled = Logger(label: "ApproovHTTPClient-do-not-log",
        factory: { _ in SwiftLogNoOpLogHandler() })

    /// Create an `ApproovHTTPClient` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public convenience init(eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider,
                            configuration: HTTPClient.Configuration = HTTPClient.Configuration()) {
        self.init(eventLoopGroupProvider: eventLoopGroupProvider,
                  configuration: configuration,
                  backgroundActivityLogger: ApproovHTTPClient.loggingDisabled)
    }

    /// Create an `ApproovHTTPClient` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public required init(eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider,
                         configuration: HTTPClient.Configuration = HTTPClient.Configuration(),
                         backgroundActivityLogger: Logger) {
        var wrappedConfiguration = configuration
        wrappedConfiguration.redirectConfiguration = .disallow
        redirectPolicy = ApproovRedirectPolicy.of(configuration.redirectConfiguration)
        httpClientDelegate = HTTPClient(eventLoopGroupProvider: eventLoopGroupProvider,
                   configuration: wrappedConfiguration,
                   backgroundActivityLogger: backgroundActivityLogger)
        // AsyncHTTPClient runs the Approov pin check only on the Network.framework path, which needs a
        // NIOTSEventLoopGroup, and only when TLS verification is full.
        var reason: String? = nil
        if case .shared(let group) = eventLoopGroupProvider, !ApproovHTTPClient.usesNetworkFramework(group) {
            reason = "ApproovHTTPClient needs a NIOTSEventLoopGroup: Approov pinning does not run on \(type(of: group))"
        } else if let tls = configuration.tlsConfiguration, tls.certificateVerification != .fullVerification {
            reason = "ApproovHTTPClient TLS configuration: certificateVerification must be .fullVerification, because Approov pinning does not run otherwise"
        }
        pinningUnavailableReason = reason
    }

    /// Whether AsyncHTTPClient connects on the Network.framework path for a group or an event loop. It is the
    /// same check that AsyncHTTPClient makes when it selects the connection bootstrap.
    static func usesNetworkFramework(_ group: EventLoopGroup) -> Bool {
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            return NIOTSConnectionBootstrap(validatingGroup: group) != nil
        }
        return false
    }

    /// Fails a request when Approov protection is on and pinning cannot run on this client.
    static func checkPinningAvailable(_ reason: String?) throws {
        if let reason, ApproovService.isApproovEnabled() {
            throw ApproovRequestPathError.configuration(reason)
        }
    }

    /// Shuts down the client and `EventLoopGroup` if it was created by the client.
    public func syncShutdown() throws {
        try httpClientDelegate.syncShutdown()
    }

    /// Shuts down the client and event loop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    public func shutdown(queue: DispatchQueue = .global(), _ callback: @escaping (Error?) -> Void) {
        httpClientDelegate.shutdown(queue: queue, callback)
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    public func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response> {
        return self.get(url: url, deadline: deadline, logger: ApproovHTTPClient.loggingDisabled)
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func get(url: String, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(.GET, url: url, deadline: deadline, logger: logger)
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func post(
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.post(url: url, body: body, deadline: deadline, logger: ApproovHTTPClient.loggingDisabled)
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func post(
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(.POST, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func patch(
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.patch(url: url, body: body, deadline: deadline, logger: ApproovHTTPClient.loggingDisabled)
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func patch(
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(.PATCH, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func put(
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.put(url: url, body: body, deadline: deadline, logger: ApproovHTTPClient.loggingDisabled)
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func put(
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(.PUT, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    public func delete(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<HTTPClient.Response> {
        return self.delete(url: url, deadline: deadline, logger: ApproovHTTPClient.loggingDisabled)
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    ///     - logger: The logger to use for this request.
    public func delete(
        url: String,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(.DELETE, url: url, deadline: deadline, logger: logger)
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - url: Request url.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        _ method: HTTPMethod = .GET,
        url: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: method, body: body)
            return self.execute(request: request, deadline: deadline, logger: logger ?? ApproovHTTPClient.loggingDisabled)
        } catch {
            return httpClientDelegate.eventLoopGroup.any().makeFailedFuture(error)
        }
    }

    /// Execute arbitrary HTTP+UNIX request to a unix domain socket path, using the specified URL as the request to send to the server.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - socketPath: The path to the unix domain socket to connect to.
    ///     - urlPath: The URL path and query that will be sent to the server.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        _ method: HTTPMethod = .GET,
        socketPath: String,
        urlPath: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        // Must always use TLS with Approov (hence secureSocketPath)
        return self.execute(method, secureSocketPath: socketPath, urlPath: urlPath, body: body, deadline: deadline,
            logger: logger)
    }

    /// Execute arbitrary HTTPS+UNIX request to a unix domain socket path over TLS, using the specified URL as the request to send to the server.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - secureSocketPath: The path to the unix domain socket to connect to.
    ///     - urlPath: The URL path and query that will be sent to the server.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        _ method: HTTPMethod = .GET,
        secureSocketPath: String,
        urlPath: String,
        body: HTTPClient.Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        do {
            guard let url = URL(httpsURLWithSocketPath: secureSocketPath, uri: urlPath) else {
                throw HTTPClientError.invalidURL
            }
            let request = try HTTPClient.Request(url: url, method: method, body: body)
            return self.execute(request: request, deadline: deadline, logger: logger ?? ApproovHTTPClient.loggingDisabled)
        } catch {
            return httpClientDelegate.eventLoopGroup.any().makeFailedFuture(error)
        }
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(
        request: HTTPClient.Request,
        deadline: NIODeadline? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(request: request, deadline: deadline, logger: ApproovHTTPClient.loggingDisabled)
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        request: HTTPClient.Request,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<HTTPClient.Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, deadline: deadline, logger: logger).futureResult
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(
        request: HTTPClient.Request,
        eventLoop: HTTPClient.EventLoopPreference,
        deadline: NIODeadline? = nil
    ) -> EventLoopFuture<HTTPClient.Response> {
        return self.execute(
            request: request,
            eventLoop: eventLoop,
            deadline: deadline,
            logger: ApproovHTTPClient.loggingDisabled
        )
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        request: HTTPClient.Request,
        eventLoop eventLoopPreference: HTTPClient.EventLoopPreference,
        deadline: NIODeadline? = nil,
        logger: Logger?
    ) -> EventLoopFuture<HTTPClient.Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, eventLoop: eventLoopPreference, deadline: deadline,
            logger: logger).futureResult
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: HTTPClient.Request,
        delegate: Delegate,
        deadline: NIODeadline? = nil
    ) -> ApproovHTTPClient.Task<Delegate, Delegate.Response> {
        return self.execute(
            request: request,
            delegate: delegate,
            deadline: deadline,
            logger: ApproovHTTPClient.loggingDisabled
        )
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: HTTPClient.Request,
        delegate: Delegate,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> ApproovHTTPClient.Task<Delegate, Delegate.Response> {
        return self.execute(request: request, delegate: delegate, eventLoop: .indifferent, deadline: deadline,
            logger: logger)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: HTTPClient.Request,
        delegate: Delegate,
        eventLoop eventLoopPreference: HTTPClient.EventLoopPreference,
        deadline: NIODeadline? = nil
    ) -> ApproovHTTPClient.Task<Delegate, Delegate.Response> {
        return self.execute(
            request: request,
            delegate: delegate,
            eventLoop: eventLoopPreference,
            deadline: deadline,
            logger: ApproovHTTPClient.loggingDisabled
        )
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: HTTPClient.Request,
        delegate: Delegate,
        eventLoop eventLoopPreference: HTTPClient.EventLoopPreference,
        deadline: NIODeadline? = nil,
        logger originalLogger: Logger?
    ) -> ApproovHTTPClient.Task<Delegate, Delegate.Response> {
        let preference = EventLoopPreference(eventLoopPreference)
        var reason = pinningUnavailableReason
        if reason == nil, case .delegateAndChannel(on: let eventLoop) = preference.preference,
           !ApproovHTTPClient.usesNetworkFramework(eventLoop) {
            // A channel event loop that is not a NIOTSEventLoop forces the NIOSSL path, where pinning does not run.
            reason = "ApproovHTTPClient: delegateAndChannel needs a NIOTSEventLoop for Approov pinning"
        }
        let task = ApproovHTTPClient.Task<Delegate, Delegate.Response>(
            httpClientDelegate: httpClientDelegate,
            request: request,
            delegate: delegate,
            eventLoopPreference: preference,
            deadline: deadline,
            logger: originalLogger ?? ApproovHTTPClient.loggingDisabled,
            pinningUnavailableReason: reason,
            redirectPolicy: redirectPolicy)
        task.runInBackground()
        return task
    }

    /// Update a request for Approov
    static func approovUpdateRequest(request: HTTPClient.Request, mutator: ApproovServiceMutator, substituteQuery: Bool) throws -> HTTPClient.Request {
        // In the Approov AsyncHTTPClient fork, a TLS configuration without full verification completes the
        // handshake without the Approov pin check. Reject it, so that one request option cannot disable pinning.
        if let tlsConfiguration = request.tlsConfiguration,
           tlsConfiguration.certificateVerification != .fullVerification,
           ApproovService.isApproovEnabled() {
            throw ApproovRequestPathError.configuration(
                "Request TLS configuration for \(request.url.host ?? ""): certificateVerification must be "
                + ".fullVerification, because Approov pinning does not run otherwise")
        }
        // The body closure runs before the send only if the mutator gets the body, for a body digest.
        let approovReq = ApproovRequest(
            url: request.url,
            method: request.method.rawValue,
            headers: request.headers,
            bodyProvider: { ApproovService.extractBodyData(from: request.body) }
        )
        
        let response = ApproovService.updateRequestWithApproov(request: approovReq, mutator: mutator, substituteQuery: substituteQuery)
        if let error = response.error {
            throw error
        }
        
        switch response.decision {
        case .ShouldProceed, .ShouldIgnore:
            return try HTTPClient.Request(
                url: response.request.url,
                method: request.method,
                headers: response.request.headers,
                body: request.body,
                tlsConfiguration: request.tlsConfiguration
            )
        case .ShouldRetry:
            throw ApproovError.networkingError(message: "Token fetch for \(request.url.host ?? ""): \(response.sdkMessage)")
        case .ShouldFail:
            throw ApproovError.permanentError(message: "Token fetch for \(request.url.host ?? ""): \(response.sdkMessage)")
        }
    }
}

// Based on https://github.com/swift-server/async-http-client/tree/main/Sources/AsyncHTTPClient/AsyncAwait/HTTPClient+execute.swift
extension ApproovHTTPClient {
    /// Execute arbitrary HTTP requests.
    ///
    /// - Parameters:
    ///   - request: HTTP request to execute.
    ///   - deadline: Point in time by which the request must complete.
    ///   - logger: The logger to use for this request.
    /// - Returns: The response to the request. Note that the `body` of the response may not yet have been fully received.
    public func execute(
        _ request: HTTPClientRequest,
        deadline: NIODeadline,
        logger: Logger? = nil
    ) async throws -> HTTPClientResponse {
        try ApproovHTTPClient.checkPinningAvailable(pinningUnavailableReason)
        // One request, one mutator, and each hop is the app's request for its URL.
        let mutator = ApproovService.getServiceMutator()
        var tracker = redirectPolicy.map { ApproovRedirectTracker(policy: $0, initialURL: request.url) }
        var hop = ApproovClientRequestHop(request: request, substituteQuery: true)
        while true {
            let start = ProcessInfo.processInfo.systemUptime
            let current = hop
            let wireRequest = try await ApproovHTTPClient.runOffCooperativePool {
                try ApproovHTTPClient.approovUpdateRequest(request: current.request, mutator: mutator,
                                                           substituteQuery: current.substituteQuery)
            }
            let response: HTTPClientResponse
            do {
                response = try await httpClientDelegate.execute(wireRequest, deadline: deadline, logger: logger)
            } catch {
                throw ApproovPinningVerifier.mapPinningFailure(error, host: URL(string: wireRequest.url)?.host, since: start)
            }
            guard var followed = tracker, let wireURL = URL(string: wireRequest.url),
                  let target = ApproovRedirects.target(status: response.status, headers: response.headers, from: wireURL) else {
                return response
            }
            try followed.redirect(to: target.absoluteString)
            tracker = followed
            let next = hop.following(status: response.status, to: target, wireURL: wireURL)
            // As in AsyncHTTPClient, a body that can be sent only once ends the chain with the redirect response.
            guard ApproovRedirects.canBeSentAgain(next.request.body) else {
                return response
            }
            hop = next
        }
    }

    /// Execute arbitrary HTTP requests.
    ///
    /// - Parameters:
    ///   - request: HTTP request to execute.
    ///   - timeout: time the request has to complete.
    ///   - logger: The logger to use for this request.
    /// - Returns: The response to the request. Note that the `body` of the response may not yet have been fully received.
    public func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger? = nil
    ) async throws -> HTTPClientResponse {
        return try await execute(request, deadline: .now() + timeout, logger: logger)
    }

    /// Runs blocking Approov work on a Dispatch queue. The token fetch blocks its thread, and the Swift
    /// concurrency pool has about one thread for each CPU core, so this work must not run on that pool.
    private static func runOffCooperativePool<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Update a request for Approov
    static func approovUpdateRequest(request: HTTPClientRequest, mutator: ApproovServiceMutator, substituteQuery: Bool) throws -> HTTPClientRequest {
        guard let url = URL(string: request.url) else {
            throw HTTPClientError.invalidURL
        }
        
        let approovReq = ApproovRequest(
            url: url,
            method: request.method.rawValue,
            headers: request.headers,
            bodyProvider: { ApproovHTTPClient.extractBodyData(from: request.body) }
        )
        
        let response = ApproovService.updateRequestWithApproov(request: approovReq, mutator: mutator, substituteQuery: substituteQuery)
        if let error = response.error {
            throw error
        }
        
        switch response.decision {
        case .ShouldProceed, .ShouldIgnore:
            var newRequest = HTTPClientRequest(url: response.request.url.absoluteString)
            newRequest.method = request.method
            newRequest.headers = response.request.headers
            newRequest.body = request.body
            return newRequest
        case .ShouldRetry:
            throw ApproovError.networkingError(message: "Token fetch for \(url.host ?? ""): \(response.sdkMessage)")
        case .ShouldFail:
            throw ApproovError.permanentError(message: "Token fetch for \(url.host ?? ""): \(response.sdkMessage)")
        }
    }

    /// Gets the body bytes of an in-memory or repeatable body, for a body digest. The layer calls this function
    /// only when it computes a body digest. It does not read a one-shot or streaming body.
    private static func extractBodyData(from body: HTTPClientRequest.Body?) -> Data? {
        guard let body = body else { return nil }
        let mirror = Mirror(reflecting: body)
        for child in mirror.children {
            if child.label == "mode" {
                let modeMirror = Mirror(reflecting: child.value)
                guard modeMirror.displayStyle == .enum, let caseLabel = modeMirror.children.first?.label else {
                    continue
                }
                if caseLabel == "byteBuffer", let byteBuffer = modeMirror.children.first?.value as? ByteBuffer {
                    return byteBuffer.getData(at: byteBuffer.readerIndex, length: byteBuffer.readableBytes)
                } else if caseLabel == "sequence" {
                    let associatedValue = modeMirror.children.first!.value
                    let assocMirror = Mirror(reflecting: associatedValue)
                    var canBeConsumedMultipleTimes = false
                    var closure: ((ByteBufferAllocator) -> ByteBuffer)? = nil
                    
                    let childrenArray = Array(assocMirror.children)
                    if childrenArray.count >= 3 {
                        if let flag = childrenArray[1].value as? Bool {
                            canBeConsumedMultipleTimes = flag
                        }
                        if let val = childrenArray[2].value as? (ByteBufferAllocator) -> ByteBuffer {
                            closure = val
                        }
                    } else {
                        for assocChild in assocMirror.children {
                            if assocChild.label == "canBeConsumedMultipleTimes", let value = assocChild.value as? Bool {
                                canBeConsumedMultipleTimes = value
                            } else if let val = assocChild.value as? (ByteBufferAllocator) -> ByteBuffer {
                                closure = val
                            }
                        }
                    }
                    
                    if canBeConsumedMultipleTimes, let closure = closure {
                        let allocator = ByteBufferAllocator()
                        let byteBuffer = closure(allocator)
                        return byteBuffer.getData(at: byteBuffer.readerIndex, length: byteBuffer.readableBytes)
                    }
                }
            }
        }
        // The body is one-shot or streaming, and this function does not read it. Or the AsyncHTTPClient
        // body layout changed and reflection does not match it. In both cases the layer makes no body digest.
        return nil
    }
}

extension ApproovHTTPClient {
    /// Wrapper for HTTPClient.Task that applies Approov related updates to the request.
    /// Can be used for obtaining the `EventLoopFuture<Response>` of the execution or for cancellation of the execution.
    public final class Task<Delegate: HTTPClientResponseDelegate, Response> {
        // Wrapped HTTPClient to execute the request
        let httpClient: HTTPClient

        // HTTP request to execute
        let request: HTTPClient.Request

        // Delegate to process response parts
        let delegate: Delegate

        // NIO Event Loop preference
        let eventLoopPreference: ApproovHTTPClient.EventLoopPreference

        /// The `EventLoop` the delegate will be executed on.
        public let eventLoop: EventLoop

        // Point in time by which the request must complete
        let deadline: NIODeadline?

        // Logger to use for the request. It is okay to store the logger here because a Task is for only one request.
        let logger: Logger

        // Promise that completes when the wrapped HTTPClient.Task's promise completes
        let promise: EventLoopPromise<Delegate.Response>

        // Why Approov pinning cannot run for this request, or nil when it can
        let pinningUnavailableReason: String?

        // The app's redirect settings, or nil when the app disallows redirects
        let redirectPolicy: ApproovRedirectPolicy?

        // Wrapped HTTPClient.Task
        private var _httpClientTask: HTTPClient.Task<Delegate.Response>?

        // Initializer
        init(httpClientDelegate: HTTPClient,
             request: HTTPClient.Request,
             delegate: Delegate,
             eventLoopPreference: ApproovHTTPClient.EventLoopPreference,
             deadline: NIODeadline? = nil,
             logger: Logger,
             pinningUnavailableReason: String? = nil,
             redirectPolicy: ApproovRedirectPolicy? = nil) {
            self.pinningUnavailableReason = pinningUnavailableReason
            self.redirectPolicy = redirectPolicy
            self.httpClient = httpClientDelegate
            self.request = request
            self.delegate = delegate
            self.eventLoopPreference = eventLoopPreference
            self.deadline = deadline
            self.logger = logger
            switch eventLoopPreference.preference {
            case .indifferent:
                self.eventLoop = httpClientDelegate.eventLoopGroup.any()
            case .delegate(on: let eventLoop):
                self.eventLoop = eventLoop
            case .delegateAndChannel(on: let eventLoop):
                self.eventLoop = eventLoop
            }
            self.promise = eventLoop.makePromise()
            self._httpClientTask = nil
        }

        // Lock for access to internal variables
        private let lock = NIOLock()

        // Indicates whether the task has been cancelled
        private var _isCancelled: Bool = false
        var isCancelled: Bool {
            self.lock.withLock {
                self._isCancelled
            }
        }

        // Runs the request as a chain of hops. Each hop is the app's request for its URL, protected on a background
        // thread as a new request, under the mutator that the request started with.
        public func runInBackground() {
            DispatchQueue.global(qos: .userInitiated).async {
                let mutator = ApproovService.getServiceMutator()
                let tracker = self.redirectPolicy.map {
                    ApproovRedirectTracker(policy: $0, initialURL: self.request.url.absoluteString)
                }
                self.runHop(ApproovRequestHop(request: self.request, substituteQuery: true), tracker: tracker, mutator: mutator)
            }
        }

        // Protects and sends one hop. It runs off the event loop, because the token fetch blocks.
        private func runHop(_ hop: ApproovRequestHop, tracker: ApproovRedirectTracker?, mutator: ApproovServiceMutator) {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try ApproovHTTPClient.checkPinningAvailable(self.pinningUnavailableReason)
                let wireRequest = try ApproovHTTPClient.approovUpdateRequest(
                    request: hop.request, mutator: mutator, substituteQuery: hop.substituteQuery)
                if self.isCancelled {
                    self.promise.fail(HTTPClientError.cancelled)
                    return
                }
                let forwarder = ApproovRedirectForwarder(delegate: self.delegate, wireURL: wireRequest.url,
                                                         follows: tracker != nil)
                let httpClientTask = self.httpClient.execute(
                    request: wireRequest,
                    delegate: forwarder,
                    eventLoop: self.eventLoopPreference.httpClientEventLoopPreference,
                    deadline: self.deadline,
                    logger: self.logger)
                // Store the task and re-check cancellation under the same lock to close the race
                // where cancel() arrives between the check above and the task being stored: such a
                // cancel() would otherwise read a nil task and the request would run uncancelled.
                let cancelledBeforeStore = self.lock.withLock { () -> Bool in
                    if self._isCancelled {
                        return true
                    }
                    self._httpClientTask = httpClientTask
                    return false
                }
                if cancelledBeforeStore {
                    httpClientTask.cancel()
                    self.promise.fail(HTTPClientError.cancelled)
                    return
                }
                httpClientTask.futureResult.whenComplete { result in
                    switch result {
                    case .success(let response):
                        self.promise.succeed(response)
                    case .failure(let redirect as ApproovRedirectSignal):
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.follow(redirect, from: hop, wireURL: wireRequest.url, tracker: tracker, mutator: mutator)
                        }
                    case .failure(let error):
                        self.promise.fail(ApproovPinningVerifier.mapPinningFailure(error, host: wireRequest.url.host, since: start))
                    }
                }
            } catch {
                self.promise.fail(error)
            }
        }

        // Starts the next hop of a redirect, inside the app's redirect limits.
        private func follow(_ redirect: ApproovRedirectSignal, from hop: ApproovRequestHop, wireURL: URL,
                            tracker: ApproovRedirectTracker?, mutator: ApproovServiceMutator) {
            // The forwarder reports a redirect only when the app follows redirects, so the tracker is set.
            guard var tracker else {
                self.promise.fail(HTTPClientError.redirectLimitReached)
                return
            }
            do {
                try tracker.redirect(to: redirect.target.absoluteString)
                let next = try hop.following(status: redirect.status, to: redirect.target, wireURL: wireURL)
                self.runHop(next, tracker: tracker, mutator: mutator)
            } catch {
                self.promise.fail(error)
            }
        }

        /// `EventLoopFuture` for the response returned by the request.
        public var futureResult: EventLoopFuture<Delegate.Response> {
            return self.promise.futureResult
        }

        /// Waits for execution of this request to complete.
        ///
        /// returns: The value of the `EventLoopFuture` when it completes.
        /// throws: The error value of the `EventLoopFuture` if it errors.
        public func wait() throws -> Delegate.Response {
            return try self.promise.futureResult.wait()
        }

        /// Cancels the request execution.
        public func cancel() {
            let httpClientTask = self.lock.withLock { () -> HTTPClient.Task<Delegate.Response>? in
                self._isCancelled = true
                return self._httpClientTask
            }
            httpClientTask?.cancel()
        }
    }
}

extension ApproovHTTPClient {
    /// Wrapper for HTTPClient.EventLoopPreference
    /// Specifies how the AsyncHTTPClient library will treat the event loop passed by the user.
    public struct EventLoopPreference {
        public enum Preference: Equatable {
            /// Event Loop will be selected by the library.
            case indifferent
            /// The delegate will be run on the specified EventLoop (and the Channel if possible).
            case delegate(on: EventLoop)
            /// The delegate and the `Channel` will be run on the specified EventLoop.
            case delegateAndChannel(on: EventLoop)
            /// Determine whether two EventLoopPreferences are considered equal
            public static func == (
                lhs: ApproovHTTPClient.EventLoopPreference.Preference,
                rhs: ApproovHTTPClient.EventLoopPreference.Preference
            ) -> Bool {
                switch lhs {
                case .indifferent:
                    switch rhs {
                    case .indifferent:
                        return true
                    default:
                        return false
                    }
                case .delegate(on: _):
                    switch rhs {
                    case .delegate(on: _):
                        return true
                    default:
                        return false
                    }
                case .delegateAndChannel(on: _):
                    switch rhs {
                    case .delegateAndChannel(on: _):
                        return true
                    default:
                        return false
                    }
                }
            }
        }

        /// Internal EventLoopPreference
        var preference: Preference

        /// Initializer
        init(_ preference: Preference) {
            self.preference = preference
        }

        /// Initializer mapping from HTTPClient.EventLoopPreference using reflection
        public init(_ httpClientPreference: HTTPClient.EventLoopPreference) {
            let mirror = Mirror(reflecting: httpClientPreference)
            for child in mirror.children {
                if child.label == "preference" {
                    let prefMirror = Mirror(reflecting: child.value)
                    if prefMirror.displayStyle == .enum, let payload = prefMirror.children.first,
                       let caseLabel = payload.label {
                        if caseLabel == "indifferent" {
                            self.preference = .indifferent
                            return
                        } else if caseLabel == "delegate", let eventLoop = Self.eventLoop(in: payload.value) {
                            self.preference = .delegate(on: eventLoop)
                            return
                        } else if caseLabel == "delegateAndChannel", let eventLoop = Self.eventLoop(in: payload.value) {
                            self.preference = .delegateAndChannel(on: eventLoop)
                            return
                        }
                    }
                }
            }
            // The reflection above relies on AsyncHTTPClient internals; if its shape ever changes we
            // cannot map the preference and fall back to .indifferent. This is a known limitation of
            // bridging the wrapped client's EventLoopPreference.
            self.preference = .indifferent
        }

        /// Gets the event loop from an enum payload. A case with a labeled value, such as
        /// `delegateAndChannel(on:)`, reflects its payload as the one-element tuple `(on: EventLoop)`.
        private static func eventLoop(in payload: Any) -> EventLoop? {
            if let eventLoop = payload as? EventLoop {
                return eventLoop
            }
            return Mirror(reflecting: payload).children.first?.value as? EventLoop
        }

        /// Event Loop will be selected by the library.
        public static let indifferent = EventLoopPreference(Preference.indifferent)

        /// The delegate will be run on the specified EventLoop (and the Channel if possible).
        ///
        /// This will call the configured delegate on `eventLoop` and will try to use a `Channel` on the same
        /// `EventLoop` but will not establish a new network connection just to satisfy the `EventLoop` preference if
        /// another existing connection on a different `EventLoop` is readily available from a connection pool.
        public static func delegate(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(Preference.delegate(on: eventLoop))
        }

        /// The delegate and the `Channel` will be run on the specified EventLoop.
        ///
        /// Use this for use-cases where you prefer a new connection to be established over re-using an existing
        /// connection that might be on a different `EventLoop`.
        public static func delegateAndChannel(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(Preference.delegateAndChannel(on: eventLoop))
        }

        /// The value of the wrapped HTTPClient.EventLoopPreference
        public var httpClientEventLoopPreference: HTTPClient.EventLoopPreference {
            switch preference {
            case .indifferent:
                return HTTPClient.EventLoopPreference.indifferent
            case .delegate(on: let eventLoop):
                return HTTPClient.EventLoopPreference.delegate(on: eventLoop)
            case .delegateAndChannel(on: let eventLoop):
                return HTTPClient.EventLoopPreference.delegateAndChannel(on: eventLoop)
            }
        }

        /// Operator required for matching ApproovHTTPClient.EventLoopPreference so it can be mapped to
        /// HTTPClient.EventLoopPreference
        static public func ~= (lhs: EventLoopPreference, rhs: EventLoopPreference) -> Bool {
            return lhs.preference == rhs.preference
        }
    }
}
