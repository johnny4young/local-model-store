import CryptoKit
import Foundation
import Testing

/// Measured in another process, because a footprint is per process and other tests run alongside.
@Test func hashingALargeFileKeepsTheFootprintSmall() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("local-model-store-hash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("weights.bin")
    let size: UInt64 = 256 << 20
    // Sparse: nothing reaches the disk, yet every read still fills a whole buffer.
    try #require(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: size)
    try handle.close()

    // A matching digest shows the whole file was read.
    var zeros = SHA256()
    let chunk = Data(count: 1 << 20)
    for _ in 0..<(size >> 20) { zeros.update(data: chunk) }
    let expected = zeros.finalize().map { String(format: "%02x", $0) }.joined()

    let fields = try await clientOutput(["--hash", file.path]).split(whereSeparator: \.isWhitespace)
    #expect(fields.first.map(String.init) == expected)
    let peak = try #require(fields.last.flatMap { UInt64($0) })
    #expect(peak < size / 4, "peak footprint \(peak >> 20) MiB for a \(size >> 20) MiB file")
}
