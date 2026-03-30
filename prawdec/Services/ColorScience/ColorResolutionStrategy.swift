//
//  ColorResolutionStrategy.swift
//  prawdec
//

import Foundation

/// Input context for color resolution strategies.
struct ColorResolutionContext: Sendable {
    let frameX: Matrix3x3
    let frameR: Double?
    let frameB: Double?
    let frameCCT: Int?
    let clipMetadata: ClipColorMetadata
    let precomputedProfile: PrecomputedClipProfile?
    let notes: [String]

    var hasWB: Bool { (frameR ?? 0) > 0 && (frameB ?? 0) > 0 }
    var hasCCT: Bool { (frameCCT ?? 0) > 0 }
    var hasByCCTWB: Bool { !clipMetadata.whiteBalanceByCCT.isEmpty }
    var hasByCCTCM: Bool { !clipMetadata.colorMatricesByCCT.isEmpty }

    var asShotNeutral: [Double] {
        guard let r = frameR, let b = frameB, r > 0, b > 0 else { return [1, 1, 1] }
        return [1 / r, 1, 1 / b]
    }
}

/// Protocol for color resolution strategies.
/// Each strategy encapsulates the math for one DNG color scenario.
protocol ColorResolutionStrategy: Sendable {
    /// Whether this strategy can handle the given context.
    static func canResolve(_ context: ColorResolutionContext) -> Bool

    /// The color mode this strategy produces.
    static var mode: ResolvedColorMode { get }

    /// Resolve DNG color metadata for a single frame.
    func resolve(_ context: ColorResolutionContext) throws -> ResolvedFrameColorMetadata
}

// MARK: - Scenario A: Dual illuminant from ByCCT tables

struct DualIlluminantFromTablesStrategy: ColorResolutionStrategy {
    static let mode = ResolvedColorMode.dualIlluminantFromTables

    static func canResolve(_ ctx: ColorResolutionContext) -> Bool {
        ctx.hasByCCTCM && ctx.hasByCCTWB && ctx.hasWB
    }

    func resolve(_ ctx: ColorResolutionContext) throws -> ResolvedFrameColorMetadata {
        let notes = ctx.notes + ["场景 A：双光源 ByCCT 表"]

        // Fast path: use precomputed clip-level matrices
        if let profile = ctx.precomputedProfile, profile.mode == .dualIlluminantFromTables {
            return ResolvedFrameColorMetadata(
                colorMatrix1: profile.colorMatrix1,
                calibrationIlluminant1: profile.calibrationIlluminant1,
                asShotNeutral: ctx.asShotNeutral,
                colorMatrix2: profile.colorMatrix2,
                calibrationIlluminant2: profile.calibrationIlluminant2,
                forwardMatrix1: profile.forwardMatrix1,
                forwardMatrix2: profile.forwardMatrix2,
                mode: Self.mode,
                notes: notes
            )
        }

        // Interpolate ByCCT tables at Standard A and D65
        let xA = ColorScience.interpolateColorMatrix(
            for: DNGIlluminant.standardACCT, samples: ctx.clipMetadata.colorMatricesByCCT) ?? ctx.frameX
        let wbA = ColorScience.interpolateWhiteBalanceFactors(
            for: DNGIlluminant.standardACCT, samples: ctx.clipMetadata.whiteBalanceByCCT)
        let rA = wbA?.redFactor ?? ctx.frameR!
        let bA = wbA?.blueFactor ?? ctx.frameB!

        let xD65 = ColorScience.interpolateColorMatrix(
            for: DNGIlluminant.d65CCT, samples: ctx.clipMetadata.colorMatricesByCCT) ?? ctx.frameX
        let wbD65 = ColorScience.interpolateWhiteBalanceFactors(
            for: DNGIlluminant.d65CCT, samples: ctx.clipMetadata.whiteBalanceByCCT)
        let rD65 = wbD65?.redFactor ?? ctx.frameR!
        let bD65 = wbD65?.blueFactor ?? ctx.frameB!

        let cm1 = try ColorScience.computeColorMatrix(
            sourceMatrix: xA, whiteBalanceRedFactor: rA, whiteBalanceBlueFactor: bA,
            sourceCCT: nil, targetCCT: nil)
        let cm2 = try ColorScience.computeColorMatrix(
            sourceMatrix: xD65, whiteBalanceRedFactor: rD65, whiteBalanceBlueFactor: bD65,
            sourceCCT: nil, targetCCT: nil)

        let fm1 = try ColorScience.computeForwardMatrix(
            sourceMatrix: xA,
            sourceCCT: nil,
            targetCCT: DNGIlluminant.standardACCT
        )
        let fm2 = try ColorScience.computeForwardMatrix(
            sourceMatrix: xD65,
            sourceCCT: nil,
            targetCCT: DNGIlluminant.d65CCT
        )

        return ResolvedFrameColorMetadata(
            colorMatrix1: cm1,
            calibrationIlluminant1: DNGIlluminant.standardA,
            asShotNeutral: ctx.asShotNeutral,
            colorMatrix2: cm2,
            calibrationIlluminant2: DNGIlluminant.d65,
            forwardMatrix1: fm1,
            forwardMatrix2: fm2,
            mode: Self.mode,
            notes: notes
        )
    }
}

// MARK: - Scenario B: Dual illuminant from CAT adaptation

struct DualIlluminantFromCATStrategy: ColorResolutionStrategy {
    static let mode = ResolvedColorMode.dualIlluminantFromCAT

    static func canResolve(_ ctx: ColorResolutionContext) -> Bool {
        ctx.hasByCCTWB && ctx.hasWB && ctx.hasCCT
    }

    func resolve(_ ctx: ColorResolutionContext) throws -> ResolvedFrameColorMetadata {
        let cm1 = try ColorScience.computeColorMatrix(
            sourceMatrix: ctx.frameX,
            whiteBalanceRedFactor: ctx.frameR!,
            whiteBalanceBlueFactor: ctx.frameB!,
            sourceCCT: Double(ctx.frameCCT!),
            targetCCT: DNGIlluminant.standardACCT
        )
        let cm2 = try ColorScience.computeColorMatrix(
            sourceMatrix: ctx.frameX,
            whiteBalanceRedFactor: ctx.frameR!,
            whiteBalanceBlueFactor: ctx.frameB!,
            sourceCCT: Double(ctx.frameCCT!),
            targetCCT: DNGIlluminant.d65CCT
        )

        let fm1 = try ColorScience.computeForwardMatrix(
            sourceMatrix: ctx.frameX,
            sourceCCT: Double(ctx.frameCCT!),
            targetCCT: DNGIlluminant.standardACCT
        )
        let fm2 = try ColorScience.computeForwardMatrix(
            sourceMatrix: ctx.frameX,
            sourceCCT: Double(ctx.frameCCT!),
            targetCCT: DNGIlluminant.d65CCT
        )

        return ResolvedFrameColorMetadata(
            colorMatrix1: cm1,
            calibrationIlluminant1: DNGIlluminant.standardA,
            asShotNeutral: ctx.asShotNeutral,
            colorMatrix2: cm2,
            calibrationIlluminant2: DNGIlluminant.d65,
            forwardMatrix1: fm1,
            forwardMatrix2: fm2,
            mode: Self.mode,
            notes: ctx.notes + ["场景 B：双光源 CAT 适配"]
        )
    }
}

// MARK: - Scenario C: Single illuminant with CAT to D65

struct SingleIlluminantWithCATStrategy: ColorResolutionStrategy {
    static let mode = ResolvedColorMode.singleIlluminantWithCAT

    static func canResolve(_ ctx: ColorResolutionContext) -> Bool {
        ctx.hasWB && ctx.hasCCT
    }

    func resolve(_ ctx: ColorResolutionContext) throws -> ResolvedFrameColorMetadata {
        let cm = try ColorScience.computeColorMatrix(
            sourceMatrix: ctx.frameX,
            whiteBalanceRedFactor: ctx.frameR!,
            whiteBalanceBlueFactor: ctx.frameB!,
            sourceCCT: Double(ctx.frameCCT!),
            targetCCT: DNGIlluminant.d65CCT
        )
        let fm = try ColorScience.computeForwardMatrix(
            sourceMatrix: ctx.frameX,
            sourceCCT: Double(ctx.frameCCT!),
            targetCCT: DNGIlluminant.d65CCT
        )

        return ResolvedFrameColorMetadata(
            colorMatrix1: cm,
            calibrationIlluminant1: DNGIlluminant.d65,
            asShotNeutral: ctx.asShotNeutral,
            colorMatrix2: nil,
            calibrationIlluminant2: nil,
            forwardMatrix1: fm,
            forwardMatrix2: nil,
            mode: Self.mode,
            notes: ctx.notes + ["场景 C：单光源 D65 + CAT"]
        )
    }
}

// MARK: - Scenario D: Single illuminant, undo WB only

struct SingleIlluminantUndoWBStrategy: ColorResolutionStrategy {
    static let mode = ResolvedColorMode.singleIlluminantUndoWB

    static func canResolve(_ ctx: ColorResolutionContext) -> Bool {
        ctx.hasWB
    }

    func resolve(_ ctx: ColorResolutionContext) throws -> ResolvedFrameColorMetadata {
        let cm = try ColorScience.computeColorMatrix(
            sourceMatrix: ctx.frameX,
            whiteBalanceRedFactor: ctx.frameR!,
            whiteBalanceBlueFactor: ctx.frameB!,
            sourceCCT: nil,
            targetCCT: nil
        )

        return ResolvedFrameColorMetadata(
            colorMatrix1: cm,
            calibrationIlluminant1: DNGIlluminant.unknown,
            asShotNeutral: ctx.asShotNeutral,
            colorMatrix2: nil,
            calibrationIlluminant2: nil,
            forwardMatrix1: nil,
            forwardMatrix2: nil,
            mode: Self.mode,
            notes: ctx.notes + ["场景 D：单光源去白平衡（无 CCT，无法做 CAT）"]
        )
    }
}

// MARK: - Scenario E: Direct inverse (no WB factors)

struct DirectInverseStrategy: ColorResolutionStrategy {
    static let mode = ResolvedColorMode.directInverse

    /// Fallback strategy — always available.
    static func canResolve(_ ctx: ColorResolutionContext) -> Bool {
        true
    }

    func resolve(_ ctx: ColorResolutionContext) throws -> ResolvedFrameColorMetadata {
        let cm = try ctx.frameX.inverted()

        return ResolvedFrameColorMetadata(
            colorMatrix1: cm,
            calibrationIlluminant1: DNGIlluminant.unknown,
            asShotNeutral: [1, 1, 1],
            colorMatrix2: nil,
            calibrationIlluminant2: nil,
            forwardMatrix1: nil,
            forwardMatrix2: nil,
            mode: Self.mode,
            notes: ctx.notes + ["场景 E：直接逆矩阵（无白平衡因子）"]
        )
    }
}
