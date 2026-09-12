//
//  ManualEntrySheet.swift
//  IOSTemplateApp
//

import SwiftUI

/// URL を手入力して追加するシート (カメラ / NFC が使えない環境の動作確認用)
struct ManualEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let onResult: (ScanAddResult) -> Void

    @State private var text = ""
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !isSubmitting && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String("https://fortee.jp/u/Shilokuma"), text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFocused)
                    .onSubmit { if canSubmit { submit() } }
                if isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(tr("Looking up profile…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(tr("Enter URL"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Add"), action: submit)
                        .disabled(!canSubmit)
                }
            }
            .onAppear { isFocused = true }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() {
        isSubmitting = true
        Task {
            let result = await store.add(
                rawValue: text,
                source: .manual,
                deviceName: settings.deviceName,
                resolver: .live
            )
            isSubmitting = false
            onResult(result)
            dismiss()
        }
    }
}

#Preview {
    ManualEntrySheet { _ in }
        .environment(ScanStore.inMemory())
        .environment(AppSettings())
}
