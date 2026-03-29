//
//  AppStateStore.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

private struct PersistedAppState: Codable {
    var jobs: [ConversionJob]
}

enum AppStateStore {
    static let appStateKey = "appState"
    static let defaultOutputDirectoryKey = "defaultOutputDirectory"

    /// Shared writer actor — serializes persistence off the main thread.
    static let writer = Writer()

    // MARK: - Synchronous reads (called once at startup, before UI appears)

    static func loadJobs(userDefaults: UserDefaults = .standard) -> [ConversionJob] {
        guard
            let data = userDefaults.data(forKey: appStateKey),
            let state = try? JSONDecoder().decode(PersistedAppState.self, from: data)
        else {
            return []
        }

        return state.jobs
    }

    static func loadDefaultOutputDirectoryURL(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let path = userDefaults.string(forKey: defaultOutputDirectoryKey), !path.isEmpty {
            let url = URL(filePath: path)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return fallbackOutputDirectoryURL(fileManager: fileManager)
    }

    static func fallbackOutputDirectoryURL(fileManager: FileManager = .default) -> URL {
        let picturesDirectory = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Pictures", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
        return picturesDirectory
    }

    // MARK: - Writer Actor

    actor Writer {
        private let userDefaults: UserDefaults

        init(userDefaults: UserDefaults = .standard) {
            self.userDefaults = userDefaults
        }

        func saveJobs(_ jobs: [ConversionJob]) {
            let state = PersistedAppState(jobs: jobs)
            guard let data = try? JSONEncoder().encode(state) else { return }
            userDefaults.set(data, forKey: AppStateStore.appStateKey)
        }

    }
}
