//
//  TetherService+Pairing.swift
//  Tether
//
//  Pairing and unpairing, and the notifications that go with them.
//

import Foundation
import AppKit
import Network
import UserNotifications

extension TetherService {
    // MARK: - Pairing & User Actions
    func requestPair(with deviceInfo: DeviceInfo) {
        if let conn = connectedDevices[deviceInfo.deviceId], !conn.isDisconnected {
            conn.requestPairing()
        } else if let endpoint = discoveredDeviceEndpoints[deviceInfo.deviceId] {
            let key = "out_\(deviceInfo.deviceId)"
            let connection = DeviceConnection(host: endpoint.host, port: endpoint.port, targetDeviceId: deviceInfo.deviceId, isOutgoing: true)
            connection.pendingPairingRequest = true
            connection.delegate = self
            self.pendingConnections[key] = connection
            connectingDeviceIds.insert(deviceInfo.deviceId)
            connection.connect()
        }
    }

    /// Accepts the pending request only if it is still the one the user saw.
    /// `incomingPairRequest` is a single slot that any peer can overwrite, so
    /// the caller passes the device ID and certificate fingerprint it showed;
    /// if another request has taken the slot since, nothing is accepted.
    func acceptIncomingPairRequest(deviceId: String, fingerprint: String?) {
        guard let pairReq = incomingPairRequest else { return }
        guard pairReq.info.deviceId == deviceId,
              SocketTLS.fingerprintsMatch(pairReq.connection.peerCertificateFingerprint, fingerprint) else {
            TetherLog("[TetherService] Not accepting: the pending pairing request changed after it was shown")
            return
        }
        dismissPairingRequestNotification(deviceId: pairReq.info.deviceId)
        pairReq.connection.acceptPairing()
        incomingPairRequest = nil
    }

    func rejectIncomingPairRequest() {
        guard let pairReq = incomingPairRequest else { return }
        dismissPairingRequestNotification(deviceId: pairReq.info.deviceId)
        pairReq.connection.rejectPairing()
        incomingPairRequest = nil
    }

    func unpair(deviceId: String) {
        contactsPlugin.forget(deviceId: deviceId)
        dismissPairingRequestNotification(deviceId: deviceId)
        connectionLock.withLock {
            activeDeviceIds.remove(deviceId)
            activeHosts[deviceId] = nil
            activeConnections[deviceId] = nil
        }
        if let conn = connectedDevices[deviceId] {
            conn.unpair()
            deactivatePlugins(for: conn)
            connectedDevices.removeValue(forKey: deviceId)
        }
        trustStore.remove(deviceId: deviceId, reason: "unpaired on this Mac")
    }

    func sendPing(to deviceId: String) {
        if let conn = connectedDevices[deviceId] {
            pingPlugin.sendPing(to: conn)
        }
    }


    // MARK: - Notifications
    func showPairingRequestNotification(info: DeviceInfo, connection: DeviceConnection) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing Request"
        content.subtitle = info.deviceName
        if let fp = connection.peerCertificateFingerprint {
            content.body = "Verification Key:\n\(fp.prefix(23))..."
        } else {
            content.body = "\(info.deviceName) wants to pair with this Mac."
        }
        content.sound = .default
        content.categoryIdentifier = "TETHER_PAIR_REQUEST_CATEGORY"
        content.userInfo = [
            "deviceId": info.deviceId,
            "fingerprint": connection.peerCertificateFingerprint ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "kde_pair_\(info.deviceId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                TetherLog("[TetherService] Failed to post pairing notification: \(error)")
            }
        }
    }

    /// A paired device came back with a different certificate. That is what
    /// an impostor looks like, and also a reinstall of KDE Connect, so it's
    /// said once per launch with what to do in the second case.
    func warnCertificateMismatch(_ info: DeviceInfo) {
        guard warnedMismatches.insert(info.deviceId).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(info.deviceName) Wasn't Connected"
        content.body = "It identified itself with a different key than when it was paired. If you reinstalled KDE Connect on it, unpair it in Tether and pair again."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "kde_mismatch_\(info.deviceId)", content: content, trigger: nil))
    }

    func dismissPairingRequestNotification(deviceId: String) {
        let id = "kde_pair_\(deviceId)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
