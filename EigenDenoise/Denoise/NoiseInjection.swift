//
//  NoiseInjection.swift
//  Seeded noise injection — Gaussian / Laplacian / two-point structured /
//  mixture-of-Gaussians. Operates on (n, H, W) Float arrays in [0, 1].
//

import Foundation

public enum NoiseKind: String, CaseIterable, Identifiable, Sendable {
    case gaussian
    case mog                       // mixture of Gaussians
    case twoPoint     = "twopoint" // H = β·δ_1 + (1-β)·δ_a
    case halfGaussian = "half_gaussian"
    case blockHalf    = "block_half"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .gaussian:     return "Gaussian"
        case .mog:          return "Mixture of Gaussians"
        case .twoPoint:     return "Two-Point H"
        case .halfGaussian: return "Half Gaussian"
        case .blockHalf:    return "Block Half"
        }
    }
}

/// All values are stored in the **0–255 scale** (matching the original
/// /Volumes/D/denoise/app.py UI). The bridge divides by 255 just before
/// serialising the JSON job sent to the Python helper.
public struct NoiseConfig: Sendable {
    public var enabled: Bool = false
    public var kind: NoiseKind = .gaussian

    // Gaussian
    public var sigma: Double = 25
    public var mu:    Double = 0

    // Mixture of Gaussians (G1: σ, μ, w1 ; G2: σ, μ ; w2 = 1 - w1)
    public var mogSigma1: Double = 10
    public var mogMu1:    Double = 0
    public var mogW1:     Double = 0.5
    public var mogSigma2: Double = 50
    public var mogMu2:    Double = 0

    // Two-Point H = β·δ_1 + (1-β)·δ_a
    public var tpSigma: Double = 25
    public var tpA:     Double = 3.0
    public var tpBeta:  Double = 0.5

    // Half Gaussian (50 % of matrix entries)
    public var hgSigma: Double = 25
    public var hgMu:    Double = 0

    // Block Half (top-left block)
    public var bhSigma: Double = 25
    public var bhMu:    Double = 0

    public init() {}
}


public enum NoiseInjector: Sendable {

    /// Add noise jointly to a stack of (n, H, W) images. Output is clipped
    /// to [0, 1]. Uses a deterministic PRNG seeded on `seed` so reruns are
    /// reproducible.
    /// Native injector — supports all 5 kinds (Gaussian / MoG / Two-Point /
    /// Half-Gaussian / Block-Half) at parity with the Python helper.
    /// `config.sigma`, `mu`, `mogSigma*`, `mogMu*`, `tpSigma`, `hgSigma`,
    /// `hgMu`, `bhSigma`, `bhMu` are in the **0–255 UI scale** — divided by
    /// 255 before being applied to images that live in [0, 1].
    public nonisolated static func add(_ images: [Float],
                            n: Int, H: Int, W: Int,
                            config: NoiseConfig,
                            seed: UInt64 = 42) -> [Float] {
        let total = n * H * W
        precondition(images.count == total)
        var rng = NormalRNG(seed: seed)
        let s = { (v: Double) -> Float in Float(v / 255.0) }
        var out = images

        switch config.kind {
        case .gaussian:
            let sigma = s(config.sigma)
            let mu    = s(config.mu)
            for i in 0..<total {
                out[i] = clamp01(out[i] + Float(rng.next()) * sigma + mu)
            }
        case .mog:
            let s1 = s(config.mogSigma1), m1 = s(config.mogMu1)
            let s2 = s(config.mogSigma2), m2 = s(config.mogMu2)
            let w1 = config.mogW1
            for i in 0..<total {
                let pickA = rng.uniform() < w1
                let mu = pickA ? m1 : m2
                let sg = pickA ? s1 : s2
                out[i] = clamp01(out[i] + Float(rng.next()) * sg + mu)
            }
        case .twoPoint:
            // Per-pixel-position σ²: fraction β get σ², the rest get σ²·a.
            let p = H * W
            let sigma = s(config.tpSigma)
            let a     = Float(config.tpA)
            let beta  = config.tpBeta
            var perPixelStd = [Float](repeating: 0, count: p)
            for i in 0..<p {
                perPixelStd[i] = (rng.uniform() < beta) ? sigma : sigma * sqrt(a)
            }
            for img in 0..<n {
                let base = img * p
                for i in 0..<p {
                    out[base + i] = clamp01(out[base + i] + Float(rng.next()) * perPixelStd[i])
                }
            }
        case .halfGaussian:
            // Random 50 % of (p × n) matrix entries get N(μ, σ²); rest stays.
            let p = H * W
            let sigma = s(config.hgSigma)
            let mu    = s(config.hgMu)
            let totalEntries = p * n
            var mask = [Bool](repeating: false, count: totalEntries)
            for i in 0..<(totalEntries / 2) { mask[i] = true }
            // Fisher-Yates shuffle.
            for i in stride(from: totalEntries - 1, through: 1, by: -1) {
                let j = Int(rng.nextU64() % UInt64(i + 1))
                mask.swapAt(i, j)
            }
            // Convert from (p × n) flat indexing to (n images, H × W per image)
            // = mask[i_pixel * n + j_image]  →  out[j*p + i] = images[j*p+i] + maskedNoise.
            for j in 0..<n {
                for i in 0..<p {
                    let mIdx = i * n + j
                    if mask[mIdx] {
                        out[j * p + i] = clamp01(out[j * p + i] + Float(rng.next()) * sigma + mu)
                    }
                }
            }
        case .blockHalf:
            // Top-left X[0:p/2, 0:n/2] block (vectorised data matrix) gets noise.
            let p = H * W
            let sigma = s(config.bhSigma)
            let mu    = s(config.bhMu)
            let halfP = p / 2
            let halfN = max(n / 2, 1)
            for j in 0..<halfN {
                for i in 0..<halfP {
                    out[j * p + i] = clamp01(out[j * p + i] + Float(rng.next()) * sigma + mu)
                }
            }
        }
        return out
    }
}


// MARK: - Box-Muller normal RNG

nonisolated struct NormalRNG {
    var state: UInt64
    var hasSpare = false
    var spare: Double = 0.0

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func nextU64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        // [0, 1)
        return Double(nextU64() >> 11) * (1.0 / Double(1 << 53))
    }

    /// Standard normal sample.
    mutating func next() -> Double {
        if hasSpare { hasSpare = false; return spare }
        var u1: Double, u2: Double, s: Double
        repeat {
            u1 = uniform() * 2 - 1
            u2 = uniform() * 2 - 1
            s = u1 * u1 + u2 * u2
        } while s == 0 || s >= 1
        let mul = sqrt(-2.0 * log(s) / s)
        spare = u2 * mul
        hasSpare = true
        return u1 * mul
    }
}

@inlinable nonisolated
func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
