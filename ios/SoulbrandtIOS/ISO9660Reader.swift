import Foundation

/// Read-only random-access ISO-9660 reader with Joliet name support.
/// Not yet connected to ps3recomp's cellFs VFS. UDF, multi-extent files,
/// interleaved files, Rock Ridge extensions, and PS3 content decryption are not implemented.
final class ISO9660Reader {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        fileprivate let extentLBA: UInt32
    }

    enum ISOError: LocalizedError {
        case invalidImage, unsupportedVolume, malformedDirectory
        case notFound(String), notDirectory(String), isDirectory(String)
        case unsupportedMultiExtent, unsupportedInterleave, entryOutsideVolume
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The image is truncated or contains invalid sector references."
            case .unsupportedVolume: return "No supported ISO-9660 or Joliet descriptor was found. This image may use UDF."
            case .malformedDirectory: return "The ISO directory records are malformed."
            case .notFound(let path): return "Path not found: \(path)"
            case .notDirectory(let path): return "Not a directory: \(path)"
            case .isDirectory(let path): return "Is a directory, not a file: \(path)"
            case .unsupportedMultiExtent: return "Multi-extent files are not supported yet."
            case .unsupportedInterleave: return "Interleaved file extents are not supported yet."
            case .entryOutsideVolume: return "A directory entry points outside the declared volume."
            }
        }
    }

    private static let sectorSize: UInt64 = 2048
    private let handle: FileHandle
    private let imageSize: UInt64
    private var volumeSize: UInt64 = 0
    private var root: Entry?
    private var usesJoliet = false
    private let ioLock = NSLock()

    init(url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        handle = file
        imageSize = try file.seekToEnd()
        guard imageSize >= 17 * Self.sectorSize else { throw ISOError.invalidImage }

        var primary: (Entry, UInt64)?
        var joliet: (Entry, UInt64)?
        var foundTerminator = false
        for sector in 16..<128 {
            let offset = UInt64(sector) * Self.sectorSize
            guard offset + Self.sectorSize <= imageSize else { break }
            let descriptor = try readExactly(offset: offset, count: Int(Self.sectorSize))
            guard descriptor.count == Int(Self.sectorSize),
                  String(data: descriptor[1..<6], encoding: .ascii) == "CD001",
                  descriptor[6] == 1 else { throw ISOError.unsupportedVolume }
            let type = descriptor[0]
            if type == 255 { foundTerminator = true; break }
            guard type == 1 || type == 2 else { continue }
            let isJolietDescriptor = type == 2 && descriptor[88] == 0x25 &&
                [UInt8(0x40), 0x43, 0x45].contains(descriptor[89])
            if type == 2 && !isJolietDescriptor { continue }
            let rootOffset = 156
            let recordLength = Int(descriptor[rootOffset])
            guard recordLength >= 34, rootOffset + recordLength <= descriptor.count else {
                throw ISOError.malformedDirectory
            }
            let rootRecord = descriptor.subdata(in: rootOffset..<(rootOffset + recordLength))
            let rootEntry = try Self.parseRecord(rootRecord, joliet: isJolietDescriptor)
            guard rootEntry.isDirectory else { throw ISOError.malformedDirectory }
            let sectors = UInt64(try Self.readBothEndian32(descriptor, at: 80))
            if type == 1 { primary = (rootEntry, sectors) } else { joliet = (rootEntry, sectors) }
        }
        guard foundTerminator else { throw ISOError.unsupportedVolume }
        let selected: (Entry, UInt64, Bool)
        if let joliet { selected = (joliet.0, joliet.1, true) }
        else if let primary { selected = (primary.0, primary.1, false) }
        else { throw ISOError.unsupportedVolume }
        volumeSize = selected.1 * Self.sectorSize
        root = selected.0
        usesJoliet = selected.2
        guard volumeSize > 0, volumeSize <= imageSize else { throw ISOError.invalidImage }
        try validate(entry: selected.0)
    }

    deinit { try? handle.close() }
    var isJoliet: Bool { usesJoliet }

    /// Lists a volume-relative directory, for example /PS3_GAME/USRDIR.
    func list(path: String = "/") throws -> [Entry] {
        let directory = try resolve(path)
        guard directory.isDirectory else { throw ISOError.notDirectory(path) }
        return try readDirectory(directory)
    }

    /// Reads at most length bytes without loading the whole image into memory.
    func readFile(path: String, offset: UInt64 = 0, length: Int) throws -> Data {
        let entry = try resolve(path)
        guard !entry.isDirectory else { throw ISOError.isDirectory(path) }
        guard length >= 0, offset <= entry.size else { throw ISOError.invalidImage }
        let count64 = min(UInt64(length), entry.size - offset)
        guard count64 <= UInt64(Int.max) else { throw ISOError.invalidImage }
        let byteOffset = UInt64(entry.extentLBA) * Self.sectorSize + offset
        let data = try readExactly(offset: byteOffset, count: Int(count64))
        guard data.count == Int(count64) else { throw ISOError.invalidImage }
        return data
    }

    private func resolve(_ path: String) throws -> Entry {
        guard var current = root else { throw ISOError.invalidImage }
        for component in path.split(separator: "/").map(String.init) where component != "." && !component.isEmpty {
            guard component != ".." else { throw ISOError.notFound(path) }
            let children = try readDirectory(current)
            guard let next = children.first(where: { $0.name.caseInsensitiveCompare(component) == .orderedSame })
                else { throw ISOError.notFound(path) }
            current = next
        }
        return current
    }

    private func readDirectory(_ entry: Entry) throws -> [Entry] {
        guard entry.isDirectory, entry.size <= 64 * 1024 * 1024, entry.size <= UInt64(Int.max)
            else { throw ISOError.notDirectory(entry.name) }
        let base = UInt64(entry.extentLBA) * Self.sectorSize
        let data = try readExactly(offset: base, count: Int(entry.size))
        guard data.count == Int(entry.size) else { throw ISOError.malformedDirectory }
        var result: [Entry] = []
        var cursor = 0
        while cursor < data.count {
            let sectorOffset = cursor % Int(Self.sectorSize)
            let recordLength = Int(data[cursor])
            if recordLength == 0 { cursor += Int(Self.sectorSize) - sectorOffset; continue }
            guard recordLength >= 34, recordLength <= Int(Self.sectorSize) - sectorOffset,
                  cursor + recordLength <= data.count else { throw ISOError.malformedDirectory }
            let record = data.subdata(in: cursor..<(cursor + recordLength))
            let parsed = try Self.parseRecord(record, joliet: usesJoliet)
            if parsed.name != "." && parsed.name != ".." {
                try validate(entry: parsed)
                result.append(parsed)
            }
            cursor += recordLength
        }
        return result
    }

    private func validate(entry: Entry) throws {
        let start = UInt64(entry.extentLBA) * Self.sectorSize
        guard start <= volumeSize, entry.size <= volumeSize - start else { throw ISOError.entryOutsideVolume }
    }

    private static func parseRecord(_ data: Data, joliet: Bool) throws -> Entry {
        guard data.count >= 34 else { throw ISOError.malformedDirectory }
        let nameLength = Int(data[32])
        guard 33 + nameLength <= data.count else { throw ISOError.malformedDirectory }
        let extent = try readBothEndian32(data, at: 2)
        let size = try readBothEndian32(data, at: 10)
        let flags = data[25]
        if (flags & 0x80) != 0 { throw ISOError.unsupportedMultiExtent }
        if data[26] != 0 || data[27] != 0 { throw ISOError.unsupportedInterleave }
        let rawName = data.subdata(in: 33..<(33 + nameLength))
        let decoded: String
        if rawName.count == 1 && (rawName[0] == 0 || rawName[0] == 1) { decoded = rawName[0] == 0 ? "." : ".." }
        else if joliet {
            guard rawName.count.isMultiple(of: 2) else { throw ISOError.malformedDirectory }
            let units: [UInt16] = stride(from: 0, to: rawName.count, by: 2).map { i in
                (UInt16(rawName[i]) << 8) | UInt16(rawName[i + 1])
            }
            decoded = String(decoding: units, as: UTF16.self)
        } else { decoded = String(decoding: rawName, as: UTF8.self) }
        let cleanName = decoded.replacingOccurrences(of: #";[0-9]+$"#, with: "", options: .regularExpression)
        return Entry(name: cleanName, isDirectory: (flags & 0x02) != 0, size: UInt64(size), extentLBA: extent)
    }

    private static func readBothEndian32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 8 <= data.count else { throw ISOError.malformedDirectory }
        let little = u32LE(data, offset)
        let big = u32BE(data, offset + 4)
        guard little == big else { throw ISOError.malformedDirectory }
        return little
    }
    private static func u32LE(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
    }
    private static func u32BE(_ d: Data, _ i: Int) -> UInt32 {
        (UInt32(d[i]) << 24) | (UInt32(d[i+1]) << 16) | (UInt32(d[i+2]) << 8) | UInt32(d[i+3])
    }

    private func readExactly(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= imageSize, UInt64(count) <= imageSize - offset else {
            throw ISOError.invalidImage
        }
        ioLock.lock(); defer { ioLock.unlock() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
}