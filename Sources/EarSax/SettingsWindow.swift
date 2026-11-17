import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window: "Open at login" and which devices EarSax lists, so hidden devices keep the lists uncluttered.
/// Opened from the panel's footer.
struct SettingsView: View {
    @Bindable var mixer: MixerModel
    @Bindable var updates: UpdateChecker
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
            }
            Section {
                Toggle("Turn the main volume down when the output changes", isOn: $mixer.limitsVolumeOnOutputChange)
                HStack {
                    Slider(value: $mixer.outputChangeVolumeLimit, in: 0.05...1)
                        .accessibilityLabel("Default volume")
                    Text("\(Int((mixer.outputChangeVolumeLimit * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!mixer.limitsVolumeOnOutputChange)
            } header: {
                Text("Default main volume")
            } footer: {
                Text("This is the device's own volume, the slider at the top of EarSax's panel. When the Mac's output changes, a device louder than this is turned down to it. App volumes don't change, and EarSax never turns a device up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(mixer.devicesForSettings) { row in
                    Toggle(isOn: Binding(get: { row.isShown },
                                         set: { mixer.setShown($0, persistentID: row.persistentID, name: row.name) })) {
                        Label(row.isConnected ? row.name : "\(row.name), not connected", systemImage: row.symbolName)
                            .foregroundStyle(row.isConnected ? .primary : .secondary)
                    }
                }
            } header: {
                Text("Show in EarSax's lists")
            } footer: {
                Text("Hiding a device only removes it from EarSax's lists, for sound output and input alike. Anything already using it keeps using it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: updates.currentVersion)
                HStack {
                    Button("Check for Updates") { Task { await updates.check() } }
                        .disabled(updates.status == .checking)
                    UpdateStatusText(status: updates.status)
                }
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                Link(destination: UpdateChecker.releasesPage) {
                    Label("EarSax on GitHub", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://ko-fi.com/aratolotl")!) {
                    Label { Text("Donate on Ko-fi") } icon: { KoFiCup() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 360)   // the form scrolls in a shorter window (code review of Settings, finding 6)
        // The window is reused, so re-read the login item each time it comes forward; it can be changed in System
        // Settings meanwhile (finding 2).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setOpensAtLogin(_ shouldOpen: Bool) {
        do {
            if shouldOpen { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            earSaxLog.error("Open at login change failed: \(String(describing: error))")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct UpdateStatusText: View {
    let status: UpdateChecker.Status

    var body: some View {
        switch status {
        case .notChecked: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("EarSax is up to date.").foregroundStyle(.secondary)
        case .available(let version, let downloadPage):
            Link("EarSax \(version) is available: Download", destination: downloadPage)
        case .failed(let reason): Text(reason).foregroundStyle(.secondary)
        }
    }
}

/// Ko-fi's cup, from Ko-fi's creator kit (more.ko-fi.com/brand-assets, which allows using the cups to
/// promote your page), shipped in the app bundle. A plain cup symbol stands in when it's missing (tests, swift run).
struct KoFiCup: View {
    var body: some View {
        if let cup = NSImage(named: "kofi-cup") {
            Image(nsImage: cup).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
        } else {
            Image(systemName: "cup.and.saucer.fill").accessibilityHidden(true)
        }
    }
}

/// One Settings window, created on first use and reused after.
@MainActor
final class SettingsWindow {
    private let mixer: MixerModel
    private let updates: UpdateChecker
    private var window: NSWindow?

    init(mixer: MixerModel, updates: UpdateChecker) {
        self.mixer = mixer
        self.updates = updates
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(mixer: mixer, updates: updates))
            let created = NSWindow(contentViewController: hosting)
            created.title = "EarSax Settings"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            window = created
        }
        // Tall enough for everything, so there's no scrollbar. Only a screen too short for it gets a scrolling window.
        // Re-measured on every open, since the device list changes.
        window?.setContentSize(fittingSize())
        if window?.isVisible == false { window?.center() }
        // A menu-bar app isn't the active app, so bring EarSax forward or the window opens behind everything.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func fittingSize() -> NSSize {
        let measuring = NSHostingView(rootView: SettingsView(mixer: mixer, updates: updates).fixedSize(horizontal: false, vertical: true))
        let available = ((window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 60
        return NSSize(width: 420, height: min(measuring.fittingSize.height, available))
    }
}
