// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Return false when the owner executor no longer accepts callbacks.
typealias RenderCallbackExecutor = (@escaping () -> Void) -> Bool

/// A failed GPU submission retains its permit until invalidation finishes on
/// the owner executor. Rejected/discarded callbacks still return that permit.
enum RenderCompletionDelivery {
    private final class ReleaseOnce {
        private let lock = NSLock()
        private var action: (() -> Void)?
        init(_ action: @escaping () -> Void) { self.action = action }
        func finish() {
            lock.lock()
            let action = action
            self.action = nil
            lock.unlock()
            action?()
        }
        deinit { finish() }
    }

    static func schedule(on executor: RenderCallbackExecutor,
                         work: @escaping () -> Void, release: @escaping () -> Void) {
        let completion = ReleaseOnce(release)
        let accepted = executor {
            defer { completion.finish() }
            work()
        }
        if !accepted { completion.finish() }
    }
}
