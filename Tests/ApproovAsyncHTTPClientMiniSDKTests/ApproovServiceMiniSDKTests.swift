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
import NIOPosix
import NIOConcurrencyHelpers

/// Integration tests for the ApproovService AsyncHTTPClient service layer.
final class ApproovServiceMiniSDKTests: XCTestCase {
    private let validInitialConfig = "#cb-ivol#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="

    override func setUpWithError() throws {
        try super.setUpWithError()
        MiniSDKAttesterProxyController.reset()
        ApproovService.resetForTesting()
        ApproovService.setLoggingLevel(.off)
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
        ApproovService.setLoggingLevel(.off)
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
        ApproovService.setLoggingLevel(.off)
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

    /// Records the Dispatch queue label of the thread that runs the interceptor.
    private final class QueueLabelRecorder: ApproovServiceMutator {
        let label = NIOLockedValueBox<String?>(nil)
        func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool {
            let current = String(cString: __dispatch_queue_get_label(nil))
            label.withLockedValue { $0 = current }
            return true
        }
    }

    func testAsyncExecuteRunsApproovUpdateOffCooperativePool() async throws {
        try reinitializeServiceWithTargetHost()
        let recorder = QueueLabelRecorder()
        ApproovService.setServiceMutator(recorder)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }

        _ = try await client.execute(HTTPClientRequest(url: targetURLString), timeout: .seconds(30))

        let label = try XCTUnwrap(recorder.label.withLockedValue { $0 }, "control: the interceptor ran")
        XCTAssertFalse(label.contains("cooperative"),
                       "The blocking Approov update ran on the Swift concurrency pool: \(label)")
    }

    // T37-26: the mini SDK classifies hosts as the real SDK does.

    func testMiniSDKReportsUnknownURLForHostNotAdded() throws {
        try reinitializeServiceWithTargetHost()
        let result = Approov.fetchTokenAndWait(unprotectedURLString)
        XCTAssertEqual(result.status, .unknownURL)
        XCTAssertEqual(result.token, "")
    }

    func testMiniSDKReportsUnprotectedURLForEmptyToken() throws {
        let host = try XCTUnwrap(URL(string: unprotectedURLString)?.host)
        try reinitializeServiceWithTargetHost(scenarioBody: "\"noApproovTokenDomains\": [\"\(host)\"]")
        let result = Approov.fetchTokenAndWait(unprotectedURLString)
        XCTAssertEqual(result.status, .unprotectedURL)
        XCTAssertEqual(result.token, "")
    }

    func testMiniSDKNeverReportsSuccessWithEmptyToken() throws {
        try reinitializeServiceWithTargetHost()
        let result = Approov.fetchTokenAndWait(targetURLString)
        XCTAssertEqual(result.status, .success)
        XCTAssertFalse(result.token.isEmpty)
    }

    func testGetLastARCMakesNoFetchAndReturnsTheLastFetchARC() throws {
        try reinitializeServiceWithTargetHost()
        XCTAssertEqual(ApproovService.getLastARC(), "", "no fetch since initialization")

        MiniSDKAttesterProxyController.clearCallLog()
        _ = ApproovService.getLastARC()
        XCTAssertEqual(MiniSDKAttesterProxyController.callLog(), [], "getLastARC must not fetch (SPEC 5.3)")

        setDirective("""
            { "operation": "fetchApproovToken", "response": { "status": "REJECTED", "arc": "TESTARC123" } }
            """)
        XCTAssertThrowsError(try ApproovService.fetchToken(url: targetURLString))
        XCTAssertEqual(ApproovService.getLastARC(), "TESTARC123")
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

    func testPinningFailsClosedWhenPinsAreUnavailable() throws {
        try reinitializeServiceWithTargetHost()
        let host = "replay.ivol.workers.dev"
        let chain = [try fixtureCertificate(PinningTestCertificates.replayLeaf),
                     try fixtureCertificate(PinningTestCertificates.replayWE1),
                     try fixtureCertificate(PinningTestCertificates.replayGTSR4)]
        XCTAssertNoThrow(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: chain,
                                                                  verifyDate: pinningFixtureDate),
                         "control: with pins available the chain is checked without an error")

        // SPEC 2.4: a layer that cannot read the pins fails the connection closed.
        MiniSDKAttesterProxyController.setPinsUnavailable(true)
        defer { MiniSDKAttesterProxyController.setPinsUnavailable(false) }
        XCTAssertThrowsError(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: chain,
                                                                      verifyDate: pinningFixtureDate)) { error in
            guard case ApproovError.pinningError = error else {
                return XCTFail("Expected ApproovError.pinningError, got \(error)")
            }
        }
    }

    func testPinningFailureTriggersPinningError() throws {
        let request = try HTTPClient.Request(url: targetURLString, method: .GET)

        // Control: with the default pins, the host is reachable.
        try reinitializeServiceWithTargetHost()
        let controlClient = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? controlClient.syncShutdown() }
        XCTAssertNoThrow(try controlClient.execute(request: request).wait(), "control: the host is reachable")

        // Both entries carry the invalid pin. At initialization the mini SDK empties the pins of the
        // TESTING_REPLY_URL host, so "*" applies. After a token fetch it uses the scenario pins as written,
        // so the host entry applies. A host that is not a key of the pins map is unpinned.
        // A new client makes sure that no pooled connection skips the handshake.
        let targetHost = try XCTUnwrap(URL(string: targetURLString)?.host)
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "*": ["invalid-pin-base64="], "\(targetHost)": ["invalid-pin-base64="] } }
            """)
        let pinnedClient = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? pinnedClient.syncShutdown() }
        // AsyncHTTPClient 1.10.2 reports the pin rejection as HTTPClientError.connectTimeout after 30 s.
        XCTAssertThrowsError(try pinnedClient.execute(request: request).wait())
    }

    // Trust evaluation date for the recorded certificates (2026-11-19T00:00:00Z).
    private let pinningFixtureDate = Date(timeIntervalSince1970: 1_795_046_400)

    private func fixtureCertificate(_ base64: String) throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    private func spkiPin(_ certificate: SecCertificate) throws -> String {
        let spki = try XCTUnwrap(ApproovPinningVerifier.publicKeyInfoOfCertificate(certificate: certificate))
        return ApproovPinningVerifier.sha256(data: spki).base64EncodedString()
    }

    /// The certificate path that the OS builds and validates for a chain.
    private func validatedPath(_ chain: [SecCertificate], host: String) throws -> [SecCertificate] {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust),
                       errSecSuccess)
        let evaluated = try XCTUnwrap(trust)
        SecTrustSetVerifyDate(evaluated, pinningFixtureDate as CFDate)
        XCTAssertTrue(SecTrustEvaluateWithError(evaluated, nil), "control: the recorded chain must validate")
        return try XCTUnwrap(SecTrustCopyCertificateChain(evaluated) as? [SecCertificate])
    }

    func testPinningRejectsDecoyCertificateOutsideValidatedPath() throws {
        let host = "replay.ivol.workers.dev"
        let leaf = try fixtureCertificate(PinningTestCertificates.replayLeaf)
        let intermediate = try fixtureCertificate(PinningTestCertificates.replayWE1)
        let crossSignedRoot = try fixtureCertificate(PinningTestCertificates.replayGTSR4)
        let decoy = try fixtureCertificate(PinningTestCertificates.appleEVCA)
        let decoyPin = try spkiPin(decoy)
        // The mini SDK empties the pins of the TESTING_REPLY_URL host, so the decoy key is a managed trust root.
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "\(host)": [], "*": ["\(decoyPin)"] } }
            """)
        let genuine = [leaf, intermediate, crossSignedRoot]

        XCTAssertFalse(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: genuine,
                                                                verifyDate: pinningFixtureDate),
                       "control: the genuine chain does not contain the pinned key")
        XCTAssertFalse(try validatedPath(genuine + [decoy], host: host).contains { try spkiPin($0) == decoyPin },
                       "control: the decoy is not part of the validated path")
        XCTAssertFalse(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: genuine + [decoy],
                                                                verifyDate: pinningFixtureDate),
                       "A decoy certificate outside the validated path must not satisfy the pin")
    }

    func testManagedTrustRootPinMatchesWhenServerOmitsRoot() throws {
        let host = "www.apple.com"
        let leaf = try fixtureCertificate(PinningTestCertificates.appleLeaf)
        let intermediate = try fixtureCertificate(PinningTestCertificates.appleEVCA)
        let path = try validatedPath([leaf, intermediate], host: host)
        XCTAssertEqual(path.count, 3, "control: the OS adds the root that the server did not send")
        let rootPin = try spkiPin(try XCTUnwrap(path.last))
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "\(host)": [], "*": ["\(rootPin)"] } }
            """)

        XCTAssertTrue(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: [leaf, intermediate],
                                                               verifyDate: pinningFixtureDate),
                      "A managed trust root pin must match the root that trust evaluation added")
    }

    func testPerRequestTLSWithoutFullVerificationIsRejected() throws {
        try reinitializeServiceWithTargetHost()
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        let request = try HTTPClient.Request(url: XCTUnwrap(URL(string: targetURLString)), method: .GET,
                                             headers: HTTPHeaders(), body: nil, tlsConfiguration: tls)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }

        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            guard case ApproovError.configurationError = error else {
                return XCTFail("Expected ApproovError.configurationError, got \(error)")
            }
        }
    }

    // MARK: - §5 Message Signing

    func testTargetUriOmitsFragment() throws {
        let provider = ApproovAsyncHTTPClientComponentProvider(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/p?q=1#frag")), method: "GET", headers: HTTPHeaders()))
        // SPECIFICATION 3.3: the target URI as the stack sends it, without the fragment.
        XCTAssertEqual(provider.getTargetUri(), "https://example.com/p?q=1")
    }

    func testPathIsSlashWhenURLPathIsEmpty() throws {
        let provider = ApproovAsyncHTTPClientComponentProvider(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: "https://example.com")), method: "GET", headers: HTTPHeaders()))
        // RFC 9421 section 2.2.6. AsyncHTTPClient also sends "/".
        XCTAssertEqual(provider.getPath(), "/")
        XCTAssertEqual(provider.getRequestTarget(), "/")
    }

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

    func testExtractBodyDataLateWriteDoesNotUseEmbeddedEventLoop() throws {
        let producerGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? producerGroup.syncShutdownGracefully() }
        let lateWrite = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)
        // An asynchronous producer: it writes 20 ms later, from its own thread.
        let body = HTTPClient.Body.stream(length: 5) { writer in
            producerGroup.next().scheduleTask(in: .milliseconds(20)) {
                lateWrite.withLockedValue { $0 = writer.write(.byteBuffer(ByteBuffer(string: "hello"))) }
            }.futureResult
        }

        XCTAssertNil(ApproovService.extractBodyData(from: body), "an asynchronous body is not digested")
        Thread.sleep(forTimeInterval: 0.2)
        let future = try XCTUnwrap(lateWrite.withLockedValue { $0 }, "control: the producer wrote")
        XCTAssertFalse(future.eventLoop is EmbeddedEventLoop,
                       "A late write must not use the EmbeddedEventLoop from another thread")
        XCTAssertNoThrow(try future.wait())
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

    // MARK: - §7 Reinitialization

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

        // SPEC 5.7(a): the SDK refuses a different comment, and the layer returns that error unchanged.
        XCTAssertThrowsError(try ApproovService.initialize(config: validInitialConfig, comment: "options:test-option")) { error in
            guard case ApproovError.initializationFailure = error else {
                return XCTFail("Expected initializationFailure, got \(error)")
            }
        }

        // A "reinit" comment is accepted again.
        XCTAssertNoThrow(try ApproovService.initialize(config: validInitialConfig, comment: "reinit-options"))
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

    func testAsyncBodyDigestCoversBytesFromReaderIndex() async throws {
        try reinitializeServiceWithTargetHost()
        let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: true)
        ApproovService.setServiceMutator(ApproovDefaultMessageSigning().setDefaultFactory(factory))

        var buffer = ByteBuffer(string: "XXXXpayload")
        buffer.moveReaderIndex(forwardBy: 4) // AsyncHTTPClient sends only "payload"
        var request = HTTPClientRequest(url: targetURLString)
        request.method = .POST
        request.body = .bytes(buffer)

        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }
        let response = try await client.execute(request, timeout: .seconds(30))
        var collected = ByteBuffer()
        for try await var part in response.body {
            collected.writeBuffer(&part)
        }
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(collected.readableBytesView)) as? [String: Any])
        let expected = Data(SHA256.hash(data: Data("payload".utf8))).base64EncodedString()
        XCTAssertEqual(getHeader(from: reply, key: "Content-Digest"), "sha-256=:\(expected):")
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

    // MARK: - §5.10 Logging

    func testLoggingOffSilencesTheLayer() throws {
        try reinitializeServiceWithTargetHost()
        let lines = try captureLogs(level: .off) {
            _ = fetchNetworkReply(for: try HTTPClient.Request(url: targetURLString + "/p?x=1", method: .GET))
        }
        XCTAssertTrue(lines.isEmpty, "OFF must silence the layer: \(lines)")
    }

    func testTokenLineIsDebugOnlyAndCarriesNoQueryOrFragment() throws {
        try reinitializeServiceWithTargetHost()
        let url = targetURLString + "/p?q=query-value#fragment-value"
        let infoLines = try captureLogs(level: .info) {
            _ = fetchNetworkReply(for: try HTTPClient.Request(url: url, method: .GET))
        }
        XCTAssertFalse(infoLines.contains { $0.1.contains("updateRequest") }, "the token line is DEBUG only")

        let debugLines = try captureLogs(level: .debug) {
            _ = fetchNetworkReply(for: try HTTPClient.Request(url: url, method: .GET))
        }
        XCTAssertTrue(debugLines.contains { $0.0 == .debug && $0.1.contains("updateRequest") }, "control: token line at DEBUG")
        XCTAssertFalse(debugLines.contains { $0.1.contains("query-value") || $0.1.contains("fragment-value") },
                       "no line carries a query or a fragment: \(debugLines.map { $0.1 })")
    }

    func testPinningLinesGoThroughTheLogAndCarryNoPin() throws {
        let host = "www.apple.com"
        let leaf = try fixtureCertificate(PinningTestCertificates.appleLeaf)
        let intermediate = try fixtureCertificate(PinningTestCertificates.appleEVCA)
        let rootPin = try spkiPin(try XCTUnwrap(try validatedPath([leaf, intermediate], host: host).last))
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "\(host)": [], "*": ["\(rootPin)"] } }
            """)
        let lines = try captureLogs(level: .debug) {
            XCTAssertTrue(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: [leaf, intermediate],
                                                                   verifyDate: pinningFixtureDate))
        }
        XCTAssertTrue(lines.contains { $0.1.contains("Matched pin") }, "control: the match line reaches the log")
        XCTAssertFalse(lines.contains { $0.1.contains(rootPin) }, "no line carries a pin (SPEC 2.6)")
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

    private func captureLogs(level: ApproovLogLevel, _ body: () throws -> Void) rethrows -> [(ApproovLogLevel, String)] {
        let lines = NIOLockedValueBox<[(ApproovLogLevel, String)]>([])
        ApproovService.logSink = { lineLevel, line in lines.withLockedValue { $0.append((lineLevel, line)) } }
        ApproovService.setLoggingLevel(level)
        defer {
            ApproovService.logSink = nil
            ApproovService.setLoggingLevel(.off)
        }
        try body()
        return lines.withLockedValue { $0 }
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
        // The SDK reads options only on the first initialization of a process.
        if comment.hasPrefix("options:") {
            MiniSDKAttesterProxyController.resetSdkForTesting()
        }
        if let scenarioJSON {
            MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON)
        }
        ApproovService.resetForTesting()
        ApproovService.setLoggingLevel(.off)
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
