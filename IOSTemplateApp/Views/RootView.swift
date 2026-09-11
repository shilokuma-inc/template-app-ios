//
//  RootView.swift
//  IOSTemplateApp
//

import SwiftUI

/// タブ構成のルート。AirDrop 等で受け取った `.scans` ファイルの取り込みもここで扱う
struct RootView: View {
    @Environment(ScanStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var selectedTab: RootTab = .scans
    @State private var importMessage: String?

    enum RootTab: Hashable {
        case scans
        case stats
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanListScreen()
                .tabItem { Label(tr("Scans"), systemImage: "list.bullet.rectangle") }
                .tag(RootTab.scans)
            StatsScreen()
                .tabItem { Label(tr("Summary"), systemImage: "chart.bar.xaxis") }
                .tag(RootTab.stats)
            SettingsScreen()
                .tabItem { Label(tr("Settings"), systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        // 言語切替時に全画面を作り直して文言を更新する (タブ選択は保持)
        .id(settings.language)
        .onOpenURL { url in
            importMessage = DataImporter.importFile(at: url, into: store).message
        }
        .alert(tr("Import data"), isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }
}

/// `.scans` ファイルを読み込んでストアに統合する
enum DataImporter {
    enum Outcome {
        case merged(MergeResult)
        case failed(String)

        var message: String {
            switch self {
            case .merged(let result): result.message
            case .failed(let reason): tr("Could not import the file: \(reason)")
            }
        }
    }

    @MainActor
    static func importFile(at url: URL, into store: ScanStore) -> Outcome {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let document = try ScanDataDocument.decode(data)
            return .merged(store.merge(document.records))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

#Preview {
    RootView()
        .environment(ScanStore.inMemory())
        .environment(AppSettings())
}
