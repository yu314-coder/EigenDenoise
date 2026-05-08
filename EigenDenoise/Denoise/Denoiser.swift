//
//  Denoiser.swift
//  Native Swift port of the core denoising pipeline from /Volumes/D/denoise
//  app.py and the rmt-denoise PyPI lib.
//
//  Methods supported in this build:
//    * .classicalMP        — width = 4√γ
//    * .generalizedMP      — fixed (a, β), width from Yu (2025)
//    * .bestABetaPSNR      — DE oracle search on (log a, β), PSNR objective
//    * .bestABetaSSIM      — DE oracle, SSIM objective
//    * .bestABetaCombined  — DE oracle, 0.5·(PSNR/50) + 0.5·SSIM
//
//  All variants share the same gen-cov acceptance test (smallest k with
//  Σ tail ≥ L_k σ̂²) and the same hard-projection reconstruction
//  x̂ = U_r̂ U_r̂ᵀ x_test.  Centring (X̃ = X − X̄) is always applied for
//  the gen-cov / oracle methods (matches `best_a_beta` in the Python app).
//

import Foundation

public enum DenoiseMethod: String, CaseIterable, Identifiable, Sendable {
    case classicalMP        = "classical_mp"
    case generalizedMP      = "generalized_mp"
    case bestABetaPSNR      = "best_a_beta_psnr"
    case bestABetaSSIM      = "best_a_beta_ssim"
    case bestABetaCombined  = "best_a_beta_combined"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .classicalMP:       return "Classical MP"
        case .generalizedMP:     return "Generalized MP (manual a, β)"
        case .bestABetaPSNR:     return "Best a β (PSNR objective)"
        case .bestABetaSSIM:     return "Best a β (SSIM objective)"
        case .bestABetaCombined: return "Best a β (PSNR + SSIM)"
        }
    }
    public var requiresClean: Bool {
        switch self {
        case .bestABetaPSNR, .bestABetaSSIM, .bestABetaCombined: return true
        default: return false
        }
    }
    public var supportsManualParams: Bool { self == .generalizedMP }
}

public struct DenoiseConfig: Sendable {
    public var method: DenoiseMethod = .bestABetaPSNR
    public var manualA: Double = 0.5
    public var manualBeta: Double = 0.99
    public var applyT: Bool = true
    public var colorResize: Bool = true
    public var aBracket: ClosedRange<Double> = 0.01 ... 1.0
    public var betaBracket: ClosedRange<Double> = 0.01 ... 0.99
    public var dePopSize: Int = 20
    public var deMaxIter: Int = 80
    public var deSeed: UInt64 = 42

    public init() {}
}

public struct DenoiseInfo: Sendable {
    public var method: DenoiseMethod
    public var aHat: Double
    public var betaHat: Double
    public var rankHat: Int
    public var sigma2Hat: Double
    public var psnr: Float
    public var ssim: Float
    public var elapsedSeconds: Double
    public var deEvaluations: Int
}

public struct DenoiseResult: Sendable {
    public var denoisedTest: [Float]                 // H · W
    public var denoisedAll: [Float]                  // (n+1) · H · W
    public var info: DenoiseInfo
}

public enum Denoiser: Sendable {

    /// Run the full pipeline on a (n_train, H, W) noisy training stack plus
    /// a noisy test image. `clean` is required for oracle methods.
    public nonisolated static func denoise(train noisyTrain: [Float],
                                test noisyTest: [Float],
                                clean: [Float]?,
                                H: Int, W: Int,
                                config: DenoiseConfig) throws -> DenoiseResult {
        let p = H * W
        let nTrain = noisyTrain.count / p
        EDLog.log(.denoise, "denoise — H=\(H) W=\(W) p=\(p) nTrain=\(nTrain) train.count=\(noisyTrain.count) test.count=\(noisyTest.count) method=\(config.method.rawValue) clean=\(clean != nil)")
        if noisyTrain.count != nTrain * p {
            EDLog.error(.denoise, "noisyTrain mismatch: count=\(noisyTrain.count) nTrain*p=\(nTrain * p)")
        }
        if noisyTest.count != p {
            EDLog.error(.denoise, "noisyTest mismatch: count=\(noisyTest.count) p=\(p)")
        }
        precondition(noisyTrain.count == nTrain * p)
        precondition(noisyTest.count == p)
        if config.method.requiresClean {
            guard let c = clean, c.count == p else {
                throw DenoiseError.cleanReferenceRequired
            }
        }
        let stack = noisyTrain + noisyTest
        let n = nTrain + 1
        let testIndex = n - 1
        let y = Double(p) / Double(n)

        // Build column-major X (p × n), centred.
        var X = [Double](repeating: 0, count: p * n)
        for j in 0..<n {
            for i in 0..<p {
                X[i * n + j] = Double(stack[j * p + i])
            }
        }
        // Mean across columns.
        var xMean = [Double](repeating: 0, count: p)
        for i in 0..<p {
            var s = 0.0
            for j in 0..<n { s += X[i * n + j] }
            xMean[i] = s / Double(n)
        }
        var Xc = X
        for i in 0..<p {
            let m = xMean[i]
            for j in 0..<n { Xc[i * n + j] -= m }
        }

        // Thin SVD of the centered (p × n) matrix.
        let svd = SVDx.svd(Xc, p: p, n: n)
        let U = svd.U
        let s = svd.s
        let m = svd.k
        // λ_i = σ_i² / n, sorted descending (LAPACK returns descending).
        var lam = [Double](repeating: 0, count: m)
        for i in 0..<m { lam[i] = (s[i] * s[i]) / Double(n) }
        let csum: [Double] = {
            var out = [Double](repeating: 0, count: m)
            var run = 0.0
            for i in 0..<m { run += lam[i]; out[i] = run }
            return out
        }()
        let totLam = csum[m - 1]
        let lamEnd = lam[m - 1]

        // Centred test column.
        var xTestC = [Double](repeating: 0, count: p)
        for i in 0..<p { xTestC[i] = X[i * n + testIndex] - xMean[i] }

        // Acceptance test → (rank, σ̂²) for given (a, β).
        func rankSigma2(a: Double, beta: Double) -> (Int, Double) {
            for k in 0..<m {
                let Lk = m - k
                if Lk < 2 { return (m, 0.0) }
                let gammaK = Double(Lk) / Double(n)
                let edges = RMT.bulkEdges(a: a, beta: beta, y: gammaK)
                let Wk = max(edges.gPlus - edges.gMinus, 1e-15)
                let tailSum = totLam - (k > 0 ? csum[k - 1] : 0)
                let lamK1 = lam[k]
                if lamK1 <= lamEnd { return (m, 0.0) }
                let sig2 = max((lamK1 - lamEnd) / Wk, 1e-30)
                if tailSum >= Double(Lk) * sig2 { return (k, sig2) }
            }
            return (m, 0.0)
        }

        // Per-rank cached projection of the centred test column.
        var projCache = [Int: [Double]]()
        // Eigen-space projection of a centred vector with the diagonal
        // shrinker T(a, β): first ⌊r·β⌋ singular components scaled by √a,
        // remaining components scaled by 1.  When `applyT` is off this is
        // a hard projection (t_j ≡ 1) — we hit the per-rank cache then.
        func projCentered(rank r: Int, a: Double, beta: Double, applyT: Bool,
                          x: [Double]) -> [Double] {
            guard r > 0 && r < m else { return [Double](repeating: 0, count: p) }
            if applyT {
                let kBeta = Int((Double(r) * min(max(beta, 0), 1)).rounded())
                let mul = sqrt(max(a, 0))
                var t = [Double](repeating: 1.0, count: r)
                for i in 0..<min(kBeta, r) { t[i] = mul }
                return SVDx.projectShrink(U: U, p: p, k: m, rank: r, x: x, t: t)
            } else {
                return SVDx.project(U: U, p: p, k: m, rank: r, x: x)
            }
        }
        // Hard-projection cache (only valid when applyT is off).
        func projCenteredCachedHard(rank r: Int) -> [Double] {
            if let cached = projCache[r] { return cached }
            let proj: [Double] = (r <= 0 || r >= m)
                ? [Double](repeating: 0, count: p)
                : SVDx.project(U: U, p: p, k: m, rank: r, x: xTestC)
            projCache[r] = proj
            return proj
        }

        // Convert centred projection → uncentred reconstructed image with
        // optional T(a, β) (eigen-space) and color-resize. The previous
        // pixel-space `applyTDiag` post-step was a bug — it darkened a
        // raster-scan pixel range instead of shrinking eigen-coordinates.
        func reconstruct(rank r: Int, a: Double, beta: Double,
                         applyT: Bool, colorResize: Bool) -> [Float] {
            let proj = applyT
                ? projCentered(rank: r, a: a, beta: beta, applyT: true, x: xTestC)
                : projCenteredCachedHard(rank: r)
            var img = [Float](repeating: 0, count: p)
            for i in 0..<p { img[i] = clamp01(Float(proj[i] + xMean[i])) }
            if colorResize { applyColorResize(&img) }
            return img
        }

        // ---- method-specific (a, β, rank) selection ------------------------

        let t0 = Date()
        var aHat = 1.0, betaHat = 0.0, rankHat = 0
        var sigma2Hat = 0.0, deEvals = 0
        let cleanFloat = clean

        switch config.method {
        case .classicalMP:
            // Width 4√γ regardless of (a, β); β = 0 → fall through to MP edges.
            let (rk, sig) = rankSigma2(a: 1.0, beta: 0.0)
            rankHat = rk == m ? 0 : rk
            sigma2Hat = sig
            aHat = 1.0; betaHat = 0.0
        case .generalizedMP:
            let (rk, sig) = rankSigma2(a: config.manualA, beta: config.manualBeta)
            rankHat = rk == m ? 0 : rk
            sigma2Hat = sig
            aHat = config.manualA; betaHat = config.manualBeta
        case .bestABetaPSNR, .bestABetaSSIM, .bestABetaCombined:
            // DE search over (log a, β).
            let lo = log(config.aBracket.lowerBound)
            let hi = log(config.aBracket.upperBound)
            let bounds = Bounds([lo, config.betaBracket.lowerBound],
                                [hi, config.betaBracket.upperBound])
            let cleanArr = cleanFloat!
            var localCache = [Int: (Float, Float, [Float])]()  // rank → (psnr, ssim, img-without-T)
            // Note: with applyT, scoring depends on (rank, a, β); we only
            // cache by rank when T is OFF. Pragmatic: cache always but
            // recompute T per call (since it depends on a, β).

            let neg: ([Double]) -> Double = { theta in
                deEvals += 1
                let a = exp(min(max(theta[0], lo), hi))
                let beta = min(max(theta[1], config.betaBracket.lowerBound),
                               config.betaBracket.upperBound)
                let (rkRaw, _) = rankSigma2(a: a, beta: beta)
                let rk = rkRaw == m ? 0 : rkRaw
                let img = reconstruct(rank: rk, a: a, beta: beta,
                                      applyT: config.applyT, colorResize: config.colorResize)
                let psnr = Metrics.psnr(clean: cleanArr, denoised: img)
                let score: Float = {
                    switch config.method {
                    case .bestABetaPSNR:
                        return psnr
                    case .bestABetaSSIM:
                        return Metrics.ssim(clean: cleanArr, denoised: img, height: H, width: W)
                    case .bestABetaCombined:
                        let s = Metrics.ssim(clean: cleanArr, denoised: img, height: H, width: W)
                        return 0.5 * (psnr / 50.0) + 0.5 * s
                    default: return psnr
                    }
                }()
                _ = localCache
                return -Double(score)
            }

            let de = DE.minimize(neg, bounds: bounds,
                                 popsize: config.dePopSize,
                                 maxIter: config.deMaxIter,
                                 seed: config.deSeed)
            aHat = exp(min(max(de.x[0], lo), hi))
            betaHat = min(max(de.x[1], config.betaBracket.lowerBound),
                          config.betaBracket.upperBound)
            let (rk, sig) = rankSigma2(a: aHat, beta: betaHat)
            rankHat = rk == m ? 0 : rk
            sigma2Hat = sig
        }

        // ---- final reconstruction (test column + full stack) ----------------

        let denoisedTest = reconstruct(rank: rankHat, a: aHat, beta: betaHat,
                                       applyT: config.applyT, colorResize: config.colorResize)

        // Reconstruct every column at the chosen rank (for "save all" workflows).
        var denoisedAll = [Float](repeating: 0, count: n * p)
        for j in 0..<n {
            var col = [Double](repeating: 0, count: p)
            for i in 0..<p { col[i] = X[i * n + j] - xMean[i] }
            let proj = projCentered(rank: rankHat, a: aHat, beta: betaHat,
                                    applyT: config.applyT, x: col)
            var img = [Float](repeating: 0, count: p)
            for i in 0..<p { img[i] = clamp01(Float(proj[i] + xMean[i])) }
            if config.colorResize { applyColorResize(&img) }
            for i in 0..<p { denoisedAll[j * p + i] = img[i] }
        }

        let psnr: Float = (cleanFloat != nil)
            ? Metrics.psnr(clean: cleanFloat!, denoised: denoisedTest)
            : .nan
        let ssim: Float = (cleanFloat != nil)
            ? Metrics.ssim(clean: cleanFloat!, denoised: denoisedTest, height: H, width: W)
            : .nan

        let info = DenoiseInfo(
            method: config.method,
            aHat: aHat, betaHat: betaHat,
            rankHat: rankHat, sigma2Hat: sigma2Hat,
            psnr: psnr, ssim: ssim,
            elapsedSeconds: Date().timeIntervalSince(t0),
            deEvaluations: deEvals
        )
        return DenoiseResult(denoisedTest: denoisedTest, denoisedAll: denoisedAll, info: info)
    }
}

public enum DenoiseError: LocalizedError {
    case cleanReferenceRequired
    public var errorDescription: String? {
        switch self {
        case .cleanReferenceRequired:
            return "This method needs a clean reference image to evaluate PSNR/SSIM during the (a, β) oracle search."
        }
    }
}


// MARK: - Post-processing helpers

/// y = (x − min(x)) / max(x_before_subtract), clipped to [0, 1].
func applyColorResize(_ img: inout [Float]) {
    guard !img.isEmpty else { return }
    var lo: Float = .greatestFiniteMagnitude
    var hi: Float = -.greatestFiniteMagnitude
    for v in img { lo = min(lo, v); hi = max(hi, v) }
    if hi <= 0 {
        for i in 0..<img.count { img[i] = clamp01(img[i]) }
        return
    }
    for i in 0..<img.count {
        let y = (img[i] - lo) / hi
        img[i] = clamp01(y)
    }
}
