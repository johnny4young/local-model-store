/// The app using the store, identified by its bundle ID. Release and Dev builds
/// are separate consumers.
public struct StoreConsumer: Codable, Equatable, Hashable, Sendable {
    public let bundleID: String
    public let displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}
