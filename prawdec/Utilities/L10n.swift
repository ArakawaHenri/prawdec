//
//  L10n.swift
//  prawdec
//
//  Created by Codex on 2026/3/30.
//

import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = tr(key)
        return withVaList(arguments) { pointer in
            NSString(format: format, locale: Locale.current, arguments: pointer) as String
        }
    }
}
