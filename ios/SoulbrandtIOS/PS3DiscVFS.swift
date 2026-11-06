import Foundation

/// Read-only bridge from PS3 cellFs paths to the imported ISO/UDF image.
/// All reader operations are serialized because ISO9660Reader owns a seekable
/// FileHandle and libudfread's volume lifetime belongs to the mounted image.
final class PS3DiscVFS {
    static let shared = PS3DiscVFS()

    private let lock = NSRecursiveLock()
    private var reader: (any DiscImageFileSystem)?
    private var openFiles: [UInt64: String] = [:]
    private var nextHandle: UInt64 = 1

    private init() {}

    func mount(_ newReader: any DiscImageFileSystem) {
        lock.lock()
        defer { lock.unlock() }
        reader = newReader
        openFiles.removeAll(keepingCapacity: true)
        nextHandle = 1
    }

    func unmount() {
        lock.lock()
        defer { lock.unlock() }
        openFiles.removeAll(keepingCapacity: false)
        reader = nil
    }

    private func normalizedPath(_ input: String) -> String? {
        guard !input.isEmpty, !input.utf8.contains(0) else { return nil }
        var path = input.replacingOccurrences(of: "\\", with: "/")
        if path == "/dev_bdvd" || path == "/app_home" { return "/" }
        if path.hasPrefix("/dev_bdvd/") {
            path.removeFirst("/dev_bdvd".count)
        } else if path.hasPrefix("/app_home/") {
            path.removeFirst("/app_home".count)
        }
        guard path.hasPrefix("/") else { return nil }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            if component == ".." || component.contains(":") { return nil }
            components.append(component)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    func open(path input: String, handleOut: UnsafeMutablePointer<UInt64>,
              sizeOut: UnsafeMutablePointer<UInt64>) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let reader, let path = normalizedPath(input) else { return -1 }
        do {
            let size = try reader.fileSize(path: path)
            let handle = nextHandle
            guard handle != 0 else { return -2 }
            nextHandle &+= 1
            openFiles[handle] = path
            handleOut.pointee = handle
            sizeOut.pointee = size
            return 0
        } catch {
            return -3
        }
    }

    func read(handle: UInt64, offset: UInt64, output: UnsafeMutableRawPointer?,
              length: UInt32) -> Int32 {
        guard let output, length > 0, length <= UInt32(Int32.max) else { return length == 0 ? 0 : -1 }
        lock.lock()
        defer { lock.unlock() }
        guard let reader, let path = openFiles[handle] else { return -2 }
        do {
            let data = try reader.readFile(path: path, offset: offset, length: Int(length))
            if !data.isEmpty { data.copyBytes(to: output.assumingMemoryBound(to: UInt8.self), count: data.count) }
            return Int32(data.count)
        } catch {
            return -3
        }
    }

    func close(handle: UInt64) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return openFiles.removeValue(forKey: handle) == nil ? -1 : 0
    }

    func list(path input: String, index: UInt32, nameOut: UnsafeMutablePointer<CChar>?,
              capacity: UInt32, directoryOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
        guard let nameOut, let directoryOut, capacity > 1 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard let reader, let path = normalizedPath(input) else { return -2 }
        do {
            let entries = try reader.entries(path: path)
            guard Int(index) < entries.count else { return 0 }
            let entry = entries[Int(index)]
            let bytes = Array(entry.name.utf8)
            guard bytes.count + 1 <= Int(capacity) else { return -3 }
            for i in 0..<bytes.count { nameOut[i] = CChar(bitPattern: bytes[i]) }
            nameOut[bytes.count] = 0
            directoryOut.pointee = entry.isDirectory ? 1 : 0
            return 1
        } catch {
            return -4
        }
    }

    func stat(path input: String, sizeOut: UnsafeMutablePointer<UInt64>?,
              directoryOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
        guard let sizeOut, let directoryOut else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard let reader, let path = normalizedPath(input) else { return -2 }
        if path == "/" {
            sizeOut.pointee = 0
            directoryOut.pointee = 1
            return 0
        }
        let parent = (path as NSString).deletingLastPathComponent
        let leaf = (path as NSString).lastPathComponent
        do {
            guard let entry = try reader.entries(path: parent).first(where: {
                $0.name.caseInsensitiveCompare(leaf) == .orderedSame
            }) else { return -3 }
            directoryOut.pointee = entry.isDirectory ? 1 : 0
            sizeOut.pointee = entry.isDirectory ? 0 : try reader.fileSize(path: path)
            return 0
        } catch {
            return -4
        }
    }
}

@_cdecl("soulbrandt_disc_vfs_open")
func soulbrandt_disc_vfs_open(_ path: UnsafePointer<CChar>?,
                              _ handleOut: UnsafeMutablePointer<UInt64>?,
                              _ sizeOut: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let path, let handleOut, let sizeOut else { return -1 }
    return PS3DiscVFS.shared.open(path: String(cString: path),
                                  handleOut: handleOut, sizeOut: sizeOut)
}

@_cdecl("soulbrandt_disc_vfs_read")
func soulbrandt_disc_vfs_read(_ handle: UInt64, _ offset: UInt64,
                              _ output: UnsafeMutableRawPointer?,
                              _ length: UInt32) -> Int32 {
    PS3DiscVFS.shared.read(handle: handle, offset: offset, output: output, length: length)
}

@_cdecl("soulbrandt_disc_vfs_close")
func soulbrandt_disc_vfs_close(_ handle: UInt64) -> Int32 {
    PS3DiscVFS.shared.close(handle: handle)
}

@_cdecl("soulbrandt_disc_vfs_list")
func soulbrandt_disc_vfs_list(_ path: UnsafePointer<CChar>?, _ index: UInt32,
                              _ nameOut: UnsafeMutablePointer<CChar>?,
                              _ capacity: UInt32,
                              _ directoryOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let path else { return -1 }
    return PS3DiscVFS.shared.list(path: String(cString: path), index: index,
                                  nameOut: nameOut, capacity: capacity,
                                  directoryOut: directoryOut)
}

@_cdecl("soulbrandt_disc_vfs_stat")
func soulbrandt_disc_vfs_stat(_ path: UnsafePointer<CChar>?,
                              _ sizeOut: UnsafeMutablePointer<UInt64>?,
                              _ directoryOut: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard let path else { return -1 }
    return PS3DiscVFS.shared.stat(path: String(cString: path),
                                  sizeOut: sizeOut, directoryOut: directoryOut)
}
