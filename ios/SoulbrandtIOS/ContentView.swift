import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = ControllerMonitor()
    @State private var showingImporter = false
    @State private var importedISOName: String?
    @State private var volumeSummary: String?
    @State private var importError: String?
    @State private var isImporting = false
    @State private var rsxBackendReady = false
    @State private var rsxBackendStatus = "RSX backend not initialized"
    @State private var ebootStatus = "No decrypted EBOOT extracted"
    @State private var extractedEbootURL: URL?

    private let savedISOKey = "Soulbrandt.importedISOName"
    private let savedSummaryKey = "Soulbrandt.importedISOSummary"
    private let savedEbootISOKey = "Soulbrandt.extractedEbootISOName"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Soulbrandt")
                    .font(.largeTitle.bold())
                Text("Demon’s Souls iOS port — development build")
                    .foregroundStyle(.secondary)

                GroupBox("Game image") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let importedISOName {
                            Label(importedISOName, systemImage: "opticaldisc")
                                .lineLimit(2)
                            if let volumeSummary {
                                Text(volumeSummary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No ISO imported")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showingImporter = true
                        } label: {
                            if isImporting {
                                Label("Importing…", systemImage: "hourglass")
                            } else {
                                Label("Import game ISO", systemImage: "folder")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting)

                        Text("Import stores the image in this app’s private storage. It can inspect ISO-9660/Joliet and UDF images, but does not decrypt game files or boot the game.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if isImporting {
                            ProgressView("Copying and inspecting image…")
                                .font(.footnote)
                        }
                        Text(ebootStatus)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                        if extractedEbootURL != nil {
                            Button { loadExtractedEboot() } label: {
                                Label("Load EBOOT into guest memory", systemImage: "memorychip")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!rsxBackendReady)
                        }
                        Text("The upstream PPU loader now maps the ELF and initializes HLE, filesystem and syscall tables. Guest execution still requires the game-specific PPU lift and SPU workloads in the IPA.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("UDF support uses libudfread (LGPL-2.1); see the bundled COPYING notice.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Metal renderer") {
                    VStack(alignment: .leading, spacing: 8) {
                        MetalRendererView(rsxBackendReady: rsxBackendReady)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 10) {
                            Button {
                                initializeRSXBackend()
                            } label: {
                                Label("Initialize RSX backend", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(rsxBackendReady)

                            if rsxBackendReady {
                                Button {
                                    stopRSXBackend()
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        Text(rsxBackendStatus)
                            .font(.footnote.monospaced())
                            .foregroundStyle(rsxBackendReady ? Color.green : Color.secondary)
                        Text("This initializes the RSX Metal surface and native PS3 controller HLE. It does not boot the game; generated PPU/SPU code and decrypted game data are still required.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Controller") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(controller.controllerName ?? "No controller detected",
                              systemImage: "gamecontroller")
                        Text(controller.lastInput)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("PS3 button mask: 0x\(String(format: "%04X", PS3PadMapper.make(snapshot: controller.input).buttons))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("L2/R2: \(PS3PadMapper.make(snapshot: controller.input).analogL2)/\(PS3PadMapper.make(snapshot: controller.input).analogR2) • Cross/Circle/Square/Triangle: mapped")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "Left stick %.2f, %.2f • Right stick %.2f, %.2f", controller.input.leftX, controller.input.leftY, controller.input.rightX, controller.input.rightY))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .task {
                restoreImportedImage()
            }
            .onDisappear {
                stopRSXBackend()
            }
        }
    }



    private func loadExtractedEboot() {
        guard let url = extractedEbootURL, rsxBackendReady else { return }
        do {
            try PS3StorageOverlay.configure()
        } catch {
            ebootStatus = "Could not prepare save/cache storage: \(error.localizedDescription)"
            return
        }
        let entry = url.path.withCString { soulbrandt_ppu_host_load_elf($0) }
        guard entry != 0 else {
            ebootStatus = "Upstream PPU loader rejected the extracted EBOOT"
            return
        }
        let functions = soulbrandt_ppu_host_function_count()
        let hleEntries = soulbrandt_ppu_host_hle_count()
        ebootStatus = String(
            format: "EBOOT mapped • OPD 0x%08X • PPU funcs %u • HLE NIDs %u • not booted",
            entry, functions, hleEntries
        )
    }

    private func initializeRSXBackend() {
        let result = soulbrandt_rsx_backend_initialize()
        if result == 0 {
            rsxBackendReady = true
            rsxBackendStatus = "4 GiB guest VM reserved • RSX Metal, controller, frame pump and PPU/HLE host linked • title code not yet built"
        } else {
            soulbrandt_rsx_backend_shutdown()
            rsxBackendReady = false
            if result == -1001 {
                rsxBackendStatus = "Metal drawable and iOS input adapter are ready; des_boot host and generated PPU/SPU code are not linked yet"
            } else if result == -1000 {
                rsxBackendStatus = "Metal drawable layer is not available yet"
            } else {
                rsxBackendStatus = "RSX Metal initialization failed (\(result))"
            }
        }
    }

    private func stopRSXBackend() {
        guard rsxBackendReady else { return }
        soulbrandt_rsx_backend_shutdown()
        rsxBackendReady = false
        rsxBackendStatus = "RSX backend stopped"
    }

    private func restoreImportedImage() {
        guard let name = UserDefaults.standard.string(forKey: savedISOKey) else { return }
        let directory = gameImagesDirectory()
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: savedISOKey)
            return
        }
        importedISOName = name
        volumeSummary = UserDefaults.standard.string(forKey: savedSummaryKey) ?? "Stored in app storage."
        do {
            let reader: any DiscImageFileSystem
            do { reader = try UDFReader(url: url) }
            catch { reader = try ISO9660Reader(url: url) }
            PS3DiscVFS.shared.mount(reader)
        } catch {
            PS3DiscVFS.shared.unmount()
        }
        let eboot = gameImagesDirectory().appendingPathComponent(PS3BootImageStore.outputName)
        if UserDefaults.standard.string(forKey: savedEbootISOKey) == name,
           FileManager.default.fileExists(atPath: eboot.path) {
            extractedEbootURL = eboot
            ebootStatus = "Decrypted EBOOT extracted • ready to load"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            guard source.pathExtension.lowercased() == "iso" else {
                throw ImportFailure.notISO
            }

            // File-provider URLs normally need a security-scoped grant. URLs that
            // already live inside this app/container may be directly readable without
            // one (a relevant case for containerized installs such as LiveContainer).
            let hasSecurityScope = source.startAccessingSecurityScopedResource()
            let isDirectlyReadable = FileManager.default.isReadableFile(atPath: source.path)
            guard hasSecurityScope || isDirectlyReadable else {
                throw ImportFailure.accessDenied
            }

            // A different image must not replace the mounted VFS while the
            // previous guest VM or PPU entry is still live.
            if rsxBackendReady {
                stopRSXBackend()
            }

            isImporting = true
            importError = nil

            Task {
                defer {
                    if hasSecurityScope {
                        source.stopAccessingSecurityScopedResource()
                    }
                    isImporting = false
                }
                do {
                    let outcome = try await Task.detached(priority: .userInitiated) {
                        try Self.copyAndInspectISO(source: source)
                    }.value
                    importedISOName = outcome.name
                    volumeSummary = outcome.summary
                    extractedEbootURL = outcome.ebootURL
                    ebootStatus = outcome.ebootStatus
                    if outcome.ebootURL != nil {
                        UserDefaults.standard.set(outcome.name, forKey: savedEbootISOKey)
                    } else {
                        UserDefaults.standard.removeObject(forKey: savedEbootISOKey)
                    }
                    UserDefaults.standard.set(outcome.name, forKey: savedISOKey)
                    UserDefaults.standard.set(outcome.summary, forKey: savedSummaryKey)
                } catch {
                    importError = "Import failed: \(error.localizedDescription)"
                }
            }
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func gameImagesDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("GameImages", isDirectory: true)
    }

    nonisolated private static func inspectDisc(_ reader: any DiscImageFileSystem) throws -> String {
        let rootEntries = try reader.entries(path: "/")
        let hasPS3Game = rootEntries.contains {
            $0.isDirectory && $0.name.caseInsensitiveCompare("PS3_GAME") == .orderedSame
        }
        var summary = "\(reader.filesystemName) filesystem • " + (
            hasPS3Game ? "PS3_GAME directory found" : "PS3_GAME was not found in the root"
        )
        guard hasPS3Game else { return summary }

        let gameEntries = try reader.entries(path: "/PS3_GAME")
        let hasUSRDIR = gameEntries.contains {
            $0.isDirectory && $0.name.caseInsensitiveCompare("USRDIR") == .orderedSame
        }
        guard hasUSRDIR else { return summary + " • PS3_GAME/USRDIR was not found" }

        let userFiles = try reader.entries(path: "/PS3_GAME/USRDIR")
        let executable = userFiles.first {
            !$0.isDirectory && (
                $0.name.caseInsensitiveCompare("EBOOT.ELF") == .orderedSame ||
                $0.name.caseInsensitiveCompare("EBOOT.BIN") == .orderedSame
            )
        }
        guard let executable else { return summary + " • EBOOT file not found" }

        let header = try reader.readFile(
            path: "/PS3_GAME/USRDIR/\(executable.name)", offset: 0, length: 20
        )
        if header.count >= 20,
           Array(header.prefix(4)) == [0x7f, 0x45, 0x4c, 0x46] {
            let is64Bit = header[4] == 2
            let isBigEndian = header[5] == 2
            let machine = (UInt16(header[18]) << 8) | UInt16(header[19])
            let architecture = machine == 21 ? " • PowerPC64" : ""
            summary += " • ELF header found\(architecture)\(is64Bit && isBigEndian ? " (64-bit big-endian)" : "")"
        } else if header.count >= 4,
                  Array(header.prefix(4)) == [0x53, 0x43, 0x45, 0x00] {
            summary += " • SELF container found; executable is not confirmed decrypted"
        } else {
            summary += " • EBOOT file found, but its format is unrecognized"
        }
        return summary
    }

    nonisolated private static func copyAndInspectISO(source: URL) throws -> (name: String, summary: String, ebootURL: URL?, ebootStatus: String) {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let directory = support.appendingPathComponent("GameImages", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(resourceValues)

        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fileManager.removeItem(at: temporary) }

        // A large disc image is copied into the app sandbox. Refuse early rather
        // than filling the user's storage halfway through a multi-gigabyte import.
        let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        guard let sourceSizeNumber = sourceAttributes[.size] as? NSNumber,
              sourceSizeNumber.int64Value > 0 else {
            throw ImportFailure.invalidSource
        }
        let sourceSize = sourceSizeNumber.int64Value
        let safetyMargin: Int64 = 512 * 1024 * 1024
        let (requiredSpace, overflow) = sourceSize.addingReportingOverflow(safetyMargin)
        guard !overflow else { throw ImportFailure.invalidSource }

        let capacityValues = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let availableSpace = capacityValues.volumeAvailableCapacityForImportantUsage
            ?? capacityValues.volumeAvailableCapacity.map { Int64($0) }
        if let availableSpace, availableSpace < requiredSpace {
            throw ImportFailure.insufficientStorage(
                required: requiredSpace,
                available: availableSpace
            )
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                try fileManager.copyItem(at: readableURL, to: temporary)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }

        var summary = "Imported. Disc filesystem could not be read."
        var ebootURL: URL?
        var ebootStatus = "EBOOT extraction was not attempted."
        var mountedReader: (any DiscImageFileSystem)?
        do {
            let reader: any DiscImageFileSystem
            do {
                // Prefer UDF for Blu-ray images; fall back for ordinary ISO-9660 images.
                reader = try UDFReader(url: temporary)
            } catch {
                reader = try ISO9660Reader(url: temporary)
            }
            mountedReader = reader
            summary = try Self.inspectDisc(reader)
            do {
                ebootURL = try PS3BootImageStore.extract(from: reader, into: directory)
                let attrs = try fileManager.attributesOfItem(atPath: ebootURL!.path)
                let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                ebootStatus = "Decrypted EBOOT extracted • " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            } catch {
                ebootStatus = error.localizedDescription
            }
        } catch {
            summary = "Imported. Disc filesystem inspection failed: \(error.localizedDescription)"
        }

        // The temporary file is in the same directory/volume as the destination.
        // POSIX rename replaces an existing image atomically, so a failed import never
        // destroys the user's previously imported ISO.
        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let mountedReader { PS3DiscVFS.shared.mount(mountedReader) }
        else { PS3DiscVFS.shared.unmount() }

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return (source.lastPathComponent, "\(sizeText) • \(summary)", ebootURL, ebootStatus)
    }
}

private enum ImportFailure: LocalizedError {
    case notISO
    case accessDenied
    case invalidSource
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notISO:
            return "Please select a file with the .iso extension."
        case .accessDenied:
            return "iOS did not grant access to the selected file."
        case .invalidSource:
            return "The selected ISO is empty or its file size could not be read."
        case .insufficientStorage(let required, let available):
            let requiredText = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough free storage. This import needs about \(requiredText); only \(availableText) is available."
        }
    }
}
