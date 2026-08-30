import Foundation
import AppleArchive
import System

/// Bundles a directory tree into a single Apple Archive file (and back). Used to
/// share scans between people and reimport them. Chosen over `.zip` because
/// AppleArchive round-trips natively on iOS with no third-party dependency.
nonisolated enum ScanArchive {

    enum ArchiveError: Error { case openFailed, encodeFailed, decodeFailed }

    /// The set of header fields to preserve — enough to rebuild the tree on the
    /// other side (type, path, data, and timestamps).
    private static let keySetString = "TYP,PAT,LNK,DAT,MOD,MTM,CTM"

    /// Archives the *contents* of `directory` into `archiveURL` (LZFSE-compressed).
    static func archive(contentsOf directory: URL, to archiveURL: URL) throws {
        guard let writeStream = ArchiveByteStream.fileStream(
            path: FilePath(archiveURL.path), mode: .writeOnly,
            options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644))
        else { throw ArchiveError.openFailed }
        defer { try? writeStream.close() }

        guard let compressStream = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeStream)
        else { throw ArchiveError.openFailed }
        defer { try? compressStream.close() }

        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream)
        else { throw ArchiveError.encodeFailed }
        defer { try? encodeStream.close() }

        guard let keySet = ArchiveHeader.FieldKeySet(keySetString) else { throw ArchiveError.encodeFailed }
        try encodeStream.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keySet)
    }

    /// Extracts an archive created by `archive(contentsOf:to:)` into `directory`.
    static func extract(_ archiveURL: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let readStream = ArchiveByteStream.fileStream(
            path: FilePath(archiveURL.path), mode: .readOnly,
            options: [], permissions: FilePermissions(rawValue: 0o644))
        else { throw ArchiveError.openFailed }
        defer { try? readStream.close() }

        guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream)
        else { throw ArchiveError.openFailed }
        defer { try? decompressStream.close() }

        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream)
        else { throw ArchiveError.decodeFailed }
        defer { try? decodeStream.close() }

        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted])
        else { throw ArchiveError.decodeFailed }
        defer { try? extractStream.close() }

        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
    }
}
