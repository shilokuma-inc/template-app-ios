//
//  L10n.swift
//  IOSTemplateApp
//

import Foundation

/// アプリ内言語設定に従ってローカライズ文字列を解決する
enum L10n {
    /// `AppSettings` と共有する UserDefaults キー
    static let languageKey = "appLanguage"
    static let systemLanguage = "system"

    /// 現在の言語設定に対応するバンドル。「システムに従う」なら `Bundle.main`
    static var bundle: Bundle {
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? systemLanguage
        guard raw != systemLanguage,
              let path = Bundle.main.path(forResource: raw, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

/// ローカライズ文字列を取得する。キーは英語の原文
func tr(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle)
}
