import Foundation

private struct MemoryDisc: DiscImageFileSystem {
    let files: [String: Data] = [
        "/PS3_GAME/USRDIR/EBOOT.ELF": Data([0x7f, 0x45, 0x4c, 0x46]),
        "/PS3_GAME/PARAM.SFO": Data("sfo-data".utf8)
    ]
    var filesystemName: String { "MemoryDisc" }

    func entries(path: String) throws -> [DiscImageEntry] {
        switch path {
        case "/":
            return [DiscImageEntry(name: "PS3_GAME", isDirectory: true)]
        case "/PS3_GAME":
            return [
                DiscImageEntry(name: "USRDIR", isDirectory: true),
                DiscImageEntry(name: "PARAM.SFO", isDirectory: false)
            ]
        case "/PS3_GAME/USRDIR":
            return [DiscImageEntry(name: "EBOOT.ELF", isDirectory: false)]
        default:
            throw NSError(domain: "MemoryDisc", code: 1)
        }
    }

    func fileSize(path: String) throws -> UInt64 {
        guard let data = files[path] else { throw NSError(domain: "MemoryDisc", code: 2) }
        return UInt64(data.count)
    }

    func readFile(path: String, offset: UInt64, length: Int) throws -> Data {
        guard let data = files[path], offset <= UInt64(data.count), length >= 0 else {
            throw NSError(domain: "MemoryDisc", code: 3)
        }
        let start = Int(offset)
        return data.subdata(in: start..<min(data.count, start + length))
    }
}

@main
private enum PS3DiscVFSSmokeTest {
    static func main() {
        let vfs = PS3DiscVFS.shared
        vfs.mount(MemoryDisc())

        var handle: UInt64 = 0
        var size: UInt64 = 0
        let opened = "/dev_bdvd/PS3_GAME/USRDIR/EBOOT.ELF".withCString {
            soulbrandt_disc_vfs_open($0, &handle, &size)
        }
        precondition(opened == 0 && size == 4 && handle != 0)

        var bytes = [UInt8](repeating: 0, count: 4)
        let count = bytes.withUnsafeMutableBytes {
            soulbrandt_disc_vfs_read(handle, 0, $0.baseAddress, 4)
        }
        precondition(count == 4 && bytes == [0x7f, 0x45, 0x4c, 0x46])
        precondition(soulbrandt_disc_vfs_close(handle) == 0)
        precondition(soulbrandt_disc_vfs_close(handle) == -1)

        // /app_home is the executable directory, not the disc root.
        let appHomeOpened = "/app_home/EBOOT.ELF".withCString {
            soulbrandt_disc_vfs_open($0, &handle, &size)
        }
        precondition(appHomeOpened == 0 && size == 4 && handle != 0)
        precondition(soulbrandt_disc_vfs_close(handle) == 0)

        var appHomeDirectory: UInt8 = 0
        var appHomeSize: UInt64 = 99
        let appHomeStat = "/app_home".withCString {
            soulbrandt_disc_vfs_stat($0, &appHomeSize, &appHomeDirectory)
        }
        precondition(appHomeStat == 0 && appHomeDirectory == 1 && appHomeSize == 0)

        var appHomeEntry = [CChar](repeating: 0, count: 64)
        var appHomeEntryIsDirectory: UInt8 = 1
        let appHomeList = "/app_home".withCString { path in
            appHomeEntry.withUnsafeMutableBufferPointer { buffer in
                soulbrandt_disc_vfs_list(path, 0, buffer.baseAddress, 64, &appHomeEntryIsDirectory)
            }
        }
        precondition(appHomeList == 1 &&
                     String(cString: appHomeEntry) == "EBOOT.ELF" &&
                     appHomeEntryIsDirectory == 0)

        let appHomeTraversal = "/app_home/../../private".withCString {
            soulbrandt_disc_vfs_open($0, &handle, &size)
        }
        precondition(appHomeTraversal < 0)

        var statSize: UInt64 = 0
        var isDirectory: UInt8 = 0
        let statResult = "/dev_bdvd/PS3_GAME".withCString {
            soulbrandt_disc_vfs_stat($0, &statSize, &isDirectory)
        }
        precondition(statResult == 0 && isDirectory == 1)

        var name = [CChar](repeating: 0, count: 64)
        var entryIsDirectory: UInt8 = 0
        let listResult = "/dev_bdvd/PS3_GAME".withCString { path in
            name.withUnsafeMutableBufferPointer { buffer in
                soulbrandt_disc_vfs_list(path, 0, buffer.baseAddress, 64, &entryIsDirectory)
            }
        }
        precondition(listResult == 1 && String(cString: name) == "USRDIR" && entryIsDirectory == 1)

        let traversal = "/dev_bdvd/../private".withCString {
            soulbrandt_disc_vfs_open($0, &handle, &size)
        }
        precondition(traversal < 0)

        vfs.unmount()
        precondition(soulbrandt_disc_vfs_open("/PS3_GAME/PARAM.SFO", &handle, &size) < 0)
        print("PS3 disc VFS smoke test passed")
    }
}
