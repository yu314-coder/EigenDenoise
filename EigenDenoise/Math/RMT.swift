//
//  RMT.swift
//  Random matrix theory primitives — direct Swift port of /Volumes/D/denoise
//  app.py and rmt-denoise PyPI lib (rmt_denoise/core.py).
//
//  All routines are double-precision and unit-tested against the Python
//  reference (see app.py:`_bulk_edges`, batch_mppca:`_g_edges`).
//

import Foundation

public enum RMT {

    /// The unified rational kernel  g(t; a, β, y)  from Yu (2025) Theorem 3.1:
    ///
    ///   g(t) = -1/t  +  y · ( β · a / (1 + a·t)  +  (1 - β) / (1 + t) )
    @inlinable
    public static func gFunction(_ t: Double, a: Double, beta: Double, y: Double) -> Double {
        guard abs(t) > 1e-15 else { return .infinity }
        return -1.0 / t + y * (beta * a / (1.0 + a * t) + (1.0 - beta) / (1.0 + t))
    }

    @inlinable
    public static func gDerivative(_ t: Double, a: Double, beta: Double, y: Double) -> Double {
        return 1.0 / (t * t)
            - y * beta * a * a / pow(1.0 + a * t, 2)
            - y * (1.0 - beta) / pow(1.0 + t, 2)
    }

    /// Bulk edges (g_minus, g_plus) of the limiting noise spectrum under the
    /// two-point population law H = β·δ_a + (1-β)·δ_1. Uses regime-switched
    /// upper interval I⁺(a) = (-1/a, 0) for a≥1, (-1, 0) for 0<a<1.
    /// Reduces to classical MP edges (1±√y)² when |a-1|<1e-9 or β degenerate.
    public static func bulkEdges(a: Double, beta: Double, y: Double) -> (gMinus: Double, gPlus: Double) {
        if abs(a - 1.0) < 1e-9 || beta < 1e-9 || beta > 1.0 - 1e-9 {
            let r = sqrt(max(y, 0.0))
            return (max(pow(1.0 - r, 2), 0.0), pow(1.0 + r, 2))
        }
        // g_minus = max over t > 0; search log-scale θ ∈ [-14, 14] via Brent.
        let gMinus: Double = {
            let f: (Double) -> Double = { theta in
                -gFunction(exp(theta), a: a, beta: beta, y: y)
            }
            let res = Brent.minimize(f: f, lo: -14.0, hi: 14.0, xtol: 1e-10, maxIter: 100)
            return -res.value
        }()
        // g_plus = min over (lo, -ε) with regime switch.
        let lo: Double = a >= 1.0 ? (-1.0 / a + 1e-10) : (-1.0 + 1e-10)
        let hi: Double = -1e-10
        let gPlus: Double = {
            let f: (Double) -> Double = { t in gFunction(t, a: a, beta: beta, y: y) }
            return Brent.minimize(f: f, lo: lo, hi: hi, xtol: 1e-10, maxIter: 100).value
        }()
        return (gMinus, gPlus)
    }

    /// Generalized MP bulk width, equivalent to gPlus - gMinus.
    public static func bulkWidth(a: Double, beta: Double, y: Double) -> Double {
        let (lo, hi) = bulkEdges(a: a, beta: beta, y: y)
        return hi - lo
    }

    /// Classical MP width 4·√y (special case of bulkWidth when (a, β) = (1, 0)).
    @inlinable
    public static func classicalMPWidth(y: Double) -> Double { 4.0 * sqrt(max(y, 0.0)) }
}


// MARK: - Brent's bounded scalar minimizer (port of scipy.optimize._bounded)

public enum Brent {
    public struct Result { public let x: Double; public let value: Double; public let iter: Int }

    /// Brent's method on [lo, hi] for a unimodal-ish 1-D function, matches
    /// `scipy.optimize.minimize_scalar(method='bounded')` to ~xtol.
    public static func minimize(f: (Double) -> Double,
                                lo: Double,
                                hi: Double,
                                xtol: Double = 1e-5,
                                maxIter: Int = 500) -> Result {
        let goldenRatio: Double = 0.3819660112501051     // (3 - √5) / 2
        var a = lo, b = hi
        var fulc = a + goldenRatio * (b - a)
        var nfc = fulc, xf = fulc
        var rat = 0.0, e = 0.0
        var x = xf, fx = f(x)
        var ffulc = fx, fnfc = fx
        let xmTol = xtol
        var xm = 0.5 * (a + b)
        var tol1 = (xtol * abs(xf)) + xmTol / 3.0
        var tol2 = 2.0 * tol1
        var num = 0
        while num < maxIter, abs(xf - xm) > (tol2 - 0.5 * (b - a)) {
            var golden = true
            if abs(e) > tol1 {
                golden = false
                let r = (xf - nfc) * (fx - ffulc)
                var q = (xf - fulc) * (fx - fnfc)
                var p = (xf - fulc) * q - (xf - nfc) * r
                q = 2.0 * (q - r)
                if q > 0 { p = -p }
                q = abs(q)
                let etemp = e
                e = rat
                if abs(p) < abs(0.5 * q * etemp) && p > q * (a - xf) && p < q * (b - xf) {
                    rat = p / q
                    let xx = xf + rat
                    if (xx - a) < tol2 || (b - xx) < tol2 {
                        let si = xm >= xf ? 1.0 : -1.0
                        rat = tol1 * si
                    }
                } else {
                    golden = true
                }
            }
            if golden {
                e = (xf >= xm) ? (a - xf) : (b - xf)
                rat = goldenRatio * e
            }
            let si = rat >= 0 ? 1.0 : -1.0
            x = xf + (abs(rat) >= tol1 ? rat : si * tol1)
            let fu = f(x)
            if fu <= fx {
                if x >= xf { a = xf } else { b = xf }
                fulc = nfc; ffulc = fnfc
                nfc = xf;   fnfc = fx
                xf = x;     fx = fu
            } else {
                if x < xf { a = x } else { b = x }
                if fu <= fnfc || nfc == xf {
                    fulc = nfc; ffulc = fnfc
                    nfc = x;    fnfc = fu
                } else if fu <= ffulc || fulc == xf || fulc == nfc {
                    fulc = x; ffulc = fu
                }
            }
            xm = 0.5 * (a + b)
            tol1 = xtol * abs(xf) + xmTol / 3.0
            tol2 = 2.0 * tol1
            num += 1
        }
        return .init(x: xf, value: fx, iter: num)
    }
}
