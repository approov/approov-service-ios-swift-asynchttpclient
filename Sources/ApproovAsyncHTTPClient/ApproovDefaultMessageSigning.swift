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

import CommonCrypto
import Foundation
import os.log
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

    /**
     * Initializer
     */
    public init() {
        hostFactories = [:]
    }

    public var description: String {
        return "ApproovDefaultMessageSigning"
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

    /**
     * Builds the signature parameters for a given request.
     *
     * - Parameters:
     *   - provider: The component provider for the request.
     *   - changes: The request mutations to apply.
     * - Returns: The generated `SignatureParameters`, or `nil` if no factory is available.
     */
    private func buildSignatureParameters(provider: ApproovAsyncHTTPClientComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters? {
        let factory = hostFactories[provider.getAuthority()] ?? defaultFactory
        return try factory?.buildSignatureParameters(provider: provider, changes: changes)
    }

    /**
     * Processes a request to add message signature headers.
     *
     * - Parameters:
     *   - request: The original HTTP request.
     *   - changes: The request mutations that were applied by the Approov interceptor.
     * - Returns: The processed HTTP request with the signature headers added.
     * - Throws: An `ApproovError` if an error occurs during processing.
     */
    public func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                                   changes: ApproovRequestMutations) throws -> ApproovRequest {
        return try processedRequest(request, changes: changes)
    }

    /**
     * Helper to process the request signature changes.
     */
    public func processedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
        // If the request doesn't have an Approov token, we don't need to sign it
        if request.headers.first(name: ApproovService.getApproovTokenHeader()) != nil {
            // Generate and add a message signature
            let provider = ApproovAsyncHTTPClientComponentProvider(request: request)
            guard let params = try buildSignatureParameters(provider: provider, changes: changes) else {
                // No signature to be added; proceed with the original request
                return request
            }

            // Build the signature base
            let baseBuilder = SignatureBaseBuilder(sigParams: params, ctx: provider)
            let message = try baseBuilder.createSignatureBase()
            // WARNING never log the message as it contains an Approov token which provides access to your API.

            // Generate the signature
            let sigId: String
            let signature: Data
            switch params.getAlg() {
            case ApproovDefaultMessageSigning.ALG_ES256:
                sigId = "install"
                guard let base64Signature = ApproovService.getInstallMessageSignature(message: message),
                      let decodedSignature = Data(base64Encoded: base64Signature) else {
                    if ApproovService.loggingLevel >= .error {
                        os_log("ApproovService: install message signature unavailable, skipping signing", type: .error)
                    }
                    return provider.getRequest()
                }
                // decode the signature from ASN.1 DER format
                signature = try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(decodedSignature)
            case ApproovDefaultMessageSigning.ALG_HS256:
                sigId = "account"
                guard let base64Signature = ApproovService.getAccountMessageSignature(message: message),
                      let decodedSignature = Data(base64Encoded: base64Signature) else {
                    if ApproovService.loggingLevel >= .error {
                        os_log("ApproovService: account message signature unavailable, skipping signing", type: .error)
                    }
                    return provider.getRequest()
                }
                signature = decodedSignature
            default:
                throw ApproovError.permanentError(message: "Unsupported algorithm identifier: \(params.getAlg() ?? "unknown")")
            }

            // Create signature headers
            guard let sigHeader = try SFV.serializeDictionary(key: sigId, data: signature) else {
                throw ApproovError.permanentError(message: "Failed to serialize signature header")
            }
            guard let sigInputHeader = try SFV.serializeDictionary(key: sigId, innerList: params.toComponentValue()) else {
                throw ApproovError.permanentError(message: "Failed to serialize signature input header")
            }

            // Add headers to the request
            var signedRequest = provider.getRequest()
            signedRequest.headers.add(name: "Signature", value: sigHeader)
            signedRequest.headers.add(name: "Signature-Input", value: sigInputHeader)

            if params.isDebugMode() {
                let digest = ApproovDefaultMessageSigning.sha256(data: Data(message.utf8))
                if let sigBaseDigestHeader = try SFV.serializeDictionary(key: "sha-256", data: digest) {
                    signedRequest.headers.add(name: "Signature-Base-Digest", value: sigBaseDigestHeader)
                } else {
                    if ApproovService.loggingLevel >= .debug {
                        os_log("ApproovService: Failed to get digest algorithm - no debug entry", type: .debug)
                    }
                }
            }

            return signedRequest
        }

        return request
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
            if ApproovService.loggingLevel >= .error {
                os_log("ApproovDefaultMessageSigning - generateDefaultSignatureParametersFactory: Failed to set default body digest algorithm", type: .error)
            }
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

    @discardableResult
    public func setUseInstallMessageSigning() -> SignatureParametersFactory {
        self.useAccountMessageSigning = false
        return self
    }

    @discardableResult
    public func setUseAccountMessageSigning() -> SignatureParametersFactory {
        self.useAccountMessageSigning = true
        return self
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
        requestParameters.setAlg(useAccountMessageSigning ? ApproovDefaultMessageSigning.ALG_HS256 : ApproovDefaultMessageSigning.ALG_ES256)

        if addCreated || expiresLifetime > 0 {
            let currentTime = Int64(Date().timeIntervalSince1970)
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
                throw ApproovError.permanentError(message: "Failed to create required body digest")
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
            request.headers.add(name: "Content-Digest", value: digestHeader)
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
        return request.url.host ?? ""
    }

    public func getScheme() -> String {
        return request.url.scheme ?? "http"
    }

    public func getTargetUri() -> String {
        return request.url.absoluteString
    }

    public func getRequestTarget() -> String {
        var target = getPath()
        if let query = request.url.query {
            target += "?\(query)"
        }
        return target
    }

    public func getPath() -> String {
        return request.url.path
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
