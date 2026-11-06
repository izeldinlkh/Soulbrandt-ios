import Foundation

/// Persistent writable storage roots for the PS3 HDD mounts.
/// The imported disc remains read-only; these folders live in Application Support.
enum PS3StorageOverlay {
    static func configure() throws {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let base = support.appendingPathComponent("SoulbrandtStorage", isDirectory: true)
        let hdd0 = base.appendingPathComponent("dev_hdd0", isDirectory: true)
        let hdd1 = base.appendingPathComponent("dev_hdd1", isDirectory: true)

        try FileManager.default.createDirectory(at: hdd0, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hdd1, withIntermediateDirectories: true)

        let result = hdd0.path.withCString { hdd0Path in
            hdd1.path.withCString { hdd1Path in
                soulbrandt_ppu_host_set_storage_roots(hdd0Path, hdd1Path)
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: "SoulbrandtStorageOverlay",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey:
                    "The PPU host could not configure persistent PS3 HDD storage (\(result))."]
            )
        }
    }
}
