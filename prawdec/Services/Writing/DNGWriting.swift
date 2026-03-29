//
//  DNGWriting.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

enum DNGWriterError: LocalizedError, Sendable {
    case deferredImplementation

    var errorDescription: String? {
        switch self {
        case .deferredImplementation:
            return L10n.tr("error.dng_writer.deferred")
        }
    }
}

struct DNGFramePayload: Sendable {
    var imageWidth: Int
    var imageHeight: Int
    var activeArea: [UInt32]
    var defaultCropOrigin: [Double]
    var defaultCropSize: [Double]
    var pixelData: Data
    var bytesPerRow: Int
    var make: String?
    var model: String?
    var uniqueCameraModel: String
    var software: String
    var bayerPattern: BayerPattern
    var blackLevel: UInt32
    var whiteLevel: UInt32
    var baselineExposure: Double
    var calibrationIlluminant1: UInt16
    var colorMatrix1: Matrix3x3
    var asShotNeutral: [Double]
    var calibrationIlluminant2: UInt16?
    var colorMatrix2: Matrix3x3?
    var forwardMatrix1: Matrix3x3?
    var forwardMatrix2: Matrix3x3?
    var timecodeData: Data?         // 8 bytes SMPTE ST 12 time-address + user bits for tag 51043
    var frameRate: (Int32, Int32)?  // numerator/denominator for tag 51044
}

struct DNGWriteRequest: Sendable {
    var destinationURL: URL
    var frameIndex: Int
    var compression: DNGCompressionPreset
    var payload: DNGFramePayload
}

protocol DNGWriting: Sendable {
    func write(request: DNGWriteRequest) throws
}

struct AdobeDNGWriter: DNGWriting {
    func write(request: DNGWriteRequest) throws {
        let mode: PDDNGCompressionMode
        let compressionQuality: Int

        switch request.compression {
        case .jpegLossless:
            mode = .jpegLosslessMosaic
            compressionQuality = 0
        case .jxlLossless:
            mode = .jxlLossless
            compressionQuality = 0
        case .jxlLossyMosaic(let requestedQuality):
            mode = .jxlLossyMosaic
            compressionQuality = DNGCompressionQuality.clampJXL(requestedQuality)
        case .jpegLossyRGB(let requestedQuality):
            mode = .jpegLossyRGB
            compressionQuality = DNGCompressionQuality.clampJPEG(requestedQuality)
        }

        var writeError: NSError?
        let cm1 = request.payload.colorMatrix1.rowMajorValues
        let cm2 = request.payload.colorMatrix2?.rowMajorValues
        let fm1 = request.payload.forwardMatrix1?.rowMajorValues
        let fm2 = request.payload.forwardMatrix2?.rowMajorValues
        let success = PDDNGSDKWriteDNG(
            request.destinationURL.path,
            mode,
            compressionQuality,
            request.payload.imageWidth,
            request.payload.imageHeight,
            request.payload.activeArea,
            request.payload.defaultCropOrigin,
            request.payload.defaultCropSize,
            request.payload.pixelData,
            request.payload.bytesPerRow,
            request.payload.make,
            request.payload.model,
            request.payload.uniqueCameraModel,
            request.payload.software,
            request.payload.bayerPattern.rawValue,
            request.payload.blackLevel,
            request.payload.whiteLevel,
            request.payload.baselineExposure,
            request.payload.calibrationIlluminant1,
            cm1,
            request.payload.asShotNeutral,
            request.payload.calibrationIlluminant2 ?? 0,
            cm2,
            fm1,
            fm2,
            &writeError
        )

        guard success else {
            throw writeError ?? DNGWriterError.deferredImplementation
        }

        // Post-write: inject CinemaDNG timecode tags (51043, 51044)
        if let tcData = request.payload.timecodeData,
           let frameRate = request.payload.frameRate {
            try TIFFTagInjector.inject(
                url: request.destinationURL,
                timecodeData: tcData,
                frameRate: frameRate
            )
        }
    }
}

struct DeferredDNGWriter: DNGWriting {
    func write(request: DNGWriteRequest) throws {
        throw DNGWriterError.deferredImplementation
    }
}
