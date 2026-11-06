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

    private let savedISOKey = "Soulbrandt.importedISOName"
    private let savedSummaryKey = "Soulbrandt.importedISOSummary"

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
                        Text("UDF support uses libudfread (LGPL-2.1); see the bundled COPYING notice.")
                            .font(.caption2)
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
        }
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

    nonisolated private static func copyAndInspectISO(source: URL) throws -> (name: String, summary: String) {
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
        do {
            let reader: any DiscImageFileSystem
            do {
                reader = try ISO9660Reader(url: temporary)
            } catch {
                // Most PS3 Blu-ray images use UDF rather than ISO-9660.
                reader = try UDFReader(url: temporary)
            }
            summary = try Self.inspectDisc(reader)
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

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return (source.lastPathComponent, "\(sizeText) • \(summary)")
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
