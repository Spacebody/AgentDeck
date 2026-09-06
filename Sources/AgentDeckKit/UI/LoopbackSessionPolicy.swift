import Foundation

/// Exposes the API transport's redirect policy to the AppKit executable.
public enum LoopbackSessionPolicy {
    public static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: APIRequestDelegate(), delegateQueue: nil)
    }
}
