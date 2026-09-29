//
//  DeviceIdentity.swift
//  Tether
//

import Foundation
import Security
import Network
import CryptoKit

public final class DeviceIdentity: @unchecked Sendable {
    public static let shared = DeviceIdentity()

    public let deviceId: String
    public var deviceName: String
    public let certificateFingerprint: String
    public let certificatePEM: String
    public let secIdentity: SecIdentity
    public let secCertificate: SecCertificate

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tether", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let p12URL = appSupport.appendingPathComponent("identity.p12")
        let certURL = appSupport.appendingPathComponent("certificate.pem")
        let keyURL = appSupport.appendingPathComponent("key.pem")
        let configURL = appSupport.appendingPathComponent("device.json")

        var id = UserDefaults.standard.string(forKey: "tether_device_id")
        var name = UserDefaults.standard.string(forKey: "tether_device_name") ?? Host.current().localizedName ?? "Mac"

        let p12Exists = FileManager.default.fileExists(atPath: p12URL.path)

        if id == nil || !p12Exists {
            // Generate clean 32-character hexadecimal UUID
            let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            id = newId
            UserDefaults.standard.set(newId, forKey: "tether_device_id")
            UserDefaults.standard.set(name, forKey: "tether_device_name")

            Self.generateCertificates(deviceId: newId, p12URL: p12URL, certURL: certURL, keyURL: keyURL)
        }

        self.deviceId = id!
        self.deviceName = name

        // Get or create dedicated private keychain to avoid touching login.keychain
        let keychainURL = appSupport.appendingPathComponent("tether.keychain-db")
        let dedicatedKeychain = Self.getOrCreateKeychain(at: keychainURL)

        // Load PKCS12 into dedicated keychain
        let p12Data = (try? Data(contentsOf: p12URL)) ?? Data()
        var options: [CFString: Any] = [
            kSecImportExportPassphrase: "tether"
        ]
        if let kc = dedicatedKeychain {
            options[kSecImportExportKeychain] = kc
        }
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] as! SecIdentity? else {
            fatalError("Failed to import Tether SecIdentity from PKCS12: \(status)")
        }

        self.secIdentity = identity

        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        self.secCertificate = certRef!

        // Resolve the private key once, here, so the cost of locating it in the
        // keychain is not paid in the middle of a TLS handshake. On a cold process
        // that lookup can block for tens of seconds, stalling whichever handshake
        // happens to be first.
        var privateKey: SecKey?
        if SecIdentityCopyPrivateKey(identity, &privateKey) != errSecSuccess || privateKey == nil {
            fatalError("Failed to resolve the Tether identity's private key from the keychain")
        }

        // Read PEM
        self.certificatePEM = (try? String(contentsOf: certURL, encoding: .utf8)) ?? ""

        // Calculate SHA-256 fingerprint
        let certData = SecCertificateCopyData(self.secCertificate) as Data
        let digest = SHA256.hash(data: certData)
        self.certificateFingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func getOrCreateKeychain(at url: URL) -> SecKeychain? {
        var keychain: SecKeychain?
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            if SecKeychainOpen(path, &keychain) == errSecSuccess, let kc = keychain {
                SecKeychainUnlock(kc, 10, "tether", true)
                return kc
            }
        }

        let status = SecKeychainCreate(path, 10, "tether", false, nil, &keychain)
        if status == errSecSuccess, let kc = keychain {
            SecKeychainUnlock(kc, 10, "tether", true)
            return kc
        }
        return nil
    }

    private static func generateCertificates(deviceId: String, p12URL: URL, certURL: URL, keyURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        
        let script = """
        openssl ecparam -name prime256v1 -genkey -noout -out "\(keyURL.path)" && \
        chmod 600 "\(keyURL.path)" && \
        openssl req -new -x509 -key "\(keyURL.path)" -out "\(certURL.path)" -days 3650 -subj "/CN=\(deviceId)/O=Tether/OU=Tether" && \
        openssl pkcs12 -export -in "\(certURL.path)" -inkey "\(keyURL.path)" -out "\(p12URL.path)" -passout pass:tether && \
        security import "\(p12URL.path)" -P tether -A
        """
        process.arguments = ["-c", script]

        try? process.run()
        process.waitUntilExit()
    }

    public func createSecIdentityProtocol() -> sec_identity_t? {
        sec_identity_create(secIdentity)
    }

    public func toDeviceInfo(tcpPort: Int = 1716) -> DeviceInfo {
        DeviceInfo(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceType: .laptop,
            protocolVersion: NetworkPacket.protocolVersion,
            incomingCapabilities: DeviceInfo.defaultIncomingCapabilities,
            outgoingCapabilities: DeviceInfo.defaultOutgoingCapabilities,
            tcpPort: tcpPort
        )
    }
}
