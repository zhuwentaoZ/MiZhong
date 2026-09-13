import Foundation

public final class ScanControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    public func pause() { condition.lock(); paused = true; condition.unlock() }
    public func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    public func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    public func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled || Task<Never, Never>.isCancelled { throw CancellationError() }
    }
}
