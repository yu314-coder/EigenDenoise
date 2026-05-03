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
}
