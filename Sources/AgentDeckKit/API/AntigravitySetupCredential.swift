import Darwin
import Foundation
import CryptoKit

enum AntigravitySetupCredential {
    static func read() throws -> String {
        try read(from: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentDeck/antigravity-enable.token"))
    }

    static func read(from url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw APIError.noData }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              (1...256).contains(info.st_size) else { throw APIError.noData }
        var bytes = [UInt8](repeating: 0, count: 257)
        let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n == info.st_size,
              let raw = String(bytes: bytes.prefix(n), encoding: .utf8) else { throw APIError.noData }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw APIError.noData }
        return token
    }

    static func proof(token: String, instance: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(("antigravity-enable:" + instance).utf8),
                                       using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
