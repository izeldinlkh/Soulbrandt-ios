import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let reader = try ExtractedGameDirectoryReader(url: source)
precondition(reader.filesystemName == "Extracted PS3 folder")
let root = try reader.entries(path: "/")
precondition(root.contains { $0.name == "PS3_GAME" && $0.isDirectory })
precondition((try reader.entries(path: "/PS3_GAME")).contains { $0.name == "USRDIR" && $0.isDirectory })
let nested = try reader.readFile(path: "/PS3_GAME/USRDIR/sub/asset.bin", offset: 0, length: 10)
precondition(String(data: nested, encoding: .utf8) == "asset-data")
precondition(try reader.fileSize(path: "/USRDIR/sub/asset.bin") == 10)
do {
    _ = try reader.entries(path: "/../../")
    fatalError("path traversal was accepted")
} catch ExtractedGameDirectoryReader.ReaderError.invalidPath {
    // Expected.
}
print("Extracted game directory reader smoke test passed")
