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
import CommonCrypto
import Foundation
import os.log

public class ApproovPinningVerifier {

    private static let rsa2048SPKIHeader:[UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]
    private static let rsa3072SPKIHeader:[UInt8] = [
        0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x01, 0x8f, 0x00
    ]
    private static let rsa4096SPKIHeader:[UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
    ]
    private static let ecdsaSecp256r1SPKIHeader:[UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48,
        0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    ]
    private static let ecdsaSecp384r1SPKIHeader:[UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04,
        0x00, 0x22, 0x03, 0x62, 0x00
    ]

    // SPKI headers for both RSA and ECC
    private static let spkiHeaders: [String:[Int:Data]] = [
        kSecAttrKeyTypeRSA as String:[
            2048:Data(rsa2048SPKIHeader),
            3072:Data(rsa3072SPKIHeader),
            4096:Data(rsa4096SPKIHeader)
        ],
        kSecAttrKeyTypeECSECPrimeRandom as String:[
            256:Data(ecdsaSecp256r1SPKIHeader),
            384:Data(ecdsaSecp384r1SPKIHeader)
        ]
    ]

    /**
     * Verify Approov pinning.
     *
     * @param sec_protocol_metadata is the metadata to allow the pinning check
     * @return Bool showing if the pinning was vallid
     */
    public static func verifyPinning(sec_protocol_metadata: sec_protocol_metadata_t) -> Bool {
        var certChain: [SecCertificate] = []
        if (
            !sec_protocol_metadata_access_peer_certificate_chain(sec_protocol_metadata,
                {
                    sec_certificate in
                    let cert: SecCertificate = sec_certificate_copy_ref(sec_certificate).takeRetainedValue()
                    certChain.append(cert)
                })
        ) {
            return false
        }
        let serverNameOption = sec_protocol_metadata_get_server_name(sec_protocol_metadata)
        if let serverNamePointer = serverNameOption {
            let serverName = String(cString: UnsafePointer<CChar>(serverNamePointer))
            do {
                let isPinned = try ApproovPinningVerifier.verifyPinning(hostname: serverName, certChain: certChain)
                return isPinned
            } catch {
                os_log("Approov: Pinning rejection for %@. %@", type: .error, serverName, error.localizedDescription)
                return false
            }
        } else {
            return false
        }
    }

    /**
     * Verify Approov pinning.
     *
     * @param hostname for which to check pinning
     * @param certChain for which to check whether it contains a pinned certificate
     * @return Bool showing if the pinning is valid
     */
    static func verifyPinning(hostname: String, certChain: [SecCertificate]) throws -> Bool {
        // Create a server trust from the peer certificates
        let policy = SecPolicyCreateSSL(true, hostname as CFString?)
        var serverTrust: SecTrust? = nil
        let result = SecTrustCreateWithCertificates(certChain as CFArray, policy, &serverTrust)
        if (result != errSecSuccess) {
            throw ApproovError.pinningError(message: "Error during certificate trust creation for host \(hostname)")
        }
        
        // Check the server trust
        if #available(iOS 12.0, *) {
            if (!SecTrustEvaluateWithError(serverTrust!, nil)) {
                throw ApproovError.pinningError(
                    message: "Error: Certificate Trust Evaluation failure for host \(hostname)")
            }
        } else {
            var trustType = SecTrustResultType.invalid
            if (SecTrustEvaluate(serverTrust!, &trustType) != errSecSuccess) {
                throw ApproovError.pinningError(
                    message: "Error during certificate trust evaluation for host \(hostname)")
            }
            if (trustType != SecTrustResultType.proceed) && (trustType != SecTrustResultType.unspecified) {
                throw ApproovError.pinningError(
                    message: "Error: Certificate Trust Evaluation failure for host \(hostname)")
            }
        }
        
        // Check the Approov dynamic pinning
        return try self.hasApproovPinMatch(host: hostname, certChain: certChain)
    }

    /**
     * Checks whether a certificate chain contains a match to an Approov pin.
     *
     * @param host for which to check pinning
     * @param certChain in which to look for a match to an Approov pin
     * @return Bool true if there was a pin match
     */
    static func hasApproovPinMatch(host: String, certChain: [SecCertificate]) throws -> Bool {
        // Ensure pins are refreshed eventually
        ApproovService.prefetch()
        
        // Get the certificate chain count
        for cert in certChain {
            if let publicKeyInfo = publicKeyInfoOfCertificate(certificate: cert) {
                // Compute the SHA-256 hash of the public key info
                let publicKeyHash = sha256(data: publicKeyInfo)

                // Check that the hash is the same as at least one of the pins
                guard let approovCertHashes = Approov.getPins("public-key-sha256") else {
                    throw ApproovError.pinningError(message: "Approov SDK getPins() call failed")
                }
                
                // Get the receivers host
                if var certHashesBase64 = approovCertHashes[host] {
                    // Check whether we have pins defined for this host
                    if certHashesBase64.count == 0 {
                        // There are no pins defined for this host, check for managed trust roots
                        if let managedTrustRootHashesBase64 = approovCertHashes["*"] {
                            // Managed trust roots are available, so use these
                            certHashesBase64 = managedTrustRootHashesBase64
                        } else {
                            // There are no managed trust roots either, accept connection. We do not pin connections
                            // where no pins are explicitly set for the host.
                            os_log("ApproovService: Pin verification %@ empty pins", host)
                            return true
                        }
                    }

                    // We have one or more cert hashes matching the receiver's host, compare them
                    for certHashBase64 in certHashesBase64 {
                        let certHash = Data(base64Encoded: certHashBase64)
                        if publicKeyHash == certHash {
                            os_log("ApproovService: Matched pin %@ for %@ from %d pins", certHashBase64, host, certHashesBase64.count)
                            return true
                        }
                    }
                } else {
                    // Host is not pinned
                    os_log("ApproovService: Pin verification %@ unpinned", host)
                    return true
                }
            } else {
                os_log("ApproovService: Skipping pin checking for unknown certificate type")
            }
        }

        // No match in current set of pins from Approov SDK and certificate chain seen during TLS handshake
        os_log("ApproovService: Pinning rejection for %@", type: .error, host)
        return false
    }

    /**
     * Gets a certificate's subject public key info (SPKI).
     *
     * @param certiificate is the SecCertificate being verified
     * @return the public key for the cerrtificate ot nil if there was a problem
     */
    static func publicKeyInfoOfCertificate(certificate: SecCertificate) -> Data? {
        var publicKey: SecKey?
        if #available(iOS 12.0, *) {
            publicKey = SecCertificateCopyKey(certificate)
        } else {
            // Fallback on earlier versions
            // from TrustKit https://github.com/datatheorem/TrustKit/blob/master/TrustKit/Pinning/TSKSPKIHashCache.m
            // lines 221-234:
            // Create an X509 trust using the certificate
            let secPolicy = SecPolicyCreateBasicX509()
            var secTrust:SecTrust?
            if SecTrustCreateWithCertificates(certificate, secPolicy, &secTrust) != errSecSuccess {
                return nil
            }
        
            // get a public key reference for the certificate from the trust
            var secTrustResultType = SecTrustResultType.invalid
            if SecTrustEvaluate(secTrust!, &secTrustResultType) != errSecSuccess {
                return nil
            }
            publicKey = SecTrustCopyPublicKey(secTrust!)
        }
        if publicKey == nil {
            return nil
        }
        
        // get the SPKI header depending on the public key's type and size
        guard var spkiHeader = publicKeyInfoHeaderForKey(publicKey: publicKey!) else {
            return nil
        }
    
        // combine the public key header and the public key data to form the public key info
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey!, nil) else {
            return nil
        }
        spkiHeader.append(publicKeyData as Data)
        return spkiHeader
    }

    /**
     * Gets the subject public key info (SPKI) header depending on a public key's type and size.
     *
     * @param certiificate is the SecCertificate being verified
     * @return the public key for the cerrtificate ot nil if there was a problem
     */
    static func publicKeyInfoHeaderForKey(publicKey: SecKey) -> Data? {
        guard let publicKeyAttributes = SecKeyCopyAttributes(publicKey) else {
            return nil
        }
        if let keyType = (publicKeyAttributes as NSDictionary).value(forKey: kSecAttrKeyType as String) {
            if let keyLength = (publicKeyAttributes as NSDictionary).value(forKey: kSecAttrKeySizeInBits as String) {
                // Find the header
                if let spkiHeader:Data = ApproovPinningVerifier.spkiHeaders[keyType as! String]?[keyLength as! Int] {
                    return spkiHeader
                }
            }
        }
        return nil
    }

    /**
     * SHA256 of given input bytes.
     *
     * @param data to be hashed
     * @return the SHA256 of the data
     */
    static func sha256(data : Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}
