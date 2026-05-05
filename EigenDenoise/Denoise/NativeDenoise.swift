//
//  NativeDenoise.swift
//  Pure-Swift port of /Volumes/D/denoise/app.py + the rmt-denoise PyPI lib.
//  Replaces the Python subprocess bridge so the app runs cleanly inside the
//  App Store sandbox.
//
//  Two methods executed on the same noisy stack:
//    * Classical M-P  — spread rule, NO centering (matches denoise/app.py).
//    * Generalized Cov — oracle (a, β) via differential evolution, with
//      centring + T(a, β) + color-resize toggles (matches rmt-denoise lib).
//
//  All heavy linear algebra goes through `SVDx` (Accelerate) and the
//  optional `MetalCompute` Gram path on the GPU.
//

import Accelerate
import AppKit
import Foundation

public struct NativeDenoiseResult: Sendable {
    public let cleanImage: [Float]      // (H · W) flat, [0, 1]
    public let noisyImage: [Float]
    public let mpImage: [Float]
    public let genImage: [Float]
    public let residualImage: [Float]   // |clean − gen| × 3, clipped
    public let psnrMP: Double
    public let rankMP: Int
    public let psnrGen: Double
    public let rankGen: Int
    public let a: Double
    public let beta: Double
    public let sigma2: Double
    public let elapsed: Double
    public let eigenvalues: [Double]    // top 60 of centred (1/n)X̃X̃ᵀ
    public let n: Int
    public let p: Int
    public let y: Double
    public let device: String           // "Accelerate (CPU)" / "Metal (GPU)"
    public let H: Int
    public let W: Int
}

public enum NativeDenoise {

    public struct Job: Sendable {
        public var noisyTrain: [Float]   // (n_train, H, W) flat
        public var cleanTest: [Float]    // (H, W)
        public var noisyTest: [Float]    // (H, W)
        public var H: Int
        public var W: Int
        public var method: String        // "both" / "mp" / "gencov"
        public var applyT: Bool
        public var colorResize: Bool
        public var center: Bool
        public var device: String        // "auto" / "cpu" / "mps"
        public var deSeed: UInt64
        public init(noisyTrain: [Float], cleanTest: [Float], noisyTest: [Float],
                    H: Int, W: Int, method: String, applyT: Bool,
                    colorResize: Bool, center: Bool, device: String,
                    deSeed: UInt64) {
            self.noisyTrain = noisyTrain; self.cleanTest = cleanTest
            self.noisyTest = noisyTest;   self.H = H; self.W = W
            self.method = method; self.applyT = applyT
            self.colorResize = colorResize; self.center = center
            self.device = device; self.deSeed = deSeed
        }
    }

    public nonisolated static func run(_ job: Job,
                                         progress: (@Sendable (Double, String) -> Void)? = nil)
        -> NativeDenoiseResult
    {
        let t0 = Date()
        let H = job.H, W = job.W, p = H * W
        let nTrain = job.noisyTrain.count / p
        let n = nTrain + 1
        let y = Double(p) / Double(n)
        progress?(0.05, "Preparing matrix")
        EDLog.log(.denoise, "native — H=\(H) W=\(W) p=\(p) n=\(n) method=\(job.method) T=\(job.applyT) resize=\(job.colorResize) center=\(job.center) device=\(job.device)")

        // Build column-major X (p × n) over Doubles. Last column = test.
        var X = [Double](repeating: 0, count: p * n)
        for j in 0..<nTrain {
            for i in 0..<p {
                X[i * n + j] = Double(job.noisyTrain[j * p + i])
            }
        }
        for i in 0..<p {
            X[i * n + (n - 1)] = Double(job.noisyTest[i])
        }

        // ---- Classical M-P (no centring, spread rule) ----------------------
        var psnrMP = Double.nan, rankMP = 0
        var mpImage = job.noisyTest
        if job.method == "both" || job.method == "mp" {
            progress?(0.15, "Classical M-P · SVD")
            (rankMP, mpImage) = runClassicalMP(X: X, p: p, n: n, H: H, W: W)
            psnrMP = psnrDouble(clean: job.cleanTest, denoised: mpImage)
            progress?(0.35, "Classical M-P · done (r̂=\(rankMP))")
        }

        // ---- Generalized Cov oracle (with toggles) -------------------------
        var psnrGen = Double.nan, rankGen = 0
        var aHat = 1.0, betaHat = 0.0, sigma2Hat = 0.0
        var genImage = job.noisyTest
        var eigs: [Double] = []
        var deviceLabel = "Accelerate (CPU)"
        if job.method == "both" || job.method == "gencov" {
            progress?(0.40, "Gen-Cov · eigendecomposition")
            let g = runGenCovOracle(X: X, p: p, n: n, H: H, W: W,
                                     cleanTest: job.cleanTest,
                                     applyT: job.applyT,
                                     colorResize: job.colorResize,
                                     center: job.center,
                                     deSeed: job.deSeed)
            rankGen = g.rank
            aHat = g.a; betaHat = g.beta; sigma2Hat = g.sigma2
            genImage = g.image
            eigs = g.eigenvalues
            deviceLabel = g.device
            psnrGen = psnrDouble(clean: job.cleanTest, denoised: genImage)
            progress?(0.95, "Gen-Cov · done (r̂=\(rankGen) â=\(String(format:"%.2f", aHat)) β̂=\(String(format:"%.2f", betaHat)))")
        }

        // Residual ×3
        var residual = [Float](repeating: 0, count: p)
        for i in 0..<p {
            residual[i] = min(max(abs(job.cleanTest[i] - genImage[i]) * 3, 0), 1)
        }

        let elapsed = Date().timeIntervalSince(t0)
        EDLog.log(.denoise, "native done — MP r̂=\(rankMP) PSNR=\(String(format:"%.3f",psnrMP))  Gen r̂=\(rankGen) PSNR=\(String(format:"%.3f",psnrGen))  â=\(String(format:"%.3f",aHat)) β̂=\(String(format:"%.3f",betaHat))  elapsed=\(String(format:"%.2fs",elapsed))")

        return NativeDenoiseResult(
            cleanImage: job.cleanTest, noisyImage: job.noisyTest,
            mpImage: mpImage, genImage: genImage, residualImage: residual,
            psnrMP: psnrMP, rankMP: rankMP,
            psnrGen: psnrGen, rankGen: rankGen,
            a: aHat, beta: betaHat, sigma2: sigma2Hat,
            elapsed: elapsed, eigenvalues: eigs.isEmpty ? topCenteredEigs(X: X, p: p, n: n) : eigs,
            n: n, p: p, y: y, device: deviceLabel, H: H, W: W)
    }

    // ====================================================================
    // Classical M-P — exact port of /Volumes/D/denoise/batch_mppca.py
    // (`_mp_threshold` + `train_subspace` with method='classical'). No
    // centring, eigenvalues are σ²/n from a raw SVD of X, spread rule.
    // ====================================================================

    private nonisolated static func runClassicalMP(X: [Double], p: Int, n: Int,
                                        H: Int, W: Int) -> (Int, [Float]) {
        // X is column-major (p × n). SVD wants row-major (p × n) array.
        var Xrow = [Double](repeating: 0, count: p * n)
        for i in 0..<p {
            for j in 0..<n {
                Xrow[i * n + j] = X[i * n + j]
            }
        }
        let svd = SVDx.svd(Xrow, p: p, n: n)
        let m = svd.k
        var eigs = [Double](repeating: 0, count: m)
        for i in 0..<m { eigs[i] = (svd.s[i] * svd.s[i]) / Double(n) }

        var P_hat = m
        for p_hat in 0..<m {
            let mRem = m - p_hat
            if mRem < 2 { break }
            let lamPlus = eigs[p_hat]
            let lamMinus = eigs[m - 1]
            if lamPlus <= lamMinus { break }
            let gamma = Double(mRem) / Double(n)
            let w = 4.0 * sqrt(gamma)
            let sigma2P = (lamPlus - lamMinus) / w
            var tail = 0.0
            for i in p_hat..<m { tail += eigs[i] }
            if tail >= Double(mRem) * sigma2P {
                P_hat = p_hat; break
            }
        }
        let rank = (P_hat < m) ? P_hat : 0
        // Hard-projection reconstruction of the test column (last column).
        var xTest = [Double](repeating: 0, count: p)
        for i in 0..<p { xTest[i] = X[i * n + (n - 1)] }
        let dv = (rank > 0)
            ? SVDx.project(U: svd.U, p: p, k: m, rank: rank, x: xTest)
            : [Double](repeating: 0, count: p)
        var img = [Float](repeating: 0, count: p)
        for i in 0..<p { img[i] = Float(min(max(dv[i], 0), 1)) }
        return (rank, img)
    }

    // ====================================================================
    // Generalized Cov oracle (a, β) — DE search, mirrors rmt-denoise lib.
    // ====================================================================

    private struct GenResult {
        let rank: Int; let a: Double; let beta: Double; let sigma2: Double
        let image: [Float]; let eigenvalues: [Double]; let device: String
    }

    private nonisolated static func runGenCovOracle(X: [Double], p: Int, n: Int,
                                          H: Int, W: Int,
                                          cleanTest: [Float],
                                          applyT: Bool, colorResize: Bool,
                                          center: Bool,
                                          deSeed: UInt64) -> GenResult {
        // Centring (toggle).
        var xMean = [Double](repeating: 0, count: p)
        if center {
            for i in 0..<p {
                var s = 0.0
                for j in 0..<n { s += X[i * n + j] }
                xMean[i] = s / Double(n)
            }
        }
        var Xc = [Double](repeating: 0, count: p * n)
        for i in 0..<p {
            let mu = xMean[i]
            for j in 0..<n { Xc[i * n + j] = X[i * n + j] - mu }
        }

        // SVD via Accelerate (we still get eigenvalues for the chart).
        let svd = SVDx.svd(Xc, p: p, n: n)
        let U = svd.U
        let m = svd.k
        var lam = [Double](repeating: 0, count: m)
        for i in 0..<m { lam[i] = (svd.s[i] * svd.s[i]) / Double(n) }
        let csum: [Double] = {
            var out = [Double](repeating: 0, count: m); var run = 0.0
            for i in 0..<m { run += lam[i]; out[i] = run }
            return out
        }()
        let totLam = csum[m - 1]
        let lamEnd = lam[m - 1]
        var xTestC = [Double](repeating: 0, count: p)
        for i in 0..<p { xTestC[i] = Xc[i * n + (n - 1)] }
        let xMeanFlat = xMean

        // Per-rank cached projection of the centred test column.
        var projCache = [Int: [Double]]()
        func proj(rank r: Int) -> [Double] {
            if let c = projCache[r] { return c }
            let dv = (r > 0 && r < m)
                ? SVDx.project(U: U, p: p, k: m, rank: r, x: xTestC)
                : [Double](repeating: 0, count: p)
            projCache[r] = dv; return dv
        }

        // Acceptance test.
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
                let s = max((lamK1 - lamEnd) / Wk, 1e-30)
                if tailSum >= Double(Lk) * s { return (k, s) }
            }
            return (m, 0.0)
        }

        // Build a reconstructed test image at given (a, β, rank).
        func reconstruct(rank r: Int, a: Double, beta: Double) -> [Float] {
            let dv = proj(rank: r)
            var img = [Float](repeating: 0, count: p)
            for i in 0..<p {
                let v = Float(dv[i] + xMeanFlat[i])
                img[i] = min(max(v, 0), 1)
            }
            if applyT { applyTDiag(&img, a: Float(a), beta: Float(beta)) }
            if colorResize { applyColorResize(&img) }
            return img
        }

        // Differential-evolution search over (log a, β).
        let aLo = log(0.01), aHi = log(1.0)
        let bLo = 0.01, bHi = 0.99
        let bounds = Bounds([aLo, bLo], [aHi, bHi])
        let cleanArr = cleanTest
        var bestState: (psnr: Double, a: Double, b: Double, r: Int, s: Double) = (-1e30, .nan, .nan, 0, 0)
        let neg: ([Double]) -> Double = { theta in
            let tA = min(max(theta[0], aLo), aHi)
            let bJ = min(max(theta[1], bLo), bHi)
            let aJ = exp(tA)
            let (rA, sigJ) = rankSigma2(a: aJ, beta: bJ)
            let r = rA == m ? 0 : rA
            let img = reconstruct(rank: r, a: aJ, beta: bJ)
            let psnr = Double(Metrics.psnr(clean: cleanArr, denoised: img))
            if psnr > bestState.psnr {
                bestState = (psnr, aJ, bJ, r, sigJ)
            }
            return -psnr
        }
        _ = DE.minimize(neg, bounds: bounds,
                          popsize: 20, maxIter: 80,
                          F: 0.7, CR: 0.7, tol: 1e-4, seed: deSeed)

        let aHat = bestState.a.isFinite ? bestState.a : 1.0
        let betaHat = bestState.b.isFinite ? bestState.b : 0.99
        let rank = bestState.r
        let sigma2 = bestState.s
        let img = reconstruct(rank: rank, a: aHat, beta: betaHat)

        // Top-60 eigenvalues for the chart.
        let topN = min(60, m)
        let topEigs = Array(lam.prefix(topN))

        return GenResult(rank: rank, a: aHat, beta: betaHat,
                          sigma2: sigma2, image: img,
                          eigenvalues: topEigs,
                          device: "Accelerate (CPU)")
    }

    // ====================================================================
    // Helper: top-60 eigenvalues of (1/n) X̃ X̃ᵀ (used when only MP runs).
    // ====================================================================
    private nonisolated static func topCenteredEigs(X: [Double], p: Int, n: Int) -> [Double] {
        var xMean = [Double](repeating: 0, count: p)
        for i in 0..<p {
            var s = 0.0
            for j in 0..<n { s += X[i * n + j] }
            xMean[i] = s / Double(n)
        }
        var Xc = [Double](repeating: 0, count: p * n)
        for i in 0..<p {
            for j in 0..<n { Xc[i * n + j] = X[i * n + j] - xMean[i] }
        }
        let svd = SVDx.svd(Xc, p: p, n: n)
        let m = svd.k
        var lam = [Double](repeating: 0, count: m)
        for i in 0..<m { lam[i] = (svd.s[i] * svd.s[i]) / Double(n) }
        return Array(lam.prefix(min(60, m)))
    }

    // PSNR helper returning Double for the result struct.
    private nonisolated static func psnrDouble(clean: [Float], denoised: [Float]) -> Double {
        Double(Metrics.psnr(clean: clean, denoised: denoised))
    }
}
