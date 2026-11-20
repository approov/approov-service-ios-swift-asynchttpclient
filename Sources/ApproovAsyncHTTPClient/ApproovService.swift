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

import Approov
import AsyncHTTPClient
import NIOCore
import NIOEmbedded
import Foundation
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOPosix
import NIOSSL
import os.log

/**
 * Approov error conditions
 */
public enum ApproovError: Error, LocalizedError {
    case initializationFailure(message: String)
    case configurationError(message: String)
    case pinningError(message: String)
    case networkingError(message: String)
    case permanentError(message: String)
    case rejectionError(message: String, ARC: String, rejectionReasons: String)
    case runtimeError(message: String)
    public var localizedDescription: String {
        get {
            switch self {
            case let .initializationFailure(message),
                 let .configurationError(message),
                 let .pinningError(message),
                 let .networkingError(message),
                 let .permanentError(message),
                 let .runtimeError(message):
                return message
            case let .rejectionError(message, ARC, rejectionReasons):
                var info: String = ""
                if ARC != "" {
                    info += ", ARC: " + ARC
                }
                if rejectionReasons != "" {
                    info += ", reasons: " + rejectionReasons
                }
                return message + info
            }
        }
    }
    public var errorDescription: String? {
        return localizedDescription
    }
}

/**
 * Log level for controlling the verbosity of os_log output from the ApproovService
 */
public enum ApproovLogLevel: Int, Comparable {
    case off = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    public static func < (lhs: ApproovLogLevel, rhs: ApproovLogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/** ApproovService provides a mediation layer to the Approov SDK itself */
public class ApproovService {

    /** Private initializer to disallow instantiation as this is a static only class */
    fileprivate init(){}

    /** Lock to manage initialization */
    private static let initLock = NIOLock()

    /** Status of Approov SDK initialization */
    private static var approovSDKInitialised = false

    /** Configuration string used for initialization */
    private static var _approovConfigString: String?

    /** Lock to manage variable access */
    private static let stateLock = NIOLock()

    /** Map of names for headers that should have their values substituted for secure strings, mapped to their required prefixes */
    private static var substitutionHeaders: Dictionary<String, String> = Dictionary<String, String>()

    /** Set of query parameters that may be substituted, specified by the key name */
    private static var substitutionQueryParams: Set<String> = []

    /** Set of URL regexs that should be excluded from any Approov protection, mapped to the compiled Pattern */
    private static var exclusionURLRegexs: Dictionary<String, NSRegularExpression> = Dictionary<String, NSRegularExpression>()

    /** Bind Header string */
    private static var _bindHeader = ""

    /** Approov token default header */
    private static var _approovTokenHeader = "Approov-Token"

    /** Approov token custom prefix: any prefix to be added such as "Bearer " */
    private static var _approovTokenPrefix = ""

    /** Approov TraceID optional header */
    private static var _approovTraceIDHeader: String? = "Approov-TraceID"

    /** Use Approov fetch status if token is empty */
    private static var _useApproovStatusIfNoToken = false

    /** The mutator instance used to control ApproovService behavior at key points in the flow. */
    private static var _serviceMutator: ApproovServiceMutator = ApproovCloseFailureMutator.instance

    /** The ARC of the most recent fetch the layer made, from the request path or a direct method (SPEC 5.3) */
    private static var _lastARC = ""

    /** True once the deprecated getMessageSignature has logged its warning in this process */
    private static var messageSignatureWarned = false

    /** True once the device clock warning of serverAdjustedTimeMS has been logged in this process */
    private static var deviceClockWarned = false

    /** Lock for the logging level and the test log sink */
    private static let logLock = NIOLock()

    /** Current logging level (SPEC 5.10); initialize never resets it */
    private static var _logLevel: ApproovLogLevel = .info

    /** Receives every line that the layer writes, with its level. For tests only. */
    private static var _logSink: ((ApproovLogLevel, String) -> Void)? = nil

    static var logLevel: ApproovLogLevel {
        get { logLock.withLock { _logLevel } }
        set { logLock.withLock { _logLevel = newValue } }
    }

    static var logSink: ((ApproovLogLevel, String) -> Void)? {
        get { logLock.withLock { _logSink } }
        set { logLock.withLock { _logSink = newValue } }
    }

    @available(*, deprecated, renamed: "setLoggingLevel(_:)")
    public static var loggingLevel: ApproovLogLevel {
        get { logLevel }
        set { logLevel = newValue }
    }

    /**
     * Sets the logging level of the layer (SPEC 5.10). Each level writes its own severity and the more severe
     * ones. OFF silences the layer. It can be called at any time, and initialize does not change it.
     */
    public static func setLoggingLevel(_ level: ApproovLogLevel) {
        logLevel = level
    }

    /**
     * Writes one log line if the logging level allows its level. Every line of the layer goes through here,
     * so OFF silences the layer. The message is built only if the line is written.
     */
    static func log(_ level: ApproovLogLevel, _ message: @autoclosure () -> String) {
        guard level != .off, logLevel >= level else {
            return
        }
        let line = message()
        logSink?(level, line)
        let type: OSLogType
        switch level {
        case .error: type = .error
        case .info: type = .info
        case .debug: type = .debug
        default: type = .default
        }
        os_log("%{public}@", type: type, line)
    }

    /**
     * Gets the form of a URL for a log line: scheme, host, port and path. It has no user info, query or
     * fragment (SPEC 5.10).
     */
    static func loggableURL(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else {
            return "<url>"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(components.percentEncodedPath)"
    }

    /**
     * Initializes the ApproovService with the config obtained using `approov sdk -getConfigString`
     * or in the original onboarding email.
     */
    public static func initialize(config: String, comment: String? = nil) throws {
        try initLock.withLock {
            let isEnabled = !config.isEmpty
            if approovSDKInitialised && config.isEmpty && !(_approovConfigString?.isEmpty ?? true) {
                log(.info, "ApproovService already initialized with a valid config; ignoring empty configuration")
                return
            }

            if isEnabled {
                do {
                    try Approov.initialize(config, updateConfig: "auto", comment: comment)
                    log(.info, "ApproovService: Approov SDK initialized")
                } catch {
                    let nsError = error as NSError
                    if nsError.code == 0, nsError.domain == "Foundation._GenericObjCError" {
                        log(.info, "ApproovService: Approov SDK already initialized")
                    } else {
                        throw ApproovError.initializationFailure(message: "Error initializing Approov SDK: \(nsError.localizedDescription)")
                    }
                }
            }

            // SDK succeeded (or bypass) — now reset and commit new service-layer state.
            approovSDKInitialised = false
            _approovConfigString = config

            stateLock.withLock {
                _bindHeader = ""
                _approovTokenHeader = "Approov-Token"
                _approovTokenPrefix = ""
                _approovTraceIDHeader = "Approov-TraceID"
                _serviceMutator = ApproovCloseFailureMutator.instance
                substitutionHeaders = Dictionary()
                substitutionQueryParams = Set()
                exclusionURLRegexs = Dictionary()
                _useApproovStatusIfNoToken = false
                _lastARC = ""
            }

            approovSDKInitialised = true
            if isEnabled {
                Approov.setUserProperty("approov-service-asynchttpclient/dev")
            }
            TLSConfiguration.setVerifyPinningBlock(newValue: ApproovPinningVerifier.verifyPinning)
        }
    }

    /**
     * Resets the ApproovService state for testing.
     */
    static func resetForTesting() {
        initLock.withLock {
            approovSDKInitialised = false
            _approovConfigString = nil
        }
        stateLock.withLock {
            _bindHeader = ""
            _approovTokenHeader = "Approov-Token"
            _approovTokenPrefix = ""
            _approovTraceIDHeader = "Approov-TraceID"
            _serviceMutator = ApproovCloseFailureMutator.instance
            substitutionHeaders = Dictionary()
            substitutionQueryParams = Set()
            exclusionURLRegexs = Dictionary()
            _useApproovStatusIfNoToken = false
            _lastARC = ""
        }
        ApproovProtectionLedger.shared.resetForTesting()
    }

    /**
     * Indicates whether the service layer has been initialized.
     */
    public static func isInitialized() -> Bool {
        initLock.withLock {
            approovSDKInitialised
        }
    }

    private static var isApproovEnabledInternal: Bool {
        approovSDKInitialised && !(_approovConfigString?.isEmpty ?? true)
    }

    /**
     * Indicates whether Approov protection is enabled for this service layer instance.
     */
    public static func isApproovEnabled() -> Bool {
        initLock.withLock {
            isApproovEnabledInternal
        }
    }

    /** True once any initialize has succeeded, bypass mode included: the layer processes requests (SPEC 5.7(c)) */
    public static func isApproovServiceEnabled() -> Bool {
        isInitialized()
    }

    /** True once the Approov SDK is initialized and Approov protection is active (SPEC 5.7(c)) */
    public static func isApproovProtectionEnabled() -> Bool {
        isApproovEnabled()
    }

    /**
     * Logs that an Approov-dependent method was invoked while the platform SDK is not active,
     * distinguishing "initialized in bypass mode (empty config)" from "service layer not initialized
     * at all" so the two states can be told apart in the logs.
     */
    private static func logApproovUnavailable(_ method: String) {
        guard logLevel >= .error else {
            return
        }
        let (initialized, enabled) = initLock.withLock {
            (approovSDKInitialised, isApproovEnabledInternal)
        }
        if initialized && !enabled {
            log(.error, "ApproovService: \(method): Approov is disabled (initialized in bypass mode); ignoring call")
        } else {
            log(.error, "ApproovService: \(method): service layer not initialized")
        }
    }

    /**
     * Runs a throwing operation (typically a service mutator callback) and guarantees that any error
     * escaping is an `ApproovError`. A custom mutator may throw an arbitrary `Error`; this wraps such
     * values as `ApproovError.permanentError` so the documented public throwing contract holds.
     */
    private static func wrappingApproovError<T>(_ context: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ApproovError {
            throw error
        } catch {
            throw ApproovError.permanentError(message: "\(context): \(error.localizedDescription)")
        }
    }

    /**
     * Sets a binding header that must be present on all requests using the Approov service.
     */
    public static var bindHeader: String {
        get {
            stateLock.withLock { _bindHeader }
        }
        set {
            stateLock.withLock { _bindHeader = newValue }
        }
    }

    /** Sets the header that carries the Approov token, and an optional prefix such as "Bearer " (SPEC 5.1) */
    public static func setTokenHeader(header: String, prefix: String?) {
        stateLock.withLock {
            _approovTokenHeader = header
            _approovTokenPrefix = prefix ?? ""
        }
        log(.debug, "ApproovService: setTokenHeader: \(header) \(prefix ?? "")")
    }

    public static func getTokenHeader() -> String {
        stateLock.withLock { _approovTokenHeader }
    }

    public static func getTokenPrefix() -> String {
        stateLock.withLock { _approovTokenPrefix }
    }

    /** Sets the header that carries the Approov trace ID. Nil disables it (SPEC 5.1). */
    public static func setTraceIDHeader(header: String?) {
        stateLock.withLock { _approovTraceIDHeader = header }
        log(.debug, "ApproovService: setTraceIDHeader: \(header ?? "nil")")
    }

    public static func getTraceIDHeader() -> String? {
        stateLock.withLock { _approovTraceIDHeader }
    }

    @available(*, deprecated, message: "Use setTokenHeader(header:prefix:), getTokenHeader() and getTokenPrefix().")
    public static var approovTokenHeaderAndPrefix: (approovTokenHeader: String, approovTokenPrefix: String) {
        get { (getTokenHeader(), getTokenPrefix()) }
        set { setTokenHeader(header: newValue.approovTokenHeader, prefix: newValue.approovTokenPrefix) }
    }

    @available(*, deprecated, renamed: "getTokenHeader()")
    public static func getApproovTokenHeader() -> String {
        getTokenHeader()
    }

    @available(*, deprecated, renamed: "setTraceIDHeader(header:)")
    public static func setApproovTraceIDHeader(header: String?) {
        setTraceIDHeader(header: header)
    }

    @available(*, deprecated, renamed: "getTraceIDHeader()")
    public static func getApproovTraceIDHeader() -> String? {
        getTraceIDHeader()
    }

    public static func setUseApproovStatusIfNoToken(shouldUse: Bool) {
        stateLock.withLock {
            _useApproovStatusIfNoToken = shouldUse
        }
    }

    public static func getUseApproovStatusIfNoToken() -> Bool {
        stateLock.withLock { _useApproovStatusIfNoToken }
    }

    public static func setServiceMutator(_ mutator: ApproovServiceMutator?) {
        stateLock.withLock {
            _serviceMutator = mutator ?? ApproovCloseFailureMutator.instance
        }
    }

    public static func getServiceMutator() -> ApproovServiceMutator {
        stateLock.withLock { _serviceMutator }
    }

    public static var approovConfigString: String? {
        initLock.withLock { _approovConfigString }
    }

    /**
     * Sets a development key.
     */
    public static func setDevKey(devKey: String) {
        if !isApproovEnabled() {
            logApproovUnavailable("setDevKey")
            return
        }
        Approov.setDevKey(devKey)
        log(.debug, "ApproovService: setDevKey")
    }

    /**
     * Legacy backward-compatible updateRequest method.
     */
    @available(*, deprecated, message: "A plain HTTPClient follows a redirect with this request's Approov protection, which can then reach another host. Use ApproovHTTPClient, which protects each redirect hop as a new request.")
    public static func updateRequest(url: URL, headers: HTTPHeaders) throws -> (URL, HTTPHeaders) {
        let appReq = ApproovRequest(url: url, method: "GET", headers: headers, body: nil)
        let response = updateRequestWithApproov(request: appReq)
        if let error = response.error {
            throw error
        }
        switch response.decision {
        case .ShouldProceed, .ShouldIgnore:
            return (response.request.url, response.request.headers)
        case .ShouldRetry:
            throw ApproovError.networkingError(message: "Token fetch for \(url.host ?? ""): \(response.sdkMessage)")
        case .ShouldFail:
            throw ApproovError.permanentError(message: "Token fetch for \(url.host ?? ""): \(response.sdkMessage)")
        }
    }

    @available(*, deprecated, message: "A plain HTTPClient follows a redirect with this request's Approov protection, which can then reach another host. Use ApproovHTTPClient, which protects each redirect hop as a new request.")
    public static func signRequest(_ request: HTTPClient.Request) throws -> HTTPClient.Request {
        let bodyData = extractBodyData(from: request.body)
        let approovReq = ApproovRequest(
            url: request.url,
            method: request.method.rawValue,
            headers: request.headers,
            body: bodyData
        )
        let response = updateRequestWithApproov(request: approovReq)
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
    
    /// Event loop for body writes that arrive from another thread or after `extractBodyData` returned.
    /// NIO permits `EmbeddedEventLoop` only on the thread that created it, so such a write gets its
    /// future from this loop. The group has one thread, created on first use.
    private static let lateBodyWriteGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /**
     * Extracts the body data from an AsyncHTTPClient `HTTPClient.Body` for body-digest computation.
     *
     * `HTTPClient.Body` is opaque. It gives no flag that tells if the body is in memory. This function
     * calls the stream closure once, on a private `EmbeddedEventLoop`, and uses the data only if all of
     * it arrives on this thread before the closure's future completes. In-memory bodies (`.byteBuffer`,
     * `.bytes`, `.string`) do this. A body of unknown length (chunked) is skipped and its closure is not
     * called. A write from another thread, or after this function returned, is ignored, and the body is
     * not digested.
     *
     * The closure runs one more time when AsyncHTTPClient sends the request. AsyncHTTPClient also runs it
     * again for a 307 or 308 redirect. So the closure must be repeatable: each call must write the same
     * bytes.
     *
     * - Parameter body: the request body to inspect.
     * - Returns: the complete body bytes if they arrived synchronously; otherwise nil.
     */
    static func extractBodyData(from body: HTTPClient.Body?) -> Data? {
        guard let body = body else {
            return nil
        }

        // A nil length indicates a chunked / streaming body of unknown size; skip it without calling it.
        if body.length == nil {
            return nil
        }

        // All state is behind a lock, because the producer can write from another thread.
        let state = NIOLockedValueBox((data: Data(), undigestable: false, closed: false))
        let ownerThread = pthread_self()
        let eventLoop = EmbeddedEventLoop()
        // Weak capture: a producer can keep the writer after this function returns. A strong capture
        // would then release the EmbeddedEventLoop on the producer thread, which NIO reports as misuse.
        let writer = HTTPClient.Body.StreamWriter { [weak eventLoop] ioData in
            let onOwnerThread = pthread_equal(pthread_self(), ownerThread) != 0
            let accepted = state.withLockedValue { current -> Bool in
                guard onOwnerThread, !current.closed else {
                    // A late or foreign-thread write: the body is not complete in memory.
                    current.undigestable = true
                    return false
                }
                switch ioData {
                case .byteBuffer(let buffer):
                    current.data.append(contentsOf: buffer.readableBytesView)
                default:
                    // File regions and other chunk kinds cannot be digested in memory.
                    current.undigestable = true
                }
                return true
            }
            // An accepted write is on the owner thread while this function runs, so the loop exists.
            if accepted, let eventLoop = eventLoop {
                return eventLoop.makeSucceededFuture(())
            }
            return lateBodyWriteGroup.next().makeSucceededFuture(())
        }

        let completed = NIOLockedValueBox(false)
        body.stream(writer).whenComplete { _ in
            completed.withLockedValue { $0 = true }
        }
        eventLoop.run()

        let data = state.withLockedValue { current -> Data? in
            current.closed = true
            return current.undigestable ? nil : current.data
        }
        guard completed.withLockedValue({ $0 }) else {
            // Streaming / asynchronous body: do not digest a partial body.
            return nil
        }
        return data
    }

    /// Maps an error from a hook call to the decision: a standard decision keeps its ApproovError, with a retry
    /// for a network failure; any other error is already a URLError and fails the request.
    private static func applyMutatorError(_ error: Error, response: inout ApproovUpdateResponse) {
        response.error = error
        if case .networkingError? = error as? ApproovError {
            response.decision = .ShouldRetry
        } else {
            response.decision = .ShouldFail
        }
    }

    /**
     * Adds Approov protection to a request, as the service mutator decides (SPEC 1, 6).
     */
    public static func updateRequestWithApproov(request: ApproovRequest) -> ApproovUpdateResponse {
        return updateRequestWithApproov(request: request, mutator: getServiceMutator(), substituteQuery: true)
    }

    /**
     * Adds Approov protection as the public form does. `mutator` is the one that the request started with, which
     * decides every hop (SPEC 6.5). `substituteQuery` is false for a redirect hop whose URL is the server's
     * `Location`: the layer never looks up the query values that the server sent (SPEC 7.3, T37-13a). A request
     * that the layer already protected is first put back as the app wrote it (T37-38).
     */
    static func updateRequestWithApproov(request: ApproovRequest, mutator: ApproovServiceMutator,
                                         substituteQuery: Bool) -> ApproovUpdateResponse {
        let appRequest = ApproovProtectionLedger.shared.restore(request)
        let response = protect(appRequest, mutator: mutator, substituteQuery: substituteQuery)
        if response.decision == .ShouldProceed {
            ApproovProtectionLedger.shared.record(original: appRequest, protected: response.request)
        }
        return response
    }

    private static func protect(_ request: ApproovRequest, mutator: ApproovServiceMutator,
                                substituteQuery: Bool) -> ApproovUpdateResponse {
        let url = request.url
        let changes = ApproovRequestMutations()

        if !isApproovEnabled() {
            log(.info, "ApproovService: Approov unavailable, forwarding: \(loggableURL(url))")
            return ApproovUpdateResponse(request: request, decision: .ShouldIgnore, sdkMessage: "", error: nil)
        }

        do {
            if try !ApproovRequestPathError.callHook("handleInterceptorShouldProcessRequest", {
                try mutator.handleInterceptorShouldProcessRequest(request)
            }) {
                log(.info, "ApproovService: excluded, forwarding: \(loggableURL(url))")
                return ApproovUpdateResponse(request: request, decision: .ShouldIgnore, sdkMessage: "", error: nil)
            }
        } catch {
            var response = ApproovUpdateResponse(request: request, decision: .ShouldFail, sdkMessage: "", error: nil)
            applyMutatorError(error, response: &response)
            return response
        }

        var response = ApproovUpdateResponse(request: request, decision: .ShouldFail, sdkMessage: "", error: nil)

        let bindHeader = stateLock.withLock { _bindHeader }
        if bindHeader != "", let value = request.headers.first(name: bindHeader) {
            Approov.setDataHashInToken(value)
        }

        let approovResult = Approov.fetchTokenAndWait(url.absoluteString)
        recordLastARC(approovResult)
        log(.debug, "ApproovService: updateRequest \(loggableURL(url)): \(approovResult.loggableToken())")
        if approovResult.isConfigChanged {
            Approov.fetchConfig()
            log(.info, "ApproovService: dynamic configuration update received")
        }
        response.sdkMessage = Approov.string(from: approovResult.status)

        // A protected channel, which can carry secrets, is a token-protected API (SUCCESS) or a secrets-only API
        // (UNPROTECTED_URL) over https. Any other status but UNKNOWN_URL is a failure status, which says nothing
        // about the host, so there the pin set decides (SPEC 1.3, 1.5).
        let status = approovResult.status
        let isHTTPS = url.scheme?.lowercased() == "https"
        let isFailure = status != .success && status != .unprotectedURL && status != .unknownURL
        let isProtectedChannel = isHTTPS && (status == .success || status == .unprotectedURL)

        // A failure for a host that is not listed goes out untouched. A standard decision is ignored, and only the
        // app's own throw aborts it (SPEC 1.3).
        if isFailure && !isListedHost(url.host) {
            do {
                _ = try ApproovRequestPathError.callHookIgnoringStandardDecisions("handleInterceptorFetchTokenResult") {
                    try mutator.handleInterceptorFetchTokenResult(approovResult, url: url.absoluteString)
                }
            } catch {
                applyMutatorError(error, response: &response)
                return response
            }
            log(.debug, "ApproovService: \(loggableURL(url)) proceeds untouched after \(statusName(status)), host not listed")
            warnOfPlaceholdersLeft(in: request, isHTTPS: isHTTPS, status: status)
            response.decision = .ShouldProceed
            return response
        }

        let shouldAddToken: Bool
        do {
            shouldAddToken = try ApproovRequestPathError.callHook("handleInterceptorFetchTokenResult") {
                try mutator.handleInterceptorFetchTokenResult(approovResult, url: url.absoluteString)
            }
        } catch {
            applyMutatorError(error, response: &response)
            return response
        }
        response.decision = .ShouldProceed
        if isFailure {
            log(.debug, "ApproovService: \(loggableURL(url)) proceeds after \(statusName(status)), ARC: \(approovResult.arc), reasons: \(approovResult.rejectionReasons)")
        }
        if !isProtectedChannel {
            warnOfPlaceholdersLeft(in: request, isHTTPS: isHTTPS, status: status)
        }
        if !shouldAddToken && !isProtectedChannel {
            return response
        }

        // The token and trace headers. After a failure the token header holds an empty token, or the status name
        // with setUseApproovStatusIfNoToken (SPEC 1.3, 4.1).
        if shouldAddToken && status != .unknownURL && status != .unprotectedURL {
            let (tokenHeader, tokenPrefix, useStatus, traceHeader) = stateLock.withLock {
                (_approovTokenHeader, _approovTokenPrefix, _useApproovStatusIfNoToken, _approovTraceIDHeader)
            }
            let token = (approovResult.token.isEmpty && useStatus) ? statusName(status) : approovResult.token
            guard isHeaderCarriable(tokenPrefix) else {
                response.decision = .ShouldFail
                response.error = ApproovRequestPathError.configuration("Approov header \(tokenHeader): invalid character in the token prefix")
                return response
            }
            guard isHeaderCarriable(token) else {
                response.decision = .ShouldFail
                response.error = ApproovRequestPathError.sdkValue("token", header: tokenHeader)
                return response
            }
            response.request.headers.replaceOrAdd(name: tokenHeader, value: tokenPrefix + token)
            changes.setTokenHeaderKey(tokenHeader)
            let traceID = approovResult.traceID
            if let traceHeader, !traceHeader.isEmpty, !traceID.isEmpty {
                guard isHeaderCarriable(traceID) else {
                    response.decision = .ShouldFail
                    response.error = ApproovRequestPathError.sdkValue("trace ID", header: traceHeader)
                    return response
                }
                response.request.headers.replaceOrAdd(name: traceHeader, value: traceID)
                changes.setTraceIDHeaderKey(traceHeader)
            }
        }

        // Secure strings only on a protected channel (SPEC 1.4, 1.5).
        if isProtectedChannel {
            do {
                try substituteHeaders(&response.request, mutator: mutator, changes: changes)
                if substituteQuery {
                    try substituteQueryParams(&response.request, mutator: mutator, changes: changes)
                }
            } catch {
                applyMutatorError(error, response: &response)
                return response
            }
        }

        do {
            response.request = try ApproovRequestPathError.callHook("handleInterceptorProcessedRequest") {
                try mutator.handleInterceptorProcessedRequest(response.request, changes: changes)
            }
        } catch {
            applyMutatorError(error, response: &response)
            return response
        }
        return response
    }

    /// True if the host is a key of the pins map other than "*" (SPEC 1.3), compared as pins are looked up.
    static func isListedHost(_ host: String?) -> Bool {
        guard let host = host, let pins = Approov.getPins("public-key-sha256") else {
            return false
        }
        let wanted = normalisedHost(host)
        return pins.keys.contains { $0 != "*" && normalisedHost($0) == wanted }
    }

    /// A host as pins are looked up: lowercase, with one trailing dot removed (SPEC 2.6).
    static func normalisedHost(_ host: String) -> String {
        var normalised = host.lowercased()
        if normalised.hasSuffix(".") {
            normalised.removeLast()
        }
        return normalised
    }

    /// True if a header can carry the value unchanged: tab and printable ASCII only (SPEC 1.4).
    static func isHeaderCarriable(_ value: String) -> Bool {
        return value.unicodeScalars.allSatisfy { $0 == "\t" || ($0.value >= 0x20 && $0.value <= 0x7E) }
    }

    /// Logs a warning for each placeholder that stays on a request that is not https or whose token fetch
    /// returned BAD_URL (SPEC 1.5). It names the header or query parameter, never a value.
    private static func warnOfPlaceholdersLeft(in request: ApproovRequest, isHTTPS: Bool, status: ApproovTokenFetchStatus) {
        guard !isHTTPS || status == .badURL else {
            return
        }
        let reason = isHTTPS ? "BAD_URL" : "not https"
        for (header, _) in getSubstitutionHeaders() where request.headers.first(name: header) != nil {
            log(.warning, "ApproovService: secure string header \(header) not substituted: \(reason)")
        }
        let present = Set(queryOccurrences(in: request.url.absoluteString).map { $0.name })
        for key in getSubstitutionQueryParams() where present.contains(key) {
            log(.warning, "ApproovService: secure string query parameter \(key) not substituted: \(reason)")
        }
    }

    private static func substituteHeaders(_ request: inout ApproovRequest, mutator: ApproovServiceMutator,
                                          changes: ApproovRequestMutations) throws {
        var substituted: [String] = []
        for (header, prefix) in getSubstitutionHeaders() {
            guard let value = request.headers.first(name: header), value.hasPrefix(prefix), value.count > prefix.count else {
                continue
            }
            let key = String(value.dropFirst(prefix.count))
            let result = Approov.fetchSecureStringAndWait(key, nil)
            recordLastARC(result)
            log(.debug, "ApproovService: header substitution: \(header), \(statusName(result.status)), ARC: \(result.arc)")
            let accepted = try ApproovRequestPathError.callHook("handleInterceptorHeaderSubstitutionResult") {
                try mutator.handleInterceptorHeaderSubstitutionResult(result, header: header)
            }
            if result.status == .success {
                guard accepted, let secret = result.secureString else {
                    continue
                }
                if isHeaderCarriable(secret) {
                    request.headers.replaceOrAdd(name: header, value: prefix + secret)
                    substituted.append(header)
                } else {
                    log(.warning, "ApproovService: secure string header \(header) not substituted: the value cannot be carried in a header")
                }
            } else {
                request.headers.replaceOrAdd(name: header, value: prefix + statusName(result.status))
            }
        }
        if !substituted.isEmpty {
            changes.setSubstitutionHeaderKeys(substituted)
        }
    }

    /// An occurrence of a query parameter: its name and the range of its value, both as written in the URL.
    struct QueryOccurrence {
        let name: String
        let value: Range<String.Index>
    }

    /// The query parameters of a URL string, in order, as written. Nothing is decoded.
    static func queryOccurrences(in urlString: String) -> [QueryOccurrence] {
        guard let queryStart = urlString.firstIndex(of: "?") else {
            return []
        }
        let queryEnd = urlString[queryStart...].firstIndex(of: "#") ?? urlString.endIndex
        var occurrences: [QueryOccurrence] = []
        var fieldStart = urlString.index(after: queryStart)
        while fieldStart <= queryEnd {
            let fieldEnd = urlString[fieldStart..<queryEnd].firstIndex(of: "&") ?? queryEnd
            if let equals = urlString[fieldStart..<fieldEnd].firstIndex(of: "=") {
                let name = String(urlString[fieldStart..<equals])
                occurrences.append(QueryOccurrence(name: name, value: urlString.index(after: equals)..<fieldEnd))
            }
            if fieldEnd == queryEnd {
                break
            }
            fieldStart = urlString.index(after: fieldEnd)
        }
        return occurrences
    }

    // The value of the occurrence at a position, as written, if the URL still has the same occurrences there.
    private static func readBack(of name: String, at position: Int, count: Int, in urlString: String) -> String? {
        let found = queryOccurrences(in: urlString)
        guard found.count == count, found[position].name == name else {
            return nil
        }
        return String(urlString[found[position].value])
    }

    private static func substituteQueryParams(_ request: inout ApproovRequest, mutator: ApproovServiceMutator,
                                              changes: ApproovRequestMutations) throws {
        let original = request.url.absoluteString
        let keys = getSubstitutionQueryParams()
        var urlString = original
        var substituted: [String] = []
        var index = 0
        while true {
            let occurrences = queryOccurrences(in: urlString)
            guard index < occurrences.count else {
                break
            }
            let occurrence = occurrences[index]
            index += 1
            guard keys.contains(occurrence.name) else {
                continue
            }
            let written = String(urlString[occurrence.value])
            guard !written.isEmpty else {
                continue
            }
            let result = Approov.fetchSecureStringAndWait(written.removingPercentEncoding ?? written, nil)
            recordLastARC(result)
            log(.debug, "ApproovService: query parameter substitution: \(occurrence.name), \(statusName(result.status)), ARC: \(result.arc)")
            let accepted = try ApproovRequestPathError.callHook("handleInterceptorQueryParamSubstitutionResult") {
                try mutator.handleInterceptorQueryParamSubstitutionResult(result, queryKey: occurrence.name)
            }
            let replacement: String
            if result.status == .success {
                guard accepted, let secret = result.secureString else {
                    continue
                }
                replacement = secret
            } else {
                replacement = statusName(result.status)
            }
            var candidate = urlString
            candidate.replaceSubrange(occurrence.value, with: replacement)
            guard let carried = URL(string: candidate)?.absoluteString,
                  readBack(of: occurrence.name, at: index - 1, count: occurrences.count, in: carried)
                    .map({ $0 == replacement || $0.removingPercentEncoding == replacement }) == true else {
                log(.warning, "ApproovService: secure string query parameter \(occurrence.name) not substituted: the value cannot be carried in the URL")
                continue
            }
            urlString = carried
            if result.status == .success {
                substituted.append(occurrence.name)
            }
        }
        if urlString != original, let url = URL(string: urlString) {
            request.url = url
            changes.setSubstitutionQueryParamResults(originalURL: original, substitutionQueryParamKeys: substituted)
        }
    }

    /**
     * Adds the value of a header which should be subject to secure strings substitution.
     */
    public static func addSubstitutionHeader(header: String, prefix: String?) {
        stateLock.withLock {
            substitutionHeaders[header] = prefix ?? ""
            log(.debug, "ApproovService: addSubstitutionHeader: \(header) \(prefix ?? "")")
        }
    }

    /**
     * Removes the name of a header if it exists from the secure strings substitution dictionary.
     */
    public static func removeSubstitutionHeader(header: String) {
        stateLock.withLock {
            if substitutionHeaders[header] != nil {
                substitutionHeaders.removeValue(forKey: header)
            }
            log(.debug, "ApproovService: removeSubstitutionHeader: \(header)")
        }
    }

    public static func getSubstitutionHeaders() -> Dictionary<String, String> {
        stateLock.withLock { substitutionHeaders }
    }

    /**
     * Adds a key name for a query parameter that should be subject to secure strings substitution.
     */
    public static func addSubstitutionQueryParam(key: String) {
        stateLock.withLock {
            substitutionQueryParams.insert(key)
            log(.debug, "ApproovService: addSubstitutionQueryParam: \(key)")
        }
    }

    /**
     * Removes a query parameter key name previously added using addSubstitutionQueryParam.
     */
    public static func removeSubstitutionQueryParam(key: String) {
        stateLock.withLock {
            substitutionQueryParams.remove(key)
            log(.debug, "ApproovService: removeSubstitutionQueryParam: \(key)")
        }
    }

    public static func getSubstitutionQueryParams() -> Set<String> {
        stateLock.withLock { substitutionQueryParams }
    }

    /**
     * Adds an exclusion URL regular expression.
     */
    public static func addExclusionURLRegex(urlRegex: String) {
        stateLock.withLock {
            do {
                let regex = try NSRegularExpression(pattern: urlRegex, options: [])
                exclusionURLRegexs[urlRegex] = regex
                log(.debug, "ApproovService: addExclusionURLRegex: \(urlRegex)")
            } catch {
                // The pattern was rejected and no exclusion was registered; surface this at error
                // level so callers are not left believing an invalid regex took effect.
                log(.error, "ApproovService: addExclusionURLRegex: \(urlRegex) rejected, exclusion NOT added: \(error.localizedDescription)")
            }
        }
    }

    /**
     * Removes an exclusion URL regular expression.
     */
    public static func removeExclusionURLRegex(urlRegex: String) {
        stateLock.withLock {
            if exclusionURLRegexs[urlRegex] != nil {
                exclusionURLRegexs.removeValue(forKey: urlRegex)
                log(.debug, "ApproovService: removeExclusionURLRegex: \(urlRegex)")
            }
        }
    }

    public static func getExclusionURLRegexs() -> Dictionary<String, NSRegularExpression> {
        stateLock.withLock { exclusionURLRegexs }
    }

    /**
     * Gets the device ID used by Approov.
     */
    public static func getDeviceID() -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("getDeviceID")
            return nil
        }
        let deviceID = Approov.getDeviceID()
        if (deviceID != nil) {
            log(.debug, "ApproovService: getDeviceID \(deviceID!)")
        }
        return deviceID
    }

    /**
     * Directly sets the data hash to be included in subsequently fetched Approov tokens.
     */
    public static func setDataHashInToken(data: String) {
        if !isApproovEnabled() {
            logApproovUnavailable("setDataHashInToken")
            return
        }
        log(.debug, "ApproovService: setDataHashInToken")
        Approov.setDataHashInToken(data)
    }

    /**
     * Performs an Approov token fetch for the given URL.
     */
    public static func fetchToken(url: String) throws -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("fetchToken")
            throw ApproovError.permanentError(message: "fetchToken: SDK not initialized")
        }
        let result = Approov.fetchTokenAndWait(url)
        recordLastARC(result)
        log(.debug, "ApproovService: fetchToken: \(Approov.string(from: result.status))")
        try wrappingApproovError("fetchToken") {
            try getServiceMutator().handleFetchTokenResult(result)
        }
        return result.token
    }

    /**
     * Sets the install attributes to be included in the Approov token.
     */
    public static func setInstallAttrsInToken(attrs: String) throws {
        if !isApproovEnabled() {
            logApproovUnavailable("setInstallAttrsInToken")
            throw ApproovError.permanentError(message: "setInstallAttrsInToken: SDK not initialized")
        }
        Approov.setInstallAttrsInToken(attrs)
        log(.debug, "ApproovService: setInstallAttrsInToken")
    }

    /** Sets the install attributes to include in the Approov token. The 3.7.x name of setInstallAttrsInToken. */
    public static func setInstallAttributes(_ attrs: String) throws {
        if !isApproovEnabled() {
            logApproovUnavailable("setInstallAttributes")
            throw ApproovError.permanentError(message: "setInstallAttributes: SDK not initialized")
        }
        Approov.setInstallAttrsInToken(attrs)
        log(.debug, "ApproovService: setInstallAttributes")
    }

    /**
     * Gets the account message signature.
     */
    public static func getAccountMessageSignature(message: String) -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("getAccountMessageSignature")
            return nil
        }
        return Approov.getMessageSignature(message)
    }

    /**
     * Gets the install message signature.
     */
    public static func getInstallMessageSignature(message: String) -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("getInstallMessageSignature")
            return nil
        }
        return Approov.getInstallMessageSignature(message)
    }

    /**
     * Gets the account message signature. A deprecated alias of getAccountMessageSignature: it returns the
     * same value and logs a deprecation warning the first time it is called in the process (SPEC 5.2).
     */
    @available(*, deprecated, message: "Use getAccountMessageSignature or getInstallMessageSignature instead.")
    public static func getMessageSignature(message: String) -> String? {
        let firstCall = stateLock.withLock { () -> Bool in
            defer { messageSignatureWarned = true }
            return !messageSignatureWarned
        }
        if firstCall {
            log(.warning, "ApproovService: getMessageSignature is deprecated, use getAccountMessageSignature")
        }
        return getAccountMessageSignature(message: message)
    }

    /**
     * Fetches a secure string with the given key.
     */
    public static func fetchSecureString(key: String, newDef: String?) throws -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("fetchSecureString")
            throw ApproovError.permanentError(message: "fetchSecureString: SDK not initialized")
        }
        let type = newDef != nil ? "definition" : "lookup"
        let approovResult = Approov.fetchSecureStringAndWait(key, newDef)
        recordLastARC(approovResult)
        log(.info, "ApproovService: fetchSecureString: \(type): \(Approov.string(from: approovResult.status))")
        try wrappingApproovError("fetchSecureString \(type) for \(key)") {
            try getServiceMutator().handleFetchSecureStringResult(approovResult, operation: type, key: key)
        }
        return approovResult.secureString
    }

    /**
     * Fetches a custom JWT with the given payload.
     */
    public static func fetchCustomJWT(payload: String) throws -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("fetchCustomJWT")
            throw ApproovError.permanentError(message: "fetchCustomJWT: SDK not initialized")
        }
        let approovResult = Approov.fetchCustomJWTAndWait(payload)
        recordLastARC(approovResult)
        log(.info, "ApproovService: fetchCustomJWT: \(Approov.string(from: approovResult.status))")
        try wrappingApproovError("fetchCustomJWT") {
            try getServiceMutator().handleFetchCustomJWTResult(approovResult)
        }
        return approovResult.token
    }

    /**
     * Performs a precheck.
     */
    public static func precheck() throws {
        if !isApproovEnabled() {
            logApproovUnavailable("precheck")
            throw ApproovError.permanentError(message: "precheck: SDK not initialized")
        }
        let approovResults = Approov.fetchSecureStringAndWait("precheck-dummy-key", nil)
        recordLastARC(approovResults)
        if approovResults.status == ApproovTokenFetchStatus.unknownKey {
            log(.debug, "ApproovService: precheck: success")
        } else {
            log(.debug, "ApproovService: precheck: \(Approov.string(from: approovResults.status))")
        }
        try wrappingApproovError("precheck") {
            try getServiceMutator().handlePrecheckResult(approovResults)
        }
    }

    /**
     * Gets the name of a fetch status as the Android SDK enum names it (SPEC 4.3). The iOS SDK gives only prose
     * from Approov.string(from:), so the layer keeps this mirror. A status the mirror does not know keeps the
     * SDK prose.
     */
    static func statusName(_ status: ApproovTokenFetchStatus) -> String {
        switch status {
        case .success: return "SUCCESS"
        case .noNetwork: return "NO_NETWORK"
        case .mitmDetected: return "MITM_DETECTED"
        case .poorNetwork: return "POOR_NETWORK"
        case .noApproovService: return "NO_APPROOV_SERVICE"
        case .badURL: return "BAD_URL"
        case .unknownURL: return "UNKNOWN_URL"
        case .unprotectedURL: return "UNPROTECTED_URL"
        case .notInitialized: return "NOT_INITIALIZED"
        case .rejected: return "REJECTED"
        case .disabled: return "DISABLED"
        case .unknownKey: return "UNKNOWN_KEY"
        case .badKey: return "BAD_KEY"
        case .badPayload: return "BAD_PAYLOAD"
        case .internalError: return "INTERNAL_ERROR"
        @unknown default: return Approov.string(from: status)
        }
    }

    /**
     * Records the ARC of a fetch result as the most recent one. An empty ARC clears the earlier value,
     * because the ARC belongs to the last fetch.
     */
    private static func recordLastARC(_ result: ApproovTokenFetchResult) {
        stateLock.withLock { _lastARC = result.arc }
    }

    /**
     * Gets the Attestation Response Code (ARC) of the most recent token, secure string or custom JWT fetch
     * that this layer made, for a request or for a direct method. It makes no fetch of its own (SPEC 5.3).
     * It returns an empty string if there was no fetch since initialization, if the last fetch had no ARC,
     * or if ARC is not enabled for the account.
     */
    public static func getLastARC() -> String {
        stateLock.withLock { _lastARC }
    }

    /**
     * Gets the current time in milliseconds, adjusted to the Approov servers' clock by the SDK (SPEC 3.8). It
     * requires Approov protection, like the other direct methods.
     */
    public static func getServerAdjustedCurrentTimeMS() throws -> Int64 {
        if !isApproovEnabled() {
            logApproovUnavailable("getServerAdjustedCurrentTimeMS")
            throw ApproovError.permanentError(message: "getServerAdjustedCurrentTimeMS: SDK not initialized")
        }
        return serverAdjustedTimeMS()
    }

    /**
     * The server adjusted time from the SDK, found at run time because SDK 3.5.3 does not have the method. If it
     * is unavailable, the device clock is used and one warning is logged (SPEC 3.8).
     */
    static func serverAdjustedTimeMS() -> Int64 {
        let selector = NSSelectorFromString("getServerAdjustedCurrentTimeMS")
        let sdk: AnyObject = Approov.self
        if sdk.responds(to: selector), let implementation = sdk.method(for: selector) {
            typealias ServerAdjustedTime = @convention(c) (AnyObject, Selector) -> Int64
            let time = unsafeBitCast(implementation, to: ServerAdjustedTime.self)(sdk, selector)
            if time > 0 {
                return time
            }
        }
        let firstUse = stateLock.withLock { () -> Bool in
            defer { deviceClockWarned = true }
            return !deviceClockWarned
        }
        if firstUse {
            log(.warning, "ApproovService: the Approov servers' time is unavailable, using the device clock")
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
