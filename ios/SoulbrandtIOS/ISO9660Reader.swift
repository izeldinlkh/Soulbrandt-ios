import Foundation

/// Read-only random-access reader for ISO-9660 primary and Joliet directory trees.
/// This is an import/inspection primitive, not yet connected to ps3recomp's cellFs VFS.
/// UDF, multi-extent files, interleaved files, and encrypted PS3 content are not handled.
final class ISO9660Reader {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        fileprivate let extentLBA: UInt32
    }

    enum ISOError: Error {
        case invalidImage
        case unsupportedVolume
        case malformedDirectory
        case notFound(String)
        case notDirectory(String)
        case isDirectory(String)
        case unsupportedMultiExtent
    }

    private let handle: FileHandle
    private let sectorSize: UInt64 = 2048
    private let volumeSpaceSize: UInt64
    private let root: Entry
    private let joliet: Bool

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 17 * sectorSize else { throw ISOError.invalidImage }

        var primary: (Entry, UInt64)?
        var supplementary: (Entry, UInt64)?
        var volumeSectors: UInt64?

        for sector in 16..<64 {
            let offset = sector * sectorSize
            guard offset + sectorSize <= fileSize,
                  let data = try readExactly(offset: offset, count: Int(sectorSize)),
                  data.count == Int(sectorSize) else { break }
            let type = data[0]
            guard String(data: data[1..<6], encoding: .ascii) == "CD001",
                  data[6] == 1 else { break }
            if type == 255 { break }
            if type == 1 || type == 2 {
                let isJoliet = type == 2 && data[88] == 0x25 && data[89] == 0x2F
                let rootOffset = 156
                guard data.count > rootOffset + 33 else { throw ISOError.malformedDirectory }
                let recordLength = Int(data[rootOffset])
                guard recordLength >= 34, rootOffset + recordLength <= data.count else {
                    throw ISOError.malformedDirectory
                }
                let record = data.subdata(in: rootOffset..<(rootOffset + recordLength))
                let rootEntry = try Self.parseRecord(record, joliet: isJoliet)
                let sectors = UInt64(Self.u32LE(data, 80))
                if type == 1 {
                    primary = (rootEntry, sectors)
                } else if isJoliet {
                    supplementary = (rootEntry, sectors)
                }
            }
        }

        if let supplementary {
            root = supplementary.0
            volumeSpaceSize = supplementary.1
            joliet = true
        } else if let primary {
            root = primary.0
            volumeSpaceSize = primary.1
            joliet = false
        } else {
            throw ISOError.unsupportedVolume
        }
        guard volumeSpaceSize > 0, volumeSpaceSize * sectorSize <= fileSize else {
            throw ISOError.invalidImage
        }
    }

    deinit { try? handle.close() }

    func list(path: String = "/") throws -> [Entry] {
        let directory = try resolve(path)
        guard directory.isDirectory else { throw ISOError.notDirectory(path) }
        return try readDirectory(directory)
    }

    /// Reads a bounded range from a file without loading the whole image or file into memory.
    func readFile(path: String, offset: UInt64 = 0, length: Int) throws -> Data {
        let entry = try resolve(path)
        guard !entry.isDirectory else { throw ISOError.isDirectory(path) }
        guard offset <= entry.size else { throw ISOError.invalidImage }
        let count = min(UInt64(max(0, length)), entry.size - offset)
        guard count <= UInt64(Int.max) else { throw ISOError.invalidImage }
        let byteOffset = UInt64(entry.extentLBA) * sectorSize + offset
        guard let data = try readExactly(offset: byteOffset, count: Int(count)),
              data.count == Int(count) else { throw ISOError.invalidImage }
        return data
    }

    private func resolve(_ path: String) throws -> Entry {
        let components = path.split(separator: "/").map(String.init)
        var current = root
        for component in components where component != "." && !component.isEmpty {
            if component == ".." { throw ISOError.notFound(path) }
            let children = try readDirectory(current)
            guard let next = children.first(where: {
                $0.name.caseInsensitiveCompare(component) == .orderedSame
            }) else { throw ISOError.notFound(path) }
            current = next
        }
        return current
    }

    private func readDirectory(_ entry: Entry) throws -> [Entry] {
        guard entry.isDirectory else { throw ISOError.notDirectory(entry.name) }
        let base = UInt64(entry.extentLBA) * sectorSize
        guard let data = try readExactly(offset: base, count: Int(entry.size)),
              data.count == Int(entry.size) else { throw ISOError.malformedDirectory }

        var entries: [Entry] = []
        var cursor = 0
        while cursor < data.count {
            let length = Int(data[cursor])
            if length == 0 {
                cursor = ((cursor / Int(sectorSize)) + 1) * Int(sectorSize)
                continue
            }
            guard length >= 34, cursor + length <= data.count else {
                throw ISOError.malformedDirectory
            }
            let record = data.subdata(in: cursor..<(cursor + length))
            let parsed = try Self.parseRecord(record, joliet: joliet)
            if parsed.name != "." && parsed.name != ".." {
                entries.append(parsed)
            }
            cursor += length
        }
        return entries
    }

    private static func parseRecord(_ data: Data, joliet: Bool) throws -> Entry {
        guard data.count >= 34 else { throw ISOError.malformedDirectory }
        let nameLength = Int(data[32])
        guard 33 + nameLength <= data.count else { throw ISOError.malformedDirectory }
        let rawName = data.subdata(in: 33..<(33 + nameLength))
        let decoded: String
        if rawName.count == 1 && (rawName[0] == 0 || rawName[0] == 1) {
            decoded = rawName[0] == 0 ? "." : ".."
        } else if joliet {
            let units = stride(from: 0, to: rawName.count - (rawName.count % 2), by: 2).map { index in
                (UInt16(rawName[index]) << 8) | UInt16(rawName[index + 1])
            }
            decoded = String(decoding: units, as: UTF16.self)
        } else {
            decoded = String(decoding: rawName, as: UTF8.self)
        }
        let cleanName = decoded.replacingOccurrences(of: #"\\;[0-9]+$"#, with: "", options: .regularExpression)
        let flags = data[25]
        let extent = u32LE(data, 2)
        let size = UInt64(u32LE(data, 10))
        return Entry(name: cleanName, isDirectory: (flags & 0x02) != 0,
                     size: size, extentLBA: extent)
    }

    private func readExactly(offset: UInt64, count: Int) throws -> Data? {
        guard count >= 0 else { return nil }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count)
    }

    private static func u32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}
