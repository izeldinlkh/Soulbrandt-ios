import Foundation

/// Read-only view of an extracted PS3 game directory. The selected folder may
/// be either the PS3_GAME directory itself or its parent containing PS3_GAME.
final class ExtractedGameDirectoryReader: DiscImageFileSystem {
    enum ReaderError: LocalizedError {
        case missingGameDirectory
        case invalidPath
        case notFound(String)
        case notDirectory(String)
        case notFile(String)
        case readFailed

        var errorDescription: String? {
            switch self {
            case .missingGameDirectory: return "Selected folder does not contain PS3_GAME."
            case .invalidPath: return "The requested game path is invalid."
            case .notFound(let path): return "Game file or directory not found: \(path)"
            case .notDirectory(let path): return "Not a directory: \(path)"
            case .notFile(let path): return "Not a regular file: \(path)"
            case .readFailed: return "Could not read the requested game-file range."
            }
        }
    }

    private let root: URL
    var filesystemName: String { "Extracted PS3 folder" }

    init(url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ReaderError.missingGameDirectory }
        let direct = url.appendingPathComponent("PS3_GAME", isDirectory: true)
        let candidate = url.lastPathComponent.caseInsensitiveCompare("PS3_GAME") == .orderedSame
            ? url : direct
        var gameIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &gameIsDirectory),
              gameIsDirectory.boolValue else { throw ReaderError.missingGameDirectory }
        // Keep the disc root as the VFS root so callers use /PS3_GAME/...
        root = candidate.deletingLastPathComponent().standardizedFileURL
    }

    private func resolve(_ input: String) throws -> URL {
        guard !input.isEmpty, !input.utf8.contains(0) else { throw ReaderError.invalidPath }
        let components = input.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains(":") else {
            throw ReaderError.invalidPath
        }
        let url = components.reduce(root) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(prefix) else {
            throw ReaderError.invalidPath
        }
        return url
    }

    func entries(path: String) throws -> [DiscImageEntry] {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ReaderError.notFound(path)
        }
        guard isDirectory.boolValue else { throw ReaderError.notDirectory(path) }
        return try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).compactMap { item in
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { return nil }
                return DiscImageEntry(name: item.lastPathComponent,
                                      isDirectory: values.isDirectory == true)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fileSize(path: String) throws -> UInt64 {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size >= 0 else { throw ReaderError.notFile(path) }
        return UInt64(size)
    }

    func readFile(path: String, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, offset <= UInt64(Int64.max) else { throw ReaderError.readFailed }
        let url = try resolve(path)
        _ = try fileSize(path: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}
