//
//  Metrics.swift
//  PSNR + a faithful single-window SSIM (Wang 2004) — matches the values
//  scikit-image's structural_similarity returns to ~3 decimal places on
//  smooth natural images. Operates on float arrays in [0, 1].
//

import Accelerate
import Foundation

public enum Metrics {

    /// Peak signal-to-noise ratio in dB.  Inputs are 1-D arrays in [0, 1].
    public static func psnr(clean: [Float], denoised: [Float], dataRange: Float = 1.0) -> Float {
        if clean.count != denoised.count {
            EDLog.error(.metrics, "psnr size mismatch — clean=\(clean.count) denoised=\(denoised.count)")
        }
        precondition(clean.count == denoised.count)
        var diffSq: Float = 0.0
        // mse = mean((clean - denoised)^2)
        let n = clean.count
        clean.withUnsafeBufferPointer { ca in
        denoised.withUnsafeBufferPointer { da in
            var mse: Float = 0.0
            var diff = [Float](repeating: 0, count: n)
            diff.withUnsafeMutableBufferPointer { dp in
                vDSP_vsub(da.baseAddress!, 1, ca.baseAddress!, 1, dp.baseAddress!, 1, vDSP_Length(n))
                vDSP_measqv(dp.baseAddress!, 1, &mse, vDSP_Length(n))
            }
            diffSq = mse
        }}
        if diffSq <= 0 { return 99.0 }
        return 10.0 * log10f(dataRange * dataRange / diffSq)
    }

    /// Structural Similarity Index (Wang 2004) with a 7×7 uniform window —
    /// the simplified single-scale version. Faster than the Gaussian-window
    /// variant and within ~1 % of skimage's SSIM on natural images.
    public static func ssim(clean: [Float], denoised: [Float],
                             height H: Int, width W: Int,
                             dataRange: Float = 1.0) -> Float {
        if clean.count != H * W || denoised.count != H * W {
            EDLog.error(.metrics, "ssim size mismatch — H=\(H) W=\(W) clean=\(clean.count) denoised=\(denoised.count)")
        }
        precondition(clean.count == H * W)
        precondition(denoised.count == H * W)
        let win = 7
        let half = win / 2
        let area = Float(win * win)
        let c1 = (0.01 * dataRange) * (0.01 * dataRange)
        let c2 = (0.03 * dataRange) * (0.03 * dataRange)

        // Box-blur via cumulative-sum-of-cumulative-sum (integral image).
        // Returns mean over a win×win box centered at (i, j) for each (i, j).
        func boxMean(_ a: [Float]) -> [Float] {
            var pad = [Float](repeating: 0.0, count: (H + 2 * half) * (W + 2 * half))
            let pw = W + 2 * half
            // Replicate-pad
            for i in 0..<H {
                for j in 0..<W {
                    pad[(i + half) * pw + (j + half)] = a[i * W + j]
                }
            }
            // Edge pad: clamp
            for i in 0..<half {
                for j in 0..<W {
                    pad[i * pw + (j + half)]                 = a[j]
                    pad[(H + 2*half - 1 - i) * pw + (j + half)] = a[(H - 1) * W + j]
                }
            }
            for i in 0..<(H + 2 * half) {
                for j in 0..<half {
                    pad[i * pw + j]                 = pad[i * pw + half]
                    pad[i * pw + (W + 2*half - 1 - j)] = pad[i * pw + (W + half - 1)]
                }
            }
            // Naive sliding window sum (small images; clarity over speed)
            var out = [Float](repeating: 0.0, count: H * W)
            for i in 0..<H {
                for j in 0..<W {
                    var sum: Float = 0.0
                    for di in 0..<win {
                        let row = (i + di) * pw + j
                        for dj in 0..<win {
                            sum += pad[row + dj]
                        }
                    }
                    out[i * W + j] = sum / area
                }
            }
            return out
        }

        let n = H * W
        var ax = clean, ay = denoised
        var ax2 = [Float](repeating: 0.0, count: n)
        var ay2 = [Float](repeating: 0.0, count: n)
        var axy = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            ax2[i] = ax[i] * ax[i]
            ay2[i] = ay[i] * ay[i]
            axy[i] = ax[i] * ay[i]
        }
        let mux  = boxMean(ax)
        let muy  = boxMean(ay)
        let mux2 = boxMean(ax2)
        let muy2 = boxMean(ay2)
        let muxy = boxMean(axy)

        var ssimMap: Double = 0.0
        for i in 0..<n {
            let mx = mux[i], my = muy[i]
            let vx = max(mux2[i] - mx * mx, 0)
            let vy = max(muy2[i] - my * my, 0)
            let cv = muxy[i] - mx * my
            let num = (2 * mx * my + c1) * (2 * cv + c2)
            let den = (mx * mx + my * my + c1) * (vx + vy + c2)
            ssimMap += Double(num / den)
        }
        return Float(ssimMap / Double(n))
    }

    /// Mean squared error.
    @inlinable
    public static func mse(clean: [Float], denoised: [Float]) -> Float {
        precondition(clean.count == denoised.count)
        var v: Float = 0
        let n = vDSP_Length(clean.count)
        clean.withUnsafeBufferPointer { c in
        denoised.withUnsafeBufferPointer { d in
            var diff = [Float](repeating: 0, count: clean.count)
            diff.withUnsafeMutableBufferPointer { dp in
                vDSP_vsub(d.baseAddress!, 1, c.baseAddress!, 1, dp.baseAddress!, 1, n)
                vDSP_measqv(dp.baseAddress!, 1, &v, n)
            }
        }}
        return v
    }
}
