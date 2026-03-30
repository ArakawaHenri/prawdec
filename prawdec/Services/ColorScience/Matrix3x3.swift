//
//  Matrix3x3.swift
//  prawdec
//

import Foundation

struct Matrix3x3: Equatable, Sendable {
    private var values: [Double]

    init(rowMajor values: [Double]) {
        precondition(values.count == 9)
        self.values = values
    }

    static let identity = Matrix3x3(rowMajor: [
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    ])

    var rowMajorValues: [Double] {
        values
    }

    func multiplied(by other: Matrix3x3) -> Matrix3x3 {
        var result = Array(repeating: 0.0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var value = 0.0
                for index in 0..<3 {
                    value += values[row * 3 + index] * other.values[index * 3 + column]
                }
                result[row * 3 + column] = value
            }
        }
        return Matrix3x3(rowMajor: result)
    }

    func multiplied(by vector: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            values[0] * vector.x + values[1] * vector.y + values[2] * vector.z,
            values[3] * vector.x + values[4] * vector.y + values[5] * vector.z,
            values[6] * vector.x + values[7] * vector.y + values[8] * vector.z
        )
    }

    /// Solves `self * x = b` using Gaussian elimination with partial pivoting.
    func solve(_ b: SIMD3<Double>) throws -> SIMD3<Double> {
        var a = [
            [values[0], values[1], values[2], b.x],
            [values[3], values[4], values[5], b.y],
            [values[6], values[7], values[8], b.z],
        ]

        for pivotColumn in 0..<3 {
            var pivotRow = pivotColumn
            var pivotMagnitude = abs(a[pivotColumn][pivotColumn])

            for candidateRow in (pivotColumn + 1)..<3 {
                let candidateMagnitude = abs(a[candidateRow][pivotColumn])
                if candidateMagnitude > pivotMagnitude {
                    pivotMagnitude = candidateMagnitude
                    pivotRow = candidateRow
                }
            }

            guard pivotMagnitude > 1e-12 else {
                throw ColorScienceError.singularMatrix
            }

            if pivotRow != pivotColumn {
                a.swapAt(pivotRow, pivotColumn)
            }

            let pivot = a[pivotColumn][pivotColumn]
            for column in pivotColumn..<4 {
                a[pivotColumn][column] /= pivot
            }

            for row in 0..<3 where row != pivotColumn {
                let factor = a[row][pivotColumn]
                guard factor != 0 else { continue }
                for column in pivotColumn..<4 {
                    a[row][column] -= factor * a[pivotColumn][column]
                }
            }
        }

        return SIMD3(a[0][3], a[1][3], a[2][3])
    }

    func inverted() throws -> Matrix3x3 {
        var inverse = Array(repeating: 0.0, count: 9)
        inverse[0] = values[4] * values[8] - values[5] * values[7]
        inverse[1] = values[2] * values[7] - values[1] * values[8]
        inverse[2] = values[1] * values[5] - values[2] * values[4]
        inverse[3] = values[5] * values[6] - values[3] * values[8]
        inverse[4] = values[0] * values[8] - values[2] * values[6]
        inverse[5] = values[2] * values[3] - values[0] * values[5]
        inverse[6] = values[3] * values[7] - values[4] * values[6]
        inverse[7] = values[1] * values[6] - values[0] * values[7]
        inverse[8] = values[0] * values[4] - values[1] * values[3]
        let determinant = values[0] * inverse[0] + values[1] * inverse[3] + values[2] * inverse[6]
        guard abs(determinant) > 1e-12 else {
            throw ColorScienceError.singularMatrix
        }
        return Matrix3x3(rowMajor: inverse.map { $0 / determinant })
    }

    func dividedRGBRows(redFactor: Double, blueFactor: Double) throws -> Matrix3x3 {
        guard redFactor > 0, blueFactor > 0 else {
            throw ColorScienceError.invalidWhiteBalanceFactors
        }
        var values = rowMajorValues
        for column in 0..<3 {
            values[column] /= redFactor
            values[6 + column] /= blueFactor
        }
        return Matrix3x3(rowMajor: values)
    }
}
