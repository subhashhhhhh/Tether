//
//  DeviceIdentity.swift
//  KDEConnect
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
            .appendingPathComponent("KDEConnect", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let p12URL = appSupport.appendingPathComponent("identity.p12")
        let certURL = appSupport.appendingPathComponent("certificate.pem")
        let keyURL = appSupport.appendingPathComponent("key.pem")
        let configURL = appSupport.appendingPathComponent("device.json")

        var id = UserDefaults.standard.string(forKey: "kdeconnect_device_id")
        var name = UserDefaults.standard.string(forKey: "kdeconnect_device_name") ?? Host.current().localizedName ?? "Mac"

        let p12Exists = FileManager.default.fileExists(atPath: p12URL.path)

        if id == nil || !p12Exists {
            // Generate clean 32-character hexadecimal UUID
            let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            id = newId
            UserDefaults.standard.set(newId, forKey: "kdeconnect_device_id")
            UserDefaults.standard.set(name, forKey: "kdeconnect_device_name")

            Self.generateCertificates(deviceId: newId, p12URL: p12URL, certURL: certURL, keyURL: keyURL)
        }

        self.deviceId = id!
        self.deviceName = name

        // Load PKCS12
        let p12Data = (try? Data(contentsOf: p12URL)) ?? Data()
        let options: [String: Any] = [kSecImportExportPassphrase as String: "kdeconnect"]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] as! SecIdentity? else {
            fatalError("Failed to import KDE Connect SecIdentity from PKCS12: \(status)")
        }

        self.secIdentity = identity

        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        self.secCertificate = certRef!

        // Read PEM
        self.certificatePEM = (try? String(contentsOf: certURL, encoding: .utf8)) ?? ""

        // Calculate SHA-256 fingerprint
        let certData = SecCertificateCopyData(self.secCertificate) as Data
        let digest = SHA256.hash(data: certData)
        self.certificateFingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func generateCertificates(deviceId: String, p12URL: URL, certURL: URL, keyURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        
        let script = """
        openssl ecparam -name prime256v1 -genkey -noout -out "\(keyURL.path)" && \
        chmod 600 "\(keyURL.path)" && \
        openssl req -new -x509 -key "\(keyURL.path)" -out "\(certURL.path)" -days 3650 -subj "/CN=\(deviceId)/O=KDE/OU=KDE Connect" && \
        openssl pkcs12 -export -in "\(certURL.path)" -inkey "\(keyURL.path)" -out "\(p12URL.path)" -passout pass:kdeconnect
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
