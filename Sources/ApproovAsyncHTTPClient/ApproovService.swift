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

    /** True if the interceptor should proceed on network failures and not add an Approov token */
    private static var _proceedOnNetworkFail = false

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
    private static var _serviceMutator: ApproovServiceMutator = ApproovServiceMutatorDefault.shared

    /** Current logging level */
    private static var _loggingLevel: ApproovLogLevel = .info

    /** Failure cache variables */
    private static let failureCacheLock = NIOLock()
    private static var cachedFailureResult: ApproovTokenFetchResult? = nil
    private static var cachedFailureTime: TimeInterval? = nil
    private static var failureCacheTTL: TimeInterval = 0.5 // seconds
    private static var failureCacheMissGroup: DispatchGroup? = nil

    public static var loggingLevel: ApproovLogLevel {
        get {
            stateLock.withLock { _loggingLevel }
        }
        set {
            stateLock.withLock { _loggingLevel = newValue }
        }
    }

    /**
     * Initializes the ApproovService with the config obtained using `approov sdk -getConfigString`
     * or in the original onboarding email.
     */
    public static func initialize(config: String, comment: String? = nil) throws {
        try initLock.withLock {
            let isEnabled = !config.isEmpty
            if approovSDKInitialised && config.isEmpty && !(_approovConfigString?.isEmpty ?? true) {
                if loggingLevel >= .info {
                    os_log("ApproovService already initialized with a valid config; ignoring empty configuration", type: .info)
                }
                return
            }

            if isEnabled {
                do {
                    try Approov.initialize(config, updateConfig: "auto", comment: comment)
                    if loggingLevel >= .info {
                        os_log("ApproovService: Approov SDK initialized", type: .info)
                    }
                } catch {
                    let nsError = error as NSError
                    if nsError.code == 0, nsError.domain == "Foundation._GenericObjCError" {
                        if loggingLevel >= .info {
                            os_log("ApproovService: Approov SDK already initialized", type: .info)
                        }
                    } else {
                        throw ApproovError.initializationFailure(message: "Error initializing Approov SDK: \(nsError.localizedDescription)")
                    }
                }
            }

            // SDK succeeded (or bypass) — now reset and commit new service-layer state.
            approovSDKInitialised = false
            _approovConfigString = config

            stateLock.withLock {
                _proceedOnNetworkFail = false
                _bindHeader = ""
                _approovTokenHeader = "Approov-Token"
                _approovTokenPrefix = ""
                _approovTraceIDHeader = "Approov-TraceID"
                _serviceMutator = ApproovServiceMutatorDefault.shared
                substitutionHeaders = Dictionary()
                substitutionQueryParams = Set()
                exclusionURLRegexs = Dictionary()
                _useApproovStatusIfNoToken = false
            }

            failureCacheLock.withLock {
                cachedFailureResult = nil
                cachedFailureTime = nil
                failureCacheMissGroup = nil
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
            _proceedOnNetworkFail = false
            _bindHeader = ""
            _approovTokenHeader = "Approov-Token"
            _approovTokenPrefix = ""
            _approovTraceIDHeader = "Approov-TraceID"
            _serviceMutator = ApproovServiceMutatorDefault.shared
            substitutionHeaders = Dictionary()
            substitutionQueryParams = Set()
            exclusionURLRegexs = Dictionary()
            _useApproovStatusIfNoToken = false
        }
        failureCacheLock.withLock {
            cachedFailureResult = nil
            cachedFailureTime = nil
            failureCacheMissGroup = nil
        }
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

    /**
     * Logs that an Approov-dependent method was invoked while the platform SDK is not active,
     * distinguishing "initialized in bypass mode (empty config)" from "service layer not initialized
     * at all" so the two states can be told apart in the logs.
     */
    private static func logApproovUnavailable(_ method: String) {
        guard loggingLevel >= .error else {
            return
        }
        let (initialized, enabled) = initLock.withLock {
            (approovSDKInitialised, isApproovEnabledInternal)
        }
        if initialized && !enabled {
            os_log("ApproovService: %@: Approov is disabled (initialized in bypass mode); ignoring call",
                   type: .error, method)
        } else {
            os_log("ApproovService: %@: service layer not initialized", type: .error, method)
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
     * Sets a flag indicating if the network interceptor should proceed anyway if it is
     * not possible to obtain an Approov token due to a networking failure.
     */
    @available(*, deprecated, message: "No longer used internally. Use setServiceMutator to customize network failure behavior.")
    public static var proceedOnNetworkFail: Bool {
        get {
            stateLock.withLock { _proceedOnNetworkFail }
        }
        set {
            stateLock.withLock { _proceedOnNetworkFail = newValue }
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

    /**
     * Sets the header that the Approov token is added on, as well as an optional prefix String.
     */
    public static var approovTokenHeaderAndPrefix: (approovTokenHeader: String, approovTokenPrefix: String) {
        get {
            stateLock.withLock { (_approovTokenHeader, _approovTokenPrefix) }
        }
        set {
            stateLock.withLock {
                _approovTokenHeader = newValue.approovTokenHeader
                _approovTokenPrefix = newValue.approovTokenPrefix
            }
        }
    }

    public static func getApproovTokenHeader() -> String {
        stateLock.withLock { _approovTokenHeader }
    }

    public static func setApproovTraceIDHeader(header: String?) {
        stateLock.withLock {
            _approovTraceIDHeader = header
        }
    }

    public static func getApproovTraceIDHeader() -> String? {
        stateLock.withLock { _approovTraceIDHeader }
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
            _serviceMutator = mutator ?? ApproovServiceMutatorDefault.shared
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
        if loggingLevel >= .debug {
            os_log("ApproovService: setDevKey", type: .debug)
        }
    }

    /**
     * Allows token prefetch operation to be performed as early as possible.
     */
    @available(*, deprecated, message: "Prefetch is managed automatically by the underlying SDK.")
    public static func prefetch() {
        if loggingLevel >= .warning {
            os_log("ApproovService: prefetch is no longer used and does nothing.")
        }
    }

    /**
     * Legacy backward-compatible updateRequest method.
     */
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
    
    /**
     * Extracts the body data from an AsyncHTTPClient `HTTPClient.Body` for body-digest computation.
     *
     * `HTTPClient.Body` is opaque: unlike the async `HTTPClientRequest.Body` it exposes no flag
     * indicating whether it can be consumed more than once. To avoid corrupting one-shot or
     * asynchronous streaming uploads, the body is only buffered when it can be read non-destructively
     * and completely: its stream closure is invoked on an isolated `EmbeddedEventLoop` and the
     * resulting future must complete synchronously. In-memory bodies (`.byteBuffer`, `.bytes`,
     * `.string`) satisfy this and still re-stream correctly at execution time, because reading the
     * buffered copy does not advance the original. Chunked / one-shot / asynchronous streaming bodies
     * are skipped (returns nil) so the request proceeds without a body digest rather than being
     * silently truncated or consumed — matching the documented "gracefully skip one-shot uploads"
     * behaviour for body digests.
     *
     * - Parameter body: the request body to inspect.
     * - Returns: the complete body bytes if they could be buffered non-destructively; otherwise nil.
     */
    static func extractBodyData(from body: HTTPClient.Body?) -> Data? {
        guard let body = body else {
            return nil
        }

        // A nil length indicates a chunked / streaming body of unknown size; treat it as one-shot and
        // skip it so we never start consuming an unrepeatable source.
        if body.length == nil {
            return nil
        }

        let eventLoop = EmbeddedEventLoop()
        var accumulated = Data()
        var unsupportedChunk = false
        let writer = HTTPClient.Body.StreamWriter { ioData in
            switch ioData {
            case .byteBuffer(let buffer):
                accumulated.append(contentsOf: buffer.readableBytesView)
            default:
                // File regions and other chunk kinds cannot be digested in-memory.
                unsupportedChunk = true
            }
            return eventLoop.makeSucceededFuture(())
        }

        var completedSynchronously = false
        let future = body.stream(writer)
        future.whenComplete { _ in completedSynchronously = true }
        eventLoop.run()

        guard completedSynchronously, !unsupportedChunk else {
            // Streaming / asynchronous body: do not digest a partial or consumed body.
            return nil
        }
        return accumulated
    }

    private static func applyMutatorError(_ error: Error,
                                          response: inout ApproovUpdateResponse,
                                          context: String) {
        if let approovError = error as? ApproovError {
            response.error = approovError
            switch approovError {
            case .networkingError:
                response.decision = .ShouldRetry
            default:
                response.decision = .ShouldFail
            }
        } else {
            response.error = ApproovError.permanentError(message: "\(context): \(error.localizedDescription)")
            response.decision = .ShouldFail
        }
    }

    private static func getCachedFailure() -> ApproovTokenFetchResult? {
        return failureCacheLock.withLock {
            return getCachedFailureLocked()
        }
    }

    private static func getCachedFailureLocked() -> ApproovTokenFetchResult? {
        guard let result = cachedFailureResult,
              let time = cachedFailureTime else {
            return nil
        }
        if (ProcessInfo.processInfo.systemUptime - time) < failureCacheTTL {
            if loggingLevel >= .debug {
                os_log("ApproovService: using cached failure: %@", type: .debug, Approov.string(from: result.status))
            }
            return result
        }
        cachedFailureResult = nil
        cachedFailureTime = nil
        return nil
    }

    private static func fetchTokenWithFailureCache(url: String) -> ApproovTokenFetchResult {
        var missGroupToWaitFor: DispatchGroup?
        var ownedMissGroup: DispatchGroup?

        if let cachedResult = failureCacheLock.withLock({ () -> ApproovTokenFetchResult? in
            if let result = getCachedFailureLocked() {
                return result
            }
            if let missGroup = failureCacheMissGroup {
                missGroupToWaitFor = missGroup
            } else {
                let missGroup = DispatchGroup()
                missGroup.enter()
                failureCacheMissGroup = missGroup
                ownedMissGroup = missGroup
            }
            return nil
        }) {
            return cachedResult
        }

        if let missGroupToWaitFor {
            missGroupToWaitFor.wait()
            if let cachedResult = getCachedFailure() {
                return cachedResult
            }
            let result = Approov.fetchTokenAndWait(url)
            cacheFailureIfNeeded(result)
            return result
        }

        let result = Approov.fetchTokenAndWait(url)
        failureCacheLock.withLock {
            cacheFailureIfNeededLocked(result)
            failureCacheMissGroup = nil
            ownedMissGroup?.leave()
        }
        return result
    }

    private static func cacheFailureIfNeededLocked(_ result: ApproovTokenFetchResult) {
        let status = result.status
        switch status {
        case .noNetwork, .poorNetwork, .mitmDetected, .noApproovService:
            cachedFailureResult = result
            cachedFailureTime = ProcessInfo.processInfo.systemUptime
            os_log("ApproovService: caching failure: %@", type: .debug, Approov.string(from: status))
        default:
            break
        }
    }

    private static func cacheFailureIfNeeded(_ result: ApproovTokenFetchResult) {
        failureCacheLock.withLock {
            cacheFailureIfNeededLocked(result)
        }
    }

    public static func setFailureCacheTTL(ttl: TimeInterval) {
        failureCacheLock.withLock {
            failureCacheTTL = ttl
        }
    }

    /**
     * Modern mutator-integrated updateRequestWithApproov method.
     */
    public static func updateRequestWithApproov(request: ApproovRequest) -> ApproovUpdateResponse {
        let url = request.url
        let changes = ApproovRequestMutations()

        if !isApproovEnabled() {
            if loggingLevel >= .info {
                os_log("ApproovService: Approov unavailable, forwarding: %@", type: .info, url.absoluteString)
            }
            return ApproovUpdateResponse(request: request, decision: .ShouldIgnore, sdkMessage: "", error: nil)
        }

        let mutator = getServiceMutator()
        do {
            if try !mutator.handleInterceptorShouldProcessRequest(request) {
                if loggingLevel >= .info {
                    os_log("ApproovService: excluded, forwarding: %@", type: .info, url.absoluteString)
                }
                return ApproovUpdateResponse(request: request, decision: .ShouldIgnore, sdkMessage: "", error: nil)
            }
        } catch {
            var response = ApproovUpdateResponse(request: request, decision: .ShouldFail, sdkMessage: "", error: nil)
            applyMutatorError(error, response: &response, context: "Interceptor should process request")
            return response
        }

        // we construct a response to return
        var response = ApproovUpdateResponse(request: request, decision: .ShouldFail, sdkMessage: "", error: nil)

        // get all of the headers
        let allHeaders = request.headers

        // check if Bind Header is set to a non empty String
        let bindHeader = stateLock.withLock {
            return _bindHeader
        }
        if bindHeader != "" {
            if let value = allHeaders.first(name: bindHeader) {
                Approov.setDataHashInToken(value)
            }
        }

        // Fetch an Approov token
        let approovResult = fetchTokenWithFailureCache(url: url.absoluteString)
        let hostname = url.host ?? ""
        if loggingLevel >= .info {
            os_log("ApproovService: updateRequest %@: %@", type: .info, hostname, approovResult.loggableToken())
        }
        if approovResult.isConfigChanged {
            Approov.fetchConfig()
            if loggingLevel >= .info {
                os_log("ApproovService: dynamic configuration update received")
            }
        }

        response.sdkMessage = Approov.string(from: approovResult.status)

        var hasChanges = false
        var setTokenHeaderKey: String?
        var setTokenHeaderValue: String?
        var setTraceIDHeaderKey: String?
        var setTraceIDHeaderValue: String?

        do {
            let shouldAddToken = try mutator.handleInterceptorFetchTokenResult(approovResult, url: url.absoluteString)
            response.decision = .ShouldProceed
            if !shouldAddToken {
                return response
            }
        } catch {
            applyMutatorError(error, response: &response, context: "Approov token fetch")
            return response
        }

        let tokenHeader = stateLock.withLock {
            return _approovTokenHeader
        }
        let tokenPrefix = stateLock.withLock {
            return _approovTokenPrefix
        }
        hasChanges = true
        setTokenHeaderKey = tokenHeader
        if approovResult.token.isEmpty && (stateLock.withLock { _useApproovStatusIfNoToken }) {
            setTokenHeaderValue = tokenPrefix + response.sdkMessage
        } else {
            setTokenHeaderValue = tokenPrefix + approovResult.token
        }
        let traceID = approovResult.traceID
        if let traceHeader = stateLock.withLock({ _approovTraceIDHeader }),
           !traceHeader.isEmpty {
            hasChanges = true
            setTraceIDHeaderKey = traceHeader
            setTraceIDHeaderValue = traceID
        }

        // deal with header substitutions
        var setSubstitutionHeaders: [String: String] = [:]
        let subsHeadersCopy = getSubstitutionHeaders()
        for (header, prefix) in subsHeadersCopy {
            if let value = allHeaders.first(name: header) {
                if ((value.hasPrefix(prefix)) && (value.count > prefix.count)) {
                    let lookupKey = String(value.dropFirst(prefix.count))
                    let approovResults = Approov.fetchSecureStringAndWait(lookupKey, nil)
                    if loggingLevel >= .info {
                        os_log("ApproovService: Substituting header: %@, %@", type: .info, header, Approov.string(from: approovResults.status))
                    }

                    do {
                        if try mutator.handleInterceptorHeaderSubstitutionResult(approovResults, header: header) {
                            if let secureStringResult = approovResults.secureString {
                                if !secureStringResult.isEmpty {
                                    hasChanges = true
                                    setSubstitutionHeaders[header] = prefix + secureStringResult
                                }
                            } else {
                                response.decision = .ShouldFail
                                response.error = ApproovError.permanentError(message: "Header substitution: key lookup error")
                                return response
                            }
                        }
                    } catch {
                        applyMutatorError(error, response: &response, context: "Header substitution for \(header)")
                        return response
                    }
                }
            }
        }

        // deal with query parameter substitutions
        var updateURL: URL?
        var queryKeys: [String] = []
        let subsQueryParamsCopy = getSubstitutionQueryParams()
        var updateURLString = url.absoluteString
        for entry in subsQueryParamsCopy {
            let urlStringRange = NSRange(updateURLString.startIndex..<updateURLString.endIndex, in: updateURLString)
            let escapedEntry = NSRegularExpression.escapedPattern(for: entry)
            guard let regex = try? NSRegularExpression(pattern: #"[\\?&]"# + escapedEntry + #"=([^&;]+)"#, options: []) else {
                continue
            }
            let matches: [NSTextCheckingResult] = regex.matches(in: updateURLString, options: [], range: urlStringRange)
            for match: NSTextCheckingResult in matches.reversed() {
                for rangeIndex in (1..<match.numberOfRanges).reversed() {
                    let matchRange = match.range(at: rangeIndex)
                    if let substringRange = Range(matchRange, in: updateURLString) {
                        let queryValue = String(updateURLString[substringRange])
                        let approovResults = Approov.fetchSecureStringAndWait(String(queryValue), nil)
                        if loggingLevel >= .info {
                            os_log("ApproovService: Attempting query parameter substitution: %@, %@", entry,
                                Approov.string(from: approovResults.status))
                        }

                        do {
                            if try mutator.handleInterceptorQueryParamSubstitutionResult(approovResults, queryKey: entry) {
                                if let secureStringResult = approovResults.secureString {
                                    if !secureStringResult.isEmpty {
                                        hasChanges = true
                                        queryKeys.append(entry)
                                        updateURLString.replaceSubrange(Range(matchRange, in: updateURLString)!, with: secureStringResult)
                                        updateURL = URL(string: updateURLString)
                                        if updateURL == nil {
                                            response.decision = .ShouldFail
                                            response.error = ApproovError.permanentError(
                                                message: "Query parameter substitution for \(entry): malformed URL \(updateURLString)")
                                            return response
                                        }
                                    }
                                }
                            }
                        } catch {
                            applyMutatorError(error, response: &response, context: "Query parameter substitution for \(entry)")
                            return response
                        }
                    }
                }
            }
        }

        // apply all the changes to the request
        if (hasChanges) {
            if let tokenHeaderKey = setTokenHeaderKey,
               let tokenHeaderValue = setTokenHeaderValue {
                response.request.headers.replaceOrAdd(name: tokenHeaderKey, value: tokenHeaderValue)
                changes.setTokenHeaderKey(tokenHeaderKey)
            }
            if let traceIDHeaderKey = setTraceIDHeaderKey,
               let traceIDHeaderValue = setTraceIDHeaderValue {
                response.request.headers.replaceOrAdd(name: traceIDHeaderKey, value: traceIDHeaderValue)
                changes.setTraceIDHeaderKey(traceIDHeaderKey)
            }
            if (!setSubstitutionHeaders.isEmpty) {
                for (header, value) in setSubstitutionHeaders {
                    response.request.headers.replaceOrAdd(name: header, value: value)
                }
                changes.setSubstitutionHeaderKeys(Array(setSubstitutionHeaders.keys))
            }
            if let updateURLString = updateURL,
               let originalURLString = request.url.absoluteString as String? {
                if (originalURLString != updateURLString.absoluteString) {
                    response.request.url = updateURLString
                    changes.setSubstitutionQueryParamResults(originalURL: originalURLString, substitutionQueryParamKeys: queryKeys)
                }
            }
        }

        // call the processed request callback
        do {
            response.request = try mutator.handleInterceptorProcessedRequest(response.request, changes: changes)
        } catch {
            applyMutatorError(error, response: &response, context: "Interceptor processed request")
            return response
        }

        return response
    }

    /**
     * Adds the value of a header which should be subject to secure strings substitution.
     */
    public static func addSubstitutionHeader(header: String, prefix: String?) {
        stateLock.withLock {
            substitutionHeaders[header] = prefix ?? ""
            if _loggingLevel >= .debug {
                os_log("ApproovService: addSubstitutionHeader: %@ %@", type: .debug, header, prefix ?? "")
            }
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
            if _loggingLevel >= .debug {
                os_log("ApproovService: removeSubstitutionHeader: %@", type: .debug, header)
            }
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
            if _loggingLevel >= .debug {
                os_log("ApproovService: addSubstitutionQueryParam: %@", type: .debug, key)
            }
        }
    }

    /**
     * Removes a query parameter key name previously added using addSubstitutionQueryParam.
     */
    public static func removeSubstitutionQueryParam(key: String) {
        stateLock.withLock {
            substitutionQueryParams.remove(key)
            if _loggingLevel >= .debug {
                os_log("ApproovService: removeSubstitutionQueryParam: %@", type: .debug, key)
            }
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
                if _loggingLevel >= .debug {
                    os_log("ApproovService: addExclusionURLRegex: %@", type: .debug, urlRegex)
                }
            } catch {
                // The pattern was rejected and no exclusion was registered; surface this at error
                // level so callers are not left believing an invalid regex took effect.
                if _loggingLevel >= .error {
                    os_log("ApproovService: addExclusionURLRegex: %@ rejected, exclusion NOT added: %@",
                           type: .error, urlRegex, error.localizedDescription)
                }
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
                if _loggingLevel >= .debug {
                    os_log("ApproovService: removeExclusionURLRegex: %@", type: .debug, urlRegex)
                }
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
            if loggingLevel >= .debug {
                os_log("ApproovService: getDeviceID %@", type: .debug, deviceID!)
            }
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
        if loggingLevel >= .debug {
            os_log("ApproovService: setDataHashInToken", type: .debug)
        }
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
        if loggingLevel >= .debug {
            os_log("ApproovService: fetchToken: %@", type: .debug, Approov.string(from: result.status))
        }
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
        if loggingLevel >= .debug {
            os_log("ApproovService: setInstallAttrsInToken", type: .debug)
        }
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
     * Legacy getMessageSignature.
     */
    @available(*, deprecated, message: "Use getAccountMessageSignature or getInstallMessageSignature instead.")
    public static func getMessageSignature(message: String) throws -> String {
        guard let signature = getAccountMessageSignature(message: message) else {
            throw ApproovError.permanentError(message: "getMessageSignature: signature unavailable")
        }
        return signature
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
        if loggingLevel >= .info {
            os_log("ApproovService: fetchSecureString: %@: %@", type: .info, type, Approov.string(from: approovResult.status))
        }
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
        if loggingLevel >= .info {
            os_log("ApproovService: fetchCustomJWT: %@", type: .info, Approov.string(from: approovResult.status))
        }
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
        if approovResults.status == ApproovTokenFetchStatus.unknownKey {
            if loggingLevel >= .debug {
                os_log("ApproovService: precheck: success", type: .debug)
            }
        } else {
            if loggingLevel >= .debug {
                os_log("ApproovService: precheck: %@", type: .debug, Approov.string(from: approovResults.status))
            }
        }
        try wrappingApproovError("precheck") {
            try getServiceMutator().handlePrecheckResult(approovResults)
        }
    }

    /**
     * Gets the last ARC (Attestation Response Code) code.
     */
    public static func getLastARC() -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("getLastARC")
            return ""
        }
        guard let approovPins = Approov.getPins("public-key-sha256") else {
            if loggingLevel >= .error {
                os_log("ApproovService: no host pinning information available", type: .error)
            }
            return ""
        }
        if let hostname = approovPins.keys.first(where: { $0 != "*" }) {
            let result = Approov.fetchTokenAndWait(hostname)
            if result.token.count > 0 {
                return result.arc
            }
        }
        if loggingLevel >= .info {
            os_log("ApproovService: ARC code unavailable", type: .info)
        }
        return ""
    }
}
