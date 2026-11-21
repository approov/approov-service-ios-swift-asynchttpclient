// MIT License
//
// Copyright (c) 2016-present, Approov Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
// ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
// THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Approov
import Foundation
import NIOHTTP1

/**
 * ApproovRequest stores information about a request being processed for Approov.
 */
public struct ApproovRequest {
    public var url: URL
    public var method: String
    public var headers: HTTPHeaders

    // The body bytes. The layer reads them only when something gets `body`, for example a body digest.
    private var bodyStorage: ApproovRequestBody

    /// The body bytes, or nil if the request has no body or its body cannot be read in memory.
    public var body: Data? {
        get { bodyStorage.value() }
        set { bodyStorage = ApproovRequestBody(value: newValue) }
    }

    public init(url: URL, method: String, headers: HTTPHeaders, body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.bodyStorage = ApproovRequestBody(value: body)
    }

    /// Creates a request whose body bytes come from `bodyProvider` on the first get of `body`. The provider runs
    /// at most once. Copies of the request that are made before a set of `body` share that one result.
    init(url: URL, method: String, headers: HTTPHeaders, bodyProvider: @escaping () -> Data?) {
        self.url = url
        self.method = method
        self.headers = headers
        self.bodyStorage = ApproovRequestBody(provider: bodyProvider)
    }
}

/// Holds the body bytes of an `ApproovRequest`. It calls the provider at most once and keeps the result.
private final class ApproovRequestBody {
    private let lock = NSLock()
    private var provider: (() -> Data?)?
    private var data: Data?

    init(value: Data?) {
        self.data = value
    }

    init(provider: @escaping () -> Data?) {
        self.provider = provider
    }

    func value() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let provider = provider {
            self.provider = nil
            data = provider()
        }
        return data
    }
}

/**
 * ApproovFetchDecision defines the possible results from an Approov request update.
 */
public enum ApproovFetchDecision {
    case ShouldProceed      // Proceed with request
    case ShouldRetry        // User can retry request
    case ShouldFail         // Request should not be made
    case ShouldIgnore       // Do not process request
}

/**
 * ApproovUpdateResponse contains the result of adding Approov protection to a request.
 */
public struct ApproovUpdateResponse {
    public internal(set) var request: ApproovRequest
    public internal(set) var decision: ApproovFetchDecision
    public internal(set) var sdkMessage: String
    public internal(set) var error: Error?
}

/**
 * ApproovRequestMutations stores information about changes made to a network request
 * during Approov processing, such as token headers, substituted headers, and query parameters.
 */
public class ApproovRequestMutations {
    private var tokenHeaderKey: String?
    private var traceIDHeaderKey: String?
    private var substitutionHeaderKeys: [String] = []
    private var originalURL: String?
    private var substitutionQueryParamKeys: [String] = []

    public init() {}

    public func getTokenHeaderKey() -> String? {
        return tokenHeaderKey
    }

    public func setTokenHeaderKey(_ tokenHeaderKey: String) {
        self.tokenHeaderKey = tokenHeaderKey
    }

    public func getTraceIDHeaderKey() -> String? {
        return traceIDHeaderKey
    }

    public func setTraceIDHeaderKey(_ traceIDHeaderKey: String?) {
        self.traceIDHeaderKey = traceIDHeaderKey
    }

    public func getSubstitutionHeaderKeys() -> [String] {
        return substitutionHeaderKeys
    }

    public func setSubstitutionHeaderKeys(_ substitutionHeaderKeys: [String]) {
        self.substitutionHeaderKeys = substitutionHeaderKeys
    }

    public func getOriginalURL() -> String? {
        return originalURL
    }

    public func getSubstitutionQueryParamKeys() -> [String] {
        return substitutionQueryParamKeys
    }

    public func setSubstitutionQueryParamResults(originalURL: String, substitutionQueryParamKeys: [String]) {
        self.originalURL = originalURL
        self.substitutionQueryParamKeys = substitutionQueryParamKeys
    }
}

/**
 * ApproovServiceMutator provides an interface for modifying the behavior of
 * the ApproovService class by overriding the default implementations of the
 * defined callbacks. Opportunities to modify behavior are offered at key
 * points in the service and attestation flows.
 */
public protocol ApproovServiceMutator {
    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.precheck() operation.
     */
    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws

    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.fetchToken() operation.
     */
    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws

    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.fetchSecureString() operation.
     */
    func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult,
                                       operation: String,
                                       key: String) throws

    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.fetchCustomJWT() operation.
     */
    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws

    /**
     * Decides whether a request should be processed in the interceptor or not.
     * Called at the start of the ApproovService interceptor processing.
     */
    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool

    /**
     * Decides how to handle the token fetch result from a call to
     * Approov.fetchTokenAndWait() from within the interceptor.
     */
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult,
                                           url: String) throws -> Bool

    /**
     * Decides how to handle the token fetch result while substituting headers
     * from within the interceptor.
     */
    func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                   header: String) throws -> Bool

    /**
     * Decides how to handle the token fetch result while substituting query params
     * from within the interceptor.
     */
    func handleInterceptorQueryParamSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                       queryKey: String) throws -> Bool

    /**
     * Called after Approov has processed a network request, allowing further
     * modifications.
     */
    func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                           changes: ApproovRequestMutations) throws -> ApproovRequest

    /**
     * Decides whether certificate pinning should be applied to a hostname or not.
     */
    func handlePinningShouldProcessRequest(hostname: String) -> Bool
}

public extension ApproovServiceMutator {
    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws {
        let status = approovResults.status
        switch status {
        case .rejected:
            throw ApproovError.rejectionError(message: "precheck: REJECTED",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "precheck network error: " + ApproovService.statusName(status))
        case .success,
             .unknownKey:
            return
        default:
            throw ApproovError.permanentError(message: "precheck: " + ApproovService.statusName(status))
        }
    }

    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws {
        let status = approovResults.status
        switch status {
        case .success:
            return
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "fetchToken network error: " + ApproovService.statusName(status))
        default:
            throw ApproovError.permanentError(message: "fetchToken: " + ApproovService.statusName(status))
        }
    }

    func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult,
                                       operation: String,
                                       key: String) throws {
        let status = approovResults.status
        switch status {
        case .rejected:
            throw ApproovError.rejectionError(message: "fetchSecureString \(operation) for \(key): REJECTED",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "fetchSecureString \(operation) for \(key): " +
                                               ApproovService.statusName(status))
        case .success,
             .unknownKey:
            return
        default:
            throw ApproovError.permanentError(message: "fetchSecureString \(operation) for \(key): " +
                                              ApproovService.statusName(status))
        }
    }

    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws {
        let status = approovResults.status
        switch status {
        case .rejected:
            throw ApproovError.rejectionError(message: "fetchCustomJWT: REJECTED",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "fetchCustomJWT network error: " + ApproovService.statusName(status))
        case .success:
            return
        default:
            throw ApproovError.permanentError(message: "fetchCustomJWT: " + ApproovService.statusName(status))
        }
    }

    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool {
        let urlString = request.url.absoluteString
        let urlStringRange = NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
        for (_, regex) in ApproovService.getExclusionURLRegexs() {
            if regex.firstMatch(in: urlString, options: [], range: urlStringRange) != nil {
                return false
            }
        }
        return true
    }

    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult,
                                           url: String) throws -> Bool {
        let status = approovResults.status
        switch status {
        case .success,
             .noApproovService:
            return true
        case .unknownURL,
             .unprotectedURL:
            return false
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            // SPEC 4.2: with the status in the token header, network failures proceed, as in 3.5.8
            if ApproovService.getUseApproovStatusIfNoToken() {
                return true
            }
            throw ApproovStandardDecisions.made(.networkingError(message: "Approov token fetch for \(url): " +
                                                                 ApproovService.statusName(status)))
        default:
            throw ApproovStandardDecisions.made(.permanentError(message: "Approov token fetch for \(url): " +
                                                                ApproovService.statusName(status)))
        }
    }

    func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                   header: String) throws -> Bool {
        return standardSubstitution(approovResults)
    }

    func handleInterceptorQueryParamSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                       queryKey: String) throws -> Bool {
        return standardSubstitution(approovResults)
    }


    func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                           changes: ApproovRequestMutations) throws -> ApproovRequest {
        return request
    }

    func handlePinningShouldProcessRequest(hostname: String) -> Bool {
        return true
    }
}

// A standard mutator never aborts a request because of a secure string (SPEC 6.2): SUCCESS substitutes, and the
// layer writes any other status into the placeholder.
private func standardSubstitution(_ approovResults: ApproovTokenFetchResult) -> Bool {
    return approovResults.status == .success
}

/// The 3.5.x token decisions (SPEC 6.2). The default mutator in 3.7.0.
public final class ApproovCloseFailureMutator: ApproovServiceMutator, CustomStringConvertible {
    static let instance = ApproovCloseFailureMutator()
    private init() {}
    public var description: String { "ApproovServiceMutator.CLOSE_FAILURE" }
}

/// Never aborts a request: every failure status proceeds (SPEC 6.2). Opt-in in 3.7.0.
public final class ApproovAlwaysProceedMutator: ApproovServiceMutator, CustomStringConvertible {
    static let instance = ApproovAlwaysProceedMutator()
    private init() {}
    public var description: String { "ApproovServiceMutator.ALWAYS_PROCEED" }

    public func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult,
                                                  url: String) throws -> Bool {
        switch approovResults.status {
        case .unknownURL, .unprotectedURL:
            return false
        default:
            return true
        }
    }
}

public extension ApproovServiceMutator where Self == ApproovCloseFailureMutator {
    static var CLOSE_FAILURE: ApproovCloseFailureMutator { ApproovCloseFailureMutator.instance }
    /// The out-of-the-box mutator: CLOSE_FAILURE in 3.7.0, planned to be ALWAYS_PROCEED in 4.0.0 (SPEC 5.5).
    static var DEFAULT: ApproovServiceMutator { ApproovCloseFailureMutator.instance }
}

public extension ApproovServiceMutator where Self == ApproovAlwaysProceedMutator {
    static var ALWAYS_PROCEED: ApproovAlwaysProceedMutator { ApproovAlwaysProceedMutator.instance }
}

@available(*, deprecated, message: "Use ApproovCloseFailureMutator.DEFAULT or .CLOSE_FAILURE.")
public struct ApproovServiceMutatorDefault: ApproovServiceMutator, CustomStringConvertible {
    public static let shared = ApproovServiceMutatorDefault()
    public var description: String { "ApproovServiceMutator.DEFAULT" }
    private init() {}
}
