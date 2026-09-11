// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreFoundation

/// A serial run loop for drawable callbacks and renderer state. AppKit keeps
/// ownership of windows; no render operation depends on main-dispatch delivery.
final class RenderExecutor: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var loop: CFRunLoop?
        var accepting = true
    }
    private let state = State()
    private let thread: Thread

    init(name: String = "foldelight.render") {
        let state = state
        thread = Thread {
            autoreleasepool {
                let loop = CFRunLoopGetCurrent()!
                var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil,
                    release: nil, copyDescription: nil, equal: nil, hash: nil,
                    schedule: nil, cancel: nil, perform: { _ in })
                let source = CFRunLoopSourceCreate(nil, 0, &context)!
                CFRunLoopAddSource(loop, source, .commonModes)
                state.condition.lock()
                state.loop = loop
                state.condition.broadcast()
                state.condition.unlock()
                CFRunLoopRun()
                CFRunLoopRemoveSource(loop, source, .commonModes)
            }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        state.condition.lock()
        while state.loop == nil { state.condition.wait() }
        state.condition.unlock()
    }

    var isCurrent: Bool { Thread.current === thread }

    @discardableResult
    func perform(_ work: @escaping () -> Void) -> Bool {
        state.condition.lock()
        guard state.accepting, let loop = state.loop else { state.condition.unlock(); return false }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { autoreleasepool(invoking: work) }
        CFRunLoopWakeUp(loop)
        state.condition.unlock()
        return true
    }

    func sync(_ work: @escaping () -> Void) {
        if isCurrent { work(); return }
        let completed = DispatchSemaphore(value: 0)
        guard perform({ work(); completed.signal() }) else { return }
        completed.wait()
    }

    func stop() {
        state.condition.lock()
        guard state.accepting, let loop = state.loop else { state.condition.unlock(); return }
        state.accepting = false
        // Previously accepted operations precede termination on this run loop.
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
        state.condition.unlock()
    }

    deinit { stop() }
}

/// Dispatch-main callbacks cannot reenter an executing dispatch-main callback.
/// Common-mode blocks can run in its nested AppKit event loop.
enum MainRunLoop {
    static func perform(_ work: @escaping @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// Coalesces wake requests, while the producer keeps its newest data separately.
final class RenderWakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private let executor: RenderExecutor
    private let action: () -> Void

    init(executor: RenderExecutor, action: @escaping () -> Void) {
        self.executor = executor
        self.action = action
    }

    func signal() {
        lock.lock()
        guard !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        if !executor.perform({ [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false; self.lock.unlock()
            self.action()
        }) {
            lock.lock(); pending = false; lock.unlock()
        }
    }
}
