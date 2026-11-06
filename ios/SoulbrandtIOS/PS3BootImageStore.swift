#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum PS3BootImageStore {
    enum ExtractionError: LocalizedError {
        case executableMissing
        case notDecrypted
        case unsupportedELF
        case invalidSize
        case incompleteRead
        case paramsfoMissing
        case invalidParamsfo

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                return "No EBOOT.ELF or EBOOT.BIN was found in PS3_GAME/USRDIR."
            case .notDecrypted:
                return "EBOOT is a SELF/encrypted container, not a decrypted ELF. Decrypt it before importing."
            case .unsupportedELF:
                return "EBOOT is not a 64-bit big-endian PowerPC64 ELF."
            case .invalidSize:
                return "EBOOT size is invalid or exceeds the 512 MiB safety limit."
            case .incompleteRead:
                return "The disc reader returned an incomplete EBOOT chunk."
            case .paramsfoMissing:
                return "PS3_GAME/PARAM.SFO was not found on the disc."
            case .invalidParamsfo:
                return "PS3_GAME/PARAM.SFO is invalid or exceeds the 1 MiB safety limit."
            }
        }
    }

    static let outputName = "DecryptedEBOOT.ELF"
    private static let maximumSize: UInt64 = 512 * 1024 * 1024
    private static let chunkSize = 4 * 1024 * 1024

    static func extract(from reader: any DiscImageFileSystem, into directory: URL) throws -> URL {
        let entries = try reader.entries(path: "/PS3_GAME/USRDIR")
        guard let executable = entries.first(where: {
            !$0.isDirectory && ["EBOOT.ELF", "EBOOT.BIN"].contains($0.name.uppercased())
        }) else { throw ExtractionError.executableMissing }

        let sourcePath = "/PS3_GAME/USRDIR/\(executable.name)"
        let size = try reader.fileSize(path: sourcePath)
        guard size >= 64, size <= maximumSize else { throw ExtractionError.invalidSize }

        let header = try reader.readFile(path: sourcePath, offset: 0, length: 64)
        guard header.count == 64 else { throw ExtractionError.incompleteRead }
        if Array(header.prefix(4)) == [0x53, 0x43, 0x45, 0x00] {
            throw ExtractionError.notDecrypted
        }
        guard Array(header.prefix(7)) == [0x7f, 0x45, 0x4c, 0x46, 2, 2, 1],
              header[18] == 0, header[19] == 21 else {
            throw ExtractionError.unsupportedELF
        }

        let temporary = directory.appendingPathComponent(outputName + ".partial")
        let destination = directory.appendingPathComponent(outputName)
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
        }

        var offset: UInt64 = 0
        while offset < size {
            let count = Int(min(UInt64(chunkSize), size - offset))
            let chunk = try reader.readFile(path: sourcePath, offset: offset, length: count)
            guard chunk.count == count else { throw ExtractionError.incompleteRead }
            try output.write(contentsOf: chunk)
            offset += UInt64(count)
        }
        try output.synchronize()
        try output.close()

        // POSIX rename replaces an existing destination atomically on the same volume.
        // The temporary file lives beside the destination, so a failed extraction never
        // leaves a half-written EBOOT or destroys the previously completed one.
        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }

    static let paramsfoOutputName = "DecryptedPARAM.SFO"

    static func extractParamsfo(from reader: any DiscImageFileSystem, into directory: URL) throws -> URL {
        let entries = try reader.entries(path: "/PS3_GAME")
        guard let entry = entries.first(where: {
            !$0.isDirectory && $0.name.caseInsensitiveCompare("PARAM.SFO") == .orderedSame
        }) else { throw ExtractionError.paramsfoMissing }

        let sourcePath = "/PS3_GAME/\\(entry.name)"
        let size = try reader.fileSize(path: sourcePath)
        guard size >= 0x14, size <= 1024 * 1024 else {
            throw ExtractionError.invalidParamsfo
        }
        let bytes = try reader.readFile(path: sourcePath, offset: 0, length: Int(size))
        guard bytes.count == Int(size),
              Array(bytes.prefix(4)) == [0x00, 0x50, 0x53, 0x46] else {
            throw ExtractionError.invalidParamsfo
        }
        let destination = directory.appendingPathComponent(paramsfoOutputName)
        try Data(bytes).write(to: destination, options: .atomic)
        return destination
    }
}
