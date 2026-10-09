//
//  Scheduler.swift
//  Menu Bar Usage for Claude
//
//  Delayed work on the main actor (retries, post-refresh checks), behind a
//  protocol so tests can run it on demand.
//

import Foundation

protocol Scheduler: AnyObject {
    @discardableResult
    func schedule(after delay: Duration, _ work: @escaping @MainActor () async -> Void) -> ScheduledWork
}

final class ScheduledWork {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}

final class LiveScheduler: Scheduler {
    func schedule(after delay: Duration, _ work: @escaping @MainActor () async -> Void) -> ScheduledWork {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await work()
        }
        return ScheduledWork { task.cancel() }
    }
}
