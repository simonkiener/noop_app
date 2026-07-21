import SwiftUI

/// The destinations the quick action menu can present.
public enum QuickActionKind: String, Identifiable, CaseIterable, Sendable {
    case live
    case workout
    case journal
    case breathe

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .live:    return "Live HR"
        case .workout: return "Start workout"
        case .journal: return "Log journal"
        case .breathe: return "Breathe"
        }
    }

    public var icon: String {
        switch self {
        case .live:    return "waveform.path.ecg"
        case .workout: return "figure.run"
        case .journal: return "square.and.pencil"
        case .breathe: return "wind"
        }
    }

    public var tint: Color {
        switch self {
        case .live:    return StrandPalette.metricRose
        case .workout: return StrandPalette.effortColor
        case .journal: return StrandPalette.accent
        case .breathe: return StrandPalette.restColor
        }
    }
}

/// A clean reusable bottom sheet of quick actions (+ button).
public struct QuickActionSheet: View {
    public let onPick: (QuickActionKind) -> Void

    public init(onPick: @escaping (QuickActionKind) -> Void) {
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                ForEach(QuickActionKind.allCases) { kind in
                    row(kind.title, icon: kind.icon, tint: kind.tint) {
                        onPick(kind)
                    }
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
        .frame(minWidth: 340, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            StrandPalette.surfaceOverlay
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    private func row(_ title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(StrandPalette.surfaceInset))
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StrandPalette.surfaceInset.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
