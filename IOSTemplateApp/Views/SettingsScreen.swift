//
//  SettingsScreen.swift
//  IOSTemplateApp
//

import SwiftUI
import UniformTypeIdentifiers

/// 外観・言語・データ管理の設定画面
struct SettingsScreen: View {
    @Environment(ScanStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var isImporterPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var shareFileURL: URL?
    @State private var resultMessage: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                appearanceSection(settings: $settings)
                deviceSection(settings: $settings)
                dataSection
                dangerSection
                aboutSection
            }
            .navigationTitle(tr("Settings"))
            .task(id: store.records.count) {
                shareFileURL = writeShareFile()
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.scanData, .json],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .confirmationDialog(
                tr("Delete all local data?"),
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(tr("Delete"), role: .destructive) { store.removeAll() }
            } message: {
                Text(tr("This removes every scan stored on this device. This cannot be undone."))
            }
            .alert(tr("Import data"), isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button(tr("OK"), role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private func appearanceSection(settings: Bindable<AppSettings>) -> some View {
        Section(tr("Appearance")) {
            Picker(tr("Theme"), selection: settings.appearance) {
                ForEach(Appearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            Picker(tr("Language"), selection: settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
        }
    }

    private func deviceSection(settings: Bindable<AppSettings>) -> some View {
        Section {
            TextField(tr("Device name"), text: settings.deviceName)
                .textInputAutocapitalization(.words)
        } header: {
            Text(tr("This device"))
        } footer: {
            Text(tr("Recorded with each scan so you can tell which device scanned it after merging."))
        }
    }

    private var dataSection: some View {
        Section {
            if let shareFileURL {
                ShareLink(item: shareFileURL, preview: SharePreview(shareFileURL.lastPathComponent)) {
                    Label(tr("Share data for merging"), systemImage: "square.and.arrow.up")
                }
                .disabled(store.records.isEmpty)
            }
            Button {
                isImporterPresented = true
            } label: {
                Label(tr("Import data from file"), systemImage: "square.and.arrow.down")
            }
        } header: {
            Text(tr("Merge with other devices"))
        } footer: {
            Text(tr("Send the file via AirDrop and open it on the other iPhone. Existing records are skipped."))
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label(tr("Delete all local data"), systemImage: "trash")
            }
            .disabled(store.records.isEmpty)
        } footer: {
            Text(tr("Stored records: \(store.totalCount)"))
        }
    }

    private var aboutSection: some View {
        Section(tr("About")) {
            LabeledContent(tr("Version"), value: Self.versionString)
        }
    }

    // MARK: - Actions

    private func writeShareFile() -> URL? {
        let document = ScanDataDocument(deviceName: settings.deviceName, records: store.records)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(document.suggestedFileName())
        do {
            try document.encoded().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let messages = urls.map { DataImporter.importFile(at: $0, into: store).message }
            resultMessage = messages.joined(separator: "\n")
        case .failure(let error):
            resultMessage = tr("Could not import the file: \(error.localizedDescription)")
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsScreen()
        .environment(ScanStore.inMemory())
        .environment(AppSettings())
}
