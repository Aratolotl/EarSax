import AppKit
import Observation
import SwiftUI

@main
enum EarSaxLaunch {
    @MainActor static func main() {
        let application = NSApplication.shared
        let menuBarController = MenuBarController()
        application.delegate = menuBarController
        application.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no main menu
        withExtendedLifetime(menuBarController) { application.run() }
    }
}

/// The menu-bar icon and the panel it opens.
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let mixer = MixerModel()
    private let updates = UpdateChecker()
    private lazy var settingsWindow = SettingsWindow(mixer: mixer, updates: updates)
    private let panel = NSPopover()
    private var statusItem: NSStatusItem?
    /// While the panel is open, the app list refreshes every second so "playing now" stays current.
    private var refreshWhilePanelIsOpen: Timer?
    /// Closes the panel on a click in another app. `.transient` only notices clicks while EarSax is the active app, and a
    /// menu-bar app usually isn't, so clicking away left the panel open. Watching mouse
    /// clicks elsewhere needs no extra permission; key presses would.
    private var closeOnClickElsewhere: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer.start()

        updates.startAutomaticChecks()
        let hostingController = MixerPanelController(rootView: MixerPanel(mixer: mixer, updates: updates, openSettings: { [weak self] in
            self?.panel.performClose(nil)
            self?.settingsWindow.show()
        }))
        hostingController.closePanel = { [weak self] in self?.panel.performClose(nil) }
        hostingController.sizingOptions = .preferredContentSize
        panel.contentViewController = hostingController
        panel.behavior = .transient   // closes when you click anywhere else
        panel.delegate = self

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.setAccessibilityLabel("EarSax")
        self.statusItem = statusItem
        updateMenuBarIcon()
        keepMenuBarIconInSync()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.stopAllTaps()
    }

    @objc private func togglePanel() {
        if panel.isShown {
            panel.performClose(nil)
        } else if let button = statusItem?.button {
            mixer.refreshApps()
            mixer.refreshOutputDevices()
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            panel.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        refreshWhilePanelIsOpen = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mixer.refreshApps() }
        }
        if let closeOnClickElsewhere { NSEvent.removeMonitor(closeOnClickElsewhere) }   // never two (code review, finding 4)
        closeOnClickElsewhere = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        refreshWhilePanelIsOpen?.invalidate()
        refreshWhilePanelIsOpen = nil
        if let closeOnClickElsewhere { NSEvent.removeMonitor(closeOnClickElsewhere) }
        closeOnClickElsewhere = nil
    }

    /// The saxophone from the app icon, as a template image so macOS draws it white or black to match the menu bar.
    /// Dimmed while the output is muted. Without the image (a `swift run` build has no app bundle) a speaker symbol
    /// stands in, showing mute and the volume level as before.
    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        if let saxophone = NSImage(named: "MenuBarIcon") {
            saxophone.isTemplate = true
            saxophone.accessibilityDescription = "EarSax"
            button.image = saxophone
            button.appearsDisabled = mixer.isOutputMuted
            return
        }
        let symbolName: String
        switch (mixer.isOutputMuted, mixer.outputVolume) {
        case (true, _): symbolName = "speaker.slash.fill"
        case (false, let volume?) where volume < 0.01: symbolName = "speaker.fill"
        case (false, let volume?) where volume < 0.34: symbolName = "speaker.wave.1.fill"
        case (false, let volume?) where volume < 0.67: symbolName = "speaker.wave.2.fill"
        default: symbolName = "speaker.wave.3.fill"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "EarSax")
    }

    private func keepMenuBarIconInSync() {
        withObservationTracking {
            _ = mixer.isOutputMuted
            _ = mixer.outputVolume
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateMenuBarIcon()
                self?.keepMenuBarIconInSync()
            }
        }
    }
}

/// Hosts the panel and quietly swallows keys the panel doesn't use. Without it, any stray key press while the panel is open
/// reaches the end of the responder chain and macOS plays its error sound, at full alert volume.
/// Keys the panel's controls use (arrows on a focused slider, Tab) are handled by SwiftUI before they get here.
final class MixerPanelController: NSHostingController<MixerPanel> {
    var closePanel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let escapeKey: UInt16 = 53
        if event.keyCode == escapeKey { closePanel?() }
    }
}
