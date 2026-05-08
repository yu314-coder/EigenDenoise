//
//  SVDx.swift
//  Thin SVD via Accelerate's LAPACK (dgesdd). Returns U (p×k), s (k),
//  Vt (k×n) such that  A_{p×n}  ≈ U · diag(s) · Vt.
//
//  Used by the denoising pipeline. Matches numpy.linalg.svd(full_matrices=False).
//

import Accelerate
import Foundation

public enum SVDx {

    public struct Result {
        public let U: [Double]   // p × k, column-major
        public let s: [Double]   // k
        public let Vt: [Double]  // k × n, row-major (== Vᵀ)
        public let p: Int
        public let n: Int
        public let k: Int
    }

    /// Thin SVD of a `p × n` real matrix, supplied row-major in `A`.
    /// Returns U (column-major), s, Vt (row-major).
    public static func svd(_ A: [Double], p: Int, n: Int) -> Result {
        EDLog.log(.svd, "svd entry — p=\(p) n=\(n) A.count=\(A.count)")
        if A.count != p * n {
            EDLog.error(.svd, "matrix size mismatch — A.count=\(A.count) expected p*n=\(p * n)")
        }
        precondition(A.count == p * n, "matrix size mismatch")
        // LAPACK uses column-major. Transpose row-major → column-major.
        var Acol = [Double](repeating: 0.0, count: p * n)
        for i in 0..<p {
            for j in 0..<n {
                Acol[j * p + i] = A[i * n + j]
            }
        }
        var jobz: Int8 = 0x53                 // 'S' — thin SVD
        var m = __CLPK_integer(p)
        var nl = __CLPK_integer(n)
        var lda = __CLPK_integer(p)
        let k = Swift.min(p, n)
        var s = [Double](repeating: 0.0, count: k)
        var u = [Double](repeating: 0.0, count: p * k)
        var ldu = __CLPK_integer(p)
        var vt = [Double](repeating: 0.0, count: k * n)
        var ldvt = __CLPK_integer(k)
        var info: __CLPK_integer = 0
        var iwork = [__CLPK_integer](repeating: 0, count: 8 * k)
        // Workspace query
        var lwork: __CLPK_integer = -1
        var workQuery: Double = 0
        Acol.withUnsafeMutableBufferPointer { ap in
        s.withUnsafeMutableBufferPointer { sp in
        u.withUnsafeMutableBufferPointer { up in
        vt.withUnsafeMutableBufferPointer { vtp in
        iwork.withUnsafeMutableBufferPointer { iwp in
            _ = dgesdd_(&jobz, &m, &nl, ap.baseAddress, &lda,
                         sp.baseAddress,
                         up.baseAddress, &ldu,
                         vtp.baseAddress, &ldvt,
                         &workQuery, &lwork,
                         iwp.baseAddress, &info)
        }}}}}
        lwork = __CLPK_integer(workQuery)
        var work = [Double](repeating: 0.0, count: Int(lwork))
        // Real call
        Acol.withUnsafeMutableBufferPointer { ap in
        s.withUnsafeMutableBufferPointer { sp in
        u.withUnsafeMutableBufferPointer { up in
        vt.withUnsafeMutableBufferPointer { vtp in
        iwork.withUnsafeMutableBufferPointer { iwp in
        work.withUnsafeMutableBufferPointer { wp in
            _ = dgesdd_(&jobz, &m, &nl, ap.baseAddress, &lda,
                         sp.baseAddress,
                         up.baseAddress, &ldu,
                         vtp.baseAddress, &ldvt,
                         wp.baseAddress, &lwork,
                         iwp.baseAddress, &info)
        }}}}}}
        // U is column-major (p × k); Vt is column-major (k × n) — transpose Vt to row-major.
        var VtRow = [Double](repeating: 0.0, count: k * n)
        for i in 0..<k {
            for j in 0..<n {
                VtRow[i * n + j] = vt[j * k + i]
            }
        }
        return Result(U: u, s: s, Vt: VtRow, p: p, n: n, k: k)
    }

    /// Thin SVD via the n×n Gram trick on the GPU. Requires p ≥ n. The two
    /// O(p·n²) and O(p²·n) matmuls (XᵀX and X·V) are dispatched through MPS;
    /// the small n×n eigendecomposition stays on CPU. Returns nil and the
    /// caller must fall back to `svd(_, p, n)` if MPS is unavailable or any
    /// kernel fails. Output matches `svd`: U column-major (p × n), s length n
    /// descending, Vt row-major (n × n).
    public nonisolated static func svdGramGPU(_ A: [Double], p: Int, n: Int) -> Result? {
        precondition(A.count == p * n)
        guard p >= n else { return nil }
        guard let gram = MetalCompute.shared.gramSmall(A, p: p, n: n) else { return nil }
        // Eigendecompose XᵀX (n×n): ascending eigenvalues μ, columns of V_asc
        // are right singular vectors (column-major n×n).
        let (mu, V_asc) = SymEigen.eigh(gram.S, n: n)
        // Reverse to descending; build V_desc row-major n×n for the GPU matmul
        // X · V_desc (which produces left singular vectors scaled by σ).
        var V_desc_rm = [Double](repeating: 0, count: n * n)
        var sigma = [Double](repeating: 0, count: n)
        for jd in 0..<n {
            let ja = n - 1 - jd
            sigma[jd] = sqrt(max(mu[ja], 0))
            for i in 0..<n {
                V_desc_rm[i * n + jd] = V_asc[i + ja * n]
            }
        }
        guard let XV = MetalCompute.shared.matmul(A, aRows: p, aCols: n,
                                                    V_desc_rm, bRows: n, bCols: n)
        else { return nil }
        // U column-major (p × n): U[:,j] = XV[:,j] / σ_j.
        var U = [Double](repeating: 0, count: p * n)
        for j in 0..<n {
            let sj = sigma[j]
            let inv = sj > 1e-12 ? 1.0 / sj : 0.0
            for i in 0..<p {
                U[i + j * p] = XV[i * n + j] * inv
            }
        }
        // Vt row-major (n × n): Vt[i,j] = V_desc[j,i] = V_desc_rm[j*n + i].
        var Vt = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                Vt[i * n + j] = V_desc_rm[j * n + i]
            }
        }
        EDLog.log(.svd, "svd via MPS gram path — p=\(p) n=\(n)")
        return Result(U: U, s: sigma, Vt: Vt, p: p, n: n, k: n)
    }

    /// Project a vector x ∈ ℝ^p onto the rank-r subspace spanned by U[:, :r]:
    ///     y  =  U_r · (U_rᵀ · x)
    public static func project(U: [Double], p: Int, k: Int, rank r: Int, x: [Double]) -> [Double] {
        precondition(x.count == p)
        guard r > 0 else { return [Double](repeating: 0.0, count: p) }
        let r = Swift.min(r, k)
        // c = U_rᵀ x   (length r). U is column-major (p × k).
        var c = [Double](repeating: 0.0, count: r)
        for j in 0..<r {
            var sum = 0.0
            let base = j * p
            for i in 0..<p { sum += U[base + i] * x[i] }
            c[j] = sum
        }
        // y = U_r c  (length p).
        var y = [Double](repeating: 0.0, count: p)
        for j in 0..<r {
            let cj = c[j]
            let base = j * p
            for i in 0..<p { y[i] += U[base + i] * cj }
        }
        return y
    }

    /// Project a vector x ∈ ℝ^p onto the rank-r subspace spanned by U[:, :r],
    /// applying a per-component shrinker t_j in eigen-coordinates:
    ///     y = U_r · diag(t) · U_rᵀ · x
    /// `t` must have length ≥ r.
    public static func projectShrink(U: [Double], p: Int, k: Int,
                                       rank r: Int, x: [Double],
                                       t: [Double]) -> [Double] {
        precondition(x.count == p)
        precondition(t.count >= Swift.min(r, k))
        guard r > 0 else { return [Double](repeating: 0.0, count: p) }
        let r = Swift.min(r, k)
        var c = [Double](repeating: 0.0, count: r)
        for j in 0..<r {
            var sum = 0.0
            let base = j * p
            for i in 0..<p { sum += U[base + i] * x[i] }
            c[j] = sum * t[j]
        }
        var y = [Double](repeating: 0.0, count: p)
        for j in 0..<r {
            let cj = c[j]
            let base = j * p
            for i in 0..<p { y[i] += U[base + i] * cj }
        }
        return y
    }
}
