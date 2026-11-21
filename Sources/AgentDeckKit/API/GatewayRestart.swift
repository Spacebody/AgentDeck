import Dispatch

public enum GatewayRestartStatus: Equatable {
    case idle, restarting, failed, foreign, restarted, recovered
}

/// One lease covers all asynchronous stages, including changes of remote instance.
public struct GatewayTransition {
    public enum Phase { case idle, checking, handoff, manual, recovery }
    public enum Callback { case current, expired, stale }
    public private(set) var epoch = 0
    public private(set) var phase = Phase.idle
    public private(set) var deadline: DispatchTime?
    public init() {}

    public func callback(for generation: Int, now: DispatchTime = .now()) -> Callback {
        guard generation == epoch else { return .stale }
        if let deadline, now >= deadline { return .expired }
        return .current
    }

    public mutating func begin(manual: Bool, now: DispatchTime = .now()) -> Bool {
        guard phase == .idle || (manual && phase == .checking) else { return false }
        epoch += 1
        phase = manual ? .manual : .checking
        deadline = now + .seconds(manual ? 20 : 45)
        return true
    }

    public mutating func prepareHandoff() {
        if phase == .checking { phase = .handoff }
    }

    /// Recovery may launch on a refused connection, never evict an owner or a listener.
    public mutating func beginRecovery(refused: Bool, childRunning: Bool,
                                       installing: Bool, now: DispatchTime = .now()) -> Bool {
        guard phase == .idle, refused, !childRunning, !installing else { return false }
        epoch += 1
        phase = .recovery
        deadline = now + .seconds(20)
        return true
    }

    public mutating func end() {
        epoch += 1
        phase = .idle
        deadline = nil
    }
}

/// A manual attempt may stop one owned process and launch at most one replacement.
public struct GatewayRestartAttempt {
    public enum Action: Equatable { case stopOwned, wait, launch, ready, foreign, timedOut }
    public let deadline: DispatchTime
    private var stopping = false
    private var launched = false
    public init(start: DispatchTime = .now()) { deadline = start + .seconds(20) }

    public mutating func next(running: Bool, ownedHealth: Bool, foreignHealth: Bool,
                              now: DispatchTime = .now()) -> Action {
        if now >= deadline { return .timedOut }
        if foreignHealth { return .foreign }
        if launched { return running && ownedHealth ? .ready : .wait }
        if running {
            if stopping { return .wait }
            stopping = true
            return .stopOwned
        }
        // Never spawn over a responding instance, even if its Process handle is gone.
        if ownedHealth { return .wait }
        launched = true
        return .launch
    }
}
