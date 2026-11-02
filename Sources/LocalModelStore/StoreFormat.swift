/// The on-disk format version. It names the version directory, so an
/// incompatible change never rewrites a tree that older clients still use.
public enum StoreFormat {
    public static let version = 1
    public static let directoryName = "v\(version).noindex"
}
