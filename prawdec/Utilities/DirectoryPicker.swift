//
//  DirectoryPicker.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import AppKit
import Foundation

enum DirectoryPicker {
    @MainActor
    static func pickDirectory(startingAt initialURL: URL?) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.prompt = L10n.tr("directory_picker.prompt.select")
            panel.title = L10n.tr("directory_picker.title.select_output")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = initialURL

            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
