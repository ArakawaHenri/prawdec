//
//  ColorScience.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

enum ColorScience {
    static let quickTimeManufacturerKey = "com.apple.proapps.manufacturer"
    static let quickTimeModelKey = "com.apple.proapps.modelname"
    static let quickTimeCaptureWhiteBalanceKey = "org.smpte.rdd18.camera.whitebalance"
    static let quickTimeWhiteBalanceByCCTKey = "com.apple.proresraw.whitebalance.bycct.whitebalancefactors"
    static let quickTimeColorMatricesByCCTKey = "com.apple.proresraw.whitebalance.bycct.colormatrices"

    static func parseCaptureCCT(from string: String?) -> Int? {
        guard let string else { return nil }
        let digits = string.prefix { $0.isNumber }
        return Int(digits)
    }

    static func extractClipColorMetadata(from assetMetadata: [String: Any]) -> ClipColorMetadata {
        ClipColorMetadata(
            whiteBalanceByCCT: parseWhiteBalanceByCCT(data: assetMetadata[quickTimeWhiteBalanceByCCTKey] as? Data),
            colorMatricesByCCT: parseColorMatricesByCCT(data: assetMetadata[quickTimeColorMatricesByCCTKey] as? Data),
            reportedCaptureCCT: parseCaptureCCT(from: assetMetadata[quickTimeCaptureWhiteBalanceKey] as? String)
        )
    }

    /// Computes DNG ColorMatrix (XYZ → Camera) at a given illuminant CCT.
    /// CM = D_wb⁻¹ · X⁻¹ when no CAT is needed.
    /// CM = D_wb⁻¹ · X⁻¹ · Bradford(sourceCCT → targetCCT) otherwise.
    static func computeColorMatrix(
        sourceMatrix X: Matrix3x3,
        whiteBalanceRedFactor R: Double,
        whiteBalanceBlueFactor B: Double,
        sourceCCT: Double?,
        targetCCT: Double?
    ) throws -> Matrix3x3 {
        var cm = try X.inverted().dividedRGBRows(redFactor: R, blueFactor: B)
        if let sourceCCT, let targetCCT, abs(sourceCCT - targetCCT) > 1 {
            cm = cm.multiplied(by: try bradfordCAT(from: sourceCCT, to: targetCCT))
        }
        return cm
    }

    /// Computes DNG ForwardMatrix (Camera → XYZ D50).
    /// FM = Bradford(illuminantCCT → D50) · Inverse(CM) · diag(CM · XYZ(illuminantCCT))
    static func computeForwardMatrix(
        colorMatrix cm: Matrix3x3,
        illuminantCCT: Double
    ) throws -> Matrix3x3 {
        let cameraToXYZ = try cm.inverted()
        let cameraToXYZ_D50 = try bradfordCAT(from: illuminantCCT, to: DNGIlluminant.d50CCT).multiplied(by: cameraToXYZ)

        let illuminantXYZ = whitePointXYZ(fromCCT: illuminantCCT)
        let cameraNeutral = cm.multiplied(by: illuminantXYZ)

        let neutralDiag = Matrix3x3(rowMajor: [
            cameraNeutral.x, 0, 0,
            0, cameraNeutral.y, 0,
            0, 0, cameraNeutral.z,
        ])
        return cameraToXYZ_D50.multiplied(by: neutralDiag)
    }

    /// Precompute clip-level color profile. Returns non-nil for Scenario A
    /// (ByCCT tables available), where matrices are constant across all frames.
    static func precomputeClipProfile(
        clipMetadata: ClipColorMetadata
    ) -> PrecomputedClipProfile? {
        let hasByCCTWB = !clipMetadata.whiteBalanceByCCT.isEmpty
        let hasByCCTCM = !clipMetadata.colorMatricesByCCT.isEmpty
        guard hasByCCTCM && hasByCCTWB else { return nil }

        guard let xA = interpolateColorMatrix(for: DNGIlluminant.standardACCT, samples: clipMetadata.colorMatricesByCCT),
              let xD65 = interpolateColorMatrix(for: DNGIlluminant.d65CCT, samples: clipMetadata.colorMatricesByCCT) else {
            return nil
        }
        let wbA = interpolateWhiteBalanceFactors(for: DNGIlluminant.standardACCT, samples: clipMetadata.whiteBalanceByCCT)
        let wbD65 = interpolateWhiteBalanceFactors(for: DNGIlluminant.d65CCT, samples: clipMetadata.whiteBalanceByCCT)

        guard let rA = wbA?.redFactor, let bA = wbA?.blueFactor,
              let rD65 = wbD65?.redFactor, let bD65 = wbD65?.blueFactor,
              rA > 0, bA > 0, rD65 > 0, bD65 > 0 else {
            return nil
        }

        guard let cm1 = try? computeColorMatrix(sourceMatrix: xA, whiteBalanceRedFactor: rA, whiteBalanceBlueFactor: bA, sourceCCT: nil, targetCCT: nil),
              let cm2 = try? computeColorMatrix(sourceMatrix: xD65, whiteBalanceRedFactor: rD65, whiteBalanceBlueFactor: bD65, sourceCCT: nil, targetCCT: nil),
              let fm1 = try? computeForwardMatrix(colorMatrix: cm1, illuminantCCT: DNGIlluminant.standardACCT),
              let fm2 = try? computeForwardMatrix(colorMatrix: cm2, illuminantCCT: DNGIlluminant.d65CCT) else {
            return nil
        }

        return PrecomputedClipProfile(
            colorMatrix1: cm1, colorMatrix2: cm2,
            forwardMatrix1: fm1, forwardMatrix2: fm2,
            calibrationIlluminant1: DNGIlluminant.standardA, calibrationIlluminant2: DNGIlluminant.d65,
            mode: .dualIlluminantFromTables
        )
    }

    // MARK: - Strategy-based resolution

    private static let strategies: [any ColorResolutionStrategy] = [
        DualIlluminantFromTablesStrategy(),
        DualIlluminantFromCATStrategy(),
        SingleIlluminantWithCATStrategy(),
        SingleIlluminantUndoWBStrategy(),
        DirectInverseStrategy(),
    ]

    static func resolveFrameColorMetadata(
        frameAttachments: FrameColorAttachments,
        clipMetadata: ClipColorMetadata,
        precomputedProfile: PrecomputedClipProfile? = nil
    ) throws -> ResolvedFrameColorMetadata {
        var notes: [String] = []

        let frameR = frameAttachments.whiteBalanceRedFactor
        let frameB = frameAttachments.whiteBalanceBlueFactor

        var frameCCT = frameAttachments.whiteBalanceCCT
        if (frameCCT ?? 0) <= 0, let reportedCCT = clipMetadata.reportedCaptureCCT, reportedCCT > 0 {
            frameCCT = reportedCCT
            notes.append(L10n.tr("color.note.use_reported_capture_cct"))
        }
        if (frameCCT ?? 0) <= 0, let r = frameR, let b = frameB,
           let estimated = estimateCCT(fromRedFactor: r, blueFactor: b, samples: clipMetadata.whiteBalanceByCCT) {
            frameCCT = estimated
            notes.append(L10n.tr("color.note.estimated_from_bycct"))
        }

        guard let frameX = frameAttachments.colorMatrix else {
            throw ColorScienceError.missingColorMatrix
        }

        let context = ColorResolutionContext(
            frameX: frameX,
            frameR: frameR,
            frameB: frameB,
            frameCCT: frameCCT,
            clipMetadata: clipMetadata,
            precomputedProfile: precomputedProfile,
            notes: notes
        )

        for strategy in strategies {
            if type(of: strategy).canResolve(context) {
                return try strategy.resolve(context)
            }
        }

        throw ColorScienceError.missingColorMatrix
    }

    // Wyszecki & Stiles Planckian locus table (Robertson's method).
    // Ported from dng_temperature.cpp in DNG SDK 1.7.1.
    private static let kTempTable: [(r: Double, u: Double, v: Double, t: Double)] = [
        (  0, 0.18006, 0.26352, -0.24341),
        ( 10, 0.18066, 0.26589, -0.25479),
        ( 20, 0.18133, 0.26846, -0.26876),
        ( 30, 0.18208, 0.27119, -0.28539),
        ( 40, 0.18293, 0.27407, -0.30470),
        ( 50, 0.18388, 0.27709, -0.32675),
        ( 60, 0.18494, 0.28021, -0.35156),
        ( 70, 0.18611, 0.28342, -0.37915),
        ( 80, 0.18740, 0.28668, -0.40955),
        ( 90, 0.18880, 0.28997, -0.44278),
        (100, 0.19032, 0.29326, -0.47888),
        (125, 0.19462, 0.30141, -0.58204),
        (150, 0.19962, 0.30921, -0.70471),
        (175, 0.20525, 0.31647, -0.84901),
        (200, 0.21142, 0.32312, -1.0182 ),
        (225, 0.21807, 0.32909, -1.2168 ),
        (250, 0.22511, 0.33439, -1.4512 ),
        (275, 0.23247, 0.33904, -1.7298 ),
        (300, 0.24010, 0.34308, -2.0637 ),
        (325, 0.24702, 0.34655, -2.4681 ),
        (350, 0.25591, 0.34951, -2.9641 ),
        (375, 0.26400, 0.35200, -3.5814 ),
        (400, 0.27218, 0.35407, -4.3633 ),
        (425, 0.28039, 0.35577, -5.3762 ),
        (450, 0.28863, 0.35714, -6.7262 ),
        (475, 0.29685, 0.35823, -8.5955 ),
        (500, 0.30505, 0.35907, -11.324 ),
        (525, 0.31320, 0.35968, -15.628 ),
        (550, 0.32129, 0.36011, -23.325 ),
        (575, 0.32931, 0.36038, -40.770 ),
        (600, 0.33724, 0.36051, -116.45 ),
    ]

    /// Convert CCT (tint=0) to CIE xy chromaticity via the Planckian locus.
    /// Uses the same Wyszecki & Stiles / Robertson method as DNG SDK.
    private static func cctToXY(_ cct: Double) -> (x: Double, y: Double) {
        let r = 1.0e6 / cct

        for index in 0..<30 {
            if r < kTempTable[index + 1].r || index == 29 {
                let f = (kTempTable[index + 1].r - r)
                      / (kTempTable[index + 1].r - kTempTable[index].r)

                let u = kTempTable[index].u * f + kTempTable[index + 1].u * (1.0 - f)
                let v = kTempTable[index].v * f + kTempTable[index + 1].v * (1.0 - f)

                let x = 1.5 * u / (u - 4.0 * v + 2.0)
                let y = v / (u - 4.0 * v + 2.0)
                return (x, y)
            }
        }
        return (0.3127, 0.3290) // D65 fallback
    }

    /// Convert CCT to XYZ white point (Y=1) via the Planckian locus (Robertson's method).
    static func whitePointXYZ(fromCCT cct: Double) -> SIMD3<Double> {
        let (x, y) = cctToXY(cct)
        return SIMD3(x / y, 1, (1 - x - y) / y)
    }

    static func bradfordCAT(from sourceCCT: Double, to destinationCCT: Double) throws -> Matrix3x3 {
        let bradford = Matrix3x3(rowMajor: [
            0.8951, 0.2664, -0.1614,
            -0.7502, 1.7135, 0.0367,
            0.0389, -0.0685, 1.0296,
        ])

        let sourceWhitePoint = whitePointXYZ(fromCCT: sourceCCT)
        let destinationWhitePoint = whitePointXYZ(fromCCT: destinationCCT)
        var sourceLMS = bradford.multiplied(by: sourceWhitePoint)
        var destinationLMS = bradford.multiplied(by: destinationWhitePoint)

        // Clamp negative LMS values to 0 (matches DNG SDK MapWhiteMatrix)
        sourceLMS = SIMD3(max(sourceLMS.x, 0), max(sourceLMS.y, 0), max(sourceLMS.z, 0))
        destinationLMS = SIMD3(max(destinationLMS.x, 0), max(destinationLMS.y, 0), max(destinationLMS.z, 0))

        // Pin scale ratios to [0.1, 10.0] (matches DNG SDK)
        func pinRatio(_ num: Double, _ den: Double) -> Double {
            min(10.0, max(0.1, den > 0 ? num / den : 10.0))
        }

        let diagonal = Matrix3x3(rowMajor: [
            pinRatio(destinationLMS.x, sourceLMS.x), 0, 0,
            0, pinRatio(destinationLMS.y, sourceLMS.y), 0,
            0, 0, pinRatio(destinationLMS.z, sourceLMS.z),
        ])

        return try bradford.inverted().multiplied(by: diagonal).multiplied(by: bradford)
    }

    static func parseWhiteBalanceByCCT(data: Data?) -> [WhiteBalanceByCCTSample] {
        guard let data, data.count >= 4 else {
            return []
        }

        let count = Int(readBEUInt16(data, at: 0))
        let expectedSize = 4 + (count * 12)
        guard data.count >= expectedSize else {
            return []
        }

        return (0..<count).map { index in
            let offset = 4 + (index * 12)
            return WhiteBalanceByCCTSample(
                cct: Double(readBEUInt32(data, at: offset)),
                redFactor: Double(readBEFloat32(data, at: offset + 4)),
                blueFactor: Double(readBEFloat32(data, at: offset + 8))
            )
        }
        .sorted { $0.cct < $1.cct }
    }

    static func parseColorMatricesByCCT(data: Data?) -> [ColorMatrixByCCTSample] {
        guard let data, data.count >= 4 else {
            return []
        }

        let count = Int(readBEUInt16(data, at: 0))
        let expectedSize = 4 + (count * 40)
        guard data.count >= expectedSize else {
            return []
        }

        return (0..<count).map { index in
            let offset = 4 + (index * 40)
            let values = (0..<9).map { element in
                Double(readBEFloat32(data, at: offset + 4 + (element * 4)))
            }
            return ColorMatrixByCCTSample(
                cct: Double(readBEUInt32(data, at: offset)),
                matrix: Matrix3x3(rowMajor: values)
            )
        }
        .sorted { $0.cct < $1.cct }
    }

    static func interpolateWhiteBalanceFactors(for cct: Double, samples: [WhiteBalanceByCCTSample]) -> WhiteBalanceByCCTSample? {
        guard !samples.isEmpty else { return nil }
        if cct <= samples[0].cct || samples.count == 1 {
            return samples[0]
        }
        if cct >= samples[samples.count - 1].cct {
            return samples[samples.count - 1]
        }

        for index in 0..<(samples.count - 1) {
            let lower = samples[index]
            let upper = samples[index + 1]
            guard cct >= lower.cct, cct <= upper.cct else { continue }
            let alpha = inverseCCTWeight(for: cct, lower: lower.cct, upper: upper.cct)
            return WhiteBalanceByCCTSample(
                cct: cct,
                redFactor: alpha * lower.redFactor + (1 - alpha) * upper.redFactor,
                blueFactor: alpha * lower.blueFactor + (1 - alpha) * upper.blueFactor
            )
        }

        return nil
    }

    static func interpolateColorMatrix(for cct: Double, samples: [ColorMatrixByCCTSample]) -> Matrix3x3? {
        guard !samples.isEmpty else { return nil }
        if cct <= samples[0].cct || samples.count == 1 {
            return samples[0].matrix
        }
        if cct >= samples[samples.count - 1].cct {
            return samples[samples.count - 1].matrix
        }

        for index in 0..<(samples.count - 1) {
            let lower = samples[index]
            let upper = samples[index + 1]
            guard cct >= lower.cct, cct <= upper.cct else { continue }
            let alpha = inverseCCTWeight(for: cct, lower: lower.cct, upper: upper.cct)
            let lowerValues = lower.matrix.rowMajorValues
            let upperValues = upper.matrix.rowMajorValues
            let interpolated = zip(lowerValues, upperValues).map { alpha * $0 + (1 - alpha) * $1 }
            return Matrix3x3(rowMajor: interpolated)
        }

        return nil
    }

    static func estimateCCT(fromRedFactor redFactor: Double, blueFactor: Double, samples: [WhiteBalanceByCCTSample]) -> Int? {
        guard samples.count >= 2 else { return nil }

        var bestError = Double.greatestFiniteMagnitude
        var bestCCT: Double?

        for index in 0..<(samples.count - 1) {
            let lower = samples[index]
            let upper = samples[index + 1]

            let deltaRed = lower.redFactor - upper.redFactor
            let deltaBlue = lower.blueFactor - upper.blueFactor
            let denominator = deltaRed * deltaRed + deltaBlue * deltaBlue
            var alpha = 0.0
            if denominator > .ulpOfOne {
                alpha = ((redFactor - upper.redFactor) * deltaRed + (blueFactor - upper.blueFactor) * deltaBlue) / denominator
            }
            alpha = min(max(alpha, 0), 1)

            let predictedRed = alpha * lower.redFactor + (1 - alpha) * upper.redFactor
            let predictedBlue = alpha * lower.blueFactor + (1 - alpha) * upper.blueFactor
            let error = hypot(abs(predictedRed - redFactor) / max(abs(redFactor), .ulpOfOne), abs(predictedBlue - blueFactor) / max(abs(blueFactor), .ulpOfOne))

            let inverseCCT = alpha * (1 / lower.cct) + (1 - alpha) * (1 / upper.cct)
            let candidateCCT = 1 / inverseCCT

            if error < bestError {
                bestError = error
                bestCCT = candidateCCT
            }
        }

        guard bestError <= 0.02, let bestCCT else { return nil }
        return Int(bestCCT.rounded())
    }

    static func inverseCCTWeight(for cct: Double, lower: Double, upper: Double) -> Double {
        let inverseCCT = 1 / cct
        let inverseLower = 1 / lower
        let inverseUpper = 1 / upper
        let weight = (inverseCCT - inverseUpper) / (inverseLower - inverseUpper)
        return min(max(weight, 0), 1)
    }

    private static func readBEUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { buffer in
            UInt16(bigEndian: buffer.load(fromByteOffset: offset, as: UInt16.self))
        }
    }

    private static func readBEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(bigEndian: buffer.load(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readBEFloat32(_ data: Data, at offset: Int) -> Float32 {
        Float32(bitPattern: readBEUInt32(data, at: offset))
    }
}
