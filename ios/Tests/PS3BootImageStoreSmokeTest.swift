import Foundation

private struct FakeDisc: DiscImageFileSystem {
    let executable: Data
    let executableName: String
    var filesystemName: String { "Fake" }

    func entries(path: String) throws -> [DiscImageEntry] {
        if path == "/PS3_GAME/USRDIR" {
            return [DiscImageEntry(name: executableName, isDirectory: false)]
        }
        return []
    }

    func fileSize(path: String) throws -> UInt64 { UInt64(executable.count) }

    func readFile(path: String, offset: UInt64, length: Int) throws -> Data {
        guard offset <= UInt64(executable.count), length >= 0 else { return Data() }
        let start = Int(offset)
        let end = min(executable.count, start + length)
        return executable.subdata(in: start..<end)
    }
}

private func makeELF(payload: [UInt8]) -> Data {
    var bytes = [UInt8](repeating: 0, count: 64)
    bytes[0...6] = [0x7f, 0x45, 0x4c, 0x46, 2, 2, 1]
    bytes[16] = 0
    bytes[17] = 2
    bytes[18] = 0
    bytes[19] = 21
    return Data(bytes + payload)
}

@main
private enum PS3BootImageStoreSmokeTest {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soulbrandt-EBOOT-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent(PS3BootImageStore.outputName)
        try Data("old-complete-image".utf8).write(to: destination)

        let firstImage = makeELF(payload: Array(0..<17))
        let firstURL = try PS3BootImageStore.extract(
            from: FakeDisc(executable: firstImage, executableName: "EBOOT.ELF"),
            into: directory
        )
        precondition(firstURL == destination)
        precondition(try Data(contentsOf: destination) == firstImage,
                     "Extraction must replace an existing complete EBOOT")

        let encrypted = Data([0x53, 0x43, 0x45, 0x00] + Array(repeating: UInt8(0), count: 60))
        do {
            _ = try PS3BootImageStore.extract(
                from: FakeDisc(executable: encrypted, executableName: "EBOOT.BIN"),
                into: directory
            )
            fatalError("SELF image should not be accepted")
        } catch PS3BootImageStore.ExtractionError.notDecrypted {
            // Expected. Existing output must remain intact.
        }
        precondition(try Data(contentsOf: destination) == firstImage,
                     "Rejected input must not damage the previous output")

        print("PS3 boot image store smoke test passed")
    }
}
