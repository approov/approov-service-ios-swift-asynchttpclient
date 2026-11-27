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
import CommonCrypto
import Foundation
import RawStructuredFieldValues
import NIOHTTP1

/**
 * Provides a base implementation of message signing for Approov when using
 * AsyncHTTPClient requests. This class provides mechanisms to configure and apply
 * message signatures to HTTP requests based on specified parameters and
 * algorithms.
 */
public class ApproovDefaultMessageSigning: ApproovServiceMutator, CustomStringConvertible {

    /**
     * Constant for the SHA-256 digest algorithm (used for body digests).
     */
    public static let DIGEST_SHA256 = "sha-256"

    /**
     * Constant for the SHA-512 digest algorithm (used for body digests).
     */
    public static let DIGEST_SHA512 = "sha-512"

    /**
     * Constant for the ECDSA P-256 with SHA-256 algorithm (used when signing with install private key).
     */
    public static let ALG_ES256 = "ecdsa-p256-sha256"

    /**
     * Constant for the HMAC with SHA-256 algorithm (used when signing with the account signing key).
     */
    public static let ALG_HS256 = "hmac-sha256"

    /**
     * Default factory for generating signature parameters.
     */
    private var defaultFactory: SignatureParametersFactory?

    /**
     * Host-specific factories for generating signature parameters.
     */
    private var hostFactories: [String: SignatureParametersFactory]

    // providers that replace the SDK signatures in tests
    private var installMessageSignatureProviderForTesting: ((String) -> String?)?
    private var accountMessageSignatureProviderForTesting: ((String) -> String?)?

    // the mutator that makes the decisions, or nil for the CLOSE_FAILURE decisions of init()
    private let decisions: ApproovServiceMutator?

    /**
     * Initializer
     */
    public init() {
        hostFactories = [:]
        decisions = nil
    }

    /**
     * Creates a signer that makes the decisions of another mutator and signs the requests that mutator
     * processed. Every decision hook is passed to the given mutator, and the request its
     * handleInterceptorProcessedRequest returns is then signed, so a change it makes is covered by the
     * signature. Apps use combined(decisions:).
     *
     * @param decisions is the mutator that makes the decisions, a standard one or your own
     */
    internal init(decisions: ApproovServiceMutator) {
        hostFactories = [:]
        self.decisions = decisions
    }

    /**
     * Gets a new message signing service mutator that adds both the install and the account signature to
     * every request carrying the Approov token header, and makes the decisions of the given mutator, such as
     * .CLOSE_FAILURE, .ALWAYS_PROCEED or your own. A signature that cannot be produced is left out and the
     * request goes ahead with the other one, or unsigned. Install it with ApproovService.setServiceMutator.
     *
     * @param decisions is the mutator whose decisions are to be made
     * @return a new signer with the default factory set to sign with both signatures
     */
    public static func combined(decisions: ApproovServiceMutator) -> ApproovDefaultMessageSigning {
        return ApproovDefaultMessageSigning(decisions: decisions)
            .setDefaultFactory(generateDefaultSignatureParametersFactory().setUseInstallAndAccountMessageSigning())
    }

    /**
     * Gets a new message signing service mutator that adds both the install and the account signature to
     * every request carrying the Approov token header, and makes the .DEFAULT decisions.
     *
     * @return a new signer with the default factory set to sign with both signatures
     */
    public static func combined() -> ApproovDefaultMessageSigning {
        return combined(decisions: .DEFAULT)
    }

    // the mutator that makes the decisions, CLOSE_FAILURE if none was given
    private var decider: ApproovServiceMutator {
        return decisions ?? ApproovCloseFailureMutator.instance
    }

    public var description: String {
        guard let decisions else {
            return "ApproovDefaultMessageSigning"
        }
        return "ApproovDefaultMessageSigning(\(String(describing: decisions)))"
    }

    // the decision hooks, each made by the decisions mutator. A standard decision it throws is recorded for the
    // hook call in progress, so it reaches the app in the same form as when that mutator is installed on its own.

    public func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws {
        try decider.handlePrecheckResult(approovResults)
    }

    public func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws {
        try decider.handleFetchTokenResult(approovResults)
    }

    public func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult,
                                              operation: String,
                                              key: String) throws {
        try decider.handleFetchSecureStringResult(approovResults, operation: operation, key: key)
    }

    public func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws {
        try decider.handleFetchCustomJWTResult(approovResults)
    }

    public func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool {
        return try decider.handleInterceptorShouldProcessRequest(request)
    }

    public func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
        return try decider.handleInterceptorFetchTokenResult(approovResults, url: url)
    }

    public func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                          header: String) throws -> Bool {
        return try decider.handleInterceptorHeaderSubstitutionResult(approovResults, header: header)
    }

    public func handleInterceptorQueryParamSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                              queryKey: String) throws -> Bool {
        return try decider.handleInterceptorQueryParamSubstitutionResult(approovResults, queryKey: queryKey)
    }

    public func handlePinningShouldProcessRequest(hostname: String) -> Bool {
        return decider.handlePinningShouldProcessRequest(hostname: hostname)
    }

    /**
     * Sets the default factory for generating signature parameters.
     *
     * - Parameter factory: The factory to set as the default.
     * - Returns: The current instance for method chaining.
     */
    public func setDefaultFactory(_ factory: SignatureParametersFactory) -> ApproovDefaultMessageSigning {
        defaultFactory = factory
        return self
    }

    /**
     * Associates a specific host with a factory for generating signature parameters.
     *
     * - Parameters:
     *   - hostName: The host name.
     *   - factory: The factory to associate with the host.
     * - Returns: The current instance for method chaining.
     */
    public func putHostFactory(hostName: String, factory: SignatureParametersFactory) -> ApproovDefaultMessageSigning {
        hostFactories[hostName] = factory
        return self
    }

    func setInstallMessageSignatureProviderForTesting(_ provider: ((String) -> String?)?) -> ApproovDefaultMessageSigning {
        installMessageSignatureProviderForTesting = provider
        return self
    }

    func setAccountMessageSignatureProviderForTesting(_ provider: ((String) -> String?)?) -> ApproovDefaultMessageSigning {
        accountMessageSignatureProviderForTesting = provider
        return self
    }

    private func installMessageSignature(message: String) -> String? {
        return installMessageSignatureProviderForTesting?(message) ?? ApproovService.getInstallMessageSignature(message: message)
    }

    private func accountMessageSignature(message: String) -> String? {
        return accountMessageSignatureProviderForTesting?(message) ?? ApproovService.getAccountMessageSignature(message: message)
    }

    /** The factory for the request's host, compared as pins are looked up, or the default factory. */
    private func factory(for provider: ApproovAsyncHTTPClientComponentProvider) -> SignatureParametersFactory? {
        let host = ApproovService.normalisedHost(provider.getRequest().url.host ?? "")
        return hostFactories.first { ApproovService.normalisedHost($0.key) == host }?.value ?? defaultFactory
    }

    private func buildSignatureParameters(provider: ApproovAsyncHTTPClientComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters? {
        return try factory(for: provider)?.buildSignatureParameters(provider: provider, changes: changes)
    }

    /**
     * Processes a request to add message signature headers. The decisions mutator processes the request first,
     * and the request it returns is signed.
     */
    public func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                                   changes: ApproovRequestMutations) throws -> ApproovRequest {
        return try signedRequest(decider.handleInterceptorProcessedRequest(request, changes: changes), changes: changes)
    }

    @available(*, deprecated, message: "Use handleInterceptorProcessedRequest instead.")
    public func processedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
        return try signedRequest(request, changes: changes)
    }

    private static func withoutSignatureHeaders(_ request: ApproovRequest) -> ApproovRequest {
        var unsigned = request
        for field in ["Signature", "Signature-Input", "Signature-Base-Digest", "Content-Digest"] {
            unsigned.headers.remove(name: field)
        }
        return unsigned
    }

    // A missing signature is logged at a higher level the first time in the process, then at debug level, so a
    // device that never produces one does not log on every request. Guarded by missingLogLock.
    private static let missingLogLock = NSLock()
    private static var installMissingLogged = false
    private static var accountMissingLogged = false
    private static var unsignedLogged = false

    internal static func resetMissingSignatureLogsForTesting() {
        missingLogLock.lock()
        installMissingLogged = false
        accountMissingLogged = false
        unsignedLogged = false
        missingLogLock.unlock()
    }

    private static func logMissingSignatures(_ missing: [(String, String)], produced: Bool) {
        guard !missing.isEmpty else { return }
        missingLogLock.lock()
        defer { missingLogLock.unlock() }
        if !produced {
            let first = !unsignedLogged
            unsignedLogged = true
            let detail = missing.map { "\($0.0) signature \($0.1)" }.joined(separator: ": ")
            ApproovService.log(first ? .error : .debug,
                               "ApproovService: no message signature could be produced, proceeding unsigned: \(detail)")
            return
        }
        for (sigId, reason) in missing {
            let first = (sigId == "install") ? !installMissingLogged : !accountMissingLogged
            if sigId == "install" { installMissingLogged = true } else { accountMissingLogged = true }
            ApproovService.log(first ? .warning : .debug,
                               "ApproovService: \(sigId) message signature \(reason), signed without it")
        }
    }

    /**
     * Signs a request that carries the token header. Each selected signature is a member of one Signature and one
     * Signature-Input dictionary. A member that cannot be produced is left out; with no member, the request is
     * sent unsigned. A missing member is logged once per process at a higher level, then at debug level. An unsupported algorithm and a required body digest that
     * cannot be generated fail the request.
     */
    func signedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
        // Sign only a request that carries the token header the layer added
        guard changes.getTokenHeaderKey() != nil else {
            return request
        }
        let provider = ApproovAsyncHTTPClientComponentProvider(request: request)
        guard let params = try buildSignatureParameters(provider: provider, changes: changes) else {
            return request
        }
        let algorithms = params.getAlg().map { [$0] } ?? (factory(for: provider)?.signatureAlgorithms() ?? [])
        for alg in algorithms where alg != ApproovDefaultMessageSigning.ALG_ES256 && alg != ApproovDefaultMessageSigning.ALG_HS256 {
            throw ApproovRequestPathError.configuration("Unsupported algorithm identifier: \(alg)")
        }
        var signatures: [(String, Data)] = []
        var inputs: [(String, InnerList)] = []
        var firstMessage: String?
        var missing: [(String, String)] = []
        for alg in algorithms {
            let memberParams = SignatureParameters(base: params).setAlg(alg)
            let sigId = (alg == ApproovDefaultMessageSigning.ALG_ES256) ? "install" : "account"
            do {
                // WARNING never log the message: it contains an Approov token which gives access to your API.
                let message = try SignatureBaseBuilder(sigParams: memberParams, ctx: provider).createSignatureBase()
                let signature: Data
                if alg == ApproovDefaultMessageSigning.ALG_ES256 {
                    guard let base64Signature = installMessageSignature(message: message),
                          let decodedSignature = Data(base64Encoded: base64Signature) else {
                        missing.append((sigId, "unavailable"))
                        continue
                    }
                    signature = try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(decodedSignature)
                } else {
                    guard let base64Signature = accountMessageSignature(message: message),
                          let decodedSignature = Data(base64Encoded: base64Signature) else {
                        missing.append((sigId, "unavailable"))
                        continue
                    }
                    signature = decodedSignature
                }
                inputs.append((sigId, try memberParams.toComponentValue()))
                signatures.append((sigId, signature))
                firstMessage = firstMessage ?? message
            } catch {
                missing.append((sigId, "failed: \(error.localizedDescription)"))
            }
        }
        ApproovDefaultMessageSigning.logMissingSignatures(missing, produced: !signatures.isEmpty)
        guard !signatures.isEmpty else {
            return ApproovDefaultMessageSigning.withoutSignatureHeaders(provider.getRequest())
        }
        guard let sigHeader = (try? SFV.serializeDictionary(entries: signatures)) ?? nil,
              let sigInputHeader = (try? SFV.serializeDictionary(entries: inputs)) ?? nil else {
            ApproovService.log(.error, "ApproovService: failed to serialize signature headers, skipping signing")
            return ApproovDefaultMessageSigning.withoutSignatureHeaders(provider.getRequest())
        }
        var signedRequest = provider.getRequest()
        signedRequest.headers.replaceOrAdd(name: "Signature", value: sigHeader)
        signedRequest.headers.replaceOrAdd(name: "Signature-Input", value: sigInputHeader)
        if params.isDebugMode(), let message = firstMessage {
            let digest = ApproovDefaultMessageSigning.sha256(data: Data(message.utf8))
            if let sigBaseDigestHeader = (try? SFV.serializeDictionary(key: "sha-256", data: digest)) ?? nil {
                signedRequest.headers.replaceOrAdd(name: "Signature-Base-Digest", value: sigBaseDigestHeader)
            } else {
                ApproovService.log(.debug, "ApproovService: Failed to get digest algorithm - no debug entry")
            }
        }
        return signedRequest
    }

    /**
     * SHA256 of given input bytes.
     *
     * @param data is the input data
     * @return the hash data
     */
    static func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0,  count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    // Decode ASN.1 DER encoded ES256 signature into "raw" signature format
    static func decodeASN_1_DER_ES256_Signature(_ signature: Data) throws -> Data {
        var offset = 0

        // Ensure signature has at least 2 bytes (tag and length)
        guard signature.count >= 2 else {
            throw ApproovError.permanentError(message: "ASN.1 DER signature too short")
        }

        // Ensure the signature starts with a valid ASN.1 sequence
        guard signature[offset] == 0x30 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER sequence")
        }
        offset += 1

        // Read the total length of the sequence
        let sequenceLength = Int(signature[offset])
        offset += 1

        guard sequenceLength == signature.count - 2 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER sequence length")
        }

        // Ensure there are at least 2 more bytes for r's tag and length
        guard offset + 2 <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading r")
        }

        // Decode the first integer (r)
        guard signature[offset] == 0x02 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER integer for r")
        }
        offset += 1

        let rLength = Int(signature[offset])
        offset += 1

        // Ensure we can read rBytes
        guard offset + rLength <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading r value")
        }

        let rBytes = signature[offset..<(offset + rLength)]
        offset += rLength

        // Ensure there are at least 2 more bytes for s's tag and length
        guard offset + 2 <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading s")
        }

        // Decode the second integer (s)
        guard signature[offset] == 0x02 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER integer for s")
        }
        offset += 1

        let sLength = Int(signature[offset])
        offset += 1

        // Ensure we can read sBytes
        guard offset + sLength <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading s value")
        }

        let sBytes = signature[offset..<(offset + sLength)]
        offset += sLength

        // Ensure the entire signature has been processed
        guard offset == signature.count else {
            throw ApproovError.permanentError(message: "Extra data in ASN.1 DER signature")
        }

        return try to32ByteData(bytes: rBytes) + to32ByteData(bytes: sBytes)
    }

    private static func to32ByteData(bytes: Data) throws -> Data {
        if bytes.count < 32 {
            let padding = Data(repeating: 0, count: 32 - bytes.count)
            return padding + bytes
        } else if bytes.count == 32 {
            // Return as-is if the byte array is exactly 32 bytes
            return bytes
        } else if bytes.count == 33 && bytes.first == 0 {
            // Remove the leading zero if the byte array is 33 bytes and starts with 0
            return bytes.dropFirst()
        } else {
            // Throw an error if the byte array cannot be represented as 32 bytes
            throw ApproovError.permanentError(message: "Not an ASN.1 DER ES256 signature part")
        }
    }

    /**
     * Generates a default `SignatureParametersFactory` with predefined settings and optional base parameters.
     *
     * - Parameter baseParametersOverride: The base parameters to override, or `nil` to use defaults.
     * - Returns: A new instance of `SignatureParametersFactory`.
     */
    public static func generateDefaultSignatureParametersFactory(baseParametersOverride: SignatureParameters? = nil) -> SignatureParametersFactory {
        let defaultExpiresLifetime: Int64 = 15
        let baseParameters: SignatureParameters

        if let override = baseParametersOverride {
            baseParameters = override
        } else {
            baseParameters = SignatureParameters()
                .addComponentIdentifier(ApproovAsyncHTTPClientComponentProvider.DC_METHOD)
                .addComponentIdentifier(ApproovAsyncHTTPClientComponentProvider.DC_TARGET_URI)
        }

        let defaultSignatureParametersFactory = SignatureParametersFactory()
            .setBaseParameters(baseParameters)
            .setUseInstallMessageSigning()
            .setAddCreated(true)
            .setExpiresLifetime(defaultExpiresLifetime)
            .setAddApproovTokenHeader(true)
            .setAddApproovTraceIDHeader(true)
            .addOptionalHeaders(["Authorization", "Content-Length", "Content-Type"])
        do {
            try defaultSignatureParametersFactory.setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: false)
        } catch {
            ApproovService.log(.error, "ApproovDefaultMessageSigning - generateDefaultSignatureParametersFactory: Failed to set default body digest algorithm")
        }
        return defaultSignatureParametersFactory
    }
}

/**
 * Factory class for creating pre-request `SignatureParameters` with configurable settings.
 */
public class SignatureParametersFactory {
    private var baseParameters: SignatureParameters?
    private var bodyDigestAlgorithm: String?
    private var bodyDigestRequired: Bool = false
    private var useInstallMessageSigning: Bool = true
    private var useAccountMessageSigning: Bool = false
    private var addCreated: Bool = false
    private var expiresLifetime: Int64 = 0
    private var addApproovTokenHeader: Bool = false
    private var addApproovTraceIDHeader: Bool = false
    private var optionalHeaders: [String] = []

    @discardableResult
    public func setBaseParameters(_ baseParameters: SignatureParameters) -> SignatureParametersFactory {
        self.baseParameters = baseParameters
        return self
    }

    @discardableResult
    public func setBodyDigestConfig(_ bodyDigestAlgorithm: String?, required: Bool) throws -> SignatureParametersFactory {
        if let algorithm = bodyDigestAlgorithm {
            guard algorithm == ApproovDefaultMessageSigning.DIGEST_SHA256 ||
                  algorithm == ApproovDefaultMessageSigning.DIGEST_SHA512 else {
                throw ApproovError.permanentError(message: "Unsupported body digest algorithm: \(algorithm)")
            }
            self.bodyDigestAlgorithm = algorithm
            self.bodyDigestRequired = required
        } else {
            // Passing a nil algorithm disables body digest generation entirely.
            self.bodyDigestAlgorithm = nil
            self.bodyDigestRequired = false
        }
        return self
    }

    /** Selects the install signature only. */
    @discardableResult
    public func setUseInstallMessageSigning() -> SignatureParametersFactory {
        self.useInstallMessageSigning = true
        self.useAccountMessageSigning = false
        return self
    }

    /** Selects the account signature only. */
    @discardableResult
    public func setUseAccountMessageSigning() -> SignatureParametersFactory {
        self.useInstallMessageSigning = false
        self.useAccountMessageSigning = true
        return self
    }

    /** Selects both signatures, as two members of one Signature dictionary. */
    @discardableResult
    public func setUseInstallAndAccountMessageSigning() -> SignatureParametersFactory {
        self.useInstallMessageSigning = true
        self.useAccountMessageSigning = true
        return self
    }

    /** The algorithms of the signatures to produce, install first. */
    func signatureAlgorithms() -> [String] {
        var algorithms: [String] = []
        if useInstallMessageSigning {
            algorithms.append(ApproovDefaultMessageSigning.ALG_ES256)
        }
        if useAccountMessageSigning {
            algorithms.append(ApproovDefaultMessageSigning.ALG_HS256)
        }
        return algorithms
    }

    @discardableResult
    public func setAddCreated(_ addCreated: Bool) -> SignatureParametersFactory {
        self.addCreated = addCreated
        return self
    }

    @discardableResult
    public func setExpiresLifetime(_ expiresLifetime: Int64) -> SignatureParametersFactory {
        self.expiresLifetime = expiresLifetime
        return self
    }

    @discardableResult
    public func setAddApproovTokenHeader(_ addApproovTokenHeader: Bool) -> SignatureParametersFactory {
        self.addApproovTokenHeader = addApproovTokenHeader
        return self
    }

    @discardableResult
    public func setAddApproovTraceIDHeader(_ addApproovTraceIDHeader: Bool) -> SignatureParametersFactory {
        self.addApproovTraceIDHeader = addApproovTraceIDHeader
        return self
    }

    @discardableResult
    public func addOptionalHeaders(_ headers: [String]) -> SignatureParametersFactory {
        self.optionalHeaders.append(contentsOf: headers)
        return self
    }

    func buildSignatureParameters(provider: ApproovAsyncHTTPClientComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters {
        var requestParameters: SignatureParameters
        if baseParameters == nil {
            requestParameters = SignatureParameters()
        } else {
            requestParameters = SignatureParameters(base: baseParameters!)
        }

        if addCreated || expiresLifetime > 0 {
            let currentTime = ApproovService.serverAdjustedTimeMS() / 1000
            if addCreated {
                requestParameters.setCreated(currentTime)
            }
            if expiresLifetime > 0 {
                requestParameters.setExpires(currentTime + expiresLifetime)
            }
        }

        if addApproovTokenHeader, let tokenHeaderKey = changes.getTokenHeaderKey() {
            requestParameters.addComponentIdentifier(tokenHeaderKey)
        }

        if addApproovTraceIDHeader, let traceIDHeaderKey = changes.getTraceIDHeaderKey() {
            requestParameters.addComponentIdentifier(traceIDHeaderKey)
        }

        for headerName in optionalHeaders {
            if provider.hasField(name: headerName) {
                requestParameters.addComponentIdentifier(headerName)
            }
        }

        if bodyDigestAlgorithm != nil {
            let bodyDigestCreated = try generateBodyDigest(provider: provider, requestParameters: requestParameters)
            if !bodyDigestCreated && bodyDigestRequired {
                throw ApproovRequestPathError.configuration("Failed to create required body digest")
            }
        }

        return requestParameters
    }

    private func generateBodyDigest(provider: ApproovAsyncHTTPClientComponentProvider, requestParameters: SignatureParameters) throws -> Bool {
        var request = provider.getRequest()

        guard let body = request.body else {
            return false
        }

        guard let bodyDigestAlg = bodyDigestAlgorithm else {
            return false
        }

        let digest: Data
        switch bodyDigestAlg {
        case ApproovDefaultMessageSigning.DIGEST_SHA256:
            digest = ApproovDefaultMessageSigning.sha256(data: body)
        case ApproovDefaultMessageSigning.DIGEST_SHA512:
            digest = SignatureParametersFactory.sha512(data: body)
        default:
            throw ApproovError.permanentError(message: "Unsupported body digest algorithm: \(bodyDigestAlg)")
        }

        do {
            guard let digestHeader = try SFV.serializeDictionary(key: bodyDigestAlg, data: digest) else {
                throw ApproovError.permanentError(message: "Failed to serialize Content-Digest header")
            }
            request.headers.replaceOrAdd(name: "Content-Digest", value: digestHeader)
            provider.setRequest(request)
        } catch let error {
            throw ApproovError.permanentError(message: "Failed to serialize Content-Digest header: \(error)")
        }
        requestParameters.addComponentIdentifier("Content-Digest")
        return true
    }

    private static func sha512(data: Data) -> Data {
        var hash = [UInt8](repeating: 0,  count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}

/**
 * ApproovAsyncHTTPClientComponentProvider implements the ComponentProvider protocol for AsyncHTTPClient requests.
 */
class ApproovAsyncHTTPClientComponentProvider: ComponentProvider {

    private var request: ApproovRequest

    init(request: ApproovRequest) {
        self.request = request
    }

    public func getRequest() -> ApproovRequest {
        return request
    }

    public func setRequest(_ newRequest: ApproovRequest) {
        self.request = newRequest
    }

    public func getMethod() -> String {
        return request.method
    }

    public func getAuthority() -> String {
        // RFC 9421 section 2.2.3: lowercase host, default port left out
        guard let host = request.url.host else {
            return ""
        }
        let scheme = request.url.scheme?.lowercased()
        if let port = request.url.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            return "\(host.lowercased()):\(port)"
        }
        return host.lowercased()
    }

    public func getScheme() -> String {
        return request.url.scheme ?? "http"
    }

    public func getTargetUri() -> String {
        // The URL as the stack sends it. A fragment is never sent, so remove it.
        let uri = request.url.absoluteString
        if let fragmentStart = uri.firstIndex(of: "#") {
            return String(uri[..<fragmentStart])
        }
        return uri
    }

    public func getRequestTarget() -> String {
        var target = getPath()
        if let query = request.url.query {
            target += "?\(query)"
        }
        return target
    }

    public func getPath() -> String {
        // RFC 9421 derived components use the on-wire (percent-encoded) path, whereas URL.path is
        // percent-decoded. Prefer the encoded form so the server reconstructs the same signature base.
        if let encodedPath = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
           !encodedPath.isEmpty {
            return encodedPath
        }
        // RFC 9421 section 2.2.6: an empty path is "/". AsyncHTTPClient also sends "/".
        return "/"
    }

    public func getQuery() -> String {
        return request.url.query ?? ""
    }

    public func getQueryParam(name: String) -> String? {
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        let values = queryItems.filter { $0.name == name }.compactMap { $0.value }
        if values.count > 1 {
            return nil
        }
        return values.first
    }

    public func hasField(name: String) -> Bool {
        return request.headers.first(name: name) != nil
    }

    public func getField(name: String) -> String? {
        let values = request.headers[name]
        guard !values.isEmpty else {
            return nil
        }
        return ApproovAsyncHTTPClientComponentProvider.combineFieldValues(fields: values)
    }

    public func hasBody() -> Bool {
        return request.body != nil
    }
}
