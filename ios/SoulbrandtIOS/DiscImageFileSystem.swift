import Foundation

struct DiscImageEntry {
    let name: String
    let isDirectory: Bool
}

protocol DiscImageFileSystem {
    var filesystemName: String { get }
    func entries(path: String) throws -> [DiscImageEntry]
    func readFile(path: String, offset: UInt64, length: Int) throws -> Data
}

extension ISO9660Reader: DiscImageFileSystem {
    var filesystemName: String { isJoliet ? "Joliet" : "ISO-9660" }

    func entries(path: String) throws -> [DiscImageEntry] {
        try list(path: path).map {
            DiscImageEntry(name: $0.name, isDirectory: $0.isDirectory)
        }
    }
}
