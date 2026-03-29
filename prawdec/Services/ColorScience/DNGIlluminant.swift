//
//  DNGIlluminant.swift
//  prawdec
//

/// DNG calibration illuminant tag values (EXIF LightSource).
enum DNGIlluminant {
    static let unknown: UInt16 = 0
    static let standardA: UInt16 = 17
    static let d65: UInt16 = 21

    /// Correlated color temperatures for standard illuminants.
    static let standardACCT = 2856.0
    static let d65CCT = 6504.0
    static let d50CCT = 5003.0
}
