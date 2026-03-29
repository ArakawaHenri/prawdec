//
//  DNGSDKSupport.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

enum DNGSDKSupport {
    static let version = PDDNGSDKVersionString()

    static func supports(_ preset: DNGCompressionPreset) -> Bool {
        switch preset {
        case .jpegLossless:
            return PDDNGSDKSupportsCompressionMode(.jpegLosslessMosaic)
        case .jxlLossless:
            return PDDNGSDKSupportsCompressionMode(.jxlLossless)
        case .jxlLossyMosaic:
            return PDDNGSDKSupportsCompressionMode(.jxlLossyMosaic)
        case .jpegLossyRGB:
            return PDDNGSDKSupportsCompressionMode(.jpegLossyRGB)
        }
    }
}
