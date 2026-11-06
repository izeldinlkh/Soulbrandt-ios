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
                                Label("Import decrypted ISO", systemImage: "folder")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting)

                        Text("Import stores the image in this app’s private storage. The current build can inspect supported ISO-9660/Joliet images, but cannot boot the game.")
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
            .task(perform: restoreImportedImage)
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

            let hasAccess = source.startAccessingSecurityScopedResource()
            guard hasAccess else { throw ImportFailure.accessDenied }

            isImporting = true
            importError = nil

            Task {
                defer {
                    source.stopAccessingSecurityScopedResource()
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

    nonisolated private static func copyAndInspectISO(source: URL) throws -> (name: String, summary: String) {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let directory = support.appendingPathComponent("GameImages", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fileManager.removeItem(at: temporary) }

        try fileManager.copyItem(at: source, to: temporary)

        var summary = "Imported. Filesystem not recognized by the current ISO-9660/Joliet reader; UDF support is still needed."
        do {
            let reader = try ISO9660Reader(url: temporary)
            let rootEntries = try reader.list()
            let hasPS3Game = rootEntries.contains {
                $0.isDirectory && $0.name.caseInsensitiveCompare("PS3_GAME") == .orderedSame
            }
            let discText = hasPS3Game
                ? "PS3_GAME directory found"
                : "PS3_GAME was not found in the root"
            let fsText = reader.isJoliet ? "Joliet" : "ISO-9660"
            summary = "\(fsText) filesystem • \(discText)"
            if hasPS3Game {
                do {
                    let gameEntries = try reader.list(path: "/PS3_GAME")
                    let hasUSRDIR = gameEntries.contains {
                        $0.isDirectory && $0.name.caseInsensitiveCompare("USRDIR") == .orderedSame
                    }
                    if hasUSRDIR {
                        let userFiles = try reader.list(path: "/PS3_GAME/USRDIR")
                        let hasEboot = userFiles.contains {
                            !$0.isDirectory && (
                                $0.name.caseInsensitiveCompare("EBOOT.ELF") == .orderedSame ||
                                $0.name.caseInsensitiveCompare("EBOOT.BIN") == .orderedSame
                            )
                        }
                        summary += hasEboot ? " • EBOOT file found" : " • EBOOT file not found"
                    }
                } catch {
                    summary += " • PS3_GAME could not be fully inspected"
                }
            }
        } catch {
            // Keep the imported image even when its filesystem is not supported by this prototype.
            summary = "Imported. ISO-9660/Joliet inspection unavailable: \(error.localizedDescription)"
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return (source.lastPathComponent, "\(sizeText) • \(summary)")
    }
}

private enum ImportFailure: LocalizedError {
    case notISO
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .notISO: return "Please select a file with the .iso extension."
        case .accessDenied: return "iOS did not grant access to the selected file."
        }
    }
}
