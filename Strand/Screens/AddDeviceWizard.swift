import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Add a device — guided, branching wizard
//
// Pairs supported bands:
//   • WHOOP 4.0 / WHOOP 5.0 (MG) → BLEManager's present-scan (`scanForWhoops`).
//   • Heart-rate strap (Polar, Wahoo, Coospo, etc.) → isolated `StandardHRSource`.

@MainActor
struct AddDeviceWizard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let onClose: () -> Void

    // MARK: Flow

    /// What the user is adding. Drives the prep copy AND which scan/register path runs.
    enum DeviceType: Identifiable, Hashable {
        case whoop5mg
        case whoop4
        case hrStrap

        var id: Self { self }

        var isWhoop: Bool { self == .whoop4 || self == .whoop5mg }
        var whoopModel: WhoopModel? {
            switch self {
            case .whoop4:   return .whoop4
            case .whoop5mg: return .whoop5mg
            default:        return nil
            }
        }
    }

    enum Step { case type, prep, pick, confirm }

    @State private var step: Step = .type
    @State private var type: DeviceType?

    // The chosen strap
    @State private var pickedWhoop: (uuid: String, name: String, rssi: Int)?
    @State private var pickedStrap: StandardHRSource.DiscoveredStrap?

    @State private var nameDraft = ""
    @State private var askMakeActive = false

    /// Discovery-only HR source for the strap path.
    @StateObject private var hrScanner: StandardHRSource

    init(live: LiveState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _hrScanner = StateObject(wrappedValue: StandardHRSource(live: live, deviceId: "discovery", persist: { _ in }, log: { _ in }))
    }

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider().overlay(StrandPalette.surfaceInset)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .type:    typeStep
                    case .prep:    prepStep
                    case .pick:    pickStep
                    case .confirm: confirmStep
                    }
                }
                .padding(NoopMetrics.screenHPadding)
            }

            footerActions
                .padding(NoopMetrics.screenHPadding)
                .padding(.vertical, 16)
                .background(StrandPalette.surfaceBase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onDisappear { stopAllScans() }
        .confirmationDialog(
            String(localized: "Make this your active device?"),
            isPresented: $askMakeActive,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Make Active")) { registerPickedDevice(makeActive: true) }
            Button(String(localized: "Keep Current Active Device")) { registerPickedDevice(makeActive: false) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "NOOP records live metrics from your active device."))
        }
    }

    // MARK: Header & Navigation

    private var wizardHeader: some View {
        HStack {
            if step != .type {
                Button(action: goBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(spacing: 2) {
                Text("Add a Device")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let sub = stepSubtitle {
                    Text(sub)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var stepSubtitle: String? {
        switch step {
        case .type:    return "What are you adding?"
        case .prep:    return "Get it ready, then scan."
        case .pick:    return "Tap the one that's yours."
        case .confirm: return nil
        }
    }

    // MARK: Step 1 — type picker

    @ViewBuilder private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            typeRow(.whoop5mg, icon: "applewatch.side.right",
                    title: "WHOOP 5.0 / MG",
                    subtitle: String(localized: "Newer WHOOP band, supported in NOOP"))
            typeRow(.whoop4, icon: "applewatch.side.right",
                    title: "WHOOP 4.0",
                    subtitle: String(localized: "NOOP's primary, fully-supported band"))
            typeRow(.hrStrap, icon: "heart.circle",
                    title: String(localized: "Heart-rate strap"),
                    subtitle: String(localized: "Polar, Wahoo, Coospo, Garmin HRM, or other Bluetooth HR strap"))

            whoopFirstNote
        }
    }

    private func typeRow(_ t: DeviceType, icon: String, title: String, subtitle: String) -> some View {
        Button {
            type = t
            nameDraft = ""
            step = .prep
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 — prep checklist

    @ViewBuilder private var prepStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if type?.isWhoop == true {
                singleConnectionWarning
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Before you scan:").strandOverline()
                ForEach(prepItems, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(item)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 14)

            Button("Scan for devices") {
                guard let type else { return }
                startScan(for: type)
                step = .pick
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .frame(maxWidth: .infinity)
        }
    }

    private var prepItems: [String] {
        guard let type else { return [] }
        switch type {
        case .whoop4, .whoop5mg:
            return [
                String(localized: "Make sure your WHOOP is charged and on your wrist/body."),
                String(localized: "Force-quit the official WHOOP app on your phone so it doesn't hold the Bluetooth link."),
                String(localized: "Double-tap your WHOOP to make sure it's awake and advertising."),
            ]
        case .hrStrap:
            return [
                String(localized: "Put on your heart-rate strap (moisten pads if needed) so it powers on."),
                String(localized: "Make sure it isn't connected to another app (a bike computer, the brand's own app…)."),
                String(localized: "NOOP will look for it nearby."),
            ]
        }
    }

    // MARK: Step 3 — pick list

    @ViewBuilder private var pickStep: some View {
        if let type {
            if type.isWhoop {
                WhoopPickList(ble: model.ble) { strap in
                    pickedWhoop = strap
                    pickedStrap = nil
                    nameDraft = strap.name.isEmpty ? typeTitle(type) : strap.name
                    model.stopWhoopScan()
                    step = .confirm
                } onRescan: {
                    model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
                }
            } else {
                HRPickList(scanner: hrScanner) { strap in
                    pickedStrap = strap
                    pickedWhoop = nil
                    nameDraft = strap.name
                    hrScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    hrScanner.scan()
                }
            }
        }
    }

    // MARK: Step 4 — name + confirm

    @ViewBuilder private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SignalBars(rssi: confirmRSSI)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmAdvertisedName).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(confirmBrand).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)

            Text("Name").strandOverline()
            TextField("Device name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(12)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Device name")

            Button("Add") { askMakeActive = true }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .frame(maxWidth: .infinity)
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 4)
        }
    }

    // MARK: Confirm-step derived values

    private var confirmName: String {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? confirmAdvertisedName : n
    }
    private var confirmAdvertisedName: String {
        if let pickedWhoop { return pickedWhoop.name.isEmpty ? (type.map(typeTitle) ?? String(localized: "Device")) : pickedWhoop.name }
        if let pickedStrap { return pickedStrap.name }
        return type.map(typeTitle) ?? String(localized: "Device")
    }
    private var confirmBrand: String {
        if type?.isWhoop == true { return "WHOOP" }
        if let pickedStrap { return brandGuess(from: pickedStrap.name) }
        return String(localized: "Heart-rate strap")
    }
    private var confirmRSSI: Int {
        pickedWhoop?.rssi ?? pickedStrap?.rssi ?? -70
    }

    // MARK: Actions

    private func goBack() {
        switch step {
        case .type:    break
        case .prep:    step = .type
        case .pick:    stopAllScans(); step = .prep
        case .confirm:
            if let type { startScan(for: type) }
            pickedWhoop = nil; pickedStrap = nil
            step = .pick
        }
    }

    private func startScan(for t: DeviceType) {
        stopAllScans()
        if t.isWhoop {
            model.presentWhoopScan(model: t.whoopModel ?? .whoop4)
        } else if t == .hrStrap {
            hrScanner.scan()
        }
    }

    private func stopAllScans() {
        model.stopWhoopScan()
        hrScanner.stopScan()
    }

    private func registerPickedDevice(makeActive: Bool) {
        let now = Int(Date().timeIntervalSince1970)
        let name = confirmName
        let device: PairedDevice

        if let pickedWhoop {
            let modelName = type?.whoopModel?.displayName ?? "WHOOP 4.0"
            device = PairedDevice(
                id: pickedWhoop.name.isEmpty ? "whoop-\(pickedWhoop.uuid)" : pickedWhoop.name,
                brand: "WHOOP",
                model: modelName,
                nickname: name == pickedWhoop.name ? nil : name,
                peripheralId: pickedWhoop.uuid,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedStrap {
            device = PairedDevice(
                id: "strap-\(pickedStrap.id.uuidString)",
                brand: brandGuess(from: pickedStrap.name),
                model: pickedStrap.name,
                nickname: name == pickedStrap.name ? nil : name,
                peripheralId: pickedStrap.id.uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else {
            onClose(); return
        }

        model.registerDevice(device, makeActive: makeActive)
        onClose()
    }

    @ViewBuilder private var footerActions: some View {
        HStack {
            if step == .type {
                Spacer()
                Button("Cancel", action: onClose)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .buttonStyle(.plain)
            }
        }
    }

    private func typeTitle(_ t: DeviceType) -> String {
        switch t {
        case .whoop5mg: return "WHOOP 5.0 / MG"
        case .whoop4:   return "WHOOP 4.0"
        case .hrStrap:  return String(localized: "Heart-rate strap")
        }
    }

    private var singleConnectionWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your WHOOP only talks to one phone at a time.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Force-quit the official WHOOP app first, or pairing may fail.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var whoopFirstNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    private func brandGuess(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("polar") { return "Polar" }
        if lower.contains("wahoo") || lower.contains("tickr") { return "Wahoo" }
        if lower.contains("coospo") { return "Coospo" }
        if lower.contains("garmin") || lower.contains("hrm") { return "Garmin" }
        if lower.contains("scosche") || lower.contains("rhythm") { return "Scosche" }
        if lower.contains("magene") { return "Magene" }
        return String(localized: "Heart-rate strap")
    }
}

// MARK: - WHOOP pick list

private struct WhoopPickList: View {
    @ObservedObject var ble: BLEManager
    let onSelect: ((uuid: String, name: String, rssi: Int)) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: true, onRescan: onRescan)
            let found = ble.discoveredWhoops.sorted { $0.rssi > $1.rssi }
            if found.isEmpty {
                SearchingCard(whoopHint: true)
            } else {
                ForEach(found, id: \.uuid) { strap in
                    DiscoveredRow(name: strap.name.isEmpty ? "WHOOP" : strap.name,
                                  subtitle: "WHOOP",
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }
}

// MARK: - HR strap pick list

private struct HRPickList: View {
    @ObservedObject var scanner: StandardHRSource
    let onSelect: (StandardHRSource.DiscoveredStrap) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { strap in
                    DiscoveredRow(name: strap.name,
                                  subtitle: brandGuess(from: strap.name),
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }

    private func brandGuess(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("polar") { return "Polar" }
        if lower.contains("wahoo") || lower.contains("tickr") { return "Wahoo" }
        if lower.contains("coospo") { return "Coospo" }
        if lower.contains("garmin") || lower.contains("hrm") { return "Garmin" }
        if lower.contains("scosche") || lower.contains("rhythm") { return "Scosche" }
        if lower.contains("magene") { return "Magene" }
        return String(localized: "Heart-rate strap")
    }
}

// MARK: - Shared pick-step pieces

private struct ScanStatusBar: View {
    let searching: Bool
    let onRescan: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            StatePill(searching ? "Searching…" : "Idle",
                      tone: searching ? .accent : .neutral,
                      pulsing: searching)
            Spacer()
            Button("Rescan", action: onRescan)
                .font(StrandFont.subhead)
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
        }
    }
}

private struct SearchingCard: View {
    var whoopHint: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().tint(StrandPalette.accent)
            Text("Searching…")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Make sure it's awake and not connected elsewhere.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if whoopHint {
                Text("Not showing up? The official WHOOP app may still be holding it. Force-quit that app, then tap Rescan.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .frostedCardSurface(cornerRadius: 14)
    }
}

private struct DiscoveredRow: View {
    let name: String
    let subtitle: String
    let rssi: Int
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                SignalBars(rssi: rssi)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), signal \(SignalBars.level(for: rssi)) of 4")
    }
}
