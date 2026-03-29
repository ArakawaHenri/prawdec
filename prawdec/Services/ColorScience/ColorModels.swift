//
//  ColorModels.swift
//  prawdec
//

import Foundation

enum ColorScienceError: LocalizedError, Sendable {
    case singularMatrix
    case missingColorMatrix
    case invalidWhiteBalanceFactors

    var errorDescription: String? {
        switch self {
        case .singularMatrix:
            return "颜色矩阵不可逆。"
        case .missingColorMatrix:
            return "未找到可用的颜色矩阵。"
        case .invalidWhiteBalanceFactors:
            return "白平衡因子无效。"
        }
    }
}

enum BayerPattern: Int, Sendable {
    case rggb = 0
    case grbg = 1
    case gbrg = 2
    case bggr = 3

    static func fromProResRAWValue(_ rawValue: Int) -> BayerPattern? {
        BayerPattern(rawValue: rawValue)
    }

    var dngPattern: [UInt8] {
        switch self {
        case .rggb: return [0, 1, 1, 2]
        case .grbg: return [1, 0, 2, 1]
        case .gbrg: return [1, 2, 0, 1]
        case .bggr: return [2, 1, 1, 0]
        }
    }
}

struct WhiteBalanceByCCTSample: Sendable {
    var cct: Double
    var redFactor: Double
    var blueFactor: Double
}

struct ColorMatrixByCCTSample: Sendable {
    var cct: Double
    var matrix: Matrix3x3
}

struct ClipColorMetadata: Sendable {
    var whiteBalanceByCCT: [WhiteBalanceByCCTSample] = []
    var colorMatricesByCCT: [ColorMatrixByCCTSample] = []
    var reportedCaptureCCT: Int?
}

struct FrameColorAttachments: Sendable {
    var colorMatrix: Matrix3x3?
    var whiteBalanceRedFactor: Double?
    var whiteBalanceBlueFactor: Double?
    var whiteBalanceCCT: Int?
}

enum ResolvedColorMode: String, Sendable {
    case dualIlluminantFromTables
    case dualIlluminantFromCAT
    case singleIlluminantWithCAT
    case singleIlluminantUndoWB
    case directInverse

    var title: String {
        switch self {
        case .dualIlluminantFromTables: return "双光源（ByCCT 表）"
        case .dualIlluminantFromCAT: return "双光源（CAT 适配）"
        case .singleIlluminantWithCAT: return "单光源 D65（CAT）"
        case .singleIlluminantUndoWB: return "单光源（去白平衡）"
        case .directInverse: return "直接逆矩阵"
        }
    }
}

struct ResolvedFrameColorMetadata: Sendable {
    var colorMatrix1: Matrix3x3
    var calibrationIlluminant1: UInt16
    var asShotNeutral: [Double]

    var colorMatrix2: Matrix3x3?
    var calibrationIlluminant2: UInt16?

    var forwardMatrix1: Matrix3x3?
    var forwardMatrix2: Matrix3x3?

    var mode: ResolvedColorMode
    var notes: [String]
}

/// Clip-level precomputed color profile for scenarios where matrices are constant across all frames.
struct PrecomputedClipProfile: Sendable {
    var colorMatrix1: Matrix3x3
    var colorMatrix2: Matrix3x3
    var forwardMatrix1: Matrix3x3
    var forwardMatrix2: Matrix3x3
    var calibrationIlluminant1: UInt16
    var calibrationIlluminant2: UInt16
    var mode: ResolvedColorMode
}
