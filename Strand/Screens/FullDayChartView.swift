import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Deep Timeline (full-day, full-resolution metric viewer) — #575
//
// The headline tap-through from Explore: a whole-day line for one metric that the user can ZOOM and PAN
// down to the raw per-second signal. The hard problem — never drawing ~86k points for a worn 24h — is
// solved in the read layer (`Repository.timelineSeries` picks coarse SQL buckets at day scale and raw
// seconds when zoomed in), so this screen only ever receives ~targetPoints points regardless of zoom.
//
// Reuses the existing `OverviewHRChart` (its `.chartXScale(domain:)` already pins the axis); the chart's
// zoom binding drives the visible window, and re-reads at the new resolution as the window changes. macOS
// adds scroll-to-zoom (no pinch); both platforms drag-to-pan. Serves #574 (owned-source filter / honest
// "Other sources" disclosure) and is the detail surface behind #582.

struct FullDayChartView: View {
    @EnvironmentObject var repo: Repository

    /// The day this timeline is showing (its real calendar midnight). Defaults to the logical day so an
    /// after-midnight open still lands on the night the user is living, not an empty new calendar day (#144).
    /// Mutable so the user can step back through previous days (#597 — was today-only with no way back).
    @State private var dayStart: Date
    /// True once we've done the one-shot "open on the most recent day with data" jump (or the caller pinned
    /// an explicit day, in which case we never override it). Stops the jump from fighting manual navigation.
    @State private var didLandOnLatest: Bool

    init(dayStart: Date? = nil) {
        _dayStart = State(initialValue: dayStart ?? Repository.logicalDayStart(Date()))
        _didLandOnLatest = State(initialValue: dayStart != nil)
    }

    @State private var metric: Repository.TimelineMetric = .hr
    /// "Owned only" hides empty non-strap rows; "All sources" surfaces the disclosure (#574). The strap is
    /// always the owned source, so this currently scopes the empty-state copy rather than swapping reads.
    @State private var ownedOnly = true

    @State private var series: Repository.TimelineSeries = .empty
    /// The visible window the chart's gestures mutate. nil → full day (the chart falls back to `dayBounds`).
    @State private var zoomDomain: ClosedRange<Date>? = nil
    @State private var loading = true
    /// Bumped on every settled zoom/metric change so the re-read task re-runs at the new resolution.
    @State private var reloadTick = 0

    /// The full clamp the zoom window can never escape — the selected calendar day.
    private var dayBounds: ClosedRange<Date> {
        dayStart...dayStart.addingTimeInterval(86_400)
    }

    /// The currently-visible window (zoomed or the whole day).
    private var visibleWindow: ClosedRange<Date> { zoomDomain ?? dayBounds }

    var body: some View {
        ScreenScaffold(title: "Deep Timeline", subtitle: "Every second of your day, zoomable.") {
            metricPills
            dayNav
            sourcePill
            chartCard
            zoomHint
        }
        .task(id: taskKey) { await reload() }
        .task { await landOnLatestDayIfNeeded() }
    }

    /// Re-read whenever the metric, the day, the source scope, the settled zoom window, or fresh strap
    /// data changes. The window is bucketed to whole seconds so micro-jitter during a drag doesn't thrash
    /// the DB — the chart redraws smoothly from the in-hand domain while the data settles.
    private var taskKey: String {
        let lo = Int(visibleWindow.lowerBound.timeIntervalSince1970)
        let hi = Int(visibleWindow.upperBound.timeIntervalSince1970)
        return "\(metric.rawValue)|\(Int(dayStart.timeIntervalSince1970))|\(ownedOnly)|\(lo)|\(hi)|\(repo.refreshSeq)"
    }

    // MARK: Controls

    private var metricPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentedPillControl(Repository.TimelineMetric.allCases, selection: $metric) { $0.title }
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var sourcePill: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("My WHOOP")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            // #574 — owned-source scope. The strap is the owned source; "All sources" reveals the honest
            // disclosure that other sources' raw per-second streams aren't offloaded on-device.
            SegmentedPillControl([true, false], selection: $ownedOnly) { $0 ? "Owned" : "All" }
                .fixedSize()
        }
        .padding(.horizontal, 2)
    }

    /// Day stepper — move the whole timeline back/forward a day so a user can reach the days that actually
    /// hold their data, not just today (#597). Forward is clamped at today (no future days).
    private var dayNav: some View {
        HStack(spacing: 12) {
            Button { stepDay(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
            .accessibilityLabel("Previous day")

            Spacer()
            Text(dayLabel)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Spacer()

            Button { stepDay(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isOnLatestDay ? StrandPalette.textTertiary : StrandPalette.accent)
            .disabled(isOnLatestDay)
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal, 4)
    }

    private var isOnLatestDay: Bool { dayStart >= Repository.logicalDayStart(Date()) }

    /// Step the shown day by `delta` days, clamped so you can never go past today, and drop any zoom so the
    /// new day opens at full-day scale.
    private func stepDay(_ delta: Int) {
        let next = dayStart.addingTimeInterval(Double(delta) * 86_400)
        if delta > 0 && next > Repository.logicalDayStart(Date()) { return }
        withAnimation(StrandMotion.interactive) {
            dayStart = next
            zoomDomain = nil
        }
    }

    private var dayLabel: String {
        let today = Repository.logicalDayStart(Date())
        if Calendar.current.isDate(dayStart, inSameDayAs: today) { return "Today" }
        if Calendar.current.isDate(dayStart, inSameDayAs: today.addingTimeInterval(-86_400)) { return "Yesterday" }
        return Self.dayFmt.string(from: dayStart)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    // MARK: Chart

    @ViewBuilder private var chartCard: some View {
        ChartCard(
            title: LocalizedStringKey(metric.title),
            subtitle: resolutionSubtitle,
            trailing: latestReadout,
            height: 280,
            tint: StrandPalette.metricRose
        ) {
            if loading && series.points.isEmpty {
                loadingState
            } else if series.points.isEmpty {
                emptyState
            } else {
                chart
            }
        } footer: {
            if !series.points.isEmpty { statsFooter }
        }
    }

    private var chart: some View {
        OverviewHRChart(
            points: series.points,
            gradient: gradientFor(metric),
            valueRange: valueRange(series.points),
            xRange: dayBounds,
            height: 280,
            zoomDomain: $zoomDomain,
            zoomBounds: dayBounds,
            valueFormat: { format($0) },
            dateFormat: { Self.timeFmt.string(from: $0) }
        )
        #if os(macOS)
        // macOS has no pinch here, so wheel/trackpad scroll zooms about the cursor-agnostic centre.
        // (DeepTimeline owns the scroll handler; the chart's own gesture covers drag-pan.)
        .modifier(ScrollToZoomModifier(
            current: { visibleWindow },
            bounds: dayBounds,
            apply: { zoomDomain = $0 }
        ))
        #endif
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Loading the day…")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Honest empty/dash state — a window the strap offloaded nothing for (a not-yet-synced stretch, an
    /// off-wrist gap, or a metric this device doesn't record). Never a fabricated flat line.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("No \(metric.title.lowercased()) here")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(ownedOnly
                 ? "Nothing offloaded for this window yet."
                 : "Other sources don’t offload raw per-second data on-device.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var zoomHint: some View {
        HStack(spacing: 8) {
            Image(systemName: zoomDomain == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11, weight: .semibold))
            #if os(macOS)
            Text(zoomDomain == nil ? "Scroll to zoom · drag to pan" : "Zoomed in — drag to pan")
            #else
            Text(zoomDomain == nil ? "Pinch to zoom · drag to pan" : "Zoomed in — drag to pan")
            #endif
            Spacer()
            if zoomDomain != nil {
                Button("Reset") { withAnimation(StrandMotion.interactive) { zoomDomain = nil } }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var statsFooter: some View {
        let v = series.points.map(\.value)
        return ChartFooter([
            ("Min", format(v.min() ?? 0)),
            ("Avg", format(v.reduce(0, +) / Double(max(1, v.count)))),
            ("Max", format(v.max() ?? 0)),
        ])
    }

    // MARK: Read

    /// One-shot on first open: if today has no data but an earlier day does (the classic just-synced-history
    /// case, #597), land the timeline on that most-recent day so the user sees their data instead of an empty
    /// today. Skipped when the caller pinned an explicit day, and never fights manual navigation afterwards.
    private func landOnLatestDayIfNeeded() async {
        guard !didLandOnLatest else { return }
        didLandOnLatest = true
        if let latest = await repo.latestDataDayStart(), latest < dayStart {
            withAnimation(StrandMotion.interactive) { dayStart = latest }
        }
    }

    private func reload() async {
        loading = true
        let window = visibleWindow
        let result = await repo.timelineSeries(
            metric: metric,
            from: Int(window.lowerBound.timeIntervalSince1970),
            to: Int(window.upperBound.timeIntervalSince1970),
            targetPoints: 600
        )
        // Guard against a stale task landing after the user moved on.
        guard !Task.isCancelled else { return }
        series = result
        loading = false
    }

    // MARK: Presentation helpers

    private var resolutionSubtitle: String {
        guard !series.points.isEmpty else { return "—" }
        if series.isRaw { return "Raw · per second" }
        let m = series.bucketSeconds / 60
        return m >= 1 ? "\(m)-minute average" : "\(series.bucketSeconds)-second average"
    }

    private var latestReadout: String? {
        series.points.last.map { "\(format($0.value))\(unitSuffix)" }
    }

    private var unitSuffix: String {
        switch metric {
        case .hr: return " bpm"
        case .skinTemp: return "°C"
        case .respiration: return ""
        case .hrv: return " ms"
        case .spo2, .motion: return ""
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .hr, .respiration, .hrv: return String(Int(v.rounded()))
        case .skinTemp: return String(format: "%.1f", v)
        case .spo2, .motion: return String(format: "%.2f", v)
        }
    }

    /// Padded value range so the line never sits flush against an edge (mirrors MetricExplorer/TodayView).
    private func valueRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else {
            return metric == .hr ? 40...120 : 0...1
        }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    private func gradientFor(_ m: Repository.TimelineMetric) -> Gradient {
        switch m {
        case .hr:
            return Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose])
        case .skinTemp:
            return Gradient(colors: [StrandPalette.strain033.opacity(0.55), StrandPalette.strain033])
        case .hrv, .spo2:
            return Gradient(colors: [StrandPalette.sleepLight.opacity(0.55), StrandPalette.sleepLight])
        case .respiration, .motion:
            return Gradient(colors: [StrandPalette.textSecondary.opacity(0.5), StrandPalette.textSecondary])
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

#if os(macOS)
import AppKit
// MARK: - macOS scroll-to-zoom
//
// Scroll up (or trackpad pinch on macOS, which arrives as a magnify event the chart already handles) zooms
// in about the window centre; scroll down zooms out toward the day. Kept as a modifier so the platform
// split stays out of the screen body.
private struct ScrollToZoomModifier: ViewModifier {
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    let apply: (ClosedRange<Date>) -> Void

    func body(content: Content) -> some View {
        content.background(ScrollCatcher { deltaY in
            // Each notch scales by ~1.15; up (positive) zooms in, down zooms out.
            let scale = deltaY > 0 ? 1.15 : (1.0 / 1.15)
            let zoomed = OverviewHRChart.zoomed(current(), scale: scale, anchorFraction: 0.5, bounds: bounds)
            apply(zoomed.upperBound > zoomed.lowerBound ? zoomed : current())
        })
    }
}

/// A transparent NSView that reports scroll-wheel deltaY up the closure. AppKit-only.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }
    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > 0.5 { onScroll(event.scrollingDeltaY) }
        }
    }
}
#endif
