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
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTLS
import NIOTransportServices


// Based on https://github.com/swift-server/async-http-client/tree/main/Sources/AsyncHTTPClient/HTTPClient.swift
public class ApproovHTTPClient {

    let httpClientDelegate: HTTPClient

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
        httpClientDelegate = HTTPClient(eventLoopGroupProvider: eventLoopGroupProvider,
                   configuration: configuration,
                   backgroundActivityLogger: backgroundActivityLogger)
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
        let task = ApproovHTTPClient.Task<Delegate, Delegate.Response>(
            httpClientDelegate: httpClientDelegate,
            request: request,
            delegate: delegate,
            eventLoopPreference: .indifferent,
            deadline: deadline,
            logger: originalLogger ?? ApproovHTTPClient.loggingDisabled)
        task.runInBackground()
        return task
    }

    /// Update a request for Approov
    private static func approovUpdateRequest(request: HTTPClient.Request) throws -> HTTPClient.Request {
        let (updatedURL, updatedHeaders) = try ApproovService.updateRequest(url: request.url, headers: request.headers)
        // Return the modified request
        return try HTTPClient.Request(
            url: updatedURL,
            method: request.method,
            headers: updatedHeaders,
            body: request.body,
            tlsConfiguration: nil /* request specific TLS configuration is always unused */
        )
    }

    /// Update a request for Approov
    private static func approovUpdateRequest(
        url: String,
        method: HTTPMethod,
        body: HTTPClient.Body?
    ) throws -> HTTPClient.Request {
        var updatedURLString = url
        var updatedHeaders: HTTPHeaders = HTTPHeaders()
        if var updatedURL: URL = URL(string: url) {
            (updatedURL, updatedHeaders) = try ApproovService.updateRequest(url: updatedURL, headers: updatedHeaders)
            updatedURLString = updatedURL.absoluteString
        }
        return try HTTPClient.Request(
            url: updatedURLString,
            method: method,
            headers: updatedHeaders,
            body: body,
            tlsConfiguration: nil /* request specific TLS configuration is always unused */
        )
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
        let updatedRequest = try await ApproovHTTPClient.approovUpdateRequest(request: request)
        return try await httpClientDelegate.execute(updatedRequest, deadline: deadline, logger: logger)
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
        let updatedRequest = try await ApproovHTTPClient.approovUpdateRequest(request: request)
        return try await httpClientDelegate.execute(updatedRequest, timeout: timeout, logger: logger)
    }

    /// Update a request for Approov
    private static func approovUpdateRequest(request: HTTPClientRequest) async throws -> HTTPClientRequest {
        var updatedURLString = request.url
        var updatedHeaders: HTTPHeaders = request.headers
        if var updatedURL: URL = URL(string: request.url) {
            (updatedURL, updatedHeaders) = try ApproovService.updateRequest(url: updatedURL, headers: updatedHeaders)
            updatedURLString = updatedURL.absoluteString
        }
        // Return the modified request
        var newRequest = HTTPClientRequest(url: updatedURLString)
        newRequest.method = request.method
        newRequest.headers = updatedHeaders
        newRequest.body = request.body
        return newRequest
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

        // Wrapped HTTPClient.Task
        private var _httpClientTask: HTTPClient.Task<Delegate.Response>?

        // Initializer
        init(httpClientDelegate: HTTPClient,
             request: HTTPClient.Request,
             delegate: Delegate,
             eventLoopPreference: ApproovHTTPClient.EventLoopPreference,
             deadline: NIODeadline? = nil,
             logger: Logger) {
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
        private let lock = Lock()

        // Indicates whether the task has been cancelled
        private var _isCancelled: Bool = false
        var isCancelled: Bool {
            self.lock.withLock {
                self._isCancelled
            }
        }

        // Runs updating the request for Approov on a background thread and, when this completes, executes the request
        // using an HTTPClient
        public func runInBackground() {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Update the request for Approov
                    let updatedRequest = try ApproovHTTPClient.approovUpdateRequest(request: self.request)
                    if self.isCancelled {
                        self.promise.fail(HTTPClientError.cancelled)
                        return
                    }
                    // Execute the modified request using the original HTTPClient
                    let httpClientTask = self.httpClient.execute(
                        request: updatedRequest,
                        delegate: self.delegate,
                        eventLoop: self.eventLoopPreference.httpClientEventLoopPreference,
                        deadline: self.deadline,
                        logger: self.logger)
                    self.lock.withLock {
                        self._httpClientTask = httpClientTask
                    }
                    // Set up the promise to complete when the wrapped HTTPClient.Task's promise completes
                    self._httpClientTask!.futureResult.whenComplete { result in
                        switch result {
                        case .failure(let error):
                            self.promise.fail(error)
                        case .success(let response):
                            self.promise.succeed(response)
                        }
                    }
                } catch {
                    self.promise.fail(error)
                }
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

        /// Event Loop will be selected by the library.
        public static let indifferent = EventLoopPreference(.indifferent)

        /// The delegate will be run on the specified EventLoop (and the Channel if possible).
        ///
        /// This will call the configured delegate on `eventLoop` and will try to use a `Channel` on the same
        /// `EventLoop` but will not establish a new network connection just to satisfy the `EventLoop` preference if
        /// another existing connection on a different `EventLoop` is readily available from a connection pool.
        public static func delegate(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(.delegate(on: eventLoop))
        }

        /// The delegate and the `Channel` will be run on the specified EventLoop.
        ///
        /// Use this for use-cases where you prefer a new connection to be established over re-using an existing
        /// connection that might be on a different `EventLoop`.
        public static func delegateAndChannel(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(.delegateAndChannel(on: eventLoop))
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
