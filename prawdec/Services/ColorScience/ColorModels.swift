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
            return L10n.tr("error.color.singular_matrix")
        case .missingColorMatrix:
            return L10n.tr("error.color.missing_color_matrix")
        case .invalidWhiteBalanceFactors:
            return L10n.tr("error.color.invalid_white_balance_factors")
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
        case .dualIlluminantFromTables: return L10n.tr("color.mode.dual_illuminant_from_tables")
        case .dualIlluminantFromCAT: return L10n.tr("color.mode.dual_illuminant_from_cat")
        case .singleIlluminantWithCAT: return L10n.tr("color.mode.single_illuminant_with_cat")
        case .singleIlluminantUndoWB: return L10n.tr("color.mode.single_illuminant_undo_wb")
        case .directInverse: return L10n.tr("color.mode.direct_inverse")
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
