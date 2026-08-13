import Foundation

/// Pure state transitions for the single-slot menubar carousel.
public enum MenubarRotationPolicy {
    public static func isSuccessfulHTTPStatus(_ statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }

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

    public static func shouldDeferPassiveRefresh(isAnimating: Bool) -> Bool {
        isAnimating
    }

    public static func shouldAcceptResponse(requestID: Int, lastAppliedRequestID: Int) -> Bool {
        requestID > lastAppliedRequestID
    }

    public static func currentItem<Item>(items: [Item], currentIndex: Int) -> Item? {
        guard !items.isEmpty else { return nil }
        return items.indices.contains(currentIndex) ? items[currentIndex] : items[0]
    }

}
