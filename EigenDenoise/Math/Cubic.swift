//
//  Cubic.swift
//  Closed-form roots of a cubic A·s³ + B·s² + C·s + D = 0 over the complex
//  numbers via Cardano + Vieta. Returns three roots (possibly equal) with
//  zero imaginary part on the real axis. Tracks roots smoothly across a
//  parameter sweep by sorting by imaginary then real part — matches the
//  `Roots vs β` plotting style in random_matrix_ESD/app.py.
//

import Foundation

public struct ComplexNumber: Sendable, Equatable {
    public var re: Double
    public var im: Double
    public init(_ re: Double, _ im: Double = 0) { self.re = re; self.im = im }
    public static let zero = ComplexNumber(0, 0)

    public var magnitude: Double { sqrt(re * re + im * im) }

    public static func + (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber {
        .init(a.re + b.re, a.im + b.im)
    }
    public static func - (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber {
        .init(a.re - b.re, a.im - b.im)
    }
    public static func * (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber {
        .init(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    public static func / (a: ComplexNumber, b: ComplexNumber) -> ComplexNumber {
        let d = b.re * b.re + b.im * b.im
        return .init((a.re * b.re + a.im * b.im) / d,
                     (a.im * b.re - a.re * b.im) / d)
    }

    /// Principal cube root.
    public func cbrt() -> ComplexNumber {
        let r = pow(magnitude, 1.0 / 3.0)
        let theta = atan2(im, re) / 3.0
        return .init(r * cos(theta), r * sin(theta))
    }
}

public enum Cubic {

    /// Solve A·s³ + B·s² + C·s + D = 0 in ℂ. Returns three roots, ordered by
    /// (imaginary, real). Falls back to a quadratic / linear / Newton path if
    /// A ≈ 0.
    public static func roots(A: Double, B: Double, C: Double, D: Double) -> [ComplexNumber] {
        if abs(A) < 1e-14 {
            // Quadratic: B s² + C s + D = 0
            if abs(B) < 1e-14 {
                if abs(C) < 1e-14 { return [] }
                return [ComplexNumber(-D / C)]   // linear
            }
            let disc = C * C - 4 * B * D
            if disc >= 0 {
                let r = sqrt(disc)
                return [ComplexNumber((-C + r) / (2 * B)), ComplexNumber((-C - r) / (2 * B))]
            }
            let r = sqrt(-disc) / (2 * B)
            let real = -C / (2 * B)
            return [ComplexNumber(real, r), ComplexNumber(real, -r)]
        }
        // Depressed cubic: s = t − B/(3A) → t³ + p t + q = 0
        let b = B / A, c = C / A, d = D / A
        let p = c - b * b / 3.0
        let q = (2.0 * b * b * b) / 27.0 - (b * c) / 3.0 + d
        let shift = -b / 3.0
        let disc = -(4.0 * p * p * p + 27.0 * q * q)
        // Vieta substitution for stable real roots when disc > 0.
        if disc > 0 {
            let m = 2.0 * sqrt(-p / 3.0)
            let theta = acos(3.0 * q / (p * m)) / 3.0
            let r0 = m * cos(theta) + shift
            let r1 = m * cos(theta - 2.0 * .pi / 3.0) + shift
            let r2 = m * cos(theta - 4.0 * .pi / 3.0) + shift
            return sortRoots([ComplexNumber(r0), ComplexNumber(r1), ComplexNumber(r2)])
        }
        // Cardano with complex cube roots otherwise.
        let halfQ = q / 2.0
        let pOver3 = p / 3.0
        let discTerm = halfQ * halfQ + pOver3 * pOver3 * pOver3
        let sqrtDisc = ComplexNumber(discTerm >= 0 ? sqrt(discTerm) : 0,
                                       discTerm <  0 ? sqrt(-discTerm) : 0)
        let u = (ComplexNumber(-halfQ) + sqrtDisc).cbrt()
        let v = (ComplexNumber(-halfQ) - sqrtDisc).cbrt()
        // Three primitive cube roots of unity.
        let omega = ComplexNumber(-0.5, sqrt(3.0) / 2.0)
        let omega2 = ComplexNumber(-0.5, -sqrt(3.0) / 2.0)
        let s = ComplexNumber(shift, 0)
        let r0 = u + v + s
        let r1 = u * omega + v * omega2 + s
        let r2 = u * omega2 + v * omega + s
        return sortRoots([r0, r1, r2])
    }

    /// Discriminant Δ = 18 ABCD − 4 B³D + B²C² − 4 A C³ − 27 A²D².
    /// Δ > 0 ⇒ three distinct real roots.
    /// Δ = 0 ⇒ multiple root.
    /// Δ < 0 ⇒ one real + two complex conjugates.
    public static func discriminant(A: Double, B: Double, C: Double, D: Double) -> Double {
        18 * A * B * C * D
            - 4 * B * B * B * D
            + B * B * C * C
            - 4 * A * C * C * C
            - 27 * A * A * D * D
    }

    /// Assemble the three coefficients of the Stieltjes cubic from
    /// (z, β, y, a) and return its three roots (in canonical order).
    ///
    ///     (z·a)·s³  +  [z·(a+1) + a·(1−y)]·s²
    ///        +  [z + (a+1) − y − y·β·(a−1)]·s  +  1  =  0
    public static func stieltjesRoots(z: Double, beta: Double, y: Double, a: Double) -> [ComplexNumber] {
        let A = z * a
        let B = z * (a + 1.0) + a * (1.0 - y)
        let C = z + (a + 1.0) - y - y * beta * (a - 1.0)
        let D = 1.0
        return roots(A: A, B: B, C: C, D: D)
    }

    public static func stieltjesDiscriminant(z: Double, beta: Double, y: Double, a: Double) -> Double {
        let A = z * a
        let B = z * (a + 1.0) + a * (1.0 - y)
        let C = z + (a + 1.0) - y - y * beta * (a - 1.0)
        let D = 1.0
        return discriminant(A: A, B: B, C: C, D: D)
    }

    private static func sortRoots(_ rs: [ComplexNumber]) -> [ComplexNumber] {
        rs.sorted {
            if abs($0.im - $1.im) > 1e-9 { return $0.im < $1.im }
            return $0.re < $1.re
        }
    }
}
