//
//  SMPTETimecode.swift
//  prawdec
//
//  Timecode handling conforming to SMPTE ST 12-1 (≤30fps) and ST 12-3 (HFR).
//  Clean-room Swift implementation — algorithms derived from public SMPTE specifications.
//

import Foundation

// MARK: - Timecode Format

enum TimecodeFormatError: LocalizedError, Sendable {
    case invalidFrameRate(Double)
    case unsupportedNominalFPS(Int, actualFPS: Double)
    case unsupportedDropFrame(actualFPS: Double, nominalFPS: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFrameRate(let fps):
            return "无效的帧率：\(fps)"
        case .unsupportedNominalFPS(let nominalFPS, let actualFPS):
            return "当前 SMPTE 时间码实现不支持名义帧率 \(nominalFPS) fps（实际 \(actualFPS) fps）。"
        case .unsupportedDropFrame(let actualFPS, let nominalFPS):
            return "不支持的 drop-frame 时间码帧率：\(actualFPS) fps（名义 \(nominalFPS) fps）。"
        }
    }
}

/// Generic SMPTE timecode format retaining the real frame-rate rational while
/// using a nominal integer FPS for ST 12-1 / ST 12-3 arithmetic.
struct TimecodeFormat: Sendable, Equatable {
    private static let maxNominalFPS = 120
    private static let commonRates: [(fps: Double, rational: (Int32, Int32))] = [
        (24000.0 / 1001.0, (24000, 1001)),
        (24.0, (24, 1)),
        (25.0, (25, 1)),
        (30000.0 / 1001.0, (30000, 1001)),
        (30.0, (30, 1)),
        (48000.0 / 1001.0, (48000, 1001)),
        (48.0, (48, 1)),
        (50.0, (50, 1)),
        (60000.0 / 1001.0, (60000, 1001)),
        (60.0, (60, 1)),
        (96000.0 / 1001.0, (96000, 1001)),
        (96.0, (96, 1)),
        (100.0, (100, 1)),
        (120000.0 / 1001.0, (120000, 1001)),
        (120.0, (120, 1)),
    ]

    let frameRateNumerator: Int32
    let frameRateDenominator: Int32
    let nominalFPS: Int
    let isDropFrame: Bool

    init(
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        nominalFPS: Int? = nil,
        dropFrame: Bool = false
    ) throws {
        let fps = Double(frameRateNumerator) / Double(frameRateDenominator)
        guard frameRateNumerator > 0, frameRateDenominator > 0, fps.isFinite, fps > 0 else {
            throw TimecodeFormatError.invalidFrameRate(fps)
        }

        let derivedNominalFPS = nominalFPS ?? Int(fps.rounded())
        guard (1...Self.maxNominalFPS).contains(derivedNominalFPS) else {
            throw TimecodeFormatError.unsupportedNominalFPS(derivedNominalFPS, actualFPS: fps)
        }
        if dropFrame, !Self.canUseDropFrame(actualFPS: fps, nominalFPS: derivedNominalFPS) {
            throw TimecodeFormatError.unsupportedDropFrame(actualFPS: fps, nominalFPS: derivedNominalFPS)
        }

        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        self.nominalFPS = derivedNominalFPS
        self.isDropFrame = dropFrame
    }

    var framesPerSecond: Double {
        Double(frameRateNumerator) / Double(frameRateDenominator)
    }

    var rational: (Int32, Int32) {
        (frameRateNumerator, frameRateDenominator)
    }

    /// Whether this format uses ST 12-3 frame-pair encoding (>30fps).
    var isHighFrameRate: Bool {
        nominalFPS > 30
    }

    /// Frames skipped at each non-tenth minute for drop-frame formats.
    var dropFrameCount: Int {
        guard isDropFrame else { return 0 }
        return nominalFPS / 15
    }

    func withDropFrame(_ enabled: Bool) throws -> TimecodeFormat {
        try TimecodeFormat(
            frameRateNumerator: frameRateNumerator,
            frameRateDenominator: frameRateDenominator,
            nominalFPS: nominalFPS,
            dropFrame: enabled
        )
    }

    static func detect(from fps: Double, dropFrame: Bool = false) throws -> TimecodeFormat {
        let rational = approximateRationalFPS(for: fps)
        return try TimecodeFormat(
            frameRateNumerator: rational.0,
            frameRateDenominator: rational.1,
            nominalFPS: Int(fps.rounded()),
            dropFrame: dropFrame
        )
    }

    private static func canUseDropFrame(actualFPS: Double, nominalFPS: Int) -> Bool {
        guard nominalFPS >= 30, nominalFPS % 30 == 0 else { return false }
        let expected = Double(nominalFPS) * 1000.0 / 1001.0
        return abs(actualFPS - expected) < 0.01
    }

    private static func approximateRationalFPS(for fps: Double) -> (Int32, Int32) {
        for candidate in commonRates where abs(candidate.fps - fps) < 0.01 {
            return candidate.rational
        }

        let approximation = rationalApproximation(of: fps, maxDenominator: 100_000)
        return normalize(numerator: approximation.0, denominator: approximation.1)
    }

    private static func rationalApproximation(of value: Double, maxDenominator: Int32) -> (Int32, Int32) {
        var x = value
        var a = floor(x)
        var h1: Int64 = 1
        var k1: Int64 = 0
        var h: Int64 = Int64(a)
        var k: Int64 = 1

        while abs(value - (Double(h) / Double(k))) > 1e-9, k < Int64(maxDenominator) {
            x = 1.0 / (x - a)
            a = floor(x)

            let nextH = Int64(a) * h + h1
            let nextK = Int64(a) * k + k1
            if nextK > Int64(maxDenominator) {
                break
            }

            h1 = h
            k1 = k
            h = nextH
            k = nextK
        }

        let numerator = max(1, min(h, Int64(Int32.max)))
        let denominator = max(1, min(k, Int64(Int32.max)))
        return (Int32(numerator), Int32(denominator))
    }

    private static func normalize(numerator: Int32, denominator: Int32) -> (Int32, Int32) {
        let divisor = gcd(abs(numerator), abs(denominator))
        return (numerator / divisor, denominator / divisor)
    }

    private static func gcd(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(1, a)
    }
}

// MARK: - SMPTE Timecode

struct SMPTETimecode: Sendable, Equatable, CustomStringConvertible {
    var hours: Int
    var minutes: Int
    var seconds: Int
    var frames: Int
    var format: TimecodeFormat

    var description: String {
        let sep = format.isDropFrame ? ";" : ":"
        let hh = String(format: "%02d", hours)
        let mm = String(format: "%02d", minutes)
        let ss = String(format: "%02d", seconds)
        let ff = String(format: "%02d", frames)
        return "\(hh):\(mm):\(ss)\(sep)\(ff)"
    }

    /// Total frame number from 00:00:00:00 (accounts for drop-frame).
    var frameNumber: Int {
        Self.hmsfToFrames(hours: hours, minutes: minutes, seconds: seconds,
                          frames: frames, format: format)
    }

    /// Create timecode from a frame number.
    init(frameNumber: Int, format: TimecodeFormat) {
        self.format = format
        let hmsf = Self.framesToHMSF(frameNumber: frameNumber, format: format)
        self.hours = hmsf.hours
        self.minutes = hmsf.minutes
        self.seconds = hmsf.seconds
        self.frames = hmsf.frames
    }

    /// Create timecode from HMSF components.
    init(hours: Int, minutes: Int, seconds: Int, frames: Int, format: TimecodeFormat) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.format = format
    }

    /// Advance by a given number of frames.
    func advanced(by frameCount: Int) -> SMPTETimecode {
        SMPTETimecode(frameNumber: frameNumber + frameCount, format: format)
    }

    // MARK: - SMPTE ST 12-1/12-3 BCD Encoding

    /// Encode as SMPTE 12M 32-bit word.
    /// For ST 12-3 (HFR), the frames field stores the frame-pair number
    /// and bit 31 is the frame-pair identifier (0=first, 1=second).
    func encodeSMPTE12M() -> UInt32 {
        var word: UInt32 = 0

        let (encFrames, pairBit): (Int, Bool)
        if format.isHighFrameRate {
            encFrames = frames / 2
            pairBit = (frames % 2) != 0
        } else {
            encFrames = frames
            pairBit = false
        }

        // Byte 0: Frames (BCD) + flags
        let frameUnits = UInt32(encFrames % 10)
        let frameTens = UInt32(encFrames / 10)
        word |= frameUnits
        word |= (frameTens & 0x3) << 4
        if format.isDropFrame { word |= (1 << 6) }

        // Byte 1: Seconds (BCD)
        let secUnits = UInt32(seconds % 10)
        let secTens = UInt32(seconds / 10)
        word |= secUnits << 8
        word |= (secTens & 0x7) << 12

        // Byte 2: Minutes (BCD)
        let minUnits = UInt32(minutes % 10)
        let minTens = UInt32(minutes / 10)
        word |= minUnits << 16
        word |= (minTens & 0x7) << 20

        // Byte 3: Hours (BCD) + frame-pair identifier
        let hrUnits = UInt32(hours % 10)
        let hrTens = UInt32(hours / 10)
        word |= hrUnits << 24
        word |= (hrTens & 0x3) << 28
        if pairBit { word |= (1 << 31) }

        return word
    }

    /// Encode as 8-byte big-endian data for CinemaDNG tag 51043.
    /// The first 4 bytes are the SMPTE time-address word and the next
    /// 4 bytes are user bits, which we currently leave as zero.
    func encodeSMPTE12MData() -> Data {
        var be = encodeSMPTE12M().bigEndian
        var data = Data(bytes: &be, count: 4)
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }

    /// Decode from SMPTE 12M 32-bit word.
    static func decodeSMPTE12M(_ word: UInt32, format: TimecodeFormat) -> SMPTETimecode {
        let frameUnits = Int(word & 0xF)
        let frameTens = Int((word >> 4) & 0x3)
        let encFrames = frameTens * 10 + frameUnits

        let secUnits = Int((word >> 8) & 0xF)
        let secTens = Int((word >> 12) & 0x7)
        let seconds = secTens * 10 + secUnits

        let minUnits = Int((word >> 16) & 0xF)
        let minTens = Int((word >> 20) & 0x7)
        let minutes = minTens * 10 + minUnits

        let hrUnits = Int((word >> 24) & 0xF)
        let hrTens = Int((word >> 28) & 0x3)
        let hours = hrTens * 10 + hrUnits

        let pairBit = (word >> 31) & 1

        let frames: Int
        if format.isHighFrameRate {
            frames = encFrames * 2 + Int(pairBit)
        } else {
            frames = encFrames
        }

        return SMPTETimecode(hours: hours, minutes: minutes, seconds: seconds,
                             frames: frames, format: format)
    }

    // MARK: - Frame Number Conversion

    /// HMSF → absolute frame number (SMPTE ST 12-1 drop-frame aware).
    static func hmsfToFrames(hours: Int, minutes: Int, seconds: Int,
                             frames: Int, format: TimecodeFormat) -> Int {
        let fps = format.nominalFPS

        var dropFrames = 0
        if format.isDropFrame {
            // Generalized drop-frame handling for nominal rates derived from
            // N * 1000 / 1001 where N is a multiple of 30.
            let dropCount = format.dropFrameCount
            let totalMinutes = hours * 60 + minutes
            dropFrames = dropCount * (totalMinutes - totalMinutes / 10)
        }

        return hours * 3600 * fps
             + minutes * 60 * fps
             + seconds * fps
             + frames
             - dropFrames
    }

    /// Absolute frame number → HMSF (SMPTE ST 12-1 drop-frame aware).
    static func framesToHMSF(frameNumber: Int, format: TimecodeFormat)
        -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        let fps = format.nominalFPS
        var fn = abs(frameNumber)

        if format.isDropFrame {
            let dropCount = format.dropFrameCount
            let framesPerMinute = fps * 60 - dropCount
            let framesPer10Minutes = framesPerMinute * 10 + dropCount

            // 24h rollover
            let framesPer24h = framesPer10Minutes * 6 * 24
            fn = fn % framesPer24h

            let chunksOf10 = fn / framesPer10Minutes
            let remainder = fn % framesPer10Minutes
            let chunksOf1: Int
            if remainder < dropCount {
                chunksOf1 = 0
            } else {
                chunksOf1 = (remainder - dropCount) / framesPerMinute
            }

            fn += dropCount * (9 * chunksOf10 + chunksOf1)
        } else {
            let framesPer24h = fps * 60 * 60 * 24
            fn = fn % framesPer24h
        }

        let f = fn % fps
        let s = (fn / fps) % 60
        let m = (fn / fps / 60) % 60
        let h = (fn / fps / 60 / 60)

        return (h, m, s, f)
    }
}
