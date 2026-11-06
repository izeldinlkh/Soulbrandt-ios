import Foundation

/// UDF reader backed by the LGPL-2.1 libudfread implementation.
final class UDFReader: DiscImageFileSystem {
    enum UDFError: LocalizedError {
        case allocationFailed
        case openFailed
        case directoryFailed(String)
        case fileNotFound(String)
        case invalidRange
        case readFailed

        var errorDescription: String? {
            switch self {
            case .allocationFailed: return "Could not allocate the UDF reader."
            case .openFailed: return "The image does not contain a readable UDF volume."
            case .directoryFailed(let path): return "Could not read UDF directory: \(path)"
            case .fileNotFound(let path): return "Could not open UDF file: \(path)"
            case .invalidRange: return "The requested UDF file range is invalid."
            case .readFailed: return "A UDF file read was incomplete."
            }
        }
    }

    private let volume: OpaquePointer
    var filesystemName: String { "UDF" }

    init(url: URL) throws {
        guard let handle = udfread_init() else { throw UDFError.allocationFailed }
        let result = url.path.withCString { udfread_open(handle, $0) }
        guard result == 0 else {
            udfread_close(handle)
            throw UDFError.openFailed
        }
        volume = handle
    }

    deinit { udfread_close(volume) }

    func entries(path: String) throws -> [DiscImageEntry] {
        guard let directory = path.withCString({ udfread_opendir(volume, $0) }) else {
            throw UDFError.directoryFailed(path)
        }
        defer { udfread_closedir(directory) }

        var rawEntry = udfread_dirent()
        var result: [DiscImageEntry] = []
        while udfread_readdir(directory, &rawEntry) != nil {
            guard let name = rawEntry.d_name else { continue }
            result.append(DiscImageEntry(
                name: String(cString: name),
                isDirectory: rawEntry.d_type == UInt32(UDF_DT_DIR)
            ))
        }
        return result
    }

    func readFile(path: String, offset: UInt64 = 0, length: Int) throws -> Data {
        guard length >= 0,
              let file = path.withCString({ udfread_file_open(volume, $0) }) else {
            throw UDFError.fileNotFound(path)
        }
        defer { udfread_file_close(file) }

        let signedSize = udfread_file_size(file)
        guard signedSize >= 0 else { throw UDFError.readFailed }
        let fileSize = UInt64(signedSize)
        guard offset <= fileSize, offset <= UInt64(Int64.max) else {
            throw UDFError.invalidRange
        }
        let count = min(UInt64(length), fileSize - offset)
        guard count <= UInt64(Int.max) else { throw UDFError.invalidRange }
        guard udfread_file_seek(file, Int64(offset), Int32(UDF_SEEK_SET)) >= 0 else {
            throw UDFError.invalidRange
        }

        var bytes = [UInt8](repeating: 0, count: Int(count))
        let received = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return Int(udfread_file_read(file, baseAddress, buffer.count))
        }
        guard received == bytes.count else { throw UDFError.readFailed }
        return Data(bytes)
    }
}
