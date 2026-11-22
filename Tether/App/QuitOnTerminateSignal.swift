//
//  QuitOnTerminateSignal.swift
//  Tether
//
//  `kill`, `killall` and a logout's last resort send SIGTERM, which by
//  default ends the app on the spot: no willTerminate, so phone drives stay
//  mounted with nobody serving them. This turns it into a normal quit.
//

import AppKit

enum QuitOnTerminateSignal {
    private static var source: DispatchSourceSignal?

    static func install() {
        guard source == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        self.source = source
    }
}
