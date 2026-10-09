//
//  DisplaySleepMonitor.swift
//  Menu Bar Usage for Claude
//
//  Tracks whether the displays are asleep. They stay off through DarkWake,
//  the brief maintenance wakes in which the poll timer would otherwise fire.
//

import AppKit
import CoreGraphics

protocol DisplayState: AnyObject {
    var displaysAsleep: Bool { get }
    /// Called on the main actor when the displays wake.
    var onWake: (() -> Void)? { get set }
}

final class DisplaySleepMonitor: DisplayState {
    private(set) var displaysAsleep: Bool
    var onWake: (() -> Void)?
    private var observers: [any NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = true
                DiagnosticLog.shared.log(.power, "Displays asleep; polling paused")
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = false
                DiagnosticLog.shared.log(.power, "Displays awake")
                self?.onWake?()
            }
        })
    }
}
