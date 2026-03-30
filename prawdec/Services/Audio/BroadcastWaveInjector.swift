//
//  BroadcastWaveInjector.swift
//  prawdec
//

import Foundation

enum BroadcastWaveInjectorError: LocalizedError, Sendable {
    case invalidWAV
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .invalidWAV:
            return L10n.tr("error.audio.invalid_wav")
        case .ioError(let message):
            return L10n.tr("error.audio.export_failed", message)
        }
    }
}

enum BroadcastWaveInjector {
    static func inject(
        url: URL,
        startTimecode: TimecodeInfo,
        sampleRate: Double
    ) throws {
        let originalData: Data
        do {
            originalData = try Data(contentsOf: url)
        } catch {
            throw BroadcastWaveInjectorError.ioError(error.localizedDescription)
        }

        guard originalData.count >= 12 else {
            throw BroadcastWaveInjectorError.invalidWAV
        }
        guard String(decoding: originalData[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: originalData[8..<12], as: UTF8.self) == "WAVE" else {
            throw BroadcastWaveInjectorError.invalidWAV
        }

        let bextChunk = makeBEXTChunk(
            startTimecode: startTimecode,
            sampleRate: sampleRate
        )

        var updatedData = Data()
        updatedData.append(originalData[0..<12])
        updatedData.append(bextChunk)
        updatedData.append(originalData[12...])

        let riffSize = UInt32(updatedData.count - 8)
        writeUInt32LE(&updatedData, offset: 4, value: riffSize)

        do {
            try updatedData.write(to: url, options: .atomic)
        } catch {
            throw BroadcastWaveInjectorError.ioError(error.localizedDescription)
        }
    }

    private static func makeBEXTChunk(
        startTimecode: TimecodeInfo,
        sampleRate: Double
    ) -> Data {
        let description = ""
        let originator = "prawdec"
        let originatorReference = ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: .now)
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: .now)

        let timeReference = sampleReference(
            from: startTimecode,
            sampleRate: sampleRate
        )

        var payload = Data()
        payload.append(paddedASCII(description, count: 256))
        payload.append(paddedASCII(originator, count: 32))
        payload.append(paddedASCII(originatorReference, count: 32))
        payload.append(paddedASCII(date, count: 10))
        payload.append(paddedASCII(time, count: 8))
        payload.append(uint64LE(timeReference))
        payload.append(uint16LE(1))
        payload.append(Data(repeating: 0, count: 64))
        payload.append(Data(repeating: 0, count: 190))

        var chunk = Data()
        chunk.append(Data("bext".utf8))
        chunk.append(uint32LE(UInt32(payload.count)))
        chunk.append(payload)
        if chunk.count % 2 != 0 {
            chunk.append(0)
        }
        return chunk
    }

    private static func sampleReference(
        from timecode: TimecodeInfo,
        sampleRate: Double
    ) -> UInt64 {
        let seconds = Double(timecode.startTimecode.frameNumber) / timecode.format.framesPerSecond
        return UInt64(max(0, (seconds * sampleRate).rounded()))
    }

    private static func paddedASCII(_ string: String, count: Int) -> Data {
        let truncated = String(string.prefix(count))
        var bytes = Array(truncated.utf8)
        if bytes.count < count {
            bytes.append(contentsOf: repeatElement(0, count: count - bytes.count))
        } else if bytes.count > count {
            bytes = Array(bytes.prefix(count))
        }
        return Data(bytes)
    }

    private static func uint16LE(_ value: UInt16) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size)
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
    }

    private static func uint64LE(_ value: UInt64) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt64>.size)
    }

    private static func writeUInt32LE(_ data: inout Data, offset: Int, value: UInt32) {
        let bytes = uint32LE(value)
        data.replaceSubrange(offset ..< offset + 4, with: bytes)
    }
}
