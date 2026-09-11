//
//  ManualEntrySheet.swift
//  IOSTemplateApp
//

import SwiftUI

/// URL を手入力して追加するシート (カメラ / NFC が使えない環境の動作確認用)
struct ManualEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ScanStore
    let onResult: (ScanAddResult) -> Void

    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://fortee.jp/u/Shilokuma", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(submit)
            }
            .navigationTitle("URLを手入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加", action: submit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submit() {
        let result = store.add(rawValue: text, source: .manual)
        onResult(result)
        dismiss()
    }
}

#Preview {
    ManualEntrySheet(store: ScanStore(userDefaults: nil)) { _ in }
}
