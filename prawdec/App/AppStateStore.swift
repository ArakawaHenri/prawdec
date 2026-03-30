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
    nonisolated static let appStateKey = "appState"
    nonisolated static let defaultOutputDirectoryKey = "defaultOutputDirectory"

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
        let moviesDirectory = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Movies", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: moviesDirectory, withIntermediateDirectories: true)
        return moviesDirectory
    }

    // MARK: - Writer Actor

    actor Writer {
        private let userDefaults: UserDefaults
        private var latestScheduledGeneration: UInt64 = 0

        init(userDefaults: UserDefaults = .standard) {
            self.userDefaults = userDefaults
        }

        func saveJobs(_ jobs: [ConversionJob], generation: UInt64) async {
            guard generation >= latestScheduledGeneration else { return }
            latestScheduledGeneration = generation

            let data = await MainActor.run { () -> Data? in
                let state = PersistedAppState(jobs: jobs)
                return try? JSONEncoder().encode(state)
            }
            guard generation == latestScheduledGeneration else { return }
            guard let data else { return }
            userDefaults.set(data, forKey: AppStateStore.appStateKey)
        }

    }
}
