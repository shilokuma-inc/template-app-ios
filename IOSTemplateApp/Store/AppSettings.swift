//
//  AppSettings.swift
//  IOSTemplateApp
//

import Foundation
import Observation
import SwiftUI
import UIKit

/// 外観モード
enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: tr("Follow system")
        case .light: tr("Light")
        case .dark: tr("Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// アプリ内言語
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case japanese = "ja"
    case english = "en"

    var id: Self { self }

    /// 言語名はその言語自身で表示する (切替先を探しやすくするため)
    var title: String {
        switch self {
        case .system: tr("Follow system")
        case .japanese: "日本語"
        case .english: "English"
        }
    }

    /// 日付などの書式に使うロケール。「システムに従う」なら端末設定
    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .japanese: Locale(identifier: "ja_JP")
        case .english: Locale(identifier: "en_US")
        }
    }
}

/// ユーザー設定 (UserDefaults に保存)
@MainActor
@Observable
final class AppSettings {
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: L10n.languageKey) }
    }
    /// この端末の名前。読み取り履歴に記録し、統合時にどの端末のデータか分かるようにする
    var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let appearance = "appearance"
        static let deviceName = "deviceName"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: L10n.languageKey) ?? "") ?? .system
        deviceName = defaults.string(forKey: Keys.deviceName) ?? UIDevice.current.name
    }
}
