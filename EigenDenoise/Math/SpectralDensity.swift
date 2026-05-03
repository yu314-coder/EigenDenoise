//
//  SpectralDensity.swift
//
//  Closed-form limiting spectral density f_{y,H}(z) for the generalized
//  sample-covariance matrix B_n = S_n T_n with H = β·δ_a + (1-β)·δ_1, taken
//  from Yu (2025) "Geometric Analysis of the Eigenvalue Range of the
//  Generalized Covariance Matrix".
//
//  The density is derived from the Stieltjes transform s(z), which is the
//  root of the cubic
//
//      a·z·s³ + (a(z−y+1)+z)·s² + (a+z−y+1−y·β(a−1))·s + 1 = 0           (Eq. 5)
//
//  Cardano's depressed-cubic form gives
//
//      f_{y,H}(z) = (√3 / (2πy)) · { ∛(P + √D) − ∛(P − √D) }              (PDF formula)
//
//  with
//      A = a(z−y+1)+z
//      B = a+z−y+1−y·β·(a−1)
//      P = A·B / (6 a² z²)  −  A³ / (27 a³ z³)  −  1 / (2az)
//      Q = B / (3az)  −  A² / (9 a² z²)
//      D = P² + Q³
//
//  When D ≥ 0 the cubic has one real root → s(z) is real → density = 0
//  (we are outside the spectral support). When D < 0 the cubic has three
//  distinct real roots (achieved by complex cube roots that give a pair of
//  conjugates), and the imaginary part of the principal cube root yields
//  the density.
//
//  Support edges and Case 1/2/3 detection follow Section 3.2 of the PDF:
//  the support is contained in [max_{t>0} g(t), min_{t∈(-1/a,0)} g(t)],
//  and the discriminant Δ of the quartic P_4 in (12) tells us whether the
//  support is one interval (Cases 1/3) or two disjoint intervals (Case 2).
//

import Foundation

public enum SpectralDensity {

    /// Cardano-form density f_{y,H}(z) at a single point. Returns 0 outside
    /// the spectral support (where the depressed cubic has three real roots,
    /// i.e. D ≤ 0). Inside the support D > 0: the cubic has one real + two
    /// complex conjugate roots, and Im(s) = (√3/2)·(∛(P+√D) − ∛(P−√D)).
    public static func density(at z: Double, a: Double, y: Double, beta: Double) -> Double {
        guard z > 0, a > 0, y > 0 else { return 0 }
        let A  = a * (z - y + 1.0) + z
        let B0 = a + z - y + 1.0 - y * beta * (a - 1.0)
        let az = a * z
        let az2 = az * az
        let az3 = az2 * az
        let P = A * B0 / (6.0 * az2)
              - A * A * A / (27.0 * az3)
              - 1.0 / (2.0 * az)
        let Q = B0 / (3.0 * az)
              - A * A / (9.0 * az2)
        let D = P * P + Q * Q * Q

        // D ≤ 0 → three real roots → outside support → density = 0.
        if D <= 0 { return 0 }

        // Inside the support: P ± √D real; use real (sign-preserving) cube
        // roots. Im(s_+) = (√3/2)·(u − v); density = Im(s)/π scaled by 1/y.
        let sD = sqrt(D)
        let u = cbrt(P + sD)
        let v = cbrt(P - sD)
        let prefactor = sqrt(3.0) / (2.0 * .pi * y)
        return max(prefactor * (u - v), 0.0)
    }

    // ------------------------------------------------------------------
    // Support — bulk edges via the existing Brent search on g(t).
    // ------------------------------------------------------------------

    public struct Support: Sendable {
        public let lowerEdge: Double          // λ_min of the bulk
        public let upperEdge: Double          // λ_max of the bulk
        public let caseLabel: Int             // 1, 2, or 3 (PDF Section 3.2)
        public let interval2: (Double, Double)?  // present in Case 2 (gap inside)
        public let discriminant: Double       // Δ of P_4(t)
    }

    /// Coarse spectral support [max_{t>0} g(t), min_{t∈I⁺(a)} g(t)] times σ²,
    /// plus a Case label distinguishing one-interval vs two-interval support
    /// (Yu 2025, Section 3.2).
    public static func support(a: Double, beta: Double, y: Double, sigma2: Double) -> Support {
        let edges = RMT.bulkEdges(a: a, beta: beta, y: y)
        let lo = edges.gMinus * sigma2
        let hi = edges.gPlus  * sigma2

        // Quartic P_4(t) = (at+1)²(t+1)² − a²·y·β·t²·(t+1)² − y(1-β)·t²·(at+1)²
        // The discriminant Δ = B²−4AC tells us about case structure.
        // Coefficients (see Eq. 12 in PDF):
        let c4 = a * a * (1.0 - y)
        let c3 = 2.0 * a * a * (1.0 - y * beta) + 2.0 * a * (1.0 - y * (1.0 - beta))
        let c2 = a * a * (1.0 - y * beta) + 4.0 * a + (1.0 - y * (1.0 - beta))
        let c1 = 2.0 * a + 2.0
        let c0 = 1.0
        let D2 = 3 * c3 * c3 - 8 * c4 * c2
        let E  = -c3 * c3 * c3 + 4 * c4 * c3 * c2 - 8 * c4 * c4 * c1
        let F  = 3 * c3 * c3 * c3 * c3
                + 16 * c4 * c4 * c2 * c2
                - 16 * c4 * c3 * c3 * c2
                + 16 * c4 * c4 * c3 * c1
                - 64 * c4 * c4 * c4 * c0
        let A2 = D2 * D2 - 3 * F
        let B2 = D2 * F - 9 * E * E
        let C2 = F * F - 3 * D2 * E * E
        let delta = B2 * B2 - 4 * A2 * C2

        // Detect a gap inside (Case 2): scan t ∈ (-1, -1/a) for an
        // additional interior extremum of g(t). If g(t) hits a value between
        // the existing g_- and g_+ along that interval, we've got a second
        // disjoint support component.
        var gap: (Double, Double)? = nil
        if a > 1.0 + 1e-9 {
            let lo2 = -1.0 + 1e-6
            let hi2 = -1.0 / a - 1e-6
            if lo2 < hi2 {
                // Sample 64 points and look for both a local minimum and a
                // local maximum of g(t) in this interval.
                let n = 64
                var ts = [Double](); ts.reserveCapacity(n)
                var gs = [Double](); gs.reserveCapacity(n)
                for i in 0..<n {
                    let t = lo2 + (hi2 - lo2) * Double(i) / Double(n - 1)
                    ts.append(t)
                    gs.append(RMT.gFunction(t, a: a, beta: beta, y: y))
                }
                if let mi = gs.indices.min(by: { gs[$0] < gs[$1] }),
                   let mx = gs.indices.max(by: { gs[$0] < gs[$1] }) {
                    let g1 = gs[mi] * sigma2
                    let g2 = gs[mx] * sigma2
                    let lo3 = min(g1, g2), hi3 = max(g1, g2)
                    // Only treat as a real gap when it lies strictly inside [lo, hi]
                    if lo3 > lo + 1e-6 && hi3 < hi - 1e-6 {
                        gap = (lo3, hi3)
                    }
                }
            }
        }

        let label: Int = {
            if delta < 0 && D2 > 0 && F > 0 { return 2 }
            if delta > 0 { return 3 }
            return 1
        }()

        return Support(lowerEdge: lo, upperEdge: hi,
                        caseLabel: label, interval2: gap, discriminant: delta)
    }

    /// Sample the density on a uniform grid over the support, returning
    /// (z, f(z)) pairs. `padding` extends the range a bit beyond the bulk
    /// edges (default 5 %) so the curve smoothly returns to zero on either
    /// side. Skips the gap interval when the support is two-piece.
    public static func sampleDensity(a: Double, beta: Double, y: Double,
                                       sigma2: Double,
                                       points: Int = 600,
                                       padding: Double = 0.05) -> [(z: Double, f: Double)] {
        let segs = sampleDensitySegments(a: a, beta: beta, y: y,
                                          sigma2: sigma2, points: points,
                                          padding: padding)
        return segs.flatMap { $0 }
    }

    /// Sample the density and return one array per disjoint support
    /// component (one segment in Cases 1/3, two segments in Case 2).
    /// Each segment uses cosine-spaced sampling so points concentrate near
    /// the edges, where the density has a square-root cusp. The number of
    /// points per segment is allocated proportionally to its width.
    public static func sampleDensitySegments(a: Double, beta: Double, y: Double,
                                              sigma2: Double,
                                              points: Int = 1500,
                                              padding: Double = 0.05)
        -> [[(z: Double, f: Double)]]
    {
        let s = support(a: a, beta: beta, y: y, sigma2: sigma2)
        let span = s.upperEdge - s.lowerEdge
        guard span > 0, points > 4 else { return [] }
        let pad = span * padding

        // Build segment ranges: in Case 2 there is an interior gap.
        var ranges: [(Double, Double)] = []
        if let g = s.interval2 {
            let lo1 = max(s.lowerEdge - pad, 0)
            ranges.append((lo1, g.0))
            ranges.append((g.1, s.upperEdge + pad))
        } else {
            let lo1 = max(s.lowerEdge - pad, 0)
            ranges.append((lo1, s.upperEdge + pad))
        }

        let totalWidth = ranges.reduce(0.0) { $0 + max($1.1 - $1.0, 0) }
        guard totalWidth > 0 else { return [] }

        var out: [[(Double, Double)]] = []
        for (lo, hi) in ranges {
            let w = hi - lo
            guard w > 0 else { continue }
            let n = max(8, Int((Double(points) * w / totalWidth).rounded()))
            var seg = [(Double, Double)](); seg.reserveCapacity(n)
            // Cosine spacing → tighter near both ends.
            for i in 0..<n {
                let t = Double(i) / Double(n - 1)
                let u = 0.5 * (1.0 - cos(.pi * t))
                let z = lo + u * w
                seg.append((z, density(at: z, a: a, y: y, beta: beta)))
            }
            out.append(seg)
        }
        return out
    }
}
