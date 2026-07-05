//
//  LockMonitor.swift
//  FaceUnlock
//

import Foundation
import AppKit
import Observation

@Observable
final class LockMonitor {
    struct Event: Identifiable {
        let id = UUID()
        let kind: Kind
        let timestamp: Date

        enum Kind {
            case locked
            case unlocked
            case screensSlept
            case screensWoke

            var description: String {
                switch self {
                case .locked:       return "Screen locked"
                case .unlocked:     return "Screen unlocked"
                case .screensSlept: return "Screens slept"
                case .screensWoke:  return "Screens woke"
                }
            }

            var systemImage: String {
                switch self {
                case .locked:       return "lock.fill"
                case .unlocked:     return "lock.open.fill"
                case .screensSlept: return "moon.fill"
                case .screensWoke:  return "sun.max.fill"
                }
            }
        }
    }

    private(set) var recentEvents: [Event] = []
    private(set) var isScreenLocked: Bool = false
    private(set) var isMonitoring: Bool = false

    /// Increments on every `screensDidWakeNotification`. Observe via `.onChange` to detect
    /// "display just woke" without false positives from other state mutations.
    private(set) var wakeEventCount: Int = 0

    /// Direct callback for code (e.g. AppController) that needs to react to wake events
    /// even when no SwiftUI view is alive to observe `wakeEventCount`.
    var onScreensWoke: (() -> Void)? = nil

    /// Fires immediately after `screenIsLocked` is recorded.
    var onScreensLocked: (() -> Void)? = nil

    /// Fires immediately after `screenIsUnlocked` is recorded.
    var onScreensUnlocked: (() -> Void)? = nil

    private static let maxEvents = 12

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.locked)
            self?.isScreenLocked = true
            self?.onScreensLocked?()
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.unlocked)
            self?.isScreenLocked = false
            self?.onScreensUnlocked?()
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.screensSlept)
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.screensWoke)
            self?.wakeEventCount += 1
            self?.onScreensWoke?()
        })

        isMonitoring = true
    }

    func stopMonitoring() {
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        distributedObservers.removeAll()

        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        isMonitoring = false
    }

    private func record(_ kind: Event.Kind) {
        recentEvents.append(Event(kind: kind, timestamp: Date()))
        if recentEvents.count > Self.maxEvents {
            recentEvents.removeFirst(recentEvents.count - Self.maxEvents)
        }
    }
}
