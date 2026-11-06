import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = ControllerMonitor()
    @State private var showingImporter = false
    @State private var importedISOName: String?
    @State private var importError: String?

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
                        } else {
                            Text("No ISO imported")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import decrypted ISO", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)

                        Text("The ISO is copied into this app’s private storage. This prototype does not boot the game yet.")
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
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            guard source.pathExtension.lowercased() == "iso" else {
                throw ImportFailure.notISO
            }

            let hasAccess = source.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { source.stopAccessingSecurityScopedResource() }
            }

            let fileManager = FileManager.default
            let gameImages = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("GameImages", isDirectory: true)
            try fileManager.createDirectory(at: gameImages, withIntermediateDirectories: true)

            let destination = gameImages.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            try fileManager.copyItem(at: source, to: destination)
            importedISOName = source.lastPathComponent
            importError = nil
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
}

private enum ImportFailure: LocalizedError {
    case notISO

    var errorDescription: String? {
        "Please select a file with the .iso extension."
    }
}
