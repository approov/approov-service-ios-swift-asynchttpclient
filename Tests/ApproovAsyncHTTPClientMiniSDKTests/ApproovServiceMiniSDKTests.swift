import XCTest
import Foundation
import NIOHTTP1
import NIOCore
import AsyncHTTPClient
import NIOSSL
@testable import ApproovAsyncHTTPClient
import Approov
import MiniSDKTestSupport
import CryptoKit
import NIOEmbedded

/// Integration tests for the ApproovService AsyncHTTPClient service layer.
final class ApproovServiceMiniSDKTests: XCTestCase {
    private let validInitialConfig = "#cb-ivol#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="

    override func setUpWithError() throws {
        try super.setUpWithError()
        MiniSDKAttesterProxyController.reset()
        ApproovService.resetForTesting()
        ApproovService.loggingLevel = .off
        try initializeService(comment: "reinit-asynchttpclient-tests")
    }

    override func tearDown() {
        ApproovService.setServiceMutator(nil)
        MiniSDKAttesterProxyController.reset()
        ApproovService.resetForTesting()
        super.tearDown()
    }

    // MARK: - §1 Initialization

    func testInitializeIgnoresSameConfigAndRejectsDifferentConfig() throws {
        XCTAssertNoThrow(try ApproovService.initialize(config: validInitialConfig, comment: nil))

        let differentConfig = "#cb-other#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="
        XCTAssertThrowsError(try ApproovService.initialize(config: differentConfig, comment: nil)) { error in
            guard case let ApproovError.initializationFailure(message) = error else {
                return XCTFail("Expected initializationFailure, got \(error)")
            }
            XCTAssertTrue(message.contains("Approov SDK already initialized with a different configuration"),
                          "Unexpected message: \(message)")
        }
    }

    func testInitializeWithEmptyConfigForwardsPlainRequests() throws {
        MiniSDKAttesterProxyController.reset()
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON(caseName: uniqueCaseName(prefix: "target-host"), body: domainsJSON))
        ApproovService.resetForTesting()
        ApproovService.loggingLevel = .off
        try ApproovService.initialize(config: "", comment: "reinit-empty-config")

        XCTAssertTrue(ApproovService.isInitialized())

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let reply = fetchNetworkReply(for: request)

        XCTAssertNotNil(reply)
        XCTAssertNil(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertNil(getHeader(from: reply, key: "Approov-TraceID"))
    }

    func testInitializeWithEmptyConfigCanLaterEnableApproov() throws {
        MiniSDKAttesterProxyController.reset()
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON(caseName: uniqueCaseName(prefix: "target-host"), body: domainsJSON))
        ApproovService.resetForTesting()
        ApproovService.loggingLevel = .off
        try ApproovService.initialize(config: "", comment: "reinit-empty-config")

        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertFalse(ApproovService.isApproovEnabled())

        let plainRequest = try HTTPClient.Request(url: targetURLString, method: .GET)
        let plainReply = fetchNetworkReply(for: plainRequest)
        XCTAssertNotNil(plainReply)
        XCTAssertNil(getHeader(from: plainReply, key: "Approov-Token"))
        XCTAssertNil(getHeader(from: plainReply, key: "Approov-TraceID"))

        try ApproovService.initialize(config: validInitialConfig, comment: nil)

        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled())

        let protectedRequest = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: protectedRequest)
        XCTAssertNotNil(protectedReply)
        XCTAssertNotNil(getHeader(from: protectedReply, key: "Approov-Token"))
    }

    func testInitializeSucceedsWhenNativeSdkAlreadyInitializedWithSameConfig() throws {
        ApproovService.resetForTesting()

        XCTAssertNoThrow(try ApproovService.initialize(config: validInitialConfig, comment: nil))
        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled())
    }

    func testInitializeRejectsWhenNativeSdkAlreadyInitializedWithDifferentConfig() throws {
        ApproovService.resetForTesting()
        let differentConfig = "#cb-other#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="

        XCTAssertThrowsError(try ApproovService.initialize(config: differentConfig, comment: nil)) { error in
            guard case let ApproovError.initializationFailure(message) = error else {
                return XCTFail("Expected initializationFailure, got \(error)")
            }
            XCTAssertEqual(message, "Error initializing Approov SDK: Approov SDK already initialized with a different configuration")
        }

        XCTAssertFalse(ApproovService.isInitialized())
        XCTAssertFalse(ApproovService.isApproovEnabled())
    }

    // MARK: - §2 Request Processing & Token Behaviors

    func testPrecheckTreatsUnknownKeyAsSuccess() throws {
        XCTAssertNoThrow(try ApproovService.precheck())
    }

    func testGetDeviceIDReturnsMiniSDKDeviceID() {
        XCTAssertEqual(ApproovService.getDeviceID(), "daIvmEWBA2gvZny7a/RC/w==")
    }

    func testUpdateRequestAddsTokenTraceBindingHashAndSubstitutions() throws {
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "substitutions"),
                body: """
                "protectedDomains": ["\(targetHost)"],
                "initialSecureStrings": {
                  "header-key": "header-secret",
                  "query-key": "query-secret"
                }
                """
            ),
            comment: "reinit-substitutions"
        )

        ApproovService.bindHeader = "Authorization"
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
        ApproovService.addSubstitutionQueryParam(key: "api_key")

        var request = try HTTPClient.Request(url: "\(targetURLString)?api_key=query-key", method: .GET)
        request.headers.add(name: "Authorization", value: "Bearer oauth-token")
        request.headers.add(name: "Api-Key", value: "header-key")

        let reply = fetchNetworkReply(for: request)

        let token = try XCTUnwrap(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertFalse(token.isEmpty)
        XCTAssertNotNil(getHeader(from: reply, key: "Approov-TraceID"))
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "header-secret")

        let urlFromReply = try XCTUnwrap(reply?["url"] as? String)
        XCTAssertTrue(urlFromReply.contains("api_key=query-secret"))

        let payload = try XCTUnwrap(decodeJWTBody(token))
        XCTAssertEqual(payload["pay"] as? String, sha256Base64("Bearer oauth-token"))
    }

    func testFetchTokenReturnsSignedTokenWithExpectedClaims() throws {
        try reinitializeServiceWithTargetHost()
        let token = try ApproovService.fetchToken(url: targetURLString)
        let payload = try XCTUnwrap(decodeJWTBody(token))

        XCTAssertEqual(payload["ip"] as? String, "81.149.55.236")
        XCTAssertEqual(payload["did"] as? String, "daIvmEWBA2gvZny7a/RC/w==")
        XCTAssertEqual(payload["mskid"] as? String, "j3AWy6")
        XCTAssertEqual(payload["arc"] as? String, "IXPSB7TRK26LXE3M")
        XCTAssertNotNil(payload["exp"] as? NSNumber)
    }

    func testFetchTokenWrapsNonApproovMutatorErrorAsApproovError() throws {
        // A custom mutator may throw an arbitrary Error; the public fetchToken contract documents
        // ApproovError, so such errors must be wrapped rather than escaping as a foreign type.
        struct CustomMutatorError: Error {}
        struct ThrowingMutator: ApproovServiceMutator {
            func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws {
                throw CustomMutatorError()
            }
        }
        try reinitializeServiceWithTargetHost()
        ApproovService.setServiceMutator(ThrowingMutator())

        XCTAssertThrowsError(try ApproovService.fetchToken(url: targetURLString)) { error in
            guard case ApproovError.permanentError = error else {
                XCTFail("Expected ApproovError.permanentError, got \(type(of: error)): \(error)")
                return
            }
        }
    }

    func testUpdateRequestNoApproovServiceProceedsWithoutToken() throws {
        try reinitializeServiceWithTargetHost()
        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "NO_APPROOV_SERVICE"
              }
            }
            """
        )

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let reply = fetchNetworkReply(for: request)

        XCTAssertNotNil(reply, "Expected to receive a reply from worker when proceeding without token")
        XCTAssertNil(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertNil(getHeader(from: reply, key: "Approov-TraceID"))
    }

    func testUpdateRequestCanIgnoreExcludedURL() throws {
        let exclusionStr = "^.*excluded.*$"
        ApproovService.addExclusionURLRegex(urlRegex: exclusionStr)

        let request = try HTTPClient.Request(url: "\(targetURLString)/excluded", method: .GET)
        let reply = fetchNetworkReply(for: request)

        XCTAssertNotNil(reply, "Expected to receive a reply even for ignored domains")
        XCTAssertNil(getHeader(from: reply, key: "Approov-Token"))
    }

    func testFetchTokenThrowsNetworkingErrorForNoNetwork() throws {
        try reinitializeServiceWithTargetHost()
        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "NO_NETWORK"
              }
            }
            """
        )

        XCTAssertThrowsError(try ApproovService.fetchToken(url: targetURLString)) { error in
            guard case let ApproovError.networkingError(message) = error else {
                return XCTFail("Expected networkingError, got \(error)")
            }
            XCTAssertEqual(message, "fetchToken network error: no network")
        }
    }

    func testExecuteRequestSendsMutatedRequest() throws {
        try reinitializeServiceWithTargetHost()
        
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        
        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let response = try client.execute(request: request).wait()
        
        XCTAssertEqual(response.status, .ok)
        
        if let body = response.body {
            let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(getHeader(from: reply, key: "Approov-Token"))
            XCTAssertNotNil(getHeader(from: reply, key: "Approov-TraceID"))
        } else {
            XCTFail("Expected response body")
        }
    }

    func testExecuteAsyncRequestSendsMutatedRequest() async throws {
        try reinitializeServiceWithTargetHost()
        
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        
        var request = HTTPClientRequest(url: targetURLString)
        request.method = .GET
        let response = try await client.execute(request, timeout: .seconds(5))
        
        XCTAssertEqual(response.status, .ok)
        
        let buffer = try await response.body.collect(upTo: 1024 * 1024)
        let data = Data(buffer: buffer)
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertNotNil(getHeader(from: reply, key: "Approov-TraceID"))
    }

    func testSignRequestAddsTokenSubstitutionsBindingHashAndSignatureHeaders() throws {
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "sign-request"),
                body: """
                "protectedDomains": ["\(targetHost)"],
                "initialSecureStrings": {
                  "header-key": "header-secret",
                  "query-key": "query-secret"
                }
                """
            ),
            comment: "reinit-sign-request"
        )

        ApproovService.bindHeader = "Authorization"
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
        ApproovService.addSubstitutionQueryParam(key: "api_key")
        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseAccountMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        var request = try HTTPClient.Request(url: "\(targetURLString)?api_key=query-key", method: .GET)
        request.headers.add(name: "Authorization", value: "Bearer oauth-token")
        request.headers.add(name: "Api-Key", value: "header-key")

        let signedRequest = try ApproovService.signRequest(request)

        XCTAssertTrue(signedRequest.url.absoluteString.contains("api_key=query-secret"))
        XCTAssertEqual(signedRequest.headers.first(name: "Authorization"), "Bearer oauth-token")
        XCTAssertEqual(signedRequest.headers.first(name: "Api-Key"), "header-secret")
        let token = try XCTUnwrap(signedRequest.headers.first(name: "Approov-Token"))
        XCTAssertFalse(token.isEmpty)
        XCTAssertNotNil(signedRequest.headers.first(name: "Approov-TraceID"))
        XCTAssertTrue(try XCTUnwrap(signedRequest.headers.first(name: "Signature-Input")).hasPrefix("account="))
        XCTAssertTrue(try XCTUnwrap(signedRequest.headers.first(name: "Signature")).hasPrefix("account="))

        let payload = try XCTUnwrap(decodeJWTBody(token))
        XCTAssertEqual(payload["pay"] as? String, sha256Base64("Bearer oauth-token"))

        let reply = fetchPlainNetworkReply(for: signedRequest)
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "header-secret")
        XCTAssertNotNil(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertNotNil(getHeader(from: reply, key: "Signature"))
        let urlFromReply = try XCTUnwrap(reply?["url"] as? String)
        XCTAssertTrue(urlFromReply.contains("api_key=query-secret"))
    }

    func testSignRequestReturnsOriginalRequestForIgnoredURL() throws {
        try reinitializeServiceWithTargetHost()

        var request = try HTTPClient.Request(url: unprotectedURLString, method: .GET)
        request.headers.add(name: "X-Test", value: "original")

        let signedRequest = try ApproovService.signRequest(request)

        XCTAssertEqual(signedRequest.url, request.url)
        XCTAssertEqual(signedRequest.headers.first(name: "X-Test"), "original")
        XCTAssertNil(signedRequest.headers.first(name: "Approov-Token"))
        XCTAssertNil(signedRequest.headers.first(name: "Approov-TraceID"))
    }

    func testSignRequestThrowsNetworkingErrorForRetryDecision() throws {
        try reinitializeServiceWithTargetHost()
        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "NO_NETWORK"
              }
            }
            """
        )

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)

        XCTAssertThrowsError(try ApproovService.signRequest(request)) { error in
            guard case let ApproovError.networkingError(message) = error else {
                return XCTFail("Expected networkingError, got \(error)")
            }
            XCTAssertTrue(message.contains("no network"), "Unexpected message: \(message)")
        }
    }

    func testSignRequestThrowsPermanentErrorForFailDecision() throws {
        try reinitializeServiceWithTargetHost()
        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "REJECTED"
              }
            }
            """
        )

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)

        XCTAssertThrowsError(try ApproovService.signRequest(request)) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertTrue(message.contains("rejected"), "Unexpected message: \(message)")
        }
    }

    // MARK: - §3 Service Mutators & Decision Overrides

    struct AlwaysProceedMutator: ApproovServiceMutator {
        func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
            return false // proceed without throwing
        }
    }

    func testServiceMutatorOverridesFailClosedBehavior() throws {
        try reinitializeServiceWithTargetHost()

        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "MITM_DETECTED"
              }
            }
            """
        )

        ApproovService.setServiceMutator(AlwaysProceedMutator())

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let reply = fetchNetworkReply(for: request)

        XCTAssertNotNil(reply, "Expected to receive a reply from worker when proceeding due to overridden mutator")
        XCTAssertNil(getHeader(from: reply, key: "Approov-Token"))
    }

    // MARK: - §4 Pinning Configuration & Scenarios

    func testPinningAcceptAny() throws {
        try reinitializeServiceWithTargetHost()

        MiniSDKAttesterProxyController.setNextPinningDirectiveJSON("{\"operation\": \"getPins\", \"acceptAny\": true}")

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let reply = fetchNetworkReply(for: request)

        XCTAssertNotNil(reply, "Expected the request to succeed when acceptAny is used")
    }

    func testPinningFailureTriggersPinningError() throws {
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": {
              "public-key-sha256": {
                "*": ["invalid-pin-base64="],
                "\(targetHost)": ["invalid-pin-base64="]
              }
            }
            """)

        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            // Should fail with standard NIO-SSL connection aborted or TLS pinning verification failure
            XCTAssertNotNil(error)
        }
    }

    // MARK: - §5 Message Signing

    func testUpdateRequestInstallMessageSigningAddsSignatureHeaders() throws {
        try reinitializeServiceWithTargetHost()

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseInstallMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: request)

        XCTAssertNotNil(getHeader(from: protectedReply, key: "Approov-Token"))
        let signatureInput = try XCTUnwrap(getHeader(from: protectedReply, key: "Signature-Input"))
        XCTAssertTrue(signatureInput.hasPrefix("install="))
        XCTAssertEqual(signatureInput.components(separatedBy: "install=").count, 2)
        XCTAssertFalse(signatureInput.contains("account="))

        let signature = try XCTUnwrap(getHeader(from: protectedReply, key: "Signature"))
        XCTAssertTrue(signature.hasPrefix("install="))
        XCTAssertEqual(signature.components(separatedBy: "install=").count, 2)
        XCTAssertFalse(signature.contains("account="))

        let unprotectedRequest = try HTTPClient.Request(url: unprotectedURLString, method: .GET)
        let unprotectedReply = fetchNetworkReply(for: unprotectedRequest)

        XCTAssertNil(getHeader(from: unprotectedReply, key: "Approov-Token"))
        XCTAssertNil(getHeader(from: unprotectedReply, key: "Signature"))
        XCTAssertNil(getHeader(from: unprotectedReply, key: "Signature-Input"))
    }

    func testUpdateRequestAccountMessageSigningAddsSignatureHeaders() throws {
        try reinitializeServiceWithTargetHost()

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseAccountMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: request)

        XCTAssertNotNil(getHeader(from: protectedReply, key: "Approov-Token"))
        let signatureInput = try XCTUnwrap(getHeader(from: protectedReply, key: "Signature-Input"))
        XCTAssertTrue(signatureInput.hasPrefix("account="))
        XCTAssertEqual(signatureInput.components(separatedBy: "account=").count, 2)
        XCTAssertFalse(signatureInput.contains("install="))

        let signature = try XCTUnwrap(getHeader(from: protectedReply, key: "Signature"))
        XCTAssertTrue(signature.hasPrefix("account="))
        XCTAssertEqual(signature.components(separatedBy: "account=").count, 2)
        XCTAssertFalse(signature.contains("install="))
    }

    func testInstallMessageSigningFailsGracefullyIfKeyGenerationFails() throws {
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "no-install-key"),
                body: domainsJSON
            ),
            comment: "options:no-install-key"
        )

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseInstallMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: request)

        XCTAssertNotNil(getHeader(from: protectedReply, key: "Approov-Token"))
        XCTAssertNil(getHeader(from: protectedReply, key: "Signature"))
        XCTAssertNil(getHeader(from: protectedReply, key: "Signature-Input"))
    }

    func testDigestBodyAppendedForPOSTPUTPATCHRequests() throws {
        try reinitializeServiceWithTargetHost()

        let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseInstallMessageSigning()
            .setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: true)
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        for method in ["POST", "PUT", "PATCH"] {
            var request = try HTTPClient.Request(url: targetURLString, method: HTTPMethod(rawValue: method))
            request.body = .byteBuffer(ByteBuffer(string: "{\"test\": 1}"))
            request.headers.add(name: "Content-Type", value: "application/json")

            let protectedReply = fetchNetworkReply(for: request)

            XCTAssertNotNil(getHeader(from: protectedReply, key: "Approov-Token"))
            let signatureInput = try XCTUnwrap(getHeader(from: protectedReply, key: "Signature-Input"), "Failed on \(method)")
            XCTAssertTrue(signatureInput.contains("content-digest"), "Signature-Input should include content-digest for \(method)")
            XCTAssertNotNil(getHeader(from: protectedReply, key: "Content-Digest"), "Content-Digest should be generated for \(method)")
        }
    }

    func testExtractBodyDataBuffersInMemoryBody() {
        // An in-memory byteBuffer body completes synchronously and must be buffered in full.
        let body = HTTPClient.Body.byteBuffer(ByteBuffer(string: "hello-body"))
        XCTAssertEqual(ApproovService.extractBodyData(from: body), Data("hello-body".utf8))
    }

    func testExtractBodyDataAccumulatesMultipleChunks() {
        // A repeatable, known-length body that emits several chunks must be accumulated in full,
        // not reduced to only the final chunk (the previous getHTTPBody overwrite bug).
        let body = HTTPClient.Body.stream(length: 6) { writer in
            _ = writer.write(.byteBuffer(ByteBuffer(string: "abc")))
            return writer.write(.byteBuffer(ByteBuffer(string: "def")))
        }
        XCTAssertEqual(ApproovService.extractBodyData(from: body), Data("abcdef".utf8))
    }

    func testExtractBodyDataSkipsOneShotStreamingBody() {
        // A chunked streaming body (nil length) is treated as one-shot and must be skipped (nil)
        // rather than consumed or partially digested.
        let body = HTTPClient.Body.stream(length: nil) { writer in
            writer.write(.byteBuffer(ByteBuffer(string: "streamed")))
        }
        XCTAssertNil(ApproovService.extractBodyData(from: body))
    }

    func testExtractBodyDataReturnsNilForNoBody() {
        XCTAssertNil(ApproovService.extractBodyData(from: nil))
    }

    func testBodyDigestEnabledAddsContentDigestComponent() throws {
        // Positive control: the default factory's SHA-256 digest adds a content-digest component.
        let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: false)
        let request = ApproovRequest(url: URL(string: "https://example.com/path")!,
                                     method: "POST",
                                     headers: HTTPHeaders(),
                                     body: Data("{\"test\": 1}".utf8))
        let provider = ApproovAsyncHTTPClientComponentProvider(request: request)
        let params = try factory.buildSignatureParameters(provider: provider, changes: ApproovRequestMutations())
        XCTAssertTrue(params.containsComponentIdentifier("content-digest"),
                      "content-digest component should be present when body digest is enabled")
    }

    func testBodyDigestDisabledViaNilAlgorithmOmitsContentDigest() throws {
        // The default factory enables SHA-256 body digest; disabling it with a nil algorithm must
        // prevent any content-digest component from being added to the signature parameters.
        let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setBodyDigestConfig(nil, required: false)
        let request = ApproovRequest(url: URL(string: "https://example.com/path")!,
                                     method: "POST",
                                     headers: HTTPHeaders(),
                                     body: Data("{\"test\": 1}".utf8))
        let provider = ApproovAsyncHTTPClientComponentProvider(request: request)
        let params = try factory.buildSignatureParameters(provider: provider, changes: ApproovRequestMutations())
        XCTAssertFalse(params.containsComponentIdentifier("content-digest"),
                       "content-digest component must be absent once body digest is disabled")
    }

    // MARK: - §6 Secure Strings & Custom JWT

    func testFetchSecureStringReturnsConfiguredValue() throws {
        setDirective(
            """
            {
              "operation": "fetchSecureString",
              "response": {
                "status": "SUCCESS",
                "secureString": "mini-secret"
              }
            }
            """
        )

        let secureString = try ApproovService.fetchSecureString(key: "api-key", newDef: nil)
        XCTAssertEqual(secureString, "mini-secret")
    }

    func testFetchSecureStringReturnsNilForUnknownKey() throws {
        setDirective(
            """
            {
              "operation": "fetchSecureString",
              "response": {
                "status": "UNKNOWN_KEY"
              }
            }
            """
        )

        let secureString = try ApproovService.fetchSecureString(key: "missing-key", newDef: nil)
        XCTAssertNil(secureString)
    }

    func testFetchSecureStringEmptyKeyRaisesPermanentError() throws {
        XCTAssertThrowsError(try ApproovService.fetchSecureString(key: "", newDef: nil)) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertTrue(message.contains("bad key"), "Expected bad key message")
        }
    }

    func testFetchCustomJWTReturnsSignedJWT() throws {
        let jwt = try XCTUnwrap(ApproovService.fetchCustomJWT(payload: "{\"role\":\"tester\"}"))
        let payload = try XCTUnwrap(decodeJWTBody(jwt))

        XCTAssertEqual(payload["role"] as? String, "tester")
        XCTAssertNil(payload["exp"])
        XCTAssertNil(payload["did"])
    }

    struct CustomPayload: Codable {
        let data: String
    }

    func testFetchCustomJWT18KBPayload() throws {
        let largePayload = String(repeating: "A", count: 18 * 1024)
        let payloadStruct = CustomPayload(data: largePayload)

        let jsonData = try JSONEncoder().encode(payloadStruct)
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))

        let jwt = try XCTUnwrap(ApproovService.fetchCustomJWT(payload: json))
        let payloadMap = try XCTUnwrap(decodeJWTBody(jwt))
        XCTAssertEqual(payloadMap["data"] as? String, largePayload)
    }

    func testFetchCustomJWTDisabledRaisesPermanentError() throws {
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "custom-jwt-disabled"),
                body: """
                "customJWTEnabled": false
                """
            ),
            comment: "reinit-custom-jwt-disabled"
        )

        XCTAssertThrowsError(try ApproovService.fetchCustomJWT(payload: "{\"role\":\"tester\"}")) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertEqual(message, "fetchCustomJWT: disabled")
        }
    }

    func testFetchCustomJWTBadPayloadRaisesPermanentError() {
        XCTAssertThrowsError(try ApproovService.fetchCustomJWT(payload: "not-json")) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertEqual(message, "fetchCustomJWT: bad payload")
        }
    }

    // MARK: - §7 Failure Caching

    func testCachedFailureShortCircuitsSDKFetchWithinTTL() throws {
        try reinitializeServiceWithTargetHost()

        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "NO_NETWORK"
              }
            }
            """
        )

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let appReq = ApproovRequest(url: request.url, method: request.method.rawValue, headers: request.headers, body: nil)
        let response1 = ApproovService.updateRequestWithApproov(request: appReq)
        XCTAssertEqual(response1.decision, .ShouldRetry)
        XCTAssertEqual(response1.sdkMessage, "no network")

        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "SUCCESS",
                "token": "fresh-token-that-should-be-ignored"
              }
            }
            """
        )

        let response2 = ApproovService.updateRequestWithApproov(request: appReq)
        XCTAssertEqual(response2.decision, .ShouldRetry)
        XCTAssertEqual(response2.sdkMessage, "no network")
    }

    func testCachedFailureShortCircuitsConcurrentRequestsWithinTTL() throws {
        try reinitializeServiceWithTargetHost()

        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "NO_NETWORK"
              }
            }
            """
        )

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let appReq = ApproovRequest(url: request.url, method: request.method.rawValue, headers: request.headers, body: nil)
        let requestCount = 24
        let startGate = DispatchSemaphore(value: 0)
        let completionGroup = DispatchGroup()
        let responsesLock = NSLock()
        var responses: [ApproovUpdateResponse] = []

        for _ in 0..<requestCount {
            completionGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                startGate.wait()
                let response = ApproovService.updateRequestWithApproov(request: appReq)
                responsesLock.lock()
                responses.append(response)
                responsesLock.unlock()
                completionGroup.leave()
            }
        }

        for _ in 0..<requestCount {
            startGate.signal()
        }

        switch completionGroup.wait(timeout: .now() + 5.0) {
        case .success:
            break
        case .timedOut:
            XCTFail("Timed out waiting for concurrent cached-failure requests")
            return
        }

        XCTAssertEqual(responses.count, requestCount)
        for response in responses {
            XCTAssertEqual(response.decision, .ShouldRetry)
            XCTAssertEqual(response.sdkMessage, "no network")
        }
    }

    func testCachedFailureExpiresAfterTTL() throws {
        try reinitializeServiceWithTargetHost()

        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "NO_NETWORK"
              }
            }
            """
        )

        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let appReq = ApproovRequest(url: request.url, method: request.method.rawValue, headers: request.headers, body: nil)
        let response1 = ApproovService.updateRequestWithApproov(request: appReq)
        XCTAssertEqual(response1.decision, .ShouldRetry)
        XCTAssertEqual(response1.sdkMessage, "no network")

        setDirective(
            """
            {
              "operation": "fetchApproovToken",
              "response": {
                "status": "SUCCESS",
                "token": "fresh-token-after-ttl"
              }
            }
            """
        )

        Thread.sleep(forTimeInterval: 1.0)

        let response2 = ApproovService.updateRequestWithApproov(request: appReq)
        XCTAssertEqual(response2.decision, .ShouldProceed)
        XCTAssertEqual(response2.sdkMessage, "success")
    }

    func testInitializeWithEmptyConfigAfterValidConfigIsIgnored() throws {
        // Initialized with valid config
        try reinitializeServiceWithTargetHost()
        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled())
        
        // Attempting initialize with empty config should be ignored
        try ApproovService.initialize(config: "")
        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled()) // Remains enabled
    }

    func testRepeatedReinitAndOptionsCommentBehavior() throws {
        try reinitializeServiceWithTargetHost()
        
        // Initial setup with options: comment
        try ApproovService.initialize(config: validInitialConfig, comment: "options:test-option")
        XCTAssertTrue(ApproovService.isInitialized())
        
        // Repeated setup with reinit... comment should be forwarded and succeed
        try ApproovService.initialize(config: validInitialConfig, comment: "reinit-options")
        XCTAssertTrue(ApproovService.isInitialized())
    }

    func testStatePreservationAfterFailedDifferentConfigInit() throws {
        try reinitializeServiceWithTargetHost()
        
        // Attempting initialize with a different non-empty config should throw and preserve state
        XCTAssertThrowsError(try ApproovService.initialize(config: "different-config-string", comment: "reinit")) { error in
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled())
    }

    func testCustomTokenAndTraceHeaderNamesAndPrefixes() throws {
        try reinitializeServiceWithTargetHost()
        
        ApproovService.approovTokenHeaderAndPrefix = (approovTokenHeader: "Custom-Token", approovTokenPrefix: "CustomPrefix ")
        ApproovService.setApproovTraceIDHeader(header: "Custom-TraceID")
        
        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: request)
        
        XCTAssertNotNil(protectedReply, "Expected request to succeed")
        let customToken = getHeader(from: protectedReply, key: "Custom-Token")
        XCTAssertNotNil(customToken)
        XCTAssertTrue(customToken?.hasPrefix("CustomPrefix ") ?? false)
        XCTAssertNotNil(getHeader(from: protectedReply, key: "Custom-TraceID"))
        
        // Test null/nil prefix treated as empty string
        ApproovService.approovTokenHeaderAndPrefix = (approovTokenHeader: "Custom-Token", approovTokenPrefix: "")
        let reply2 = fetchNetworkReply(for: request)
        let customToken2 = getHeader(from: reply2, key: "Custom-Token")
        XCTAssertFalse(customToken2?.hasPrefix("null") ?? true)
    }

    func testMissingAndEmptyTokenAndTraceArtifacts() throws {
        try reinitializeServiceWithTargetHost()
        
        class FallbackMutator: ApproovServiceMutator {
            func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool { return true }
            func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool { return true }
            func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult, header: String) throws -> Bool { return true }
            func handleInterceptorQueryParamSubstitutionResult(_ approovResults: ApproovTokenFetchResult, queryKey: String) throws -> Bool { return true }
            func handleInterceptorProcessedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest { return request }
            func handlePinningShouldProcessRequest(hostname: String) -> Bool { return true }
        }
        ApproovService.setServiceMutator(FallbackMutator())
        
        // Set next attestation directive to yield empty token/trace with status REJECTED (so they are not overwritten)
        MiniSDKAttesterProxyController.setNextAttestationDirectiveJSON("{\"response\": {\"status\": \"REJECTED\", \"token\": \"\", \"traceID\": \"\"}}")
        
        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: request)
        
        // Emitted headers should be empty rather than omitted
        let token = getHeader(from: protectedReply, key: "Approov-Token")
        let trace = getHeader(from: protectedReply, key: "Approov-TraceID")
        XCTAssertEqual(token, "")
        XCTAssertEqual(trace, "")
    }

    func testSubstitutionRemoval() throws {
        try reinitializeServiceWithTargetHost()
        
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: "Bearer ")
        ApproovService.removeSubstitutionHeader(header: "Api-Key")
        
        var request = try HTTPClient.Request(url: targetURLString, method: .GET)
        request.headers.add(name: "Api-Key", value: "Bearer placeholder-key")
        
        let reply = fetchNetworkReply(for: request)
        // Original placeholder should remain since substitution was removed
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "Bearer placeholder-key")
    }

    func testEmptySubstitutionValues() throws {
        try reinitializeServiceWithTargetHost()
        
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: "")
        
        // Load scenario where key lookup yields empty secure string
        MiniSDKAttesterProxyController.setNextAttestationDirectiveJSON("{\"status\": \"SUCCESS\", \"secureString\": \"\"}")
        
        var request = try HTTPClient.Request(url: targetURLString, method: .GET)
        request.headers.add(name: "Api-Key", value: "placeholder-key")
        
        let reply = fetchNetworkReply(for: request)
        // Original placeholder should remain intact if lookup is empty
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "placeholder-key")
    }

    func testUnprotectedExcludedPinningBehavior() throws {
        try reinitializeServiceWithTargetHost()
        
        // Add exclusion for matching endpoint
        ApproovService.addExclusionURLRegex(urlRegex: ".*/excluded")
        
        // Verify pinning still active for host even if URL is excluded from token injection
        MiniSDKAttesterProxyController.setNextPinningDirectiveJSON("{\"operation\": \"getPins\", \"shouldFail\": true}")
        
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        let request = try HTTPClient.Request(url: "\(targetURLString)/excluded", method: .GET)
        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            XCTAssertNotNil(error)
        }
    }

    func testAsyncBodyDigestBehavior() async throws {
        try reinitializeServiceWithTargetHost()
        
        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseInstallMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)
        
        var request = HTTPClientRequest(url: targetURLString)
        request.method = .POST
        request.body = .bytes(ByteBuffer(string: "test-async-body"))
        
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        let response = try await client.execute(request, timeout: .seconds(5))
        
        // Consume response
        var body = try await response.body.collect(upTo: 1024 * 1024)
        guard let data = body.readData(length: body.readableBytes),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = obj["headers"] as? [String: Any] else {
            XCTFail("Failed to parse response body")
            return
        }
        
        XCTAssertNotNil(headers["content-digest"])
        XCTAssertNotNil(headers["signature"])
    }

    func testUnsupportedSigningAlgorithms() throws {
        try reinitializeServiceWithTargetHost()
        
        class UnsupportedAlgFactory: SignatureParametersFactory {
            override func buildSignatureParameters(provider: ApproovAsyncHTTPClientComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters {
                let params = try super.buildSignatureParameters(provider: provider, changes: changes)
                params.setAlg("unsupported-alg")
                return params
            }
        }
        
        let factory = UnsupportedAlgFactory()
            .setUseInstallMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)
        
        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            XCTAssertNotNil(error)
        }
    }

    func testASN1DecodeFailures() throws {
        // Test various invalid ASN.1 DER structures directly to verify bounds checking
        let tooShort = Data([0x30])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(tooShort))
        
        let invalidSequenceTag = Data([0x02, 0x01, 0x00])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(invalidSequenceTag))
        
        let invalidSequenceLength = Data([0x30, 0x05, 0x02, 0x01, 0x00])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(invalidSequenceLength))
        
        let truncatedR = Data([0x30, 0x02, 0x02, 0x01])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(truncatedR))
        
        let invalidRTag = Data([0x30, 0x04, 0x03, 0x01, 0x00, 0x02])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(invalidRTag))
        
        let truncatedRValue = Data([0x30, 0x04, 0x02, 0x05, 0x01, 0x02])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(truncatedRValue))
        
        let truncatedS = Data([0x30, 0x06, 0x02, 0x01, 0x00, 0x02, 0x01])
        XCTAssertThrowsError(try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(truncatedS))
    }

    func testMessageSerializationFailures() throws {
        try reinitializeServiceWithTargetHost()

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseInstallMessageSigning()
        // Require a body digest, then provide a one-shot streaming body that the service layer cannot
        // buffer. The required digest must fail closed during request processing.
        _ = try? factory.setBodyDigestConfig("sha-256", required: true)

        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        // A chunked/one-shot streaming body (no declared length) is not buffered by body extraction, so
        // a required Content-Digest cannot be produced and signing must fail closed at request-processing
        // time — before the request is ever sent. The stream closure writes via the provided writer
        // (never returning a future from an undriven EmbeddedEventLoop); here it is not invoked at all
        // because the body is intentionally skipped.
        let requestBody = HTTPClient.Body.stream(length: nil) { writer in
            writer.write(.byteBuffer(ByteBuffer(string: "non-repeat")))
        }

        let request = try HTTPClient.Request(url: targetURLString, method: .POST, body: requestBody)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }

        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            guard case ApproovError.permanentError = error else {
                XCTFail("Expected ApproovError.permanentError for a required digest that cannot be created, got \(error)")
                return
            }
        }
    }

    // MARK: - Test Helpers

    private var targetURLString: String {
        guard let url = ProcessInfo.processInfo.environment["TESTING_REPLY_URL"] else {
            fatalError("TESTING_REPLY_URL environment variable is not set")
        }
        return url
    }

    private var unprotectedURLString: String {
        guard let url = ProcessInfo.processInfo.environment["TESTING_REPLY_URL_UNPROTECTED"] else {
            fatalError("TESTING_REPLY_URL_UNPROTECTED environment variable is not set")
        }
        return url
    }

    private func fetchNetworkReply(for request: HTTPClient.Request) -> [String: Any]? {
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        var receivedData: Data?
        do {
            let response = try client.execute(request: request).wait()
            if let body = response.body {
                receivedData = body.getData(at: 0, length: body.readableBytes)
            }
        } catch {
            print("Request failed with error: \(error)")
        }
        guard let data = receivedData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func fetchPlainNetworkReply(for request: HTTPClient.Request) -> [String: Any]? {
        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try? client.syncShutdown()
        }
        var receivedData: Data?
        do {
            let response = try client.execute(request: request).wait()
            if let body = response.body {
                receivedData = body.getData(at: 0, length: body.readableBytes)
            }
        } catch {
            print("Request failed with error: \(error)")
        }
        guard let data = receivedData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func getHeader(from reply: [String: Any]?, key: String) -> String? {
        guard let headers = reply?["headers"] as? [String: Any] else { return nil }
        let lowerKey = key.lowercased()
        let val = headers[lowerKey] ?? headers[key]
        if let str = val as? String {
            return str
        }
        if let arr = val as? [String], let first = arr.first {
            return first
        }
        return nil
    }

    private func reinitializeServiceWithTargetHost(scenarioBody: String = "") throws {
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        let fullBody = scenarioBody.isEmpty ? domainsJSON : "\(domainsJSON), \(scenarioBody)"

        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "target-host"),
                body: fullBody
            ),
            comment: "reinit-target-host"
        )
    }

    private func initializeService(comment: String?) throws {
        try ApproovService.initialize(config: validInitialConfig, comment: comment)
    }

    private func reinitializeService(scenarioJSON: String? = nil, comment: String) throws {
        MiniSDKAttesterProxyController.reset()
        if let scenarioJSON {
            MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON)
        }
        ApproovService.resetForTesting()
        ApproovService.loggingLevel = .off
        try initializeService(comment: comment)
    }

    private func setDirective(_ json: String) {
        MiniSDKAttesterProxyController.setNextAttestationDirectiveJSON(json)
    }

    private func uniqueCaseName(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private func scenarioJSON(caseName: String, body: String) -> String {
        """
        {
          "activeCase": "\(caseName)",
          "cases": {
            "\(caseName)": {
              \(body)
            }
          }
        }
        """
    }

    private func decodeJWTBody(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        guard let data = base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func base64URLDecode(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded.append(String(repeating: "=", count: (4 - padded.count % 4) % 4))
        return Data(base64Encoded: padded)
    }

    private func sha256Base64(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
}
