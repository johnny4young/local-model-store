/// The app using the store, identified by its bundle ID. Release and Dev builds
/// are separate consumers.
public struct StoreConsumer: Codable, Equatable, Hashable, Sendable {
    public let bundleID: String
    public let displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }

    /// The bundle ID names a claim file, so it must stay inside the claims directory.
    var hasSafeBundleID: Bool {
        !bundleID.isEmpty && bundleID.count <= 128 && !bundleID.hasPrefix(".")
            && bundleID.utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
                    return true
                default:
                    return false
                }
            }
    }
}
