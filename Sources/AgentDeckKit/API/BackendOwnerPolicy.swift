import Foundation

public enum BackendOwnerPolicy {
    public static func shouldShare(
        currentVersion: String,
        currentScript: String,
        remoteVersion: String?,
        remoteScript: String?,
        remoteOwnerIsAlive: Bool
    ) -> Bool {
        guard remoteOwnerIsAlive,
              let remoteVersion,
              let remoteScript else { return false }

        let versionOrder = compareVersions(remoteVersion, currentVersion)
        if versionOrder == .orderedDescending { return true }
        if versionOrder == .orderedAscending { return false }

        let current = canonicalPath(currentScript)
        let remote = canonicalPath(remoteScript)
        if current == remote { return true }

        let currentInstalled = isSystemInstalled(current)
        let remoteInstalled = isSystemInstalled(remote)
        if currentInstalled != remoteInstalled { return remoteInstalled }

        // Stable tie-breaker: both App instances independently choose the same owner.
        return remote.compare(current) == .orderedAscending
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSystemInstalled(_ path: String) -> Bool {
        path.hasPrefix("/Applications/AgentDeck.app/")
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = parseVersion(lhs), let right = parseVersion(rhs) else {
            return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
        }
        for (leftPart, rightPart) in zip(left.core, right.core) {
            if leftPart != rightPart {
                return leftPart < rightPart ? .orderedAscending : .orderedDescending
            }
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case let (leftPre?, rightPre?):
            for (leftPart, rightPart) in zip(leftPre, rightPre) {
                if leftPart == rightPart { continue }
                let leftNumber = Int(leftPart)
                let rightNumber = Int(rightPart)
                switch (leftNumber, rightNumber) {
                case let (leftNumber?, rightNumber?):
                    return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
                case (_?, nil):
                    return .orderedAscending
                case (nil, _?):
                    return .orderedDescending
                case (nil, nil):
                    return leftPart.compare(rightPart, options: .literal)
                }
            }
            if leftPre.count == rightPre.count { return .orderedSame }
            return leftPre.count < rightPre.count ? .orderedAscending : .orderedDescending
        }
    }

    private static func parseVersion(
        _ value: String
    ) -> (core: [Int], prerelease: [String]?)? {
        let withoutBuild = value.split(separator: "+", maxSplits: 1,
                                       omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1,
                                       omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".").compactMap { Int($0) }
        guard core.count == 3 else { return nil }
        let prerelease = parts.count == 2
            ? parts[1].split(separator: ".").map(String.init)
            : nil
        return (core, prerelease)
    }
}
