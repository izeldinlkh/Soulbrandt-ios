import Foundation

private func putBothEndian32(_ value: UInt32, into data: inout Data, at offset: Int) {
    for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xff) }
    for i in 0..<4 { data[offset + 4 + i] = UInt8((value >> (8 * (3 - i))) & 0xff) }
}

private func directoryRecord(name: [UInt8], extent: UInt32, size: UInt32, directory: Bool) -> Data {
    let length = 33 + name.count + (name.count.isMultiple(of: 2) ? 1 : 0)
    var record = Data(repeating: 0, count: length)
    record[0] = UInt8(length)
    putBothEndian32(extent, into: &record, at: 2)
    putBothEndian32(size, into: &record, at: 10)
    record[25] = directory ? 0x02 : 0x00
    record[28] = 0x01
    record[30] = 0x01
    record[32] = UInt8(name.count)
    for (index, byte) in name.enumerated() { record[33 + index] = byte }
    return record
}

private func descriptor(type: UInt8, volumeSectors: UInt32, rootRecord: Data) -> Data {
    var block = Data(repeating: 0, count: 2048)
    block[0] = type
    for (i, byte) in Array("CD001".utf8).enumerated() { block[1 + i] = byte }
    block[6] = 1
    putBothEndian32(volumeSectors, into: &block, at: 80)
    block[156] = UInt8(rootRecord.count)
    block.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)
    return block
}

func makeFixture() throws -> URL {
    let sectorSize = 2048
    let volumeSectors: UInt32 = 24
    var image = Data(repeating: 0, count: sectorSize * Int(volumeSectors))

    let root = directoryRecord(name: [0], extent: 20, size: 2048, directory: true)
    image.replaceSubrange((16 * sectorSize)..<(17 * sectorSize),
                          with: descriptor(type: 1, volumeSectors: volumeSectors, rootRecord: root))
    image[17 * sectorSize] = 255
    for (i, byte) in Array("CD001".utf8).enumerated() { image[17 * sectorSize + 1 + i] = byte }
    image[17 * sectorSize + 6] = 1

    var directory = Data(repeating: 0, count: sectorSize)
    let dot = directoryRecord(name: [0], extent: 20, size: 2048, directory: true)
    let dotdot = directoryRecord(name: [1], extent: 20, size: 2048, directory: true)
    let file = directoryRecord(name: Array("README.TXT;1".utf8), extent: 21, size: 5, directory: false)
    var cursor = 0
    for record in [dot, dotdot, file] {
        directory.replaceSubrange(cursor..<(cursor + record.count), with: record)
        cursor += record.count
    }
    image.replaceSubrange((20 * sectorSize)..<(21 * sectorSize), with: directory)
    image.replaceSubrange((21 * sectorSize)..<(21 * sectorSize + 5), with: Data("hello".utf8))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
    try image.write(to: url)
    return url
}

let url = try makeFixture()
defer { try? FileManager.default.removeItem(at: url) }
let reader = try ISO9660Reader(url: url)
let entries = try reader.list()
precondition(entries.count == 1 && entries[0].name == "README.TXT", "Directory listing failed")
let bytes = try reader.readFile(path: "/README.TXT", length: 32)
precondition(String(data: bytes, encoding: .utf8) == "hello", "Random-access file read failed")
print("ISO9660Reader smoke test passed")
