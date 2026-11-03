import Foundation

/// Where a store lives. There is no default, so no caller reaches a real store by accident.
public enum StoreLocation: Sendable, Equatable {
    /// The shared folder in the user's Application Support. This name is permanent:
    /// Core ML ties compiled models to their path, so a rename re-specializes everything.
    case userLibrary
    /// An explicit directory, for tests and tools.
    case directory(URL)

    public static let sharedFolderName = "com.johnny4young.local-models"

    /// A sandboxed process resolves Application Support into its own container, which
    /// would silently create a private store. It fails instead.
    func resolvedRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        switch self {
        case .directory(let url):
            return url
        case .userLibrary:
            guard environment["APP_SANDBOX_CONTAINER_ID"] == nil else {
                throw LocalModelStore.LocalModelStoreError.sandboxed
            }
            return URL.applicationSupportDirectory.appendingPathComponent(Self.sharedFolderName, isDirectory: true)
        }
    }
}
