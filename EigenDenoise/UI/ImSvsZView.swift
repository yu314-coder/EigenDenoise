//
//  ImSvsZView.swift
//  Im(s) vs z — solves the Stieltjes cubic
//      (z·a)·s³ + [z·(a+1) + a·(1−y)]·s² + [z + (a+1) − y − y·β·(a−1)]·s + 1 = 0
//  on a logarithmic z grid (β, y, a fixed) and plots the imaginary parts of
//  its three roots. Mirrors random_matrix_ESD/app.py's "Im(s) vs z" tab.
//

import Charts
import SwiftUI

struct ImSvsZView: View {
    @State private var beta: Double = 0.5
    @State private var y: Double = 1.0
    @State private var a: Double = 2.0
    @State private var zmin: Double = 0.01
    @State private var zmax: Double = 10.0
    @State private var nPoints: Int = 400

    @State private var samples: [SampledRoots] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EmptyView().onAppear {
                EDLog.log(.ui, "ImSvsZView appear — samples=\(samples.count)")
            }
            SectionHeading(title: "Im(s) vs z",
                            systemImage: "function",
                            subtitle: "Stieltjes-cubic root tracking on a logarithmic z grid")

            ControlPlotLayout(
                controls: { controlsCard },
                plots: { plotCard }
            )
        }
    }

    // ---------------------------------------------------------- controls

    private var controlsCard: some View {
        Card(title: "Parameters", systemImage: "slider.horizontal.3") {
            InlineField(label: "Beta (β)", value: $beta)
            InlineField(label: "Y ratio",  value: $y)
            InlineField(label: "Spike (a)", value: $a)
            Divider()
            Text("Z range").font(.caption.bold()).foregroundStyle(Palette.muted)
            InlineField(label: "Minimum", value: $zmin)
            InlineField(label: "Maximum", value: $zmax)
            Divider()
            InlineField(label: "Grid points", value: $nPoints)
            Button {
                samples = compute()
            } label: {
                Label("Compute Im(s) vs z", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Solves cubic on logarithmic z grid; plots Im(s) for each of the three roots.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    // ---------------------------------------------------------- plots

    private var plotCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Cubic equation", systemImage: "function") {
                EquationPanel(title: "Cubic polynomial & Stieltjes transform") {
                    Text("(z·a)·s³ + [z·(a+1) + a·(1−y)]·s² + [z + (a+1) − y − y·β·(a−1)]·s + 1 = 0")
                    Text("s(z) = ∫ 1/(λ − z) dμ(λ)")
                    Text("Im(s) ↔ density of eigenvalues  ·  Re(s) ↔ principal value")
                    Text("Complex roots ⇒ overlapping support  ·  real roots ⇒ separated bands")
                }
            }
            Card(title: "Imaginary parts vs z",
                  systemImage: "chart.line.uptrend.xyaxis") {
                if samples.isEmpty {
                    placeholder("Click Compute to generate plot")
                } else {
                    chartIm
                }
            }
            Card(title: "Real parts vs z",
                  systemImage: "chart.xyaxis.line") {
                if samples.isEmpty {
                    placeholder("Waiting for computation…")
                } else {
                    chartRe
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                .fill(Color(white: 0.96))
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2).foregroundStyle(Palette.accent)
                Text(text).foregroundStyle(Palette.muted).font(.callout)
            }
        }
        .frame(minHeight: 240)
    }

    @ViewBuilder
    private var chartIm: some View {
        let series: [Series] = (0..<3).map { idx in
            Series(idx: idx,
                   points: samples.compactMap { s in
                       let v = s.roots[idx].im
                       guard s.z > 0, v.isFinite else { return nil }
                       return Pt(z: s.z, value: v)
                   })
        }
        let canLog = samples.allSatisfy { $0.z > 0 }
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("z", p.z),
                             y: .value("Im(s)", p.value),
                             series: .value("series", s.label))
                        .foregroundStyle(by: .value("series", s.label))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxisLabel("z")
        .chartYAxisLabel("Im(s)")
        .chartXScale(type: canLog ? .log : .linear)
        .chartLegend(.visible)
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private var chartRe: some View {
        let series: [Series] = (0..<3).map { idx in
            Series(idx: idx,
                   points: samples.compactMap { s in
                       let v = s.roots[idx].re
                       guard s.z > 0, v.isFinite else { return nil }
                       return Pt(z: s.z, value: v)
                   })
        }
        let canLog = samples.allSatisfy { $0.z > 0 }
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("z", p.z),
                             y: .value("Re(s)", p.value),
                             series: .value("series", s.label))
                        .foregroundStyle(by: .value("series", s.label))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxisLabel("z")
        .chartYAxisLabel("Re(s)")
        .chartXScale(type: canLog ? .log : .linear)
        .chartLegend(.visible)
        .frame(minHeight: 320)
    }

    // ---------------------------------------------------------- compute

    private struct SampledRoots: Identifiable {
        let id = UUID()
        let z: Double
        let roots: [ComplexNumber]   // length 3, sorted
    }
    private struct Series: Identifiable {
        let id = UUID()
        let idx: Int
        let points: [Pt]
        var label: String { "root #\(idx + 1)" }
    }
    private struct Pt: Identifiable { let id = UUID(); let z: Double; let value: Double }

    private func compute() -> [SampledRoots] {
        EDLog.log(.math, "ImSvsZ.compute — beta=\(beta) y=\(y) a=\(a) z=[\(zmin),\(zmax)] N=\(nPoints)")
        guard nPoints > 1, zmax > zmin, zmin > 0 else {
            EDLog.warn(.math, "ImSvsZ.compute — invalid range, returning empty")
            return []
        }
        let logA = log(zmin), logB = log(zmax)
        var out = [SampledRoots](); out.reserveCapacity(nPoints)
        for i in 0..<nPoints {
            let t = Double(i) / Double(nPoints - 1)
            let z = exp(logA + (logB - logA) * t)
            let rs = Cubic.stieltjesRoots(z: z, beta: beta, y: y, a: a)
            // Always pad to 3 entries.
            var padded = rs
            while padded.count < 3 { padded.append(.zero) }
            out.append(SampledRoots(z: z, roots: padded))
        }
        return out
    }
}
