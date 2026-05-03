//
//  RootsView.swift
//  Roots vs β — solves the same Stieltjes cubic with z, a, y fixed and β
//  swept, plotting Imaginary parts, Real parts, and the discriminant Δ.
//  Mirrors random_matrix_ESD/app.py's "Roots vs beta" tab layout.
//

import Charts
import SwiftUI

struct RootsView: View {
    @State private var z: Double = 1.0
    @State private var y: Double = 1.0
    @State private var a: Double = 2.0
    @State private var betaMin: Double = 0.0
    @State private var betaMax: Double = 1.0
    @State private var nPoints: Int = 400

    @State private var samples: [SampledRoots] = []
    @State private var discZeros: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EmptyView().onAppear {
                EDLog.log(.ui, "RootsView appear — samples=\(samples.count) zeros=\(discZeros.count)")
            }
            SectionHeading(title: "Roots vs β",
                            systemImage: "chart.line.uptrend.xyaxis",
                            subtitle: "Track the three Stieltjes-cubic roots as β sweeps; mark every Δ = 0 crossing")

            ControlPlotLayout(
                controls: { controlsCard },
                plots: { plotsCard }
            )
        }
    }

    // ---------------------------------------------------------- controls

    private var controlsCard: some View {
        Card(title: "Parameters", systemImage: "slider.horizontal.3") {
            InlineField(label: "Z position", value: $z)
            InlineField(label: "Y ratio", value: $y)
            InlineField(label: "Spike (a)", value: $a)
            Divider()
            Text("β range").font(.caption.bold()).foregroundStyle(Palette.muted)
            InlineField(label: "Minimum", value: $betaMin)
            InlineField(label: "Maximum", value: $betaMax)
            Divider()
            InlineField(label: "Grid points", value: $nPoints)
            Button {
                let r = compute()
                samples = r.samples
                discZeros = r.discZeros
            } label: {
                Label("Generate root plots", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Tracks root evolution across β values. Red dashed lines mark discriminant zero-crossings.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    // ---------------------------------------------------------- plots

    private var plotsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Cubic equation & discriminant", systemImage: "function") {
                EquationPanel(title: "Same cubic, β as the swept variable") {
                    Text("(z·a)·s³ + [z·(a+1) + a·(1−y)]·s² + [z + (a+1) − y − y·β·(a−1)]·s + 1 = 0")
                    Text("Δ = 18 ABCD − 4 B³D + B²C² − 4 A C³ − 27 A²D²")
                    Text("Δ > 0 ⇒ three distinct real roots")
                    Text("Δ < 0 ⇒ one real + two complex conjugates")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Card(title: "Imaginary parts", systemImage: "chart.line.uptrend.xyaxis") {
                    if samples.isEmpty { placeholder("Click Generate") }
                    else { chartImaginary }
                }
                Card(title: "Real parts", systemImage: "chart.xyaxis.line") {
                    if samples.isEmpty { placeholder("Waiting for computation…") }
                    else { chartReal }
                }
            }
            Card(title: "Cubic discriminant Δ(β)", systemImage: "scribble") {
                if samples.isEmpty { placeholder("Waiting for computation…") }
                else { chartDiscriminant }
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

    // ---------------------------------------------------------- charts

    @ViewBuilder
    private var chartImaginary: some View {
        let series: [Series] = (0..<3).map { idx in
            Series(idx: idx, points: samples.map { Pt(beta: $0.beta, value: $0.roots[idx].im) })
        }
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("β", p.beta),
                             y: .value("Im(s)", p.value),
                             series: .value("series", s.label))
                        .foregroundStyle(by: .value("series", s.label))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(Array(discZeros.enumerated()), id: \.offset) { _, b in
                RuleMark(x: .value("Δ=0", b))
                    .foregroundStyle(.red)
                    .lineStyle(.init(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxisLabel("β")
        .chartYAxisLabel("Im(s)")
        .chartLegend(.visible)
        .frame(minHeight: 280)
    }

    @ViewBuilder
    private var chartReal: some View {
        let series: [Series] = (0..<3).map { idx in
            Series(idx: idx, points: samples.map { Pt(beta: $0.beta, value: $0.roots[idx].re) })
        }
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("β", p.beta),
                             y: .value("Re(s)", p.value),
                             series: .value("series", s.label))
                        .foregroundStyle(by: .value("series", s.label))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(Array(discZeros.enumerated()), id: \.offset) { _, b in
                RuleMark(x: .value("Δ=0", b))
                    .foregroundStyle(.red)
                    .lineStyle(.init(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxisLabel("β")
        .chartYAxisLabel("Re(s)")
        .chartLegend(.visible)
        .frame(minHeight: 280)
    }

    @ViewBuilder
    private var chartDiscriminant: some View {
        Chart {
            ForEach(samples) { s in
                LineMark(x: .value("β", s.beta), y: .value("Δ", s.disc))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                                     startPoint: .leading, endPoint: .trailing))
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(.gray.opacity(0.6))
                .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
            ForEach(Array(discZeros.enumerated()), id: \.offset) { _, b in
                RuleMark(x: .value("Δ=0", b))
                    .foregroundStyle(.red)
                    .lineStyle(.init(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxisLabel("β")
        .chartYAxisLabel("Δ(β)")
        .frame(minHeight: 240)
    }

    // ---------------------------------------------------------- compute

    private struct SampledRoots: Identifiable {
        let id = UUID()
        let beta: Double
        let roots: [ComplexNumber]
        let disc: Double
    }
    private struct Series: Identifiable {
        let id = UUID()
        let idx: Int
        let points: [Pt]
        var label: String { "root #\(idx + 1)" }
    }
    private struct Pt: Identifiable { let id = UUID(); let beta: Double; let value: Double }

    private struct Run { let samples: [SampledRoots]; let discZeros: [Double] }

    private func compute() -> Run {
        EDLog.log(.math, "Roots.compute — z=\(z) y=\(y) a=\(a) beta=[\(betaMin),\(betaMax)] N=\(nPoints)")
        guard nPoints > 1, betaMax > betaMin else {
            EDLog.warn(.math, "Roots.compute — invalid range, returning empty")
            return Run(samples: [], discZeros: [])
        }
        var samples = [SampledRoots](); samples.reserveCapacity(nPoints)
        let dx = (betaMax - betaMin) / Double(nPoints - 1)
        var prevDisc: Double = 0
        var zeros = [Double]()
        for i in 0..<nPoints {
            let b = betaMin + Double(i) * dx
            let rs = Cubic.stieltjesRoots(z: z, beta: b, y: y, a: a)
            var padded = rs; while padded.count < 3 { padded.append(.zero) }
            let disc = Cubic.stieltjesDiscriminant(z: z, beta: b, y: y, a: a)
            samples.append(SampledRoots(beta: b, roots: padded, disc: disc))
            if i > 0, prevDisc * disc < 0 {
                // Linear interpolation for the zero crossing.
                let prevB = betaMin + Double(i - 1) * dx
                let frac = prevDisc / (prevDisc - disc)
                zeros.append(prevB + frac * dx)
            }
            prevDisc = disc
        }
        return Run(samples: samples, discZeros: zeros)
    }
}
