//
//  TIFFTagInjector.swift
//  prawdec
//
//  Post-write TIFF tag injection for CinemaDNG tags (51043, 51044)
//  that the DNG SDK does not natively support.
//
//  DNG is a TIFF-based format. After the SDK writes the file, we parse
//  the TIFF structure, add our tags to IFD0, and rewrite the IFD at the
//  end of the file. Existing data and offsets are not disturbed.
//

import Foundation

enum TIFFTagInjectorError: LocalizedError, Sendable {
    case fileNotFound(String)
    case invalidTIFF
    case unsupportedBigTIFFOffsetSize(UInt16)
    case classicTIFFOffsetOverflow(UInt64)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return L10n.tr("error.tiff.file_not_found", path)
        case .invalidTIFF: return L10n.tr("error.tiff.invalid_tiff")
        case .unsupportedBigTIFFOffsetSize(let size): return L10n.tr("error.tiff.unsupported_bigtiff_offset_size", size)
        case .classicTIFFOffsetOverflow(let offset): return L10n.tr("error.tiff.classic_offset_overflow", offset)
        case .ioError(let msg): return L10n.tr("error.tiff.io_error", msg)
        }
    }
}

enum TIFFTagInjector {

    // TIFF tag 51043 (0xC763) - TimeCodes: BYTE array, 8 bytes per timecode
    static let tagTimeCodes: UInt16 = 0xC763
    // TIFF tag 51044 (0xC764) - FrameRate: SRATIONAL (num/den)
    static let tagFrameRate: UInt16 = 0xC764

    // TIFF type constants
    private static let typeByte: UInt16 = 1
    private static let typeSRational: UInt16 = 10

    private enum ContainerKind {
        case classic
        case big

        var entryCountSize: Int {
            switch self {
            case .classic: return 2
            case .big: return 8
            }
        }

        var entrySize: Int {
            switch self {
            case .classic: return 12
            case .big: return 20
            }
        }

        var nextIFDOffsetSize: Int {
            switch self {
            case .classic: return 4
            case .big: return 8
            }
        }

        var firstIFDOffsetFieldOffset: UInt64 {
            switch self {
            case .classic: return 4
            case .big: return 8
            }
        }
    }

    private struct Header {
        var kind: ContainerKind
        var isLittleEndian: Bool
        var firstIFDOffset: UInt64
    }

    private struct IFDEntry {
        var tag: UInt16
        var data: Data
    }

    private struct IFDContents {
        var entries: [IFDEntry]
        var nextIFDOffset: UInt64
    }

    /// Inject TimeCodes and FrameRate tags into a DNG file's IFD0.
    ///
    /// - Parameters:
    ///   - url: Path to the DNG file (will be modified in-place).
    ///   - timecodeData: 8 bytes of SMPTE ST 12 time-address + user bits.
    ///   - frameRate: Rational frame rate (numerator, denominator).
    static func inject(
        url: URL,
        timecodeData: Data,
        frameRate: (Int32, Int32)
    ) throws {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw TIFFTagInjectorError.fileNotFound(path)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw TIFFTagInjectorError.ioError(L10n.tr("error.tiff.open_for_update_failed"))
        }
        defer { try? handle.close() }

        let header = try readHeader(from: handle)
        var ifd0 = try readIFD(at: header.firstIFDOffset, from: handle, header: header)
        ifd0.entries.removeAll { $0.tag == tagTimeCodes || $0.tag == tagFrameRate }

        handle.seekToEndOfFile()
        let timecodeDataOffset = handle.offsetInFile
        handle.write(timecodeData.prefix(8))

        let frameRateDataOffset = handle.offsetInFile
        handle.write(encodeFrameRate(frameRate, littleEndian: header.isLittleEndian))

        ifd0.entries.append(
            IFDEntry(
                tag: tagTimeCodes,
                data: try makeEntry(
                    kind: header.kind,
                    tag: tagTimeCodes,
                    type: typeByte,
                    count: 8,
                    valueOrOffset: timecodeDataOffset,
                    littleEndian: header.isLittleEndian
                )
            )
        )
        ifd0.entries.append(
            IFDEntry(
                tag: tagFrameRate,
                data: try makeEntry(
                    kind: header.kind,
                    tag: tagFrameRate,
                    type: typeSRational,
                    count: 1,
                    valueOrOffset: frameRateDataOffset,
                    littleEndian: header.isLittleEndian
                )
            )
        )
        ifd0.entries.sort { $0.tag < $1.tag }

        let newIFDOffset = handle.offsetInFile
        try writeIFD(ifd0, atEndOf: handle, header: header)
        try updateFirstIFDOffset(newIFDOffset, in: handle, header: header)
    }

    // MARK: - TIFF Parsing

    private static func readHeader(from handle: FileHandle) throws -> Header {
        handle.seek(toFileOffset: 0)
        guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else {
            throw TIFFTagInjectorError.invalidTIFF
        }

        let byteOrder = UInt16(prefix[0]) | (UInt16(prefix[1]) << 8)
        let isLittleEndian: Bool
        if byteOrder == 0x4949 {
            isLittleEndian = true
        } else if byteOrder == 0x4D4D {
            isLittleEndian = false
        } else {
            throw TIFFTagInjectorError.invalidTIFF
        }

        let magic = readUInt16(prefix, offset: 2, littleEndian: isLittleEndian)
        switch magic {
        case 42:
            let firstIFDOffset = UInt64(readUInt32(prefix, offset: 4, littleEndian: isLittleEndian))
            return Header(kind: .classic, isLittleEndian: isLittleEndian, firstIFDOffset: firstIFDOffset)
        case 43:
            let offsetSize = readUInt16(prefix, offset: 4, littleEndian: isLittleEndian)
            let reserved = readUInt16(prefix, offset: 6, littleEndian: isLittleEndian)
            guard offsetSize == 8, reserved == 0 else {
                throw TIFFTagInjectorError.unsupportedBigTIFFOffsetSize(offsetSize)
            }
            guard let tail = try? handle.read(upToCount: 8), tail.count == 8 else {
                throw TIFFTagInjectorError.invalidTIFF
            }
            let firstIFDOffset = readUInt64(tail, offset: 0, littleEndian: isLittleEndian)
            return Header(kind: .big, isLittleEndian: isLittleEndian, firstIFDOffset: firstIFDOffset)
        default:
            throw TIFFTagInjectorError.invalidTIFF
        }
    }

    private static func readIFD(at offset: UInt64, from handle: FileHandle, header: Header) throws -> IFDContents {
        handle.seek(toFileOffset: offset)

        let countSize = header.kind.entryCountSize
        guard let countData = try? handle.read(upToCount: countSize), countData.count == countSize else {
            throw TIFFTagInjectorError.invalidTIFF
        }

        let entryCount: Int
        switch header.kind {
        case .classic:
            entryCount = Int(readUInt16(countData, offset: 0, littleEndian: header.isLittleEndian))
        case .big:
            entryCount = Int(readUInt64(countData, offset: 0, littleEndian: header.isLittleEndian))
        }

        let entriesSize = entryCount * header.kind.entrySize
        let entriesData: Data
        if entriesSize == 0 {
            entriesData = Data()
        } else {
            guard let data = try? handle.read(upToCount: entriesSize), data.count == entriesSize else {
                throw TIFFTagInjectorError.invalidTIFF
            }
            entriesData = data
        }

        guard let nextIFDData = try? handle.read(upToCount: header.kind.nextIFDOffsetSize),
              nextIFDData.count == header.kind.nextIFDOffsetSize else {
            throw TIFFTagInjectorError.invalidTIFF
        }

        var entries: [IFDEntry] = []
        entries.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let base = index * header.kind.entrySize
            let tag = readUInt16(entriesData, offset: base, littleEndian: header.isLittleEndian)
            let range = entriesData.startIndex + base ..< entriesData.startIndex + base + header.kind.entrySize
            entries.append(IFDEntry(tag: tag, data: Data(entriesData[range])))
        }

        let nextIFDOffset: UInt64
        switch header.kind {
        case .classic:
            nextIFDOffset = UInt64(readUInt32(nextIFDData, offset: 0, littleEndian: header.isLittleEndian))
        case .big:
            nextIFDOffset = readUInt64(nextIFDData, offset: 0, littleEndian: header.isLittleEndian)
        }

        return IFDContents(entries: entries, nextIFDOffset: nextIFDOffset)
    }

    // MARK: - TIFF Writing

    private static func encodeFrameRate(_ frameRate: (Int32, Int32), littleEndian: Bool) -> Data {
        var data = Data(count: 8)
        writeInt32(&data, offset: 0, value: frameRate.0, littleEndian: littleEndian)
        writeInt32(&data, offset: 4, value: frameRate.1, littleEndian: littleEndian)
        return data
    }

    private static func makeEntry(
        kind: ContainerKind,
        tag: UInt16,
        type: UInt16,
        count: UInt64,
        valueOrOffset: UInt64,
        littleEndian: Bool
    ) throws -> Data {
        switch kind {
        case .classic:
            guard valueOrOffset <= UInt64(UInt32.max) else {
                throw TIFFTagInjectorError.classicTIFFOffsetOverflow(valueOrOffset)
            }

            var data = Data(count: 12)
            writeUInt16(&data, offset: 0, value: tag, littleEndian: littleEndian)
            writeUInt16(&data, offset: 2, value: type, littleEndian: littleEndian)
            writeUInt32(&data, offset: 4, value: UInt32(truncatingIfNeeded: count), littleEndian: littleEndian)
            writeUInt32(&data, offset: 8, value: UInt32(valueOrOffset), littleEndian: littleEndian)
            return data

        case .big:
            var data = Data(count: 20)
            writeUInt16(&data, offset: 0, value: tag, littleEndian: littleEndian)
            writeUInt16(&data, offset: 2, value: type, littleEndian: littleEndian)
            writeUInt64(&data, offset: 4, value: count, littleEndian: littleEndian)
            writeUInt64(&data, offset: 12, value: valueOrOffset, littleEndian: littleEndian)
            return data
        }
    }

    private static func writeIFD(_ ifd: IFDContents, atEndOf handle: FileHandle, header: Header) throws {
        switch header.kind {
        case .classic:
            guard ifd.entries.count <= Int(UInt16.max) else {
                throw TIFFTagInjectorError.ioError(L10n.tr("error.tiff.classic_ifd_entry_overflow"))
            }
            var countData = Data(count: 2)
            writeUInt16(&countData, offset: 0, value: UInt16(ifd.entries.count), littleEndian: header.isLittleEndian)
            handle.write(countData)

        case .big:
            var countData = Data(count: 8)
            writeUInt64(&countData, offset: 0, value: UInt64(ifd.entries.count), littleEndian: header.isLittleEndian)
            handle.write(countData)
        }

        for entry in ifd.entries {
            handle.write(entry.data)
        }

        switch header.kind {
        case .classic:
            guard ifd.nextIFDOffset <= UInt64(UInt32.max) else {
                throw TIFFTagInjectorError.classicTIFFOffsetOverflow(ifd.nextIFDOffset)
            }
            var nextData = Data(count: 4)
            writeUInt32(&nextData, offset: 0, value: UInt32(ifd.nextIFDOffset), littleEndian: header.isLittleEndian)
            handle.write(nextData)

        case .big:
            var nextData = Data(count: 8)
            writeUInt64(&nextData, offset: 0, value: ifd.nextIFDOffset, littleEndian: header.isLittleEndian)
            handle.write(nextData)
        }
    }

    private static func updateFirstIFDOffset(_ offset: UInt64, in handle: FileHandle, header: Header) throws {
        handle.seek(toFileOffset: header.kind.firstIFDOffsetFieldOffset)

        switch header.kind {
        case .classic:
            guard offset <= UInt64(UInt32.max) else {
                throw TIFFTagInjectorError.classicTIFFOffsetOverflow(offset)
            }
            var data = Data(count: 4)
            writeUInt32(&data, offset: 0, value: UInt32(offset), littleEndian: header.isLittleEndian)
            handle.write(data)

        case .big:
            var data = Data(count: 8)
            writeUInt64(&data, offset: 0, value: offset, littleEndian: header.isLittleEndian)
            handle.write(data)
        }
    }

    // MARK: - Binary helpers

    private static func readUInt16(_ data: Data, offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    private static func readUInt32(_ data: Data, offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return littleEndian
            ? (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
    }

    private static func readUInt64(_ data: Data, offset: Int, littleEndian: Bool) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            let byte = UInt64(data[data.startIndex + offset + index])
            if littleEndian {
                value |= byte << (index * 8)
            } else {
                value = (value << 8) | byte
            }
        }
        return value
    }

    private static func writeUInt16(_ data: inout Data, offset: Int, value: UInt16, littleEndian: Bool) {
        if littleEndian {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8(value >> 8)
        } else {
            data[offset] = UInt8(value >> 8)
            data[offset + 1] = UInt8(value & 0xFF)
        }
    }

    private static func writeUInt32(_ data: inout Data, offset: Int, value: UInt32, littleEndian: Bool) {
        if littleEndian {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8(value >> 24)
        } else {
            data[offset] = UInt8(value >> 24)
            data[offset + 1] = UInt8((value >> 16) & 0xFF)
            data[offset + 2] = UInt8((value >> 8) & 0xFF)
            data[offset + 3] = UInt8(value & 0xFF)
        }
    }

    private static func writeUInt64(_ data: inout Data, offset: Int, value: UInt64, littleEndian: Bool) {
        if littleEndian {
            for index in 0..<8 {
                data[offset + index] = UInt8((value >> (index * 8)) & 0xFF)
            }
        } else {
            for index in 0..<8 {
                let shift = (7 - index) * 8
                data[offset + index] = UInt8((value >> shift) & 0xFF)
            }
        }
    }

    private static func writeInt32(_ data: inout Data, offset: Int, value: Int32, littleEndian: Bool) {
        writeUInt32(&data, offset: offset, value: UInt32(bitPattern: value), littleEndian: littleEndian)
    }
}
