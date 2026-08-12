import Foundation

/// Pure state transitions for the single-slot menubar carousel.
public enum MenubarRotationPolicy {
    public static func reconciledIndex(currentID: String?, itemIDs: [String]) -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        guard let currentID, let index = itemIDs.firstIndex(of: currentID) else { return 0 }
        return index
    }

    public static func nextIndex(current: Int, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (max(0, current) + 1) % itemCount
    }

    public static func interval(configuredSeconds: Int, itemCount: Int) -> TimeInterval? {
        guard itemCount > 1, configuredSeconds > 0 else { return nil }
        return TimeInterval(configuredSeconds)
    }

    public static func easedProgress(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let linear = min(1, max(0, elapsed / duration))
        return 1 - pow(1 - linear, 3)
    }
}
