//
//  DifferentialEvolution.swift
//  Best/1/bin differential evolution — port of scipy.optimize.differential_evolution
//  used by the rmt-denoise lib for the (a, β) oracle search.
//
//  Single-objective, derivative-free. Sobol initialisation + bounded-Brent
//  polish (cheap final 1-D refinement on each axis).
//

import Foundation

public struct Bounds: Sendable {
    public let lo: [Double]
    public let hi: [Double]
    public init(_ lo: [Double], _ hi: [Double]) {
        precondition(lo.count == hi.count)
        self.lo = lo; self.hi = hi
    }
    public var dim: Int { lo.count }
    public func clip(_ x: [Double]) -> [Double] {
        var y = x
        for i in 0..<y.count { y[i] = min(max(y[i], lo[i]), hi[i]) }
        return y
    }
}

public struct DEResult {
    public let x: [Double]
    public let f: Double
    public let nEval: Int
    public let iters: Int
    public let converged: Bool
}

public enum DE {

    public static func minimize(_ f: ([Double]) -> Double,
                                bounds: Bounds,
                                popsize: Int = 20,
                                maxIter: Int = 80,
                                F: Double = 0.7,
                                CR: Double = 0.7,
                                tol: Double = 1e-4,
                                seed: UInt64 = 42) -> DEResult {
        let dim = bounds.dim
        var rng = SplitMix64(seed: seed)
        let N = max(popsize * dim, 5 * dim)

        // Sobol-ish quasi-random initial population (uses Halton — good enough
        // for our 2-D search; full Sobol would need more code).
        var pop: [[Double]] = (0..<N).map { i in
            var p = [Double](repeating: 0, count: dim)
            for d in 0..<dim {
                let h = halton(index: i + 1, base: primeBase(d))
                p[d] = bounds.lo[d] + h * (bounds.hi[d] - bounds.lo[d])
            }
            return p
        }
        var fitness: [Double] = pop.map(f)
        var nEval = N
        var bestIdx = fitness.indices.min(by: { fitness[$0] < fitness[$1] })!
        var prevBest = fitness[bestIdx]

        var converged = false
        var iters = 0
        for iter in 0..<maxIter {
            iters = iter + 1
            for i in 0..<N {
                // Pick three distinct indices a, b, c ≠ i.
                var ia = Int(rng.next() % UInt64(N))
                while ia == i { ia = Int(rng.next() % UInt64(N)) }
                var ib = Int(rng.next() % UInt64(N))
                while ib == i || ib == ia { ib = Int(rng.next() % UInt64(N)) }
                var ic = Int(rng.next() % UInt64(N))
                while ic == i || ic == ia || ic == ib { ic = Int(rng.next() % UInt64(N)) }
                // Mutation: best/1 — use the population best as the base.
                let xa = pop[bestIdx]
                let xb = pop[ib]
                let xc = pop[ic]
                _ = ia
                var trial = [Double](repeating: 0, count: dim)
                let jrand = Int(rng.next() % UInt64(dim))
                for d in 0..<dim {
                    let crRoll = Double(rng.next() % 1_000_000) / 1_000_000.0
                    if crRoll < CR || d == jrand {
                        trial[d] = xa[d] + F * (xb[d] - xc[d])
                    } else {
                        trial[d] = pop[i][d]
                    }
                }
                trial = bounds.clip(trial)
                let ft = f(trial)
                nEval += 1
                if ft <= fitness[i] {
                    pop[i] = trial
                    fitness[i] = ft
                    if ft < fitness[bestIdx] { bestIdx = i }
                }
            }
            // Convergence: stddev of fitness < tol * mean(|fitness|) AND best stable.
            let mean = fitness.reduce(0, +) / Double(N)
            let sd = sqrt(fitness.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(N))
            let bestNow = fitness[bestIdx]
            if sd < tol * (1.0 + abs(mean)) && abs(prevBest - bestNow) < tol * (1.0 + abs(bestNow)) {
                converged = true
                break
            }
            prevBest = bestNow
        }
        // Polish via 1-D Brent on each axis around the best.
        var xb = pop[bestIdx]
        var fb = fitness[bestIdx]
        for d in 0..<dim {
            let lo = bounds.lo[d]; let hi = bounds.hi[d]
            let res = Brent.minimize(
                f: { v in
                    var t = xb; t[d] = v
                    return f(t)
                },
                lo: lo, hi: hi, xtol: 1e-6, maxIter: 100)
            nEval += res.iter + 1
            if res.value < fb {
                xb[d] = res.x
                fb = res.value
            }
        }
        return DEResult(x: xb, f: fb, nEval: nEval, iters: iters, converged: converged)
    }
}


// MARK: - Halton low-discrepancy sequence + tiny RNG

private func halton(index n: Int, base b: Int) -> Double {
    var n = n, f = 1.0, q = 0.0
    while n > 0 {
        f /= Double(b)
        q += f * Double(n % b)
        n /= b
    }
    return q
}

private func primeBase(_ d: Int) -> Int {
    let primes = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41]
    return primes[d % primes.count]
}

/// Tiny SplitMix64 RNG — deterministic, fast, good enough for DE jitter.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z =  z ^ (z >> 31)
        return z
    }
}
