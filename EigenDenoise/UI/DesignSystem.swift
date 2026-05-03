//
//  DesignSystem.swift
//  Visual primitives matched to the random_matrix_ESD/app.py HTML/CSS:
//
//      bg     radial(circle at 20% 15%, rgba(255,255,255,0.10), transparent 30%)
//             over linear-gradient(135deg, #0c1224, #0f172a 50%, #0b1020)
//      panel  #0f172a
//      card   #ffffff
//      accent #3b82f6 → #60a5fa
//      border #d9e1ef
//
//  Components: Card (white panel), Pill, MetricBadge, ImageTile, Header,
//  TabBar, AppBackground.
//

import SwiftUI

// MARK: - Palette

enum Palette {
    static let bgDeep    = Color(red: 0.047, green: 0.071, blue: 0.141)   // #0c1224
    static let bgPanel   = Color(red: 0.059, green: 0.090, blue: 0.165)   // #0f172a
    static let bgEdge    = Color(red: 0.043, green: 0.063, blue: 0.125)   // #0b1020
    static let card      = Color(red: 1.000, green: 1.000, blue: 1.000)
    static let cardDark  = Color(red: 0.094, green: 0.118, blue: 0.180)
    static let border    = Color(red: 0.851, green: 0.882, blue: 0.937)   // #d9e1ef
    static let borderDark = Color(red: 0.117, green: 0.161, blue: 0.231)  // #1e293b
    static let accent    = Color(red: 0.231, green: 0.510, blue: 0.965)   // #3b82f6
    static let accent2   = Color(red: 0.376, green: 0.647, blue: 0.980)   // #60a5fa
    static let text      = Color(red: 0.059, green: 0.090, blue: 0.165)   // #0f172a
    static let textOnDark = Color(red: 0.886, green: 0.910, blue: 0.941)  // #e2e8f0
    static let muted     = Color(red: 0.357, green: 0.392, blue: 0.459)   // #5b6475
}

enum Theme {
    static let cornerLg: CGFloat = 14
    static let cornerMd: CGFloat = 10
    static let cornerSm: CGFloat = 6
    static let panelInset: CGFloat = 20

    static let accentGradient = LinearGradient(
        colors: [Palette.accent, Palette.accent2],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - App-wide background

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.bgDeep, Palette.bgPanel, Palette.bgEdge],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
            // Subtle highlight at top-left, like the radial-gradient in the CSS.
            RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.20, y: 0.15),
                           startRadius: 30, endRadius: 480)
                .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

// MARK: - White card on dark background (matches `.card` CSS)

struct Card<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var trailing: AnyView? = nil
    var padding: CGFloat = Theme.panelInset
    @ViewBuilder var content: Content

    @State private var isHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || trailing != nil {
                HStack(spacing: 10) {
                    if let sys = systemImage {
                        Image(systemName: sys)
                            .foregroundStyle(Theme.accentGradient)
                            .font(.headline)
                    }
                    if let t = title {
                        Text(t).font(.headline).foregroundStyle(Palette.text)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerLg, style: .continuous)
                .fill(Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLg, style: .continuous)
                .stroke(Palette.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isHover ? 0.30 : 0.20),
                radius: isHover ? 14 : 10, y: isHover ? 4 : 2)
        .onHover { isHover = $0 }
        .animation(.easeOut(duration: 0.18), value: isHover)
        .foregroundStyle(Palette.text)
        // Force LIGHT colour scheme inside the white card so form labels,
        // text-field text, secondary labels, etc. all render dark and stay
        // legible on the white background.
        .environment(\.colorScheme, .light)
        .tint(Palette.accent)
    }
}

// MARK: - Header (sticky-feel top bar matching `<header>` CSS)

struct AppHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 44, height: 44)
                    .shadow(color: Palette.accent.opacity(0.4), radius: 8, y: 2)
                Image(systemName: "function")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.textOnDark.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            Palette.bgDeep.opacity(0.85)
                .background(.ultraThinMaterial)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderDark).frame(height: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

// MARK: - Tab bar (matches `.tabs` CSS)

struct TabBar<TabType: Hashable & Identifiable>: View {
    let tabs: [TabType]
    let label: (TabType) -> String
    let icon: (TabType) -> String
    @Binding var selection: TabType

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                let isActive = selection == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(tab))
                            .font(.caption.weight(.semibold))
                        Text(label(tab))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        ZStack {
                            if isActive {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white)
                            } else {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isActive ? Color.white.opacity(0.0) : Color.white.opacity(0.15),
                                    lineWidth: 1)
                    )
                    .foregroundStyle(isActive ? Palette.text : Color.white.opacity(0.92))
                    .shadow(color: isActive ? Palette.accent.opacity(0.35) : .clear,
                            radius: 8, y: 2)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Pill / MetricBadge / ImageTile

struct Pill: View {
    let text: String
    var color: Color = Palette.accent
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let s = systemImage { Image(systemName: s).font(.caption2) }
            Text(text).font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.16))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

struct MetricBadge: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let s = systemImage {
                    Image(systemName: s).foregroundStyle(tint).font(.caption.bold())
                }
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Palette.text.opacity(0.65))
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                .fill(Color(white: 0.965))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                .stroke(Palette.border, lineWidth: 0.5)
        )
        .environment(\.colorScheme, .light)
    }
}

struct ImageTile: View {
    let title: String
    let image: NSImage?
    var height: CGFloat? = nil
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                    .fill(Color(white: 0.94))
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("not available").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(minHeight: height ?? 240)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                    .stroke(hover ? Palette.accent : Palette.border,
                            lineWidth: hover ? 2 : 0.5)
            )
            .scaleEffect(hover ? 1.01 : 1.0)
            .shadow(color: hover ? Palette.accent.opacity(0.30) : .clear, radius: 10)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.18), value: hover)
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
        }
    }
}

// MARK: - Section heading (used inside white cards)

/// Section heading rendered on the dark page background (between cards).
/// Defaults to white text; pass `onCard: true` if used inside a Card body
/// so it renders dark instead.
struct SectionHeading: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    var onCard: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let s = systemImage {
                Image(systemName: s)
                    .font(.title2)
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(onCard ? Palette.text : .white)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(onCard ? Palette.muted : Color.white.opacity(0.78))
                }
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}

// MARK: - Two-column "controls + plot" layout (matches repo's .grid 320px 1fr)

struct ControlPlotLayout<Controls: View, Plots: View>: View {
    @ViewBuilder var controls: Controls
    @ViewBuilder var plots: Plots
    var sidebarWidth: CGFloat = 320

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                controls
            }
            .frame(width: sidebarWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 14) {
                plots
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Inline labelled input row (matches the repo's `<label>` + `<input>` style)

struct InlineField<Value>: View where Value: Numeric, Value: LosslessStringConvertible {
    let label: String
    @Binding var value: Value
    var width: CGFloat = 120
    var format: FloatingPointFormatStyle<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text.opacity(0.65))
            TextField("", text: stringBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: width)
        }
    }
    private var stringBinding: Binding<String> {
        Binding(get: { String(value) },
                set: { if let v = Value($0) { value = v } })
    }
}

// MARK: - Equation panel (collapsible, matches `<details>` blocks in the repo)

struct EquationPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open: Bool = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Palette.text)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "function").foregroundStyle(Theme.accentGradient)
                Text(title).font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.vertical, 4)
        .tint(Palette.accent)
    }
}

// MARK: - Field styling helper

extension View {
    func subtleField() -> some View {
        textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 12, design: .monospaced))
    }
}

// MARK: - Status pill (running / idle / failed)

struct StatusBadge: View {
    enum Kind { case idle, running, ok, warn, fail }
    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .idle:    return .gray
        case .running: return .yellow
        case .ok:      return .green
        case .warn:    return .orange
        case .fail:    return .red
        }
    }
    private var icon: String {
        switch kind {
        case .idle:    return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .ok:      return "checkmark.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .fail:    return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.bold())
                .symbolEffect(.pulse, isActive: kind == .running)
            Text(text).font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.20))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}
