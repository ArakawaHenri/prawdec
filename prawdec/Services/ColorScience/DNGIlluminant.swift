//
//  DNGIlluminant.swift
//  prawdec
//

import Foundation

/// DNG calibration illuminant tag values (EXIF LightSource).
enum DNGIlluminant {
    static let unknown: UInt16 = 0
    static let standardA: UInt16 = 17
    static let d65: UInt16 = 21

    /// Correlated color temperatures for standard illuminants.
    static let standardACCT = 2856.0
    static let d65CCT = 6504.0
    static let d50CCT = 5003.0

    /// Canonical DNG SDK white points for standard illuminants.
    static func xyWhitePoint(for illuminant: UInt16) -> (x: Double, y: Double)? {
        switch illuminant {
        case standardA:
            return (0.4476, 0.4074)
        case d65:
            return (0.3127, 0.3290)
        default:
            return nil
        }
    }

    static let d50XYWhitePoint = (x: 0.3457, y: 0.3585)
}

enum WhitePointReference: Sendable {
    case standardIlluminant(UInt16)
    case correlatedColorTemperature(Double)
    case xy(x: Double, y: Double)
}
