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

    // MARK: - Initialization

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

    func testInitializeResetsConfigurationButKeepsTheLoggingLevel() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.setTokenHeader(header: "X-Custom", prefix: "Bearer ")
        ApproovService.setTraceIDHeader(header: nil)
        ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
        ApproovService.bindHeader = "Authorization"
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
        ApproovService.addSubstitutionQueryParam(key: "k")
        ApproovService.addExclusionURLRegex(urlRegex: "^https://excluded")
        ApproovService.setServiceMutator(ApproovDefaultMessageSigning())
        setDirective("""
            { "operation": "fetchApproovToken", "response": { "status": "REJECTED", "arc": "RESETARC" } }
            """)
        _ = try? ApproovService.fetchToken(url: targetURLString)
        XCTAssertEqual(ApproovService.getLastARC(), "RESETARC", "control: an ARC is recorded")
        ApproovService.setLoggingLevel(.warning)

        try ApproovService.initialize(config: validInitialConfig, comment: "reinit-reset-check")

        XCTAssertEqual(ApproovService.getTokenHeader(), "Approov-Token")
        XCTAssertEqual(ApproovService.getTokenPrefix(), "")
        XCTAssertEqual(ApproovService.getTraceIDHeader(), "Approov-TraceID")
        XCTAssertFalse(ApproovService.getUseApproovStatusIfNoToken())
        XCTAssertEqual(ApproovService.bindHeader, "")
        XCTAssertTrue(ApproovService.getSubstitutionHeaders().isEmpty)
        XCTAssertTrue(ApproovService.getSubstitutionQueryParams().isEmpty)
        XCTAssertTrue(ApproovService.getExclusionURLRegexs().isEmpty)
        XCTAssertTrue(ApproovService.getServiceMutator() is ApproovCloseFailureMutator)
        XCTAssertEqual(ApproovService.getLastARC(), "")
        XCTAssertEqual(ApproovService.logLevel, .warning, "initialize keeps the logging level")
        ApproovService.setLoggingLevel(.off)
    }

    func testIgnoredAndFailedInitializeChangeNothing() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.setTokenHeader(header: "X-Custom", prefix: nil)
        try ApproovService.initialize(config: "", comment: nil)
        XCTAssertEqual(ApproovService.getTokenHeader(), "X-Custom", "an empty account ID after protection is ignored")
        XCTAssertThrowsError(try ApproovService.initialize(config: validInitialConfig, comment: "options:different"))
        XCTAssertEqual(ApproovService.getTokenHeader(), "X-Custom", "a failed initialize changes nothing")
    }

    func testInvalidExclusionRegexIsLoggedAndIgnored() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.addExclusionURLRegex(urlRegex: "^https://excluded\\.example")
        let lines = captureLogs(level: .error) {
            ApproovService.addExclusionURLRegex(urlRegex: "([unclosed")
        }
        XCTAssertEqual(Set(ApproovService.getExclusionURLRegexs().keys), ["^https://excluded\\.example"])
        XCTAssertTrue(lines.contains { $0.0 == .error && $0.1.contains("([unclosed") })
    }

    func testDirectMethodsInBypassModeUseTheNotInitializedTexts() throws {
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: nil)
        let calls: [(String, () throws -> Void)] = [
            ("fetchToken", { _ = try ApproovService.fetchToken(url: self.targetURLString) }),
            ("fetchSecureString", { _ = try ApproovService.fetchSecureString(key: "k", newDef: nil) }),
            ("fetchCustomJWT", { _ = try ApproovService.fetchCustomJWT(payload: "{}") }),
            ("precheck", { try ApproovService.precheck() }),
            ("setInstallAttrsInToken", { try ApproovService.setInstallAttrsInToken(attrs: "{}") })
        ]
        for (name, call) in calls {
            XCTAssertThrowsError(try call()) { error in
                guard case let ApproovError.permanentError(message) = error else {
                    return XCTFail("\(name): expected permanentError, got \(error)")
                }
                XCTAssertEqual(message, "\(name): SDK not initialized")
            }
        }
    }

    func testServiceAndProtectionFlags() throws {
        ApproovService.resetForTesting()
        XCTAssertFalse(ApproovService.isApproovServiceEnabled())
        XCTAssertFalse(ApproovService.isApproovProtectionEnabled())
        try ApproovService.initialize(config: "", comment: nil)
        XCTAssertTrue(ApproovService.isApproovServiceEnabled(), "bypass mode is a service that processes requests")
        XCTAssertFalse(ApproovService.isApproovProtectionEnabled(), "bypass mode has no protection")
        try reinitializeServiceWithTargetHost()
        XCTAssertTrue(ApproovService.isApproovServiceEnabled())
        XCTAssertTrue(ApproovService.isApproovProtectionEnabled())
    }

    @available(*, deprecated)
    func testGetMessageSignatureIsTheAccountSignatureAndWarnsOnce() throws {
        try reinitializeServiceWithTargetHost()
        _ = Approov.fetchTokenAndWait(targetURLString)
        let lines = captureLogs(level: .warning) {
            XCTAssertEqual(ApproovService.getMessageSignature(message: "m"), ApproovService.getAccountMessageSignature(message: "m"))
            XCTAssertEqual(ApproovService.getMessageSignature(message: "m"), ApproovService.getAccountMessageSignature(message: "m"))
        }
        XCTAssertLessThanOrEqual(lines.filter { $0.1.contains("getMessageSignature is deprecated") }.count, 1,
                                 "the deprecation warning is logged once per process")
    }

    func testSetInstallAttributesIsTheNewName() throws {
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: nil)
        XCTAssertThrowsError(try ApproovService.setInstallAttributes("{}")) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertEqual(message, "setInstallAttributes: SDK not initialized")
        }
    }

    // MARK: - Request Processing & Token Behaviors

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

    // NO_APPROOV_SERVICE proceeds to a listed host with an empty token header and the SDK
    // trace header, as evidence that Approov processing ran. Under 3.5.x it carried no Approov header.
    func testUpdateRequestNoApproovServiceProceedsWithEmptyToken() throws {
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

        XCTAssertNotNil(reply, "Expected to receive a reply from worker when proceeding without a token")
        XCTAssertEqual(getHeader(from: reply, key: "Approov-Token"), "", "the token header is present and empty")
        XCTAssertNotNil(getHeader(from: reply, key: "Approov-TraceID"), "the trace header the SDK supplied")
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
            XCTAssertEqual(message, "fetchToken network error: NO_NETWORK")  // Status names, not SDK prose
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
            XCTAssertTrue(message.contains("NO_NETWORK"), "Unexpected message: \(message)")  // Status names, not SDK prose
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
            XCTAssertTrue(message.contains("REJECTED"), "Unexpected message: \(message)")  // Status names, not SDK prose
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

    // The mini SDK classifies hosts as the real SDK does.

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

    func testCommonHeaderNamesSetAndGetTheHeaders() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.setTokenHeader(header: "X-Approov", prefix: nil)
        XCTAssertEqual(ApproovService.getTokenHeader(), "X-Approov")
        XCTAssertEqual(ApproovService.getTokenPrefix(), "", "a nil prefix means no prefix, never \"null\"")
        ApproovService.setTokenHeader(header: "Authorization", prefix: "Bearer ")
        XCTAssertEqual(ApproovService.getTokenPrefix(), "Bearer ")
        ApproovService.setTraceIDHeader(header: nil)
        XCTAssertNil(ApproovService.getTraceIDHeader())

        let reply = fetchNetworkReply(for: try HTTPClient.Request(url: targetURLString, method: .GET))
        XCTAssertTrue(try XCTUnwrap(getHeader(from: reply, key: "Authorization")).hasPrefix("Bearer "))
        XCTAssertNil(getHeader(from: reply, key: "Approov-TraceID"), "a nil trace header is disabled")
    }

    func testGetLastARCMakesNoFetchAndReturnsTheLastFetchARC() throws {
        try reinitializeServiceWithTargetHost()
        XCTAssertEqual(ApproovService.getLastARC(), "", "no fetch since initialization")

        MiniSDKAttesterProxyController.clearCallLog()
        _ = ApproovService.getLastARC()
        XCTAssertEqual(MiniSDKAttesterProxyController.callLog(), [], "getLastARC must not fetch")

        setDirective("""
            { "operation": "fetchApproovToken", "response": { "status": "REJECTED", "arc": "TESTARC123" } }
            """)
        XCTAssertThrowsError(try ApproovService.fetchToken(url: targetURLString))
        XCTAssertEqual(ApproovService.getLastARC(), "TESTARC123")
    }

    func testStatusNamesAreTheSDKEnumNames() {
        let expected: [(ApproovTokenFetchStatus, String)] = [
            (.success, "SUCCESS"), (.noNetwork, "NO_NETWORK"), (.mitmDetected, "MITM_DETECTED"),
            (.poorNetwork, "POOR_NETWORK"), (.noApproovService, "NO_APPROOV_SERVICE"), (.badURL, "BAD_URL"),
            (.unknownURL, "UNKNOWN_URL"), (.unprotectedURL, "UNPROTECTED_URL"), (.notInitialized, "NOT_INITIALIZED"),
            (.rejected, "REJECTED"), (.disabled, "DISABLED"), (.unknownKey, "UNKNOWN_KEY"), (.badKey, "BAD_KEY"),
            (.badPayload, "BAD_PAYLOAD"), (.internalError, "INTERNAL_ERROR")
        ]
        for (status, name) in expected {
            XCTAssertEqual(ApproovService.statusName(status), name)
        }
    }

    func testDirectMethodMessagesUseStatusNames() throws {
        try reinitializeServiceWithTargetHost()
        setDirective(#"{ "operation": "fetchApproovToken", "response": { "status": "REJECTED" } }"#)
        XCTAssertThrowsError(try ApproovService.fetchToken(url: targetURLString)) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertEqual(message, "fetchToken: REJECTED")
        }
    }

    func testCallHookPassesURLErrorAndWrapsOthers() throws {
        struct AppError: Error {}
        XCTAssertThrowsError(try ApproovRequestPathError.callHook("hook") { throw URLError(.cancelled) }) { error in
            XCTAssertEqual((error as? URLError)?.code, .cancelled, "an app abort with a URLError passes through")
        }
        XCTAssertThrowsError(try ApproovRequestPathError.callHook("hook") { throw AppError() }) { error in
            XCTAssertEqual((error as? URLError)?.code, .unknown)
            XCTAssertTrue((error as NSError).userInfo[NSUnderlyingErrorKey] is AppError, "the original is the cause")
        }
        XCTAssertThrowsError(try ApproovRequestPathError.callHook("hook") {
            throw ApproovError.permanentError(message: "app")
        }) { error in
            XCTAssertEqual((error as? URLError)?.code, .unknown, "an ApproovError the app threw is a hook failure (1.6.1)")
        }
        XCTAssertThrowsError(try ApproovRequestPathError.callHook("hook") {
            throw ApproovStandardDecisions.made(.permanentError(message: "standard"))
        }) { error in
            guard case ApproovError.permanentError = error else {
                return XCTFail("a standard decision keeps its ApproovError, got \(error)")
            }
        }
        XCTAssertNil(try ApproovRequestPathError.callHookIgnoringStandardDecisions("hook") { () -> Bool in
            throw ApproovStandardDecisions.made(.networkingError(message: "standard"))
        }, "a standard decision is ignored where the standard decisions do not apply")
    }

    // MARK: - Service Mutators & Decision Overrides

    func testDefaultMutatorIsCloseFailure() throws {
        try reinitializeServiceWithTargetHost()
        XCTAssertTrue(ApproovService.getServiceMutator() is ApproovCloseFailureMutator)
        ApproovService.setServiceMutator(ApproovAlwaysProceedMutator.ALWAYS_PROCEED)
        ApproovService.setServiceMutator(nil)
        XCTAssertTrue(ApproovService.getServiceMutator() is ApproovCloseFailureMutator, "nil restores DEFAULT")
        XCTAssertTrue(ApproovCloseFailureMutator.DEFAULT is ApproovCloseFailureMutator, "DEFAULT is CLOSE_FAILURE")
    }

    func testAlwaysProceedNeverThrowsATokenDecision() throws {
        let fetch = ApproovAlwaysProceedMutator.ALWAYS_PROCEED
        try reinitializeServiceWithTargetHost()
        for status in ["NO_NETWORK", "MITM_DETECTED", "REJECTED", "INTERNAL_ERROR", "NO_APPROOV_SERVICE"] {
            setDirective(#"{ "operation": "fetchApproovToken", "response": { "status": "\#(status)" } }"#)
            let result = Approov.fetchTokenAndWait(targetURLString)
            XCTAssertTrue(try fetch.handleInterceptorFetchTokenResult(result, url: targetURLString), status)
        }
    }

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

    // MARK: - Pinning Configuration & Scenarios

    func testPinningFailsClosedWhenPinsAreUnavailable() throws {
        try reinitializeServiceWithTargetHost()
        let host = "replay.ivol.workers.dev"
        let chain = [try fixtureCertificate(PinningTestCertificates.replayLeaf),
                     try fixtureCertificate(PinningTestCertificates.replayWE1),
                     try fixtureCertificate(PinningTestCertificates.replayGTSR4)]
        XCTAssertNoThrow(try ApproovPinningVerifier.verifyPinning(hostname: host, certChain: chain,
                                                                  verifyDate: pinningFixtureDate),
                         "control: with pins available the chain is checked without an error")

        // A layer that cannot read the pins fails the connection closed.
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
        let client = pinnedClient()
        defer { try? client.syncShutdown() }
        // The layer reports the pin rejection as URLError(.serverCertificateUntrusted).
        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted, "\(error)")
        }
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

    private func applePinFixture() throws -> (leaf: SecCertificate, ca: SecCertificate, caPin: String, rootPin: String) {
        let leaf = try fixtureCertificate(PinningTestCertificates.appleLeaf)
        let ca = try fixtureCertificate(PinningTestCertificates.appleEVCA)
        let root = try XCTUnwrap(try validatedPath([leaf, ca], host: "www.apple.com").last)
        return (leaf, ca, try spkiPin(ca), try spkiPin(root))
    }

    // Lookup ignores case and one trailing dot, on the host and on the key.
    func testPinLookupIgnoresCaseAndTrailingDot() throws {
        let f = try applePinFixture()
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "WWW.Apple.COM.": ["\(f.caPin)"] } }
            """)
        XCTAssertTrue(try ApproovPinningVerifier.verifyPinning(hostname: "www.apple.com", certChain: [f.leaf, f.ca], verifyDate: pinningFixtureDate))
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "www.apple.com": ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="] } }
            """)
        XCTAssertFalse(try ApproovPinningVerifier.verifyPinning(hostname: "WWW.APPLE.COM.", certChain: [f.leaf, f.ca], verifyDate: pinningFixtureDate),
                       "control: the normalised host still finds its pins")
    }

    // A listed host with no pins and an empty "*" connects on OS trust, with one warning per host.
    func testEmptyManagedTrustRootsFallBackToOSTrustWithOneWarning() throws {
        let f = try applePinFixture()
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "www.apple.com": [], "*": [] } }
            """)
        let lines = try captureLogs(level: .warning) {
            XCTAssertTrue(try ApproovPinningVerifier.verifyPinning(hostname: "www.apple.com", certChain: [f.leaf, f.ca], verifyDate: pinningFixtureDate))
            XCTAssertTrue(try ApproovPinningVerifier.verifyPinning(hostname: "www.apple.com", certChain: [f.leaf, f.ca], verifyDate: pinningFixtureDate))
        }
        let warnings = lines.filter { $0.0 == .warning && $0.1.contains("www.apple.com") }
        XCTAssertEqual(warnings.count, 1, "one warning per host: \(lines)")
        XCTAssertFalse(lines.contains { $0.1.contains(f.caPin) || $0.1.contains(f.rootPin) }, "never a pin")
    }

    // A connection without SNI (an IP literal host) cannot be matched to a host.
    func testConnectionWithoutServerName() throws {
        let f = try applePinFixture()
        try reinitializeServiceWithTargetHost()
        XCTAssertTrue(try ApproovPinningVerifier.verifyPinning(serverName: nil, certChain: [f.leaf, f.ca], verifyDate: pinningFixtureDate),
                      "no IP literal is pinned, so the connection uses OS trust")
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "192.0.2.1": ["\(f.caPin)"] } }
            """)
        XCTAssertFalse(try ApproovPinningVerifier.verifyPinning(serverName: nil, certChain: [f.leaf, f.ca], verifyDate: pinningFixtureDate),
                       "an IP literal is pinned and the host is unknown, so the connection fails closed")
    }

    private func pinnedClient() -> ApproovHTTPClient {
        ApproovHTTPClient(eventLoopGroupProvider: .createNew,
                          configuration: HTTPClient.Configuration(timeout: .init(connect: .seconds(3))))
    }

    func testPinRejectionIsServerCertificateUntrustedOnBothAPIs() throws {
        let host = try XCTUnwrap(URL(string: targetURLString)?.host)
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "pins": { "public-key-sha256": { "*": ["invalid-pin-base64="], "\(host)": ["invalid-pin-base64="] } }
            """)
        let url = targetURLString
        let client = pinnedClient()
        defer { try? client.syncShutdown() }
        let results: [(String, Result<Void, Error>)] = [
            ("HTTPClient.Request API", Result { _ = try client.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait() }),
            ("HTTPClientRequest API", blockingResult { _ = try await client.execute(HTTPClientRequest(url: url), timeout: .seconds(10)) })
        ]
        for (api, result) in results {
            switch result {
            case .success:
                XCTFail("\(api): expected a pinning failure")
            case .failure(let error):
                XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted, "\(api): \(error)")
            }
        }
    }

    // Cleartext is not blocked by pinning; the SDK answers BAD_URL and the mutator decides.
    func testCleartextToAListedHostIsTheMutatorsDecision() throws {
        try reinitializeServiceWithTargetHost()
        let http = targetURLString.replacingOccurrences(of: "https://", with: "http://")
        let closed = try decide(http, mutator: ApproovCloseFailureMutator.CLOSE_FAILURE)
        guard case ApproovError.permanentError(let message)? = closed.error else { return XCTFail("\(String(describing: closed.error))") }
        XCTAssertTrue(message.hasSuffix(": BAD_URL"), message)
        let proceeds = try decide(http, mutator: ApproovAlwaysProceedMutator.ALWAYS_PROCEED)
        XCTAssertEqual(proceeds.decision, .ShouldProceed)
    }

    /// Runs async work from a synchronous test and returns its result, so that every assertion runs on the
    /// test thread. An async test that mixes blocking `wait()` calls with `await` lost recorded failures.
    private func blockingResult<T>(_ work: @escaping () async throws -> T) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task.detached {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    private func assertPinningUnavailable<T>(_ result: Result<T, Error>, _ message: String) {
        switch result {
        case .success:
            XCTFail("\(message): expected URLError(.unknown), but the request succeeded")
        case .failure(let error):
            XCTAssertEqual((error as? URLError)?.code, .unknown, "\(message): \(error)")
        }
    }

    func testClientsWherePinningCannotRunAreRefused() throws {
        try reinitializeServiceWithTargetHost()
        let url = targetURLString
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let posixClient = ApproovHTTPClient(eventLoopGroupProvider: .shared(group))
        defer { try? posixClient.syncShutdown() }
        assertPinningUnavailable(Result { try posixClient.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait() },
                                 "NIOSSL group, HTTPClient.Request API")
        assertPinningUnavailable(blockingResult { try await posixClient.execute(HTTPClientRequest(url: url), timeout: .seconds(10)) },
                                 "NIOSSL group, HTTPClientRequest API")

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        let noVerifyClient = ApproovHTTPClient(eventLoopGroupProvider: .createNew,
                                               configuration: HTTPClient.Configuration(tlsConfiguration: tls))
        defer { try? noVerifyClient.syncShutdown() }
        assertPinningUnavailable(Result { try noVerifyClient.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait() },
                                 "client TLS without full verification")

        // A NIOTS client, but a channel event loop from a POSIX group, forces the NIOSSL path.
        let tsClient = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? tsClient.syncShutdown() }
        assertPinningUnavailable(Result {
            let request = try HTTPClient.Request(url: url, method: .GET)
            _ = try tsClient.execute(request: request, delegate: ResponseAccumulator(request: request),
                                     eventLoop: .delegateAndChannel(on: group.next()), logger: nil).wait()
        }, "delegateAndChannel on a POSIX event loop")
        XCTAssertNoThrow(try tsClient.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait(),
                         "control: the same client with no event loop preference")

        // Bypass mode has no pins, so the same clients work.
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: nil)
        XCTAssertNoThrow(try posixClient.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait())
    }

    func testClientWithAProxyIsRefused() throws {
        try reinitializeServiceWithTargetHost()
        let url = targetURLString
        // Nothing listens on port 9. The client never reaches the proxy while Approov is enabled.
        var configuration = HTTPClient.Configuration()
        configuration.proxy = .server(host: "127.0.0.1", port: 9)
        configuration.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(2))
        let proxyClient = ApproovHTTPClient(eventLoopGroupProvider: .createNew, configuration: configuration)
        defer { try? proxyClient.syncShutdown() }
        assertPinningUnavailable(Result { try proxyClient.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait() },
                                 "proxy, HTTPClient.Request API")
        assertPinningUnavailable(blockingResult { try await proxyClient.execute(HTTPClientRequest(url: url), timeout: .seconds(10)) },
                                 "proxy, HTTPClientRequest API")

        // Bypass mode has no pins, so the layer sends the request. It then fails only because no proxy listens.
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: nil)
        XCTAssertThrowsError(try proxyClient.execute(request: try HTTPClient.Request(url: url, method: .GET)).wait()) { error in
            XCTAssertNotEqual((error as? URLError)?.code, .unknown, "the layer must not refuse the request in bypass mode: \(error)")
        }
    }

    func testEventLoopPreferenceKeepsTheEventLoop() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        func mappedLoop(_ preference: HTTPClient.EventLoopPreference) -> EventLoop? {
            switch ApproovHTTPClient.EventLoopPreference(preference).preference {
            case .indifferent: return nil
            case .delegate(on: let mapped): return mapped
            case .delegateAndChannel(on: let mapped): return mapped
            }
        }
        XCTAssertNil(mappedLoop(.indifferent))
        XCTAssertTrue(mappedLoop(.delegate(on: loop)) === loop, "delegate(on:)")
        XCTAssertTrue(mappedLoop(.delegateAndChannel(on: loop)) === loop, "delegateAndChannel(on:)")
        XCTAssertEqual(ApproovHTTPClient.EventLoopPreference(HTTPClient.EventLoopPreference.delegateAndChannel(on: loop)).preference,
                       ApproovHTTPClient.EventLoopPreference.Preference.delegateAndChannel(on: loop))
    }

    func testPerRequestTLSWithoutFullVerificationIsRejected() throws {
        try reinitializeServiceWithTargetHost()
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        let request = try HTTPClient.Request(url: XCTUnwrap(URL(string: targetURLString)), method: .GET,
                                             headers: HTTPHeaders(), body: nil, tlsConfiguration: tls)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }

        // A configuration error on the request path is the network error, URLError(.unknown).
        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            XCTAssertEqual((error as? URLError)?.code, .unknown, "\(error)")
        }
    }

    // MARK: - Redirects

    func testRedirectPolicyIsReadFromTheConfiguration() {
        XCTAssertNil(ApproovRedirectPolicy.of(.disallow))
        XCTAssertEqual(ApproovRedirectPolicy.of(HTTPClient.Configuration().redirectConfiguration),
                       ApproovRedirectPolicy(max: 5, allowCycles: false))
        XCTAssertEqual(ApproovRedirectPolicy.of(.follow(max: 2, allowCycles: true)),
                       ApproovRedirectPolicy(max: 2, allowCycles: true))
        let lines = captureLogs(level: .error) { _ = ApproovRedirectPolicy.of(.follow(max: 3, allowCycles: false)) }
        XCTAssertTrue(lines.isEmpty, "the configuration is read, not guessed: \(lines)")
    }

    func testRedirectTrackerKeepsTheAppsLimits() {
        var two = ApproovRedirectTracker(policy: ApproovRedirectPolicy(max: 2, allowCycles: false), initialURL: "https://h/0")
        XCTAssertNoThrow(try two.redirect(to: "https://h/1"))
        XCTAssertNoThrow(try two.redirect(to: "https://h/2"))
        XCTAssertThrowsError(try two.redirect(to: "https://h/3")) {
            XCTAssertEqual($0 as? HTTPClientError, .redirectLimitReached)
        }
        var noCycles = ApproovRedirectTracker(policy: ApproovRedirectPolicy(max: 5, allowCycles: false), initialURL: "https://h/0")
        XCTAssertThrowsError(try noCycles.redirect(to: "https://h/0")) {
            XCTAssertEqual($0 as? HTTPClientError, .redirectCycleDetected)
        }
        var cycles = ApproovRedirectTracker(policy: ApproovRedirectPolicy(max: 5, allowCycles: true), initialURL: "https://h/0")
        XCTAssertNoThrow(try cycles.redirect(to: "https://h/0"))
    }

    func testRedirectTargetFollowsAsyncHTTPClientRules() throws {
        let from = try XCTUnwrap(URL(string: "https://h.example/a/b?q=1"))
        func target(_ status: HTTPResponseStatus, _ location: String?) -> String? {
            var headers = HTTPHeaders()
            if let location {
                headers.add(name: "Location", value: location)
            }
            return ApproovRedirects.target(status: status, headers: headers, from: from)?.absoluteString
        }
        XCTAssertEqual(target(.found, "/x?k=v"), "https://h.example/x?k=v", "resolved against the request URL")
        XCTAssertEqual(target(.temporaryRedirect, "https://o.example/y"), "https://o.example/y")
        XCTAssertEqual(target(.movedPermanently, "http://h.example/z"), "http://h.example/z")
        XCTAssertNil(target(.ok, "/x"), "not a redirect status")
        XCTAssertNil(target(.found, nil), "no Location")
        XCTAssertNil(target(.found, "ftp://h.example/f"), "not an http or https target")
        XCTAssertNil(target(.found, "file:///etc/hosts"))
        let followed: [HTTPResponseStatus] = [.movedPermanently, .found, .seeOther, .notModified, .useProxy,
                                              .temporaryRedirect, .permanentRedirect]
        for status in followed {
            XCTAssertNotNil(target(status, "/x"), "\(status.code)")
        }
    }

    func testRedirectTransformFollowsAsyncHTTPClientRules() throws {
        let from = try XCTUnwrap(URL(string: "https://h.example/a"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://h.example/b"))
        let otherOrigin = try XCTUnwrap(URL(string: "https://o.example/b"))
        let headers = HTTPHeaders([("Content-Type", "text/plain"), ("Content-Length", "7"), ("Authorization", "a"),
                                   ("Cookie", "c"), ("Origin", "o"), ("Proxy-Authorization", "p"),
                                   ("Api-Key", "Bearer header-key")])
        let seeOther = ApproovRedirects.transform(method: .POST, headers: headers, from: from, to: sameOrigin, status: .seeOther)
        XCTAssertEqual(seeOther.method, .GET)
        XCTAssertFalse(seeOther.keepsBody)
        XCTAssertNil(seeOther.headers.first(name: "Content-Type"))
        XCTAssertNil(seeOther.headers.first(name: "Content-Length"))
        XCTAssertEqual(seeOther.headers.first(name: "Authorization"), "a", "same origin keeps the app's credentials")
        XCTAssertEqual(ApproovRedirects.transform(method: .HEAD, headers: headers, from: from, to: sameOrigin,
                                                  status: .seeOther).method, .HEAD)
        XCTAssertEqual(ApproovRedirects.transform(method: .POST, headers: headers, from: from, to: sameOrigin,
                                                  status: .movedPermanently).method, .GET)
        XCTAssertEqual(ApproovRedirects.transform(method: .PUT, headers: headers, from: from, to: sameOrigin,
                                                  status: .found).method, .PUT)
        let temporary = ApproovRedirects.transform(method: .POST, headers: headers, from: from, to: otherOrigin,
                                                   status: .temporaryRedirect)
        XCTAssertEqual(temporary.method, .POST)
        XCTAssertTrue(temporary.keepsBody)
        for name in ["Authorization", "Cookie", "Origin", "Proxy-Authorization"] {
            XCTAssertNil(temporary.headers.first(name: name), name)
        }
        XCTAssertEqual(temporary.headers.first(name: "Api-Key"), "Bearer header-key", "the app's placeholder header is kept")
    }

    func testRedirectHopIsBuiltFromTheAppsRequest() throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv13
        let app = try HTTPClient.Request(url: XCTUnwrap(URL(string: "https://h.example/p?k=query-key")), method: .POST,
                                         headers: HTTPHeaders([("Api-Key", "Bearer header-key")]),
                                         body: .string("payload"), tlsConfiguration: tls)
        let hop = ApproovRequestHop(request: app, substituteQuery: true)
        let wire = try XCTUnwrap(URL(string: "https://h.example/p?k=query-secret"))

        // The server redirects to the URL that was sent: the app's URL, with its placeholders, is protected again.
        let same = try hop.following(status: .temporaryRedirect, to: wire, wireURL: wire)
        XCTAssertEqual(same.request.url.absoluteString, "https://h.example/p?k=query-key")
        XCTAssertTrue(same.substituteQuery)
        XCTAssertNotNil(same.request.body)

        // Any other target is used exactly as the server sent it, and its query is never looked up.
        let echoed = try XCTUnwrap(URL(string: "https://o.example/q?k=query-secret"))
        let other = try hop.following(status: .seeOther, to: echoed, wireURL: wire)
        XCTAssertEqual(other.request.url, echoed)
        XCTAssertFalse(other.substituteQuery)
        XCTAssertEqual(other.request.method, .GET)
        XCTAssertNil(other.request.body)
        XCTAssertEqual(other.request.headers.first(name: "Api-Key"), "Bearer header-key", "the app's header, never the layer's")
        XCTAssertEqual(other.request.tlsConfiguration?.minimumTLSVersion, .tlsv13, "the request's TLS configuration is kept")

        // The async request hop follows the same rules.
        var asyncApp = HTTPClientRequest(url: "https://h.example/p?k=query-key")
        asyncApp.method = .POST
        asyncApp.headers = HTTPHeaders([("Api-Key", "Bearer header-key")])
        let asyncHop = ApproovClientRequestHop(request: asyncApp, substituteQuery: true)
        XCTAssertEqual(asyncHop.following(status: .temporaryRedirect, to: wire, wireURL: wire).request.url,
                       "https://h.example/p?k=query-key")
        let asyncOther = asyncHop.following(status: .seeOther, to: echoed, wireURL: wire)
        XCTAssertEqual(asyncOther.request.url, echoed.absoluteString)
        XCTAssertFalse(asyncOther.substituteQuery)
        XCTAssertEqual(asyncOther.request.method, .GET)
    }

    func testOnlyARepeatableAsyncBodyIsSentAgain() {
        XCTAssertTrue(ApproovRedirects.canBeSentAgain(nil))
        XCTAssertTrue(ApproovRedirects.canBeSentAgain(.bytes(ByteBuffer(string: "payload"))))
        XCTAssertTrue(ApproovRedirects.canBeSentAgain(.bytes(Array("payload".utf8))))
        XCTAssertFalse(ApproovRedirects.canBeSentAgain(.bytes(AnySequence(Array("payload".utf8)), length: .known(7))))
        XCTAssertFalse(ApproovRedirects.canBeSentAgain(.stream(AsyncStream<ByteBuffer> { $0.finish() }, length: .known(0))))
    }

    // A request that the layer already protected is put back as the app wrote it before it is protected
    // again. No secure string is fetched with a secret as its key, and it carries one token and one signature.
    func testProtectedRequestIsProtectedAgainFromThePlaceholders() throws {
        try secureStringScenario()
        let first = try decide(targetURLString + "/p?k=query-key", mutator: signer(),
                               headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
        XCTAssertEqual(first.request.headers.first(name: "Api-Key"), "Bearer header-secret")
        XCTAssertTrue(first.request.url.absoluteString.hasSuffix("k=query-secret"), first.request.url.absoluteString)
        MiniSDKAttesterProxyController.clearCallLog()
        let again = ApproovService.updateRequestWithApproov(request: first.request)
        XCTAssertEqual(again.decision, .ShouldProceed)
        XCTAssertEqual(again.request.headers.first(name: "Api-Key"), "Bearer header-secret")
        XCTAssertEqual(again.request.url, first.request.url)
        for name in ["Approov-Token", "Signature", "Signature-Input"] {
            XCTAssertEqual(again.request.headers[name].count, 1, name)
        }
        let calls = MiniSDKAttesterProxyController.callLog()
        XCTAssertTrue(calls.contains("fetchSecureStringAndWait:header-key"), "\(calls)")
        XCTAssertTrue(calls.contains("fetchSecureStringAndWait:query-key"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("fetchSecureStringAndWait:") && $0.contains("secret") },
                       "a secret is never a key: \(calls)")
    }

    // signRequest output sent through ApproovHTTPClient is protected once, from the app's placeholders.
    func testSignRequestOutputThroughApproovHTTPClientIsProtectedOnce() throws {
        try secureStringScenario()
        ApproovService.setServiceMutator(signer())
        let request = try HTTPClient.Request(url: targetURLString + "/p?k=query-key", method: .GET,
                                             headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
        let signed = try ApproovService.signRequest(request)
        MiniSDKAttesterProxyController.clearCallLog()
        let reply = try XCTUnwrap(fetchNetworkReply(for: signed))
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "Bearer header-secret")
        let url = try XCTUnwrap(reply["url"] as? String)
        XCTAssertTrue(url.hasSuffix("k=query-secret"), url)
        let token = try XCTUnwrap(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertFalse(token.contains(","), "one token header: \(token)")
        let signature = try XCTUnwrap(getHeader(from: reply, key: "Signature"))
        XCTAssertFalse(signature.contains(", "), "one signature: \(signature)")
        XCTAssertFalse(MiniSDKAttesterProxyController.callLog().contains {
            $0.hasPrefix("fetchSecureStringAndWait:") && $0.contains("secret")
        })
    }

    // A redirect to another origin carries nothing that the layer added. The hop is a new
    // request for its target, the target URL is used as the server sent it, and a query value from Location is
    // never looked up.
    func testRedirectToAnotherOriginCarriesNoProtection() throws {
        try redirectScenario()
        ApproovService.setServiceMutator(signer())
        let unprotected = try XCTUnwrap(URL(string: unprotectedURLString)?.host)
        let location = "https://\(unprotected)/landing?k=query-key"
        let request = try HTTPClient.Request(
            url: redirectURL(to: location, status: 307), method: .POST,
            headers: HTTPHeaders([("Api-Key", "Bearer header-key"), ("Authorization", "app-auth")]),
            body: .string("payload"))
        MiniSDKAttesterProxyController.clearCallLog()
        let reply = try XCTUnwrap(fetchNetworkReply(for: request))
        XCTAssertEqual(reply["url"] as? String, location, "the URL as the server sent it")
        XCTAssertEqual(reply["method"] as? String, "POST")
        XCTAssertEqual(reply["body"] as? String, "payload", "a 307 sends the body again")
        for name in ["Approov-Token", "Approov-TraceID", "Signature", "Signature-Input", "Content-Digest"] {
            XCTAssertNil(getHeader(from: reply, key: name), "\(name) must not reach another origin")
        }
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "Bearer header-key", "the placeholder as the app wrote it")
        XCTAssertNil(getHeader(from: reply, key: "Authorization"), "AsyncHTTPClient drops Authorization on another origin")
        let calls = MiniSDKAttesterProxyController.callLog()
        XCTAssertTrue(calls.contains { $0.hasPrefix("fetchApproovTokenAndWait:") && $0.contains("/redirect-to") }, "\(calls)")
        XCTAssertTrue(calls.contains("fetchSecureStringAndWait:header-key"), "the first hop was protected: \(calls)")
        XCTAssertTrue(calls.contains("fetchApproovTokenAndWait:\(location)"), "the hop is evaluated for its target: \(calls)")
        XCTAssertFalse(calls.contains("fetchSecureStringAndWait:query-key"), "the query of the server's target is never looked up: \(calls)")
    }

    // A redirect to a second protected host fetches a token for the target and never carries the first one.
    func testRedirectToASecondProtectedHostFetchesItsOwnToken() throws {
        let first = try XCTUnwrap(URL(string: targetURLString)?.host)
        let second = try XCTUnwrap(URL(string: unprotectedURLString)?.host)
        try reinitializeService(scenarioJSON: scenarioJSON(caseName: uniqueCaseName(prefix: "two-protected"), body: """
            "protectedDomains": ["\(first)", "\(second)"], "noApproovTokenDomains": []
            """), comment: "reinit-two-protected")
        ApproovService.setServiceMutator(signer())
        let location = "https://\(second)/second"
        let reply = try XCTUnwrap(fetchNetworkReply(for: HTTPClient.Request(url: redirectURL(to: location, status: 302),
                                                                             method: .GET)))
        XCTAssertEqual(reply["url"] as? String, location)
        let token = try XCTUnwrap(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertEqual(decodeJWTBody(token)?["aud"] as? String, second, "the target's own token")
        XCTAssertNotNil(getHeader(from: reply, key: "Signature"), "signed again for the target")
        XCTAssertNotNil(getHeader(from: reply, key: "Signature-Input"))
    }

    // A same-origin 303 is protected again and signed again over the new method and target.
    func testSameOrigin303IsProtectedAgainAsGET() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.setServiceMutator(signer())
        let location = targetURLString + "/after-303"
        let request = try HTTPClient.Request(url: redirectURL(to: location, status: 303), method: .POST,
                                             headers: HTTPHeaders([("Content-Type", "text/plain")]), body: .string("payload"))
        MiniSDKAttesterProxyController.clearCallLog()
        let reply = try XCTUnwrap(fetchNetworkReply(for: request))
        XCTAssertEqual(reply["url"] as? String, location)
        XCTAssertEqual(reply["method"] as? String, "GET")
        XCTAssertNil(getHeader(from: reply, key: "Content-Type"), "AsyncHTTPClient drops the body headers on a 303")
        XCTAssertNil(getHeader(from: reply, key: "Content-Digest"), "no body, no digest")
        XCTAssertNotNil(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertNotNil(getHeader(from: reply, key: "Signature"))
        XCTAssertEqual(MiniSDKAttesterProxyController.callLog().filter { $0.hasPrefix("fetchApproovTokenAndWait:") }.count, 2,
                       "each hop fetches its own token")
    }

    // The app's redirect settings apply, and the app's delegate sees one response head, the final one.
    func testRedirectSettingsAreTheApps() throws {
        try reinitializeServiceWithTargetHost()
        let location = targetURLString + "/final"
        let once = try redirectURL(to: location, status: 302)
        let twice = try redirectURL(to: once, status: 302)

        let disallow = ApproovHTTPClient(eventLoopGroupProvider: .createNew,
                                         configuration: HTTPClient.Configuration(redirectConfiguration: .disallow))
        defer { try? disallow.syncShutdown() }
        XCTAssertEqual(try disallow.execute(request: HTTPClient.Request(url: once, method: .GET)).wait().status, .found)

        let one = ApproovHTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClient.Configuration(redirectConfiguration: .follow(max: 1, allowCycles: false)))
        defer { try? one.syncShutdown() }
        XCTAssertEqual(try one.execute(request: HTTPClient.Request(url: once, method: .GET)).wait().status, .ok)
        XCTAssertThrowsError(try one.execute(request: HTTPClient.Request(url: twice, method: .GET)).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .redirectLimitReached)
        }

        let follows = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? follows.syncShutdown() }
        let heads = try follows.execute(request: HTTPClient.Request(url: twice, method: .GET), delegate: HeadRecorder()).wait()
        XCTAssertEqual(heads, [200])
    }

    // The mutator that the request started with decides every hop, also after setServiceMutator.
    func testOneMutatorDecidesEveryHop() throws {
        try reinitializeServiceWithTargetHost()
        let later = HopRecordingMutator()
        let first = HopRecordingMutator { _ in ApproovService.setServiceMutator(later) }
        ApproovService.setServiceMutator(first)
        let location = targetURLString + "/after-mutator-change"
        _ = try XCTUnwrap(fetchNetworkReply(for: HTTPClient.Request(url: redirectURL(to: location, status: 302), method: .GET)))
        let firstURLs = first.urls.withLockedValue { $0 }
        XCTAssertEqual(firstURLs.count, 2, "both hops: \(firstURLs)")
        XCTAssertEqual(firstURLs.last, location)
        XCTAssertEqual(later.urls.withLockedValue { $0 }, [], "a later mutator never decides a hop of this request")
    }

    // cancel() works across hops: a cancel while the second hop is processed stops the request.
    func testCancelStopsTheNextHop() throws {
        try reinitializeServiceWithTargetHost()
        let location = targetURLString + "/never-sent"
        let cancel = NIOLockedValueBox<(() -> Void)?>(nil)
        ApproovService.setServiceMutator(HopRecordingMutator { request in
            if request.url.absoluteString == location {
                cancel.withLockedValue { $0 }?()
            }
        })
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }
        let request = try HTTPClient.Request(url: redirectURL(to: location, status: 302), method: .GET)
        let task = client.execute(request: request, delegate: ResponseAccumulator(request: request))
        cancel.withLockedValue { $0 = { task.cancel() } }
        XCTAssertThrowsError(try task.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    // The same redirect rules on the async API. A body that can be sent only once is not sent again.
    func testAsyncAPIFollowsRedirectsAsNewRequests() throws {
        try redirectScenario()
        let unprotected = try XCTUnwrap(URL(string: unprotectedURLString)?.host)
        let location = "https://\(unprotected)/landing-async?k=query-key"
        let url = try redirectURL(to: location, status: 307)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }

        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers = HTTPHeaders([("Api-Key", "Bearer header-key")])
        request.body = .bytes(ByteBuffer(string: "payload"))
        MiniSDKAttesterProxyController.clearCallLog()
        let sent = request
        let followed = try blockingResult { () -> (UInt, Data) in
            let response = try await client.execute(sent, timeout: .seconds(20))
            var data = Data()
            for try await buffer in response.body {
                data.append(contentsOf: buffer.readableBytesView)
            }
            return (response.status.code, data)
        }.get()
        XCTAssertEqual(followed.0, 200)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: followed.1) as? [String: Any])
        XCTAssertEqual(reply["url"] as? String, location, "the URL as the server sent it")
        XCTAssertEqual(reply["body"] as? String, "payload")
        XCTAssertNil(getHeader(from: reply, key: "Approov-Token"))
        XCTAssertEqual(getHeader(from: reply, key: "Api-Key"), "Bearer header-key", "the placeholder as the app wrote it")
        XCTAssertFalse(MiniSDKAttesterProxyController.callLog().contains("fetchSecureStringAndWait:query-key"))

        var streamed = request
        streamed.body = .stream(AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "payload"))
            continuation.finish()
        }, length: .known(7))
        let once = streamed
        let status = try blockingResult { try await client.execute(once, timeout: .seconds(20)).status.code }.get()
        XCTAssertEqual(status, 307, "a body that can be sent only once is not sent again, as in AsyncHTTPClient")
    }

    // WebSockets are not supported. An upgrade request goes out untouched, with no fetch.
    func testWebSocketUpgradeIsForwardedUntouched() throws {
        try secureStringScenario()
        ApproovService.setServiceMutator(signer())
        MiniSDKAttesterProxyController.clearCallLog()
        let headers = HTTPHeaders([("Connection", "Upgrade"), ("Upgrade", "WebSocket"), ("Api-Key", "Bearer header-key")])
        let url = targetURLString + "/ws?k=query-key"
        let response = ApproovService.updateRequestWithApproov(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: url)), method: "GET", headers: headers))
        XCTAssertEqual(response.decision, .ShouldIgnore)
        XCTAssertEqual(response.request.headers, headers, "no token, trace, signature or substitution")
        XCTAssertEqual(response.request.url.absoluteString, url)
        XCTAssertEqual(MiniSDKAttesterProxyController.callLog().filter { $0.hasPrefix("fetch") }, [], "no fetch")
    }

    // MARK: - Message Signing

    func testAuthorityIsLowercaseWithANonDefaultPort() throws {
        func authority(_ url: String) throws -> String {
            ApproovAsyncHTTPClientComponentProvider(request: ApproovRequest(
                url: try XCTUnwrap(URL(string: url)), method: "GET", headers: HTTPHeaders())).getAuthority()
        }
        XCTAssertEqual(try authority("https://Example.COM:8443/p"), "example.com:8443")
        XCTAssertEqual(try authority("https://example.com:443/p"), "example.com", "default port left out (RFC 9421 2.2.3)")
        XCTAssertEqual(try authority("http://example.com:80/p"), "example.com")
    }

    func testHostFactoryMatchesTheNormalisedHost() throws {
        try reinitializeServiceWithTargetHost()
        let host = try XCTUnwrap(URL(string: targetURLString)?.host)
        let accountOnly = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory().setUseAccountMessageSigning()
        let signer = ApproovDefaultMessageSigning()
            .setDefaultFactory(ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory())
            .putHostFactory(hostName: host.uppercased() + ".", factory: accountOnly)
        let response = try decide(targetURLString, mutator: signer)
        XCTAssertTrue(try XCTUnwrap(response.request.headers.first(name: "Signature")).hasPrefix("account=:"))
    }

    private final class TargetURIRecorder: ApproovServiceMutator {
        let signed = NIOLockedValueBox<String?>(nil)
        func handleInterceptorProcessedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
            signed.withLockedValue { $0 = ApproovAsyncHTTPClientComponentProvider(request: request).getTargetUri() }
            return request
        }
    }

    // The signed @target-uri equals the URL the server receives.
    func testTargetURIIsTheWireURL() async throws {
        try reinitializeServiceWithTargetHost()
        let url = targetURLString + "/p/a%20b?q=x|y&s=%20&p=%25&n=\u{00E9}"
        let recorder = TargetURIRecorder()
        ApproovService.setServiceMutator(recorder)

        let legacy = fetchNetworkReply(for: try HTTPClient.Request(url: url, method: .GET))
        XCTAssertNotNil(legacy?["url"] as? String, "control: the echo carries the URL it received")
        XCTAssertEqual(recorder.signed.withLockedValue { $0 }, legacy?["url"] as? String, "HTTPClient.Request API")

        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }
        let response = try await client.execute(HTTPClientRequest(url: url), timeout: .seconds(30))
        var collected = ByteBuffer()
        for try await var part in response.body { collected.writeBuffer(&part) }
        let echo = try JSONSerialization.jsonObject(with: Data(collected.readableBytesView)) as? [String: Any]
        XCTAssertNotNil(echo?["url"] as? String, "control: the echo carries the URL it received")
        XCTAssertEqual(recorder.signed.withLockedValue { $0 }, echo?["url"] as? String, "HTTPClientRequest API")
    }

    // A failure that proceeds to a listed host is signed over the token header as sent.
    func testFailureThatProceedsIsSigned() throws {
        try reinitializeServiceWithTargetHost()
        final class AlwaysProceedSigner: ApproovDefaultMessageSigning {
            override func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool { true }
        }
        let signer = AlwaysProceedSigner().setDefaultFactory(ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory())
        let response = try decide(targetURLString, tokenStatus: "NO_NETWORK", mutator: signer)
        XCTAssertEqual(response.request.headers.first(name: "Approov-Token"), "")
        XCTAssertTrue(try XCTUnwrap(response.request.headers.first(name: "Signature-Input")).contains("\"approov-token\""))
    }

    // A token header the app set itself is not the layer's, so it is not signed.
    func testAppSetTokenHeaderIsNotSigned() throws {
        let unprotected = try XCTUnwrap(URL(string: unprotectedURLString)?.host)
        try reinitializeServiceWithTargetHost(scenarioBody: "\"noApproovTokenDomains\": [\"\(unprotected)\"]")
        let response = try decide(unprotectedURLString, mutator: signer(),
                                  headers: HTTPHeaders([("Approov-Token", "set-by-the-app")]))
        XCTAssertNil(response.request.headers.first(name: "Signature"), "a secrets-only request is never signed")
    }

    private func signer(_ configure: (SignatureParametersFactory) -> Void = { _ in }) -> ApproovDefaultMessageSigning {
        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
        configure(factory)
        return ApproovDefaultMessageSigning().setDefaultFactory(factory)
    }

    // The three out-of-the-box signing states.
    func testSigningStates() throws {
        try reinitializeServiceWithTargetHost()
        XCTAssertNil(try decide(targetURLString).request.headers.first(name: "Signature"), "off out of the box")

        let install = try decide(targetURLString, mutator: signer())
        let installSignature = try XCTUnwrap(install.request.headers.first(name: "Signature"))
        XCTAssertTrue(installSignature.hasPrefix("install=:"))
        XCTAssertFalse(installSignature.contains("account="), "the default factory gives install only")

        let both = try decide(targetURLString, mutator: signer { $0.setUseInstallAndAccountMessageSigning() })
        let bothSignature = try XCTUnwrap(both.request.headers.first(name: "Signature"))
        let bothInput = try XCTUnwrap(both.request.headers.first(name: "Signature-Input"))
        XCTAssertTrue(bothSignature.contains("install=:") && bothSignature.contains("account=:"), bothSignature)
        XCTAssertTrue(bothInput.contains("alg=\"ecdsa-p256-sha256\"") && bothInput.contains("alg=\"hmac-sha256\""), bothInput)

        ApproovService.setServiceMutator(signer())
        try ApproovService.initialize(config: validInitialConfig, comment: "reinit-signing-off")
        let afterInit = ApproovService.updateRequestWithApproov(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: targetURLString)), method: "GET", headers: HTTPHeaders()))
        XCTAssertNil(afterInit.request.headers.first(name: "Signature"), "initialize turns signing off")
    }

    // With both selected, a member that cannot be produced is left out.
    func testOneMemberFailsOpen() throws {
        try reinitializeService(scenarioJSON: scenarioJSON(caseName: uniqueCaseName(prefix: "no-install-key"),
                                                          body: "\"protectedDomains\": [\"\(try XCTUnwrap(URL(string: targetURLString)?.host))\"]"),
                                comment: "options:no-install-key")
        let response = try decide(targetURLString, mutator: signer { $0.setUseInstallAndAccountMessageSigning() })
        let signature = try XCTUnwrap(response.request.headers.first(name: "Signature"), "the account member still signs")
        XCTAssertTrue(signature.hasPrefix("account=:"))
        XCTAssertFalse(signature.contains("install="))
    }

    private func signatureCreated(_ response: ApproovUpdateResponse) throws -> Int64 {
        let input = try XCTUnwrap(response.request.headers.first(name: "Signature-Input"))
        let range = try XCTUnwrap(input.range(of: #"created=(\d+)"#, options: .regularExpression))
        return try XCTUnwrap(Int64(input[range].dropFirst("created=".count)))
    }

    func testSignatureTimesFollowTheServerAdjustedClock() throws {
        try reinitializeServiceWithTargetHost()
        MiniSDKAttesterProxyController.setServerTimeOffsetMS(3_600_000)
        defer { MiniSDKAttesterProxyController.setServerTimeOffsetMS(0) }
        let signer = ApproovDefaultMessageSigning()
            .setDefaultFactory(ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory())
        let response = try decide(targetURLString, mutator: signer)
        let created = try signatureCreated(response)
        let deviceNow = Int64(Date().timeIntervalSince1970)
        XCTAssertLessThan(abs(created - (deviceNow + 3600)), 10, "created follows the server adjusted time")
        let input = try XCTUnwrap(response.request.headers.first(name: "Signature-Input"))
        XCTAssertTrue(input.contains("expires=\(created + 15)"), "expires is created plus the lifetime")
    }

    func testGetServerAdjustedCurrentTimeMS() throws {
        try reinitializeServiceWithTargetHost()
        MiniSDKAttesterProxyController.setServerTimeOffsetMS(60_000)
        defer { MiniSDKAttesterProxyController.setServerTimeOffsetMS(0) }
        let deviceNowMS = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(try ApproovService.getServerAdjustedCurrentTimeMS() - (deviceNowMS + 60_000)), 5_000)
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: nil)
        XCTAssertThrowsError(try ApproovService.getServerAdjustedCurrentTimeMS()) { error in
            guard case let ApproovError.permanentError(message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(message, "getServerAdjustedCurrentTimeMS: SDK not initialized")
        }
    }

    func testTargetUriOmitsFragment() throws {
        let provider = ApproovAsyncHTTPClientComponentProvider(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/p?q=1#frag")), method: "GET", headers: HTTPHeaders()))
        // The target URI as the stack sends it, without the fragment.
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

    func testBodyIsNotReadWhenNoBodyDigestIsComputed() throws {
        try reinitializeServiceWithTargetHost()
        // A one-shot source with a known length: it has the bytes only on the first call.
        let calls = NIOLockedValueBox(0)
        let body = HTTPClient.Body.stream(length: 5) { writer in
            let first = calls.withLockedValue { count -> Bool in
                count += 1
                return count == 1
            }
            return writer.write(.byteBuffer(ByteBuffer(string: first ? "hello" : "")))
        }
        let request = try HTTPClient.Request(url: targetURLString, method: .POST, body: body)
        let client = ApproovHTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? client.syncShutdown() }
        // The default mutator does not sign, so nothing needs the body bytes before the send.
        XCTAssertNoThrow(try client.execute(request: request).wait())
        XCTAssertEqual(calls.withLockedValue { $0 }, 1, "the layer must not call the body closure before the send")
    }

    func testSignRequestDoesNotReadBodyWithoutBodyDigest() throws {
        try reinitializeServiceWithTargetHost()
        let calls = NIOLockedValueBox(0)
        let body = HTTPClient.Body.stream(length: 5) { writer in
            calls.withLockedValue { $0 += 1 }
            return writer.write(.byteBuffer(ByteBuffer(string: "hello")))
        }
        let request = try HTTPClient.Request(url: targetURLString, method: .POST, body: body)
        // The default mutator does not sign, so signRequest has no use for the body bytes.
        let signed = try ApproovService.signRequest(request)
        XCTAssertNotNil(signed.headers.first(name: "Approov-Token"))
        XCTAssertEqual(calls.withLockedValue { $0 }, 0, "signRequest must not call the body closure without a body digest")
    }

    func testBodyDigestReadsBodyOnceBeforeTheSend() throws {
        try reinitializeServiceWithTargetHost()
        let factory = try ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: true)
        ApproovService.setServiceMutator(ApproovDefaultMessageSigning().setDefaultFactory(factory))
        // A repeatable source: each call writes the same bytes.
        let calls = NIOLockedValueBox(0)
        let body = HTTPClient.Body.stream(length: 5) { writer in
            calls.withLockedValue { $0 += 1 }
            return writer.write(.byteBuffer(ByteBuffer(string: "hello")))
        }
        let request = try HTTPClient.Request(url: targetURLString, method: .POST, body: body)

        let reply = fetchNetworkReply(for: request)

        let expected = Data(SHA256.hash(data: Data("hello".utf8))).base64EncodedString()
        XCTAssertEqual(getHeader(from: reply, key: "Content-Digest"), "sha-256=:\(expected):")
        let signatureInput = try XCTUnwrap(getHeader(from: reply, key: "Signature-Input"))
        XCTAssertTrue(signatureInput.contains("content-digest"), signatureInput)
        XCTAssertEqual(calls.withLockedValue { $0 }, 2, "one call for the body digest and one call for the send")
    }

    func testApproovRequestBodyProviderIsEvaluatedAtMostOnce() throws {
        let calls = NIOLockedValueBox(0)
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        let request = ApproovRequest(url: url, method: "POST", headers: HTTPHeaders(), bodyProvider: {
            calls.withLockedValue { $0 += 1 }
            return Data("hello".utf8)
        })
        XCTAssertEqual(calls.withLockedValue { $0 }, 0, "creating the request must not read the body")

        var copy = request
        XCTAssertEqual(copy.body, Data("hello".utf8))
        XCTAssertEqual(request.body, Data("hello".utf8))
        XCTAssertEqual(calls.withLockedValue { $0 }, 1, "copies share one read")

        copy.body = Data("other".utf8)
        XCTAssertEqual(copy.body, Data("other".utf8))
        XCTAssertEqual(request.body, Data("hello".utf8), "a set changes only that copy")
        XCTAssertEqual(calls.withLockedValue { $0 }, 1)
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

    // MARK: - Secure Strings & Custom JWT

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
            XCTAssertTrue(message.contains("BAD_KEY"), "Expected bad key message")  // Status names, not SDK prose
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
            XCTAssertEqual(message, "fetchCustomJWT: DISABLED")  // Status names, not SDK prose
        }
    }

    func testFetchCustomJWTBadPayloadRaisesPermanentError() {
        XCTAssertThrowsError(try ApproovService.fetchCustomJWT(payload: "not-json")) { error in
            guard case let ApproovError.permanentError(message) = error else {
                return XCTFail("Expected permanentError, got \(error)")
            }
            XCTAssertEqual(message, "fetchCustomJWT: BAD_PAYLOAD")  // Status names, not SDK prose
        }
    }

    // MARK: - Reinitialization

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

        // The SDK refuses a different comment, and the layer returns that error unchanged.
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
        
        ApproovService.setTokenHeader(header: "Custom-Token", prefix: "CustomPrefix ")
        ApproovService.setTraceIDHeader(header: "Custom-TraceID")
        
        let request = try HTTPClient.Request(url: targetURLString, method: .GET)
        let protectedReply = fetchNetworkReply(for: request)
        
        XCTAssertNotNil(protectedReply, "Expected request to succeed")
        let customToken = getHeader(from: protectedReply, key: "Custom-Token")
        XCTAssertNotNil(customToken)
        XCTAssertTrue(customToken?.hasPrefix("CustomPrefix ") ?? false)
        XCTAssertNotNil(getHeader(from: protectedReply, key: "Custom-TraceID"))
        
        // Test null/nil prefix treated as empty string
        ApproovService.setTokenHeader(header: "Custom-Token", prefix: nil)
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
        
        // The token header is present and empty. The trace header is sent only when the SDK
        // supplied a trace ID, so an empty trace ID leaves it out (3.5.x sent it empty).
        let token = getHeader(from: protectedReply, key: "Approov-Token")
        let trace = getHeader(from: protectedReply, key: "Approov-TraceID")
        XCTAssertEqual(token, "")
        XCTAssertNil(trace)
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
        // A key with no value is UNKNOWN_KEY, which is not a secure string key, so the value stays as the app wrote it.
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

        // A required digest that cannot be created is a configuration error, the layer's
        // network error, URLError on iOS (3.5.x threw ApproovError.permanentError).
        XCTAssertThrowsError(try client.execute(request: request).wait()) { error in
            XCTAssertEqual((error as? URLError)?.code, .unknown, "got \(error)")
            XCTAssertTrue(error.localizedDescription.contains("required body digest"), "got \(error)")
        }
    }

    // MARK: - Request Decisions

    private func decide(_ url: String, tokenStatus: String? = nil, secureStringStatus: String? = nil,
                        mutator: ApproovServiceMutator? = nil, useStatus: Bool = false,
                        headers: HTTPHeaders = HTTPHeaders()) throws -> ApproovUpdateResponse {
        ApproovService.setServiceMutator(mutator)
        ApproovService.setUseApproovStatusIfNoToken(shouldUse: useStatus)
        if let tokenStatus {
            setDirective(#"{ "operation": "fetchApproovToken", "response": { "status": "\#(tokenStatus)" } }"#)
        }
        if let secureStringStatus {
            setDirective(#"{ "operation": "fetchSecureString", "response": { "status": "\#(secureStringStatus)" } }"#)
        }
        return ApproovService.updateRequestWithApproov(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: url)), method: "GET", headers: headers))
    }

    // Token decisions for a listed host.
    func testTokenDecisionTablesForAListedHost() throws {
        try reinitializeServiceWithTargetHost()
        let network = ["NO_NETWORK", "POOR_NETWORK", "MITM_DETECTED"]
        let fatal = ["BAD_URL", "NOT_INITIALIZED", "REJECTED", "DISABLED", "UNKNOWN_KEY", "BAD_KEY", "BAD_PAYLOAD", "INTERNAL_ERROR"]
        let mutators: [(String, ApproovServiceMutator)] = [("CLOSE_FAILURE", ApproovCloseFailureMutator.CLOSE_FAILURE),
                                                           ("ALWAYS_PROCEED", ApproovAlwaysProceedMutator.ALWAYS_PROCEED)]
        for (name, mutator) in mutators {
            for useStatus in [false, true] {
                for status in ["NO_APPROOV_SERVICE"] + network + fatal {
                    let row = "\(name) useStatus=\(useStatus) \(status)"
                    let response = try decide(targetURLString, tokenStatus: status, mutator: mutator, useStatus: useStatus)
                    let aborts = name == "CLOSE_FAILURE" && (fatal.contains(status) || (network.contains(status) && !useStatus))
                    if aborts {
                        XCTAssertNotEqual(response.decision, .ShouldProceed, row)
                        if network.contains(status) {
                            guard case ApproovError.networkingError? = response.error else { XCTFail("\(row): \(String(describing: response.error))"); continue }
                            XCTAssertEqual(response.decision, .ShouldRetry, row)
                        } else {
                            guard case ApproovError.permanentError(let message)? = response.error else { XCTFail("\(row): \(String(describing: response.error))"); continue }
                            XCTAssertEqual(message, "Approov token fetch for \(targetURLString): \(status)", row)
                        }
                    } else {
                        XCTAssertEqual(response.decision, .ShouldProceed, row)
                        XCTAssertNil(response.error, row)
                        XCTAssertEqual(response.request.headers.first(name: "Approov-Token"), useStatus ? status : "", row)
                    }
                }
                for status in ["UNKNOWN_URL", "UNPROTECTED_URL"] {
                    let response = try decide(targetURLString, tokenStatus: status, mutator: mutator, useStatus: useStatus)
                    XCTAssertEqual(response.decision, .ShouldProceed, status)
                    XCTAssertNil(response.request.headers.first(name: "Approov-Token"), "\(name) \(status): no token header")
                }
                let success = try decide(targetURLString, mutator: mutator, useStatus: useStatus)
                XCTAssertFalse(try XCTUnwrap(success.request.headers.first(name: "Approov-Token")).isEmpty, "\(name) SUCCESS")
            }
        }
    }

    // A failure for a host that is not listed, or with no pins map, goes out untouched.
    func testFailureForAHostThatIsNotListedGoesOutUntouched() throws {
        try reinitializeServiceWithTargetHost()
        for mutator in [ApproovCloseFailureMutator.CLOSE_FAILURE as ApproovServiceMutator,
                        ApproovAlwaysProceedMutator.ALWAYS_PROCEED] {
            for status in ["NO_NETWORK", "REJECTED", "NO_APPROOV_SERVICE"] {
                let response = try decide(unprotectedURLString, tokenStatus: status, mutator: mutator, useStatus: true)
                XCTAssertEqual(response.decision, .ShouldProceed, "\(mutator) \(status)")
                XCTAssertNil(response.error)
                XCTAssertNil(response.request.headers.first(name: "Approov-Token"), "\(mutator) \(status): untouched")
            }
        }
        MiniSDKAttesterProxyController.setPinsUnavailable(true)
        defer { MiniSDKAttesterProxyController.setPinsUnavailable(false) }
        let response = try decide(targetURLString, tokenStatus: "REJECTED", mutator: ApproovCloseFailureMutator.CLOSE_FAILURE)
        XCTAssertEqual(response.decision, .ShouldProceed, "with no pins map no host is listed")
        XCTAssertNil(response.request.headers.first(name: "Approov-Token"))
    }

    private struct ThrowingFetchMutator: ApproovServiceMutator {
        let error: Error
        func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool { throw error }
    }

    private struct InheritingMutator: ApproovServiceMutator {}

    // An app abort is a URLError, a standard decision keeps its ApproovError.
    func testHookErrorsOnTheRequestPath() throws {
        try reinitializeServiceWithTargetHost()
        let abort = try decide(unprotectedURLString, tokenStatus: "NO_NETWORK",
                               mutator: ThrowingFetchMutator(error: URLError(.notConnectedToInternet)))
        XCTAssertEqual((abort.error as? URLError)?.code, .notConnectedToInternet, "a custom throw aborts even an unlisted host")

        struct AppError: Error {}
        let wrapped = try decide(targetURLString, mutator: ThrowingFetchMutator(error: AppError()))
        XCTAssertEqual((wrapped.error as? URLError)?.code, .unknown)
        XCTAssertTrue((wrapped.error as NSError?)?.userInfo[NSUnderlyingErrorKey] is AppError)

        let inherited = try decide(targetURLString, tokenStatus: "REJECTED", mutator: InheritingMutator())
        guard case ApproovError.permanentError? = inherited.error else {
            return XCTFail("an inherited standard decision keeps its ApproovError, got \(String(describing: inherited.error))")
        }
    }

    func testTokenPrefixThatAHeaderCannotCarryIsAConfigurationError() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.setTokenHeader(header: "Authorization", prefix: "Bearer\n")
        let response = try decide(targetURLString)
        XCTAssertEqual((response.error as? URLError)?.code, .unknown)
        XCTAssertFalse((response.error?.localizedDescription ?? "").contains("Bearer\n"))
    }

    /// A URL on the echo worker that answers with a redirect to `target`, a sibling host of the worker.
    private func redirectURL(to target: String, status: Int) throws -> String {
        let host = try XCTUnwrap(URL(string: targetURLString)?.host)
        let encoded = try XCTUnwrap(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        return "https://\(host)/redirect-to?url=\(encoded)&status=\(status)"
    }

    /// The target host is protected and has secure strings. The unprotected host is not added to Approov, so the SDK
    /// answers UNKNOWN_URL for it.
    private func redirectScenario() throws {
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "noApproovTokenDomains": [],
            "initialSecureStrings": { "header-key": "header-secret", "query-key": "query-secret" }
            """)
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: "Bearer ")
        ApproovService.addSubstitutionQueryParam(key: "k")
    }

    private func secureStringScenario() throws {
        let unprotected = try XCTUnwrap(URL(string: unprotectedURLString)?.host)
        try reinitializeServiceWithTargetHost(scenarioBody: """
            "noApproovTokenDomains": ["\(unprotected)"],
            "initialSecureStrings": { "header-key": "header-secret", "query-key": "query-secret", "amp-key": "a&b" }
            """)
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: "Bearer ")
        ApproovService.addSubstitutionQueryParam(key: "k")
    }

    // On a protected channel a status other than SUCCESS is written into the placeholder.
    func testSecureStringStatusIsWrittenIntoThePlaceholder() throws {
        try secureStringScenario()
        let success = try decide(targetURLString, headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
        XCTAssertEqual(success.request.headers.first(name: "Api-Key"), "Bearer header-secret")
        let unknown = try decide(targetURLString, headers: HTTPHeaders([("Api-Key", "Bearer no-such-key")]))
        XCTAssertEqual(unknown.request.headers.first(name: "Api-Key"), "Bearer no-such-key", "UNKNOWN_KEY leaves the value")
        XCTAssertNil(unknown.error)
        for status in ["REJECTED", "NO_NETWORK", "INTERNAL_ERROR"] {
            let response = try decide(targetURLString, secureStringStatus: status,
                                      headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
            XCTAssertEqual(response.decision, .ShouldProceed, status)
            XCTAssertEqual(response.request.headers.first(name: "Api-Key"), "Bearer \(status)", status)
            XCTAssertFalse(try XCTUnwrap(response.request.headers.first(name: "Approov-Token")).isEmpty, "token present")
        }
    }

    // No secure string on a failure status, on http or on UNKNOWN_URL; no fetch at all.
    func testNoSecureStringWithoutAProtectedChannel() throws {
        try secureStringScenario()
        let headers = HTTPHeaders([("Api-Key", "Bearer header-key")])
        MiniSDKAttesterProxyController.clearCallLog()
        let failure = try decide(targetURLString, tokenStatus: "NO_NETWORK",
                                 mutator: ApproovAlwaysProceedMutator.ALWAYS_PROCEED, headers: headers)
        XCTAssertEqual(failure.request.headers.first(name: "Api-Key"), "Bearer header-key")
        let http = try decide(targetURLString.replacingOccurrences(of: "https://", with: "http://"), headers: headers)
        XCTAssertEqual(http.request.headers.first(name: "Api-Key"), "Bearer header-key")
        let unknownURL = try decide(targetURLString, tokenStatus: "UNKNOWN_URL", headers: headers)
        XCTAssertEqual(unknownURL.request.headers.first(name: "Api-Key"), "Bearer header-key")
        XCTAssertFalse(MiniSDKAttesterProxyController.callLog().contains { $0.hasPrefix("fetchSecureString") },
                       "no secure string is fetched there")
    }

    // A secrets-only API gets its secure strings and no token or trace header.
    func testSecretsOnlyAPIGetsSecureStringsAndNoToken() throws {
        try secureStringScenario()
        let response = try decide(unprotectedURLString + "/p?k=query-key",
                                  headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
        XCTAssertEqual(response.request.headers.first(name: "Api-Key"), "Bearer header-secret")
        XCTAssertEqual(URLComponents(url: response.request.url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "k" }?.value, "query-secret")
        XCTAssertNil(response.request.headers.first(name: "Approov-Token"))
        XCTAssertNil(response.request.headers.first(name: "Approov-TraceID"))
    }

    // A value that is not a secure string key (UNKNOWN_KEY) is the app's own and is left as the app wrote it, as in 3.5.x.
    func testAValueThatIsNotAKeyIsLeftUntouched() throws {
        try secureStringScenario()
        let response = try decide(targetURLString + "/a?k=not-a-key",
                                  headers: HTTPHeaders([("Api-Key", "Bearer user-session-token")]))
        XCTAssertEqual(response.decision, .ShouldProceed)
        XCTAssertEqual(response.request.headers.first(name: "Api-Key"), "Bearer user-session-token")
        XCTAssertEqual(response.request.url.absoluteString, targetURLString + "/a?k=not-a-key")
    }

    // Every query occurrence on its own; a value the URL cannot carry keeps the placeholder.
    func testQuerySubstitutionEveryOccurrenceAndCarriability() throws {
        try secureStringScenario()
        let response = try decide(targetURLString + "/p?k=query-key&x=1&k=amp-key&k=no-such-key")
        let query = try XCTUnwrap(response.request.url.query)
        XCTAssertEqual(query, "k=query-secret&x=1&k=amp-key&k=no-such-key",
                       "a value with & cannot be carried, so its placeholder stays, and UNKNOWN_KEY leaves the value")
    }

    // Non-delivery and failure lines are DEBUG only and carry no secret.
    func testNonDeliveryLinesAreDebugOnly() throws {
        try secureStringScenario()
        let infoLines = try captureLogs(level: .info) {
            _ = try decide(targetURLString, secureStringStatus: "REJECTED", headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
            _ = try decide(targetURLString, tokenStatus: "NO_NETWORK", mutator: ApproovAlwaysProceedMutator.ALWAYS_PROCEED)
        }
        XCTAssertFalse(infoLines.contains { $0.1.contains("substitution") || $0.1.contains("proceeds") }, "\(infoLines)")
        let debugLines = try captureLogs(level: .debug) {
            _ = try decide(targetURLString, headers: HTTPHeaders([("Api-Key", "Bearer header-key")]))
        }
        XCTAssertTrue(debugLines.contains { $0.0 == .debug && $0.1.contains("header substitution: Api-Key") }, "control")
        XCTAssertFalse(debugLines.contains { $0.1.contains("header-secret") }, "no line carries a secret")
    }

    private final class SwitchingMutator: ApproovServiceMutator {
        func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
            ApproovService.setServiceMutator(ApproovAlwaysProceedMutator.ALWAYS_PROCEED)
            return true
        }
        func handleInterceptorProcessedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
            var marked = request
            marked.headers.replaceOrAdd(name: "X-Mutator", value: "first")
            return marked
        }
    }

    func testOneRequestOneMutator() throws {
        try reinitializeServiceWithTargetHost()
        let response = try decide(targetURLString, mutator: SwitchingMutator())
        XCTAssertEqual(response.request.headers.first(name: "X-Mutator"), "first",
                       "a mutator change during a request does not reach that request")
        XCTAssertTrue(ApproovService.getServiceMutator() is ApproovAlwaysProceedMutator, "control: the change applies later")
    }

    // MARK: - Logging

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
        XCTAssertFalse(lines.contains { $0.1.contains(rootPin) }, "no line carries a pin")
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
        var status: HTTPResponseStatus?
        do {
            let response = try client.execute(request: request).wait()
            status = response.status
            if let body = response.body {
                receivedData = body.getData(at: body.readerIndex, length: body.readableBytes)
            }
        } catch {
            print("Request failed with error: \(error)")
        }
        guard let data = receivedData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A reply that is not the echo worker's JSON: record what came back, so that a failure in CI can
            // be told apart from a fault in the layer.
            if let status {
                let snippet = String(decoding: (receivedData ?? Data()).prefix(200), as: UTF8.self)
                print("Echo reply is not JSON: \(request.method) \(request.url.absoluteString) -> HTTP \(status.code): \(snippet)")
            }
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
        var status: HTTPResponseStatus?
        do {
            let response = try client.execute(request: request).wait()
            status = response.status
            if let body = response.body {
                receivedData = body.getData(at: body.readerIndex, length: body.readableBytes)
            }
        } catch {
            print("Request failed with error: \(error)")
        }
        guard let data = receivedData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A reply that is not the echo worker's JSON: record what came back, so that a failure in CI can
            // be told apart from a fault in the layer.
            if let status {
                let snippet = String(decoding: (receivedData ?? Data()).prefix(200), as: UTF8.self)
                print("Echo reply is not JSON: \(request.method) \(request.url.absoluteString) -> HTTP \(status.code): \(snippet)")
            }
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

/// Records the status of every response head that a delegate receives.
private final class HeadRecorder: HTTPClientResponseDelegate {
    typealias Response = [UInt]
    private let statuses = NIOLockedValueBox<[UInt]>([])

    func didReceiveHead(task: HTTPClient.Task<[UInt]>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        statuses.withLockedValue { $0.append(head.status.code) }
        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didFinishRequest(task: HTTPClient.Task<[UInt]>) throws -> [UInt] {
        statuses.withLockedValue { $0 }
    }
}

/// A service mutator that records each request it is asked about and runs an action on it.
private final class HopRecordingMutator: ApproovServiceMutator {
    let urls = NIOLockedValueBox<[String]>([])
    private let onRequest: (ApproovRequest) -> Void

    init(onRequest: @escaping (ApproovRequest) -> Void = { _ in }) {
        self.onRequest = onRequest
    }

    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool {
        urls.withLockedValue { $0.append(request.url.absoluteString) }
        onRequest(request)
        return true
    }
}

// MARK: - Token binding

/// Token binding. The SDK holds one binding value for the process, so the layer sets the value of the binding
/// header and fetches the token as one step, and each token carries the value of its own request. Requests
/// without the binding header do not wait for that step.
extension ApproovServiceMiniSDKTests {
    private func bound(_ value: String, header: String = "Authorization", path: String = "/binding") throws -> ApproovRequest {
        return ApproovRequest(url: try XCTUnwrap(URL(string: targetURLString + path)), method: "GET",
                              headers: HTTPHeaders([(header, value)]))
    }

    func testConcurrentRequestsEachGetATokenBoundToTheirOwnValue() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.bindHeader = "Authorization"
        let count = 10
        let rounds = 20
        var mismatches: [String] = []
        for round in 0..<rounds {
            let requests = try (0..<count).map { try bound("Bearer value-\(round)-\($0)") }
            let tokens = NIOLockedValueBox<[String?]>([String?](repeating: nil, count: count))
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let response = ApproovService.updateRequestWithApproov(request: requests[index])
                let token = response.request.headers.first(name: "Approov-Token")
                tokens.withLockedValue { $0[index] = token }
            }
            for index in 0..<count {
                let value = "Bearer value-\(round)-\(index)"
                let token = try XCTUnwrap(tokens.withLockedValue { $0[index] }, "no token for \(value)")
                if decodeJWTBody(token)?["pay"] as? String != sha256Base64(value) {
                    mismatches.append(value)
                }
            }
        }
        XCTAssertEqual(mismatches, [], "\(mismatches.count) of \(count * rounds) tokens were bound to another request's value")
    }

    func testTheBindingHeaderIsFoundWithoutRegardToCase() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.bindHeader = "authorization"
        MiniSDKAttesterProxyController.clearCallLog()
        let response = ApproovService.updateRequestWithApproov(request: try bound("Bearer mixed-case"))
        let token = try XCTUnwrap(response.request.headers.first(name: "Approov-Token"))
        XCTAssertEqual(decodeJWTBody(token)?["pay"] as? String, sha256Base64("Bearer mixed-case"))
        XCTAssertEqual(MiniSDKAttesterProxyController.callLog().filter { $0.hasPrefix("setDataHashInToken:") },
                       ["setDataHashInToken:Bearer mixed-case"])
    }

    func testOnlyARequestWithTheBindingHeaderWaitsForTheBindingStep() throws {
        try reinitializeServiceWithTargetHost()
        ApproovService.bindHeader = "Authorization"
        // the binding step is held, as a slow token fetch for a bound request would hold it
        ApproovService.bindingLock.lock()
        var held = true
        defer {
            if held {
                ApproovService.bindingLock.unlock()
            }
        }
        let unbound = expectation(description: "unbound request")
        let boundDone = expectation(description: "bound request")
        let unboundRequest = ApproovRequest(url: try XCTUnwrap(URL(string: targetURLString + "/unbound")), method: "GET",
                                            headers: HTTPHeaders())
        let boundRequest = try bound("Bearer waiting")
        let boundFinished = NIOLockedValueBox(false)
        DispatchQueue.global().async {
            _ = ApproovService.updateRequestWithApproov(request: unboundRequest)
            unbound.fulfill()
        }
        DispatchQueue.global().async {
            _ = ApproovService.updateRequestWithApproov(request: boundRequest)
            boundFinished.withLockedValue { $0 = true }
            boundDone.fulfill()
        }
        wait(for: [unbound], timeout: 10)
        XCTAssertFalse(boundFinished.withLockedValue { $0 }, "a bound request did not wait for the binding step")
        ApproovService.bindingLock.unlock()
        held = false
        wait(for: [boundDone], timeout: 10)
    }
}

// MARK: - Signer under the decisions of another mutator

/// The signer under the decisions of another mutator. The signer makes the given mutator's decisions at every
/// hook and signs the request that mutator processed, so a change it makes is covered by the signature. init()
/// is unchanged: it makes the CLOSE_FAILURE decisions.
extension ApproovServiceMiniSDKTests {
    private func markedFactory() -> SignatureParametersFactory {
        return ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory().addOptionalHeaders(["X-Mutator"])
    }

    private func signer(decisions: ApproovServiceMutator) -> ApproovDefaultMessageSigning {
        return ApproovDefaultMessageSigning(decisions: decisions).setDefaultFactory(markedFactory())
    }

    private func signatureMemberNames(_ request: ApproovRequest) -> [String] {
        guard let header = request.headers.first(name: "Signature") else { return [] }
        return header.split(separator: ",").compactMap { member in
            member.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    func testEachDecisionHookIsDelegated() throws {
        try reinitializeServiceWithTargetHost()
        let recording = RecordingDecisions()
        let signing = signer(decisions: recording)
        ApproovService.setServiceMutator(signing)

        // the direct methods: a REJECTED result does not throw, as the delegate decides
        setDirective(#"{ "operation": "fetchSecureString", "response": { "status": "REJECTED" } }"#)
        XCTAssertNoThrow(try ApproovService.precheck())
        setDirective(#"{ "operation": "fetchApproovToken", "response": { "status": "REJECTED" } }"#)
        XCTAssertNoThrow(try ApproovService.fetchToken(url: targetURLString + "/direct"))
        setDirective(#"{ "operation": "fetchSecureString", "response": { "status": "REJECTED" } }"#)
        XCTAssertNoThrow(try ApproovService.fetchSecureString(key: "some-key", newDef: nil))
        setDirective(#"{ "operation": "fetchCustomJWT", "response": { "status": "REJECTED" } }"#)
        XCTAssertNoThrow(try ApproovService.fetchCustomJWT(payload: "{\"a\":1}"))

        // connection checks: the delegate turns them off
        XCTAssertFalse(signing.handlePinningShouldProcessRequest(hostname: try XCTUnwrap(URL(string: targetURLString)?.host)))

        // the interceptor: the delegate declines the header substitution and accepts the query one
        _ = try ApproovService.fetchSecureString(key: "own-key", newDef: "secret-value")
        ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
        ApproovService.addSubstitutionQueryParam(key: "k")
        let processed = ApproovService.updateRequestWithApproov(request: ApproovRequest(
            url: try XCTUnwrap(URL(string: targetURLString + "/a?k=own-key")), method: "GET",
            headers: HTTPHeaders([("Api-Key", "own-key")])))
        XCTAssertEqual(processed.decision, .ShouldProceed, String(describing: processed.error))
        XCTAssertEqual(processed.request.headers.first(name: "Api-Key"), "own-key", "the declined substitution was made")
        XCTAssertEqual(processed.request.url.absoluteString, targetURLString + "/a?k=secret-value")
        XCTAssertEqual(processed.request.headers.first(name: "X-Mutator"), "recorded")
        XCTAssertTrue(processed.request.headers.first(name: "Signature-Input")?.contains("\"x-mutator\"") ?? false)

        // a REJECTED token fetch proceeds, signed, as the delegate decides
        let rejected = try decide(targetURLString + "/b", tokenStatus: "REJECTED", mutator: signing)
        XCTAssertEqual(rejected.decision, .ShouldProceed, String(describing: rejected.error))
        XCTAssertEqual(signatureMemberNames(rejected.request), ["install"])

        // a request the delegate does not process gets nothing
        let skipped = try decide(targetURLString + "/skip", mutator: signing)
        XCTAssertEqual(skipped.decision, .ShouldIgnore)
        XCTAssertNil(skipped.request.headers.first(name: "Approov-Token"))

        let calls = recording.calls
        for expected in ["handlePrecheckResult:REJECTED",
                         "handleFetchTokenResult:REJECTED",
                         "handleFetchSecureStringResult:lookup:some-key:REJECTED",
                         "handleFetchCustomJWTResult:REJECTED",
                         "handlePinningShouldProcessRequest",
                         "handleFetchSecureStringResult:definition:own-key:SUCCESS",
                         "handleInterceptorShouldProcessRequest:/a",
                         "handleInterceptorFetchTokenResult:SUCCESS",
                         "handleInterceptorHeaderSubstitutionResult:Api-Key",
                         "handleInterceptorQueryParamSubstitutionResult:k",
                         "handleInterceptorProcessedRequest",
                         "handleInterceptorFetchTokenResult:REJECTED",
                         "handleInterceptorShouldProcessRequest:/skip"] {
            XCTAssertTrue(calls.contains(expected), "\(expected) was not delegated: \(calls)")
        }
    }

    func testTheDelegatesProcessedRequestRunsFirstAndIsSigned() throws {
        try reinitializeServiceWithTargetHost()
        let marking = MarkingDecisions(addQuery: true)
        let response = try decide(targetURLString + "/a?k=v", mutator: signer(decisions: marking))
        XCTAssertEqual(response.decision, .ShouldProceed, String(describing: response.error))
        XCTAssertEqual(marking.calls, 1)
        XCTAssertEqual(response.request.headers.first(name: "X-Mutator"), "marked")
        XCTAssertEqual(response.request.url.absoluteString, targetURLString + "/a?k=v&by=delegate")
        let input = try XCTUnwrap(response.request.headers.first(name: "Signature-Input"))
        XCTAssertTrue(input.contains("\"x-mutator\""), "the delegate's header is not covered: \(input)")
        XCTAssertEqual(signatureMemberNames(response.request), ["install"])
    }

    func testInitStillMakesTheCloseFailureDecisions() throws {
        try reinitializeServiceWithTargetHost()
        XCTAssertEqual(String(describing: ApproovDefaultMessageSigning()), "ApproovDefaultMessageSigning")
        for status in ["NO_APPROOV_SERVICE", "NO_NETWORK", "REJECTED", "UNKNOWN_URL"] {
            let expected = try decide(targetURLString + "/a", tokenStatus: status, mutator: ApproovCloseFailureMutator.CLOSE_FAILURE)
            let actual = try decide(targetURLString + "/a", tokenStatus: status,
                                    mutator: ApproovDefaultMessageSigning().setDefaultFactory(markedFactory()))
            XCTAssertEqual(actual.decision, expected.decision, status)
            XCTAssertEqual(String(reflecting: actual.error), String(reflecting: expected.error), status)
            XCTAssertEqual(actual.request.headers.first(name: "Approov-Token"),
                           expected.request.headers.first(name: "Approov-Token"), status)
        }
        let signed = try decide(targetURLString + "/a", mutator: ApproovDefaultMessageSigning().setDefaultFactory(markedFactory()))
        XCTAssertEqual(signatureMemberNames(signed.request), ["install"])
    }

    func testCombinedMakesTheGivenDecisionsAndSignsBoth() throws {
        try reinitializeServiceWithTargetHost()
        let proceeded = try decide(targetURLString + "/a", tokenStatus: "NO_NETWORK",
                                   mutator: ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED))
        XCTAssertEqual(proceeded.decision, .ShouldProceed, String(describing: proceeded.error))
        XCTAssertEqual(signatureMemberNames(proceeded.request), ["install", "account"])

        XCTAssertEqual(try decide(targetURLString + "/a", tokenStatus: "NO_NETWORK",
                                  mutator: ApproovDefaultMessageSigning.combined(decisions: .CLOSE_FAILURE)).decision, .ShouldRetry)

        let recording = RecordingDecisions()
        XCTAssertEqual(try decide(targetURLString + "/b", tokenStatus: "REJECTED",
                                  mutator: ApproovDefaultMessageSigning.combined(decisions: recording)).decision, .ShouldProceed)
        XCTAssertTrue(recording.calls.contains("handleInterceptorFetchTokenResult:REJECTED"), "\(recording.calls)")
    }

    func testCombinedWithoutDecisionsMakesTheDefaultDecisions() throws {
        try reinitializeServiceWithTargetHost()
        for status in ["NO_NETWORK", "REJECTED", "UNKNOWN_URL"] {
            let expected = try decide(targetURLString + "/a", tokenStatus: status, mutator: ApproovCloseFailureMutator.DEFAULT)
            let actual = try decide(targetURLString + "/a", tokenStatus: status, mutator: ApproovDefaultMessageSigning.combined())
            XCTAssertEqual(actual.decision, expected.decision, status)
            XCTAssertEqual(String(reflecting: actual.error), String(reflecting: expected.error), status)
        }
        let signed = try decide(targetURLString + "/a", mutator: ApproovDefaultMessageSigning.combined())
        XCTAssertEqual(signatureMemberNames(signed.request), ["install", "account"])
    }

    func testCombinedReturnsANewInstanceEachTime() {
        XCTAssertFalse(ApproovDefaultMessageSigning.combined() === ApproovDefaultMessageSigning.combined())
        XCTAssertFalse(ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED)
                       === ApproovDefaultMessageSigning.combined(decisions: .ALWAYS_PROCEED))
    }
}

/// A mutator that marks the request it processed, and that can also add a query parameter to it.
private final class MarkingDecisions: ApproovServiceMutator {
    private let count = NIOLockedValueBox(0)
    private let addQuery: Bool
    init(addQuery: Bool = false) { self.addQuery = addQuery }
    var calls: Int { count.withLockedValue { $0 } }

    func handleInterceptorProcessedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
        count.withLockedValue { $0 += 1 }
        var marked = request
        marked.headers.replaceOrAdd(name: "X-Mutator", value: "marked")
        if addQuery {
            let url = request.url.absoluteString
            marked.url = URL(string: url + (url.contains("?") ? "&" : "?") + "by=delegate")!
        }
        return marked
    }
}

/// A mutator that records each decision it is asked for. Each decision differs from the CLOSE_FAILURE one, so
/// its result shows that the decision was made here.
private final class RecordingDecisions: ApproovServiceMutator, CustomStringConvertible {
    private let log = NIOLockedValueBox<[String]>([])
    var calls: [String] { log.withLockedValue { $0 } }
    var description: String { return "Recording" }

    private func record(_ call: String) {
        log.withLockedValue { $0.append(call) }
    }

    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws {
        record("handlePrecheckResult:" + ApproovService.statusName(approovResults.status))
    }

    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws {
        record("handleFetchTokenResult:" + ApproovService.statusName(approovResults.status))
    }

    func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult, operation: String, key: String) throws {
        record("handleFetchSecureStringResult:\(operation):\(key):" + ApproovService.statusName(approovResults.status))
    }

    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws {
        record("handleFetchCustomJWTResult:" + ApproovService.statusName(approovResults.status))
    }

    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool {
        record("handleInterceptorShouldProcessRequest:" + request.url.path)
        return request.url.path != "/skip"
    }

    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool {
        record("handleInterceptorFetchTokenResult:" + ApproovService.statusName(approovResults.status))
        return true
    }

    func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult, header: String) throws -> Bool {
        record("handleInterceptorHeaderSubstitutionResult:" + header)
        return false
    }

    func handleInterceptorQueryParamSubstitutionResult(_ approovResults: ApproovTokenFetchResult, queryKey: String) throws -> Bool {
        record("handleInterceptorQueryParamSubstitutionResult:" + queryKey)
        return true
    }

    func handleInterceptorProcessedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
        record("handleInterceptorProcessedRequest")
        var recorded = request
        recorded.headers.replaceOrAdd(name: "X-Mutator", value: "recorded")
        return recorded
    }

    func handlePinningShouldProcessRequest(hostname: String) -> Bool {
        record("handlePinningShouldProcessRequest")
        return false
    }
}

// MARK: - Missing signature logging

/// A signature that cannot be produced is left out, and the line saying so is written once per process at a
/// higher level, then at debug level.
extension ApproovServiceMiniSDKTests {
    // sends one request with a signer for both signatures, the given ones being unavailable
    @discardableResult
    private func sendCombined(installMissing: Bool, accountMissing: Bool) throws -> ApproovRequest {
        var signer = ApproovDefaultMessageSigning.combined()
        if installMissing { signer = signer.setInstallMessageSignatureProviderForTesting { _ in "not-base64" } }
        if accountMissing { signer = signer.setAccountMessageSignatureProviderForTesting { _ in "not-base64" } }
        let response = try decide(targetURLString + "/a", mutator: signer)
        XCTAssertEqual(response.decision, .ShouldProceed, String(describing: response.error))
        return response.request
    }

    private func levels(_ lines: [(ApproovLogLevel, String)], containing text: String) -> [ApproovLogLevel] {
        return lines.filter { $0.1.contains(text) }.map { $0.0 }
    }

    func testAMissingInstallSignatureWarnsOnceThenLogsAtDebug() throws {
        try reinitializeServiceWithTargetHost()
        let lines = try captureLogs(level: .debug) {
            let request = try sendCombined(installMissing: true, accountMissing: false)
            XCTAssertEqual(request.headers.first(name: "Signature")?.hasPrefix("account="), true)
            try sendCombined(installMissing: true, accountMissing: false)
        }
        XCTAssertEqual(levels(lines, containing: "install message signature unavailable, signed without it"), [.warning, .debug])
        XCTAssertTrue(levels(lines, containing: "account message signature").isEmpty)
    }

    func testAMissingAccountSignatureWarnsOnceThenLogsAtDebug() throws {
        try reinitializeServiceWithTargetHost()
        let lines = try captureLogs(level: .debug) {
            try sendCombined(installMissing: false, accountMissing: true)
            try sendCombined(installMissing: false, accountMissing: true)
        }
        XCTAssertEqual(levels(lines, containing: "account message signature unavailable, signed without it"), [.warning, .debug])
        XCTAssertTrue(levels(lines, containing: "install message signature").isEmpty)
    }

    func testBothMissingLogsAnErrorOnceThenDebugAndSendsUnsigned() throws {
        try reinitializeServiceWithTargetHost()
        let lines = try captureLogs(level: .debug) {
            let request = try sendCombined(installMissing: true, accountMissing: true)
            XCTAssertNil(request.headers.first(name: "Signature"))
            try sendCombined(installMissing: true, accountMissing: true)
        }
        let text = "no message signature could be produced, proceeding unsigned: install signature unavailable: account signature unavailable"
        XCTAssertEqual(levels(lines, containing: text), [.error, .debug])
        XCTAssertTrue(levels(lines, containing: "signed without it").isEmpty)
    }

    func testResetRestoresTheFirstTimeBehaviour() throws {
        try reinitializeServiceWithTargetHost()
        let lines = try captureLogs(level: .debug) {
            try sendCombined(installMissing: true, accountMissing: false)
            try sendCombined(installMissing: true, accountMissing: false)
            ApproovDefaultMessageSigning.resetMissingSignatureLogsForTesting()
            try sendCombined(installMissing: true, accountMissing: false)
        }
        XCTAssertEqual(levels(lines, containing: "install message signature unavailable, signed without it"), [.warning, .debug, .warning])
    }

    func testTargetUriLeavesOutADefaultPort() throws {
        let targetUris = [
            ("https://api.example.com:443/", "https://api.example.com/"),
            ("https://api.example.com:443/v1?a=1", "https://api.example.com/v1?a=1"),
            ("http://api.example.com:80/v1", "http://api.example.com/v1"),
            ("https://api.example.com:8443/v1", "https://api.example.com:8443/v1"),
            ("http://api.example.com:443/v1", "http://api.example.com:443/v1"),
            ("https://api.example.com/v1%2Fx?q=a%20b#frag", "https://api.example.com/v1%2Fx?q=a%20b"),
        ]
        for (sent, signed) in targetUris {
            let provider = ApproovAsyncHTTPClientComponentProvider(request: ApproovRequest(
                url: try XCTUnwrap(URL(string: sent)), method: "GET", headers: HTTPHeaders()))
            XCTAssertEqual(provider.getTargetUri(), signed, sent)
        }
    }
}
