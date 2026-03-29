//
//  DNGCompression.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

enum DNGCompressionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpegLossless
    case jxlLossless
    case jxlLossyMosaic
    case jpegLossyRGB

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpegLossless:
            return "JPEG Lossless"
        case .jxlLossless:
            return "JXL Lossless"
        case .jxlLossyMosaic:
            return "JXL Lossy Mosaic"
        case .jpegLossyRGB:
            return "JPEG Lossy RGB"
        }
    }
}

enum DNGCompressionPreset: Hashable, Codable, Sendable, CaseIterable, Identifiable {
    case jpegLossless
    case jxlLossless
    case jxlLossyMosaic(quality: Int)
    case jpegLossyRGB(quality: Int)

    var id: String {
        switch self {
        case .jpegLossless:
            return "jpeg-lossless"
        case .jxlLossless:
            return "jxl-lossless"
        case .jxlLossyMosaic(let quality):
            return "jxl-lossy-mosaic-\(quality)"
        case .jpegLossyRGB(let quality):
            return "jpeg-lossy-rgb-\(quality)"
        }
    }

    static var allCases: [DNGCompressionPreset] {
        [
            .jpegLossless,
            .jxlLossless,
            .jxlLossyMosaic(quality: DNGCompressionQualityDefaults.jxlQuality),
            .jpegLossyRGB(quality: DNGCompressionQualityDefaults.jpegQuality),
        ]
    }

    var title: String {
        kind.title
    }

    var shortDescription: String {
        switch self {
        case .jpegLossless:
            return "官方默认 raw 压缩"
        case .jxlLossless:
            return "JPEG XL 无损"
        case .jxlLossyMosaic(let quality):
            return "JPEG XL 有损 Mosaic，质量 \(quality)"
        case .jpegLossyRGB(let quality):
            return "JPEG 有损 RGB，质量 \(quality)"
        }
    }

    var outputDirectorySuffix: String {
        id
    }

    var isLossy: Bool {
        switch self {
        case .jxlLossyMosaic, .jpegLossyRGB:
            return true
        case .jpegLossless, .jxlLossless:
            return false
        }
    }

    var kind: DNGCompressionKind {
        switch self {
        case .jpegLossless:
            return .jpegLossless
        case .jxlLossless:
            return .jxlLossless
        case .jxlLossyMosaic:
            return .jxlLossyMosaic
        case .jpegLossyRGB:
            return .jpegLossyRGB
        }
    }

    var quality: Int? {
        switch self {
        case .jxlLossyMosaic(let quality), .jpegLossyRGB(let quality):
            return quality
        case .jpegLossless, .jxlLossless:
            return nil
        }
    }

    func updating(kind: DNGCompressionKind) -> DNGCompressionPreset {
        switch kind {
        case .jpegLossless:
            return .jpegLossless
        case .jxlLossless:
            return .jxlLossless
        case .jxlLossyMosaic:
            return .jxlLossyMosaic(quality: quality.map(DNGCompressionQuality.clampJXL) ?? DNGCompressionQualityDefaults.jxlQuality)
        case .jpegLossyRGB:
            return .jpegLossyRGB(quality: quality.map(DNGCompressionQuality.clampJPEG) ?? DNGCompressionQualityDefaults.jpegQuality)
        }
    }

    func updating(quality: Int) -> DNGCompressionPreset {
        switch self {
        case .jxlLossyMosaic:
            return .jxlLossyMosaic(quality: DNGCompressionQuality.clampJXL(quality))
        case .jpegLossyRGB:
            return .jpegLossyRGB(quality: DNGCompressionQuality.clampJPEG(quality))
        case .jpegLossless, .jxlLossless:
            return self
        }
    }

    var qualityRange: ClosedRange<Int>? {
        switch self {
        case .jxlLossyMosaic:
            return DNGCompressionQuality.jxlRange
        case .jpegLossyRGB:
            return DNGCompressionQuality.jpegRange
        case .jpegLossless, .jxlLossless:
            return nil
        }
    }
}

enum DNGCompressionQualityDefaults {
    nonisolated static var jpegQuality: Int { Int(PDDNGSDKDefaultJPEGQuality()) }
    nonisolated static var jxlQuality: Int { Int(PDDNGSDKDefaultJXLQuality()) }
}

enum DNGCompressionQuality {
    static let jpegRange = 0...12
    static let jxlRange = 1...13

    nonisolated static func clampJPEG(_ quality: Int) -> Int {
        Int(PDDNGSDKClampJPEGQuality(quality))
    }

    nonisolated static func clampJXL(_ quality: Int) -> Int {
        Int(PDDNGSDKClampJXLQuality(quality))
    }
}
