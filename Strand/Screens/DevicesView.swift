import SwiftUI
import StrandDesign
import StrandAnalytics   // ConnectionReadout - the #987 clock-latch / RTC-epoch readout parsers
import WhoopStore

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over `DeviceRegistry` (the Phase 1A/1B data layer): every mutation
// goes through a registry op, and the `SourceCoordinator` (already wired in AppModel) reacts to the
// active-device change — so this view never touches BLEManager or the WHOOP path directly.
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    // PERF: this OUTER view does NOT observe `LiveState`. It only branches on `model.deviceRegistry`
    // becoming non-nil and hands off to `DevicesContent`, which owns its own `@EnvironmentObject live`
    // (the live battery / "Active · Live" badge live there). Observing `live` here would re-render the
    // whole screen on every ~1 Hz strap tick for no visible change — `live` is still in the environment
    // for `DevicesContent` and the Add-device wizard, so nothing downstream loses its live readout.

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "Pair and manage the bands NOOP reads from.",
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends: a fixed,
                       // full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       topBackground: liquidScaffoldSky()) {
            if let registry = model.deviceRegistry {
                DevicesContent(registry: registry)
            } else {
                // The registry is built once the on-device store opens (a beat after launch). Show a
                // calm pending note rather than an empty screen in that brief window.
                DataPendingNote(
                    title: "Getting your devices ready",
                    message: "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
                    symbol: "badge.plus.radiowaves.right")
            }
        }
    }
}

// MARK: - Content (registry resolved)

/// The screen body once `DeviceRegistry` exists. Split out so it can observe the registry's
/// `@Published devices` / `activeDeviceId` directly — the parent only observes `model.deviceRegistry`
/// becoming non-nil.
private struct DevicesContent: View {
    @ObservedObject var registry: DeviceRegistry
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    // Sheets / alerts
    @State private var showAddWizard = false
    @State private var switchTarget: PairedDevice?
    @State private var renameTarget: PairedDevice?
    @State private var renameDraft = ""
    @State private var removeTarget: PairedDevice?
    @State private var deleteDataTarget: PairedDevice?
    /// After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    @State private var pickNewActive = false

    private var activeDevices: [PairedDevice] { registry.devices.filter { $0.status != .archived } }
    private var removedDevices: [PairedDevice] { registry.devices.filter { $0.status == .archived } }

    /// #987: the active+connected strap's clock state, from the SAME pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds (one source of truth). nil (no row at all) until the WHOOP path
    /// has produced any clock signal - a routed frame, a clock correlation, or a data-range reply - so a
    /// generic HR strap or an idle card never shows a fabricated "waiting" state. One computation for
    /// both the line and the warning (the log scan is the cost worth paying once, not twice).
    private var strapClockState: (line: String, warning: String?)? {
        guard live.connected else { return nil }
        let deviceClock = ConnectionReadout.clockCorrelatedDevice(logLines: live.log)
        guard deviceClock != nil || live.strapRange != nil || live.lastFrameAtUnix != nil else { return nil }
        let latched = ConnectionReadout.clockLatchedLabel(deviceClockUnix: deviceClock)
        let frame = ConnectionReadout.lastFrameLabel(lastFrameUnix: live.lastFrameAtUnix,
                                                     nowUnix: Int(Date().timeIntervalSince1970))
        let warning = ConnectionReadout.rtcWarning(deviceClockUnix: deviceClock,
                                                   strapNewestUnix: live.strapRange?.newestUnix)
        return (String(localized: "Clock latched: \(latched) · last frame \(frame)"), warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            // UPPERCASE overline section header, matching the liquid Today. Counts the paired bands so the
            // multi-WHOOP reality reads at a glance.
            sectionHead("YOUR BANDS", trailing: activeDevices.count == 1
                        ? String(localized: "1 paired")
                        : String(localized: "\(activeDevices.count) paired"))
            ForEach(Array(activeDevices.enumerated()), id: \.element.id) { idx, device in
                DeviceCard(
                    device: device,
                    isActive: device.status == .active,
                    isLiveConnected: device.status == .active && live.connected,
                    // The live battery belongs to whichever device is ACTIVE + connected (the WHOOP, a
                    // generic strap, or an FTMS machine all funnel into live.batteryPct). nil otherwise.
                    liveBatteryPct: (device.status == .active && live.connected) ? live.batteryPct.map { Int($0.rounded()) } : nil,
                    // Firmware version belongs to the active + connected strap only; nil otherwise (and
                    // for a non-WHOOP source that never reports one).
                    liveFirmware: (device.status == .active && live.connected) ? live.strapFirmware : nil,
                    // #987: clock latch + frame freshness + the 1970/71 RTC warning, active card only.
                    liveClockLine: device.status == .active ? strapClockState?.line : nil,
                    liveClockWarning: device.status == .active ? strapClockState?.warning : nil,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: { removeTarget = device })
                    .staggeredAppear(index: idx)
            }

            addButton
                .staggeredAppear(index: activeDevices.count)

            if !removedDevices.isEmpty { removedSection }

            whoopFirstFooter
        }
        // Add a device — guided, branching wizard (asks the device TYPE first, then runs the right
        // scan/register path: WHOOP present-scan for WHOOP families, StandardHRSource for HR straps).
        .sheet(isPresented: $showAddWizard) {
            AddDeviceWizard(live: live) { showAddWizard = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        // Switch confirm
        .alert("Make this your active strap?",
               isPresented: Binding(get: { switchTarget != nil },
                                    set: { if !$0 { switchTarget = nil } }),
               presenting: switchTarget) { device in
            Button("Cancel", role: .cancel) { switchTarget = nil }
            Button("Make active") {
                registry.setActive(device.id)
                switchTarget = nil
            }
        } message: { device in
            Text("Make \(device.displayName) your active strap? From now on it provides your live data. \(currentActiveName)'s history stays exactly as it is. Only new days come from \(device.displayName).")
        }
        // Rename
        .alert("Rename device",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { device in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                registry.rename(device.id, to: renameDraft)
                renameTarget = nil
            }
        } message: { device in
            Text("Give \(device.brand) \(device.model) a name you'll recognise.")
        }
        // Remove confirm
        .alert("Remove this device?",
               isPresented: Binding(get: { removeTarget != nil },
                                    set: { if !$0 { removeTarget = nil } }),
               presenting: removeTarget) { device in
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove", role: .destructive) { confirmRemove(device) }
        } message: { device in
            Text("Remove \(device.displayName)? NOOP will stop connecting to it. Its recorded data is kept and you can re-add it any time.")
        }
        // Second, strongly-worded delete-data confirm (reached from the Remove card's secondary control)
        .alert("Delete all of this device's data?",
               isPresented: Binding(get: { deleteDataTarget != nil },
                                    set: { if !$0 { deleteDataTarget = nil } }),
               presenting: deleteDataTarget) { device in
            Button("Cancel", role: .cancel) { deleteDataTarget = nil }
            Button("Delete data", role: .destructive) {
                // Route the heavy 16+-table delete through the WhoopStore actor (off the main thread) so a
                // large device dataset can't freeze the UI. Resolve the store handle inside the Task, then
                // await the delete; the registry reloads the (now-emptied) list on completion.
                let deviceId = device.id
                Task {
                    guard let store = await model.repo.storeHandle() else { return }
                    await registry.deleteDeviceData(deviceId, store: store)
                }
                deleteDataTarget = nil
            }
        } message: { device in
            Text("This permanently deletes all data recorded from \(device.displayName). This can't be undone.")
        }
        // After removing the active device, offer to pick a new active one (if any remain).
        .confirmationDialog("Pick a new active strap",
                            isPresented: $pickNewActive,
                            titleVisibility: .visible) {
            ForEach(activeDevices) { device in
                Button(device.displayName) { registry.setActive(device.id) }
            }
            Button("Leave none active", role: .cancel) { }
        } message: {
            Text("You removed your active strap. Choose which paired band provides your live data, or leave none active and pair one later.")
        }
    }

    // MARK: Pieces

    private var addButton: some View {
        NoopButton("Add a device", systemImage: "plus", kind: .primary, fullWidth: true) {
            showAddWizard = true
        }
        .accessibilityLabel("Add a device")
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            sectionHead("REMOVED", trailing: String(localized: "Data kept"))
            ForEach(removedDevices) { device in
                DeviceCard(
                    device: device,
                    isActive: false,
                    isLiveConnected: false,
                    dimmed: true,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: nil,
                    onReAdd: { registry.setActive(device.id) },
                    onDeleteData: { deleteDataTarget = device })
            }
        }
    }

    private var whoopFirstFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps are an early, in-development addition: they stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// UPPERCASE overline section header with tracking + a muted trailing note, matching the liquid Today's
    /// `sectionHead`. Keeps every page's section chrome identical.
    private func sectionHead(_ title: LocalizedStringKey, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(trailing).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Logic

    private var currentActiveName: String {
        registry.devices.first(where: { $0.status == .active })?.displayName ?? String(localized: "Your current strap")
    }

    /// Archive the device, then — if it was the active one and other non-archived devices remain —
    /// prompt for a new active device. The active row is demoted to `.paired` by the registry's reload,
    /// so the dialog's choices come from the still-paired devices.
    private func confirmRemove(_ device: PairedDevice) {
        let wasActive = device.status == .active
        // #78: actually RELEASE the BLE link, not just archive the registry row — otherwise NOOP keeps
        // re-grabbing the strap (reconnect timer + targeted-connect pin + iOS state restoration), holding
        // it connected so it can never enter pairing mode to be re-paired.
        model.ble.forgetDevice(device.peripheralId)
        registry.archive(device.id)
        removeTarget = nil
        if wasActive {
            // Other paired devices left → ask which becomes active; otherwise no active device remains.
            if !activeDevices.isEmpty {
                pickNewActive = true
            }
        }
    }
}

// MARK: - Device card

/// One paired device as a card: name, brand/model, capabilities line, a state pill, last-seen, and a
/// per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries an "Active" pill.
private struct DeviceCard: View {
    let device: PairedDevice
    let isActive: Bool
    let isLiveConnected: Bool
    /// The active+connected device's live battery percent (0–100), surfaced on the card the same way
    /// for WHOOP, a generic strap, or an FTMS machine. nil when not the active/connected device or
    /// the source hasn't reported a battery (e.g. a strap/machine without the 0x180F service).
    var liveBatteryPct: Int? = nil
    /// The active+connected strap's firmware version (from the connect handshake). nil when not the
    /// active/connected device, or for a source that reports no firmware (e.g. a non-WHOOP strap).
    var liveFirmware: String? = nil
    /// #987: the active+connected strap's clock-state line ("Clock latched: yes · last frame 12s ago"),
    /// nil for every other card. Built by the parent off the same pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds, so the two readouts can never disagree.
    var liveClockLine: String? = nil
    /// #987: the plain-words warning when the strap RTC reads ~1970/71 (never set, so it banks no
    /// history) - the single most common "no history" root cause, surfaced where the user looks first.
    var liveClockWarning: String? = nil
    var dimmed: Bool = false
    var onMakeActive: () -> Void
    var onRename: () -> Void
    var onRemove: (() -> Void)?
    /// Removed-section affordances (re-add as active / delete its data).
    var onReAdd: (() -> Void)? = nil
    var onDeleteData: (() -> Void)? = nil

    /// The card's visible content. The required `body` wraps this in the whole-card liquid press button +
    /// the ⋮ menu overlay.
    private var cardContent: some View {
        StrandCard(padding: 18, tint: isActive ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: icon)
                        .font(StrandFont.title2)
                        .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(profile.displayModel)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    statePill
                }

                // What this device CAPTURES — honest, per-model (not the generic stored set, which would
                // mislabel e.g. a "Blood oxygen" chip when no SpO₂ % ever comes off the strap).
                capabilityRow(symbol: "waveform.path.ecg", text: profile.captures,
                              tint: StrandPalette.textSecondary)
                // What NOOP USES it for — the scores/screens this device drives.
                capabilityRow(symbol: "bolt.fill", text: profile.powers,
                              tint: StrandPalette.textSecondary)
                // Honest footnote: the "*" estimates + the SpO₂/steps caveats.
                if !profile.footnote.isEmpty {
                    Text(profile.footnote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Live battery for the active+connected device, shown as a liquid tube that fills to the
                // charge — same surface for WHOOP / strap / FTMS. The tube reads the charge band's colour.
                if let pct = liveBatteryPct {
                    batteryTube(pct)
                }

                // #987: strap clock state for the active+connected strap - "clock latched" + frame
                // freshness, with the plain amber 1970/71 warning when the RTC was never set (the strap
                // banks no history in that state, which otherwise looks like a NOOP sync bug).
                if let clockLine = liveClockLine {
                    Text(clockLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityLabel(clockLine)
                }
                if let warning = liveClockWarning {
                    Text(warning)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(warning)
                }

                HStack(spacing: 6) {
                    Text(lastSeenLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    // Firmware version for the active+connected strap, read on connect.
                    if let fw = liveFirmware {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text("FW \(fw)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityLabel("Firmware version \(fw)")
                    }
                    // The whole-card tap hint sits on the left; the ⋮ menu is a bottom-trailing overlay above
                    // the press button (so its own taps win). No hint on the active card (no make-active),
                    // nor on a removed card whose re-add is menu-only.
                    if let hint = primaryActionHint {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text(hint)
                            .font(StrandFont.overlineScaled(10)).tracking(1.0)
                            .foregroundStyle(StrandPalette.accent)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 44)   // leave room for the ⋮ menu overlay at the bottom-trailing
                }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    /// The whole-card liquid press wrapper: tapping the card performs its PRIMARY action (make active for a
    /// paired band, re-add for a removed one), with the settle-in `LiquidPressStyle`. The ⋮ menu is layered
    /// on top as an overlay so it captures its own taps; cards with no primary action (the active one, or a
    /// removed one whose re-add is menu-only) fall back to a plain container so nothing taps by accident.
    var body: some View {
        Group {
            if let action = primaryAction {
                Button(action: action) { cardContent }
                    .buttonStyle(LiquidPressStyle())
            } else {
                cardContent
            }
        }
        .overlay(alignment: .bottomTrailing) {
            actionsMenu
                .padding(18)
        }
    }

    /// The card's primary tap action, or nil when there isn't one. A paired-but-not-active band → make it
    /// active; a removed band → re-add it as active. The active band and any card without those callbacks
    /// have no whole-card tap (their controls live entirely in the ⋮ menu).
    private var primaryAction: (() -> Void)? {
        if device.status == .archived { return onReAdd }
        if !isActive { return onMakeActive }
        return nil
    }

    /// Short accent hint mirroring the primary tap, shown in the footer row. nil when the card has no
    /// whole-card action (active band / menu-only removed band).
    private var primaryActionHint: String? {
        if device.status == .archived { return onReAdd == nil ? nil : String(localized: "Make active") }
        if !isActive { return String(localized: "Make active") }
        return nil
    }

    /// The live battery as a liquid tube (fills to the charge, coloured by band) with a trailing percent.
    /// Static-posed so it costs nothing per frame — one of many small liquid elements on the screen.
    private func batteryTube(_ pct: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: batterySymbol(pct))
                .font(StrandFont.caption)
                .foregroundStyle(batteryTint(pct))
                .frame(width: 18)
                .accessibilityHidden(true)
            LiquidTube(frac: Double(pct) / 100, tint: batteryTint(pct), height: 8, animated: false)
            Text("\(pct)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(pct) percent")
    }

    /// The charge-band colour for the battery tube/icon (mirrors the menu-bar battery buckets).
    private func batteryTint(_ pct: Int) -> Color {
        pct < 15 ? StrandPalette.statusCritical : pct < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }

    private var statePill: some View {
        Group {
            if device.status == .archived {
                StatePill("Removed", tone: .neutral, showsDot: false)
            } else if isActive {
                StatePill(isLiveConnected ? "Active · Live" : "Active",
                          tone: .positive, pulsing: isLiveConnected)
            } else {
                StatePill("Paired", tone: .neutral)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            if device.status == .archived {
                if let onReAdd {
                    Button { onReAdd() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onDeleteData {
                    Divider()
                    Button(role: .destructive) { onDeleteData() } label: {
                        Label("Delete this device's data…", systemImage: "trash")
                    }
                }
            } else {
                if !isActive {
                    Button { onMakeActive() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Device actions for \(device.displayName)")
    }

    /// SF Symbol for the device: WHOOP keeps the band glyph;
    /// an Apple Watch reads as a watch; generic straps read as a heart-rate strap.
    private var icon: String {
        if device.sourceKind == .liveAppleWatch { return "applewatch" }
        return SourceCoordinator.isWhoop(device) ? "applewatch.side.right" : "heart.circle"
    }

    /// The honest, per-model capability + function summary for this device's card.
    private var profile: DeviceCapabilityProfile { .make(for: device) }

    /// One icon-prefixed info row (captures / powers), matching the card's caption style.
    private func capabilityRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastSeenLine: String {
        if device.status == .archived { return String(localized: "Removed · data kept") }
        if isLiveConnected { return String(localized: "Connected now") }
        return String(localized: "Last seen \(relativeAgo(TimeInterval(device.lastSeenAt)))")
    }

    /// A battery SF Symbol matching the charge band (mirrors the menu-bar battery glyph buckets).
    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

// MARK: - Capability profile

/// Honest, per-model summary of what a device captures and what NOOP uses it for — shown on its card.
struct DeviceCapabilityProfile {
    let displayModel: String   // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    let captures: String       // "·"-joined honest capture labels for THIS model
    let powers: String         // the NOOP scores / screens this device drives
    let footnote: String       // one short honest caveat line

    static func make(for d: PairedDevice) -> DeviceCapabilityProfile {
        // Apple Watch (live HealthKit source). UNLIKE the WHOOP/strap branches, the watch's stored
        // capability `Set` is already the honest per-model trim (AppleWatchDevice only adds a metric
        // once real data for it arrives), so we read the labels straight off it. An older watch with
        // no SpO₂/wrist-temp samples simply won't list them. Recovery is the calibrating-by-design
        // score (~a week of nights), so the footnote sets that expectation rather than over-promising.
        if d.sourceKind == .liveAppleWatch {
            let labels: [(Metric, String)] = [
                (.hr, String(localized: "Heart rate")), (.hrv, "HRV"), (.sleep, String(localized: "Sleep")),
                (.steps, String(localized: "Steps")), (.spo2, String(localized: "Blood oxygen")), (.skinTemp, String(localized: "Wrist temp")),
            ]
            let captures = labels.filter { d.capabilities.contains($0.0) }.map { $0.1 }.joined(separator: " · ")
            return DeviceCapabilityProfile(
                displayModel: "Apple Watch",
                captures: captures.isEmpty ? String(localized: "Calibrating, no data yet") : captures,
                powers: String(localized: "Powers Rest, Effort, Fitness Age and steps, plus Charge once recovery calibrates"),
                footnote: String(localized: "Computed live from your Apple Watch via Health. Recovery needs about a week of nights to calibrate, and every watch-derived score is labelled with its confidence. Only the metrics your watch actually records are listed above."))
        }
        // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
        // (Same WHOOP test as SourceCoordinator.isWhoop, inlined so this stays nonisolated.)
        let isWhoop = d.id == "my-whoop" || d.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        guard isWhoop else {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Heart-rate strap"),
                captures: String(localized: "Heart rate · HRV (live)* · Strain"),
                powers: String(localized: "Powers the live console + Effort. No Charge, Rest or Sleep"),
                footnote: String(localized: "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery (those are WHOOP-only)."))
        }
        let whoopPowers = String(localized: "Powers Charge, Effort, Rest, Sleep + Health Monitor")
        let model = d.model.lowercased()
        // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
        if model.contains("5") || model.contains("mg") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 5.0 / MG",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation, steps are a raw motion count (#78). No SpO₂ % off the strap; import a WHOOP CSV for a real %."))
        }
        // WHOOP 4.0 — NOOP's primary band; no steps over BLE.
        if model.contains("4") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 4.0",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation (firmware-dependent); no steps over BLE on a 4.0. No SpO₂ % off the strap; import a WHOOP CSV for a real %."))
        }
        // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
        return DeviceCapabilityProfile(
            displayModel: "WHOOP",
            captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
            powers: whoopPowers,
            footnote: String(localized: "Exact model unknown. Shows what every WHOOP can do. * on-device estimate · no SpO₂ % off the strap (import a WHOOP CSV for that)."))
    }
}

// MARK: - Signal indicator

/// A four-bar Wi-Fi-style signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is
/// stronger. Buckets are coarse on purpose — a precise dBm readout would be noise to the user.
/// Internal (not private) so the Add-a-device wizard reuses the same indicator.
struct SignalBars: View {
    let rssi: Int

    static func level(for rssi: Int) -> Int {
        switch rssi {
        case (-55)...:    return 4   // very strong
        case (-67)...:    return 3
        case (-80)...:    return 2
        case (-90)...:    return 1
        default:          return 0
        }
    }

    var body: some View {
        let level = Self.level(for: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < level ? StrandPalette.accent : StrandPalette.hairlineStrong)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .frame(width: 22, height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Capability catalog (DEBUG render harness)

#if DEBUG
/// DEBUG-only: one DeviceCard per capability-profile kind so the honest per-model display can be
/// screenshotted deterministically (`--demo-screen devicescatalog`). Same file as `DeviceCard` /
/// `DeviceCapabilityProfile` so it can reach them. Stripped from Release.
struct DeviceCardCatalog: View {
    private static let whoopCaps: Set<Metric> = [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad]

    private static func dev(_ id: String, _ brand: String, _ model: String,
                            _ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: caps, status: .paired,
                     addedAt: 0, lastSeenAt: 0)
    }

    private static func watch(_ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch", nickname: nil,
                     peripheralId: nil, sourceKind: .liveAppleWatch, capabilities: caps,
                     status: .paired, addedAt: 0, lastSeenAt: 0)
    }

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "What each band captures (and what NOOP uses it for).",
                       topBackground: liquidScaffoldSky()) {
            VStack(spacing: NoopMetrics.gap) {
                DeviceCard(device: Self.dev("whoop-4d", "WHOOP", "4.0", Self.whoopCaps),
                           isActive: true, isLiveConnected: true,
                           onMakeActive: {}, onRename: {}, onRemove: nil)
                DeviceCard(device: Self.dev("whoop-5d", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                DeviceCard(device: Self.dev("strap-d", "Polar", "H10", [.hr, .hrv]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Apple Watch, with an older-model trimmed set (no SpO₂ / wrist temp) so the honest
                // capability read renders deterministically alongside the straps.
                DeviceCard(device: Self.watch([.hr, .hrv, .sleep, .steps]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Devices") {
    let model = AppModel()
    return DevicesView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
