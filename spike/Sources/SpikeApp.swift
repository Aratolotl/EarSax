import AppKit
import CoreAudio
import SwiftUI

// Launch options for runs with no clicks (pass after `open … --args`):
//   -autotap <text>   tap the first app whose bundle ID or name contains <text>
//   -gain <0...1>     slider position for that auto tap (default 1)
//   -bundletap YES    use macOS 26 tap-by-bundle-ID mode (CATapDescription.bundleIDs + isProcessRestoreEnabled)
//   -quitafter <s>    quit cleanly after <s> seconds

/// One row in the window: an app plus every process it uses for audio (helpers included).
struct AudioApp: Identifiable {
    let id: String               // bundle ID of the app that owns the processes, or "pid:N" for bundle-less tools
    let name: String
    let icon: NSImage?
    var processes: [ProcessUsingAudio]
    var isPlayingSound: Bool { processes.contains { $0.isPlayingSound } }
    var processSummary: String {
        processes.map { "\($0.bundleID.isEmpty ? "?" : $0.bundleID) [\($0.processID)]\($0.isPlayingSound ? " ▶︎" : "")" }
            .joined(separator: ", ")
    }
}

@Observable @MainActor
final class MixerModel {
    var apps: [AudioApp] = []
    var volumeSliderByApp: [String: Double] = [:]
    var isMutedByApp: [String: Bool] = [:]
    var soundLevelByApp: [String: Float] = [:]
    var tapDiagnosticsByApp: [String: String] = [:]
    var tapErrorByApp: [String: String] = [:]
    var outputDeviceDescription = ""
    var permissionStatus = ""
    var useBundleIDTaps = UserDefaults.standard.bool(forKey: "bundletap")
    private(set) var activeTapByApp: [String: AppVolumeTap] = [:]
    private var audioCycleCountAtLastCheck: [String: UInt64] = [:]
    private var lastLoggedAppList = ""
    private var autoTapSearchText = UserDefaults.standard.string(forKey: "autotap")
    private var meterUpdateCount = 0

    init() {
        writeToSpikeLog("LAUNCH pid \(getpid()) bundle \(Bundle.main.bundleIdentifier ?? "?") "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) "
            + "sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) "
            + "bundleIDTaps=\(useBundleIDTaps) log=\(spikeLogFile.path)")
        refreshAppList()
        whenCoreAudioPropertyChanges(kAudioHardwarePropertyDefaultOutputDevice, of: coreAudioSystem) {
            $0.rebuildTapsAfterOutputChange(reason: "default output device changed")
        }
        whenCoreAudioPropertyChanges(kAudioHardwarePropertyDevices, of: coreAudioSystem) { _ in
            writeToSpikeLog("EVENT device list changed: \(Self.describeAllDevices())")
        }
        watchCurrentOutputDevice()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.stopAllTaps(reason: "app quitting") }
        }
        for sleepOrWake in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: sleepOrWake, object: nil, queue: .main) {
                writeToSpikeLog("EVENT \($0.name.rawValue)")
            }
        }
        let quitAfterSeconds = UserDefaults.standard.double(forKey: "quitafter")
        if quitAfterSeconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfterSeconds) { NSApp.terminate(nil) }
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { self.updateLevelMetersAndHealth() }
        }
    }

    // MARK: Every 0.1 s: level meters. Every 1 s: app list and health stats.

    private func updateLevelMetersAndHealth() {
        for (appID, tap) in activeTapByApp {
            soundLevelByApp[appID] = Float(bitPattern: tap.realtimeState.loudestSampleSinceLastRead.exchange(0, ordering: .relaxed))
        }
        meterUpdateCount += 1
        guard meterUpdateCount % 10 == 0 else { return }
        refreshAppList()
        for (appID, tap) in activeTapByApp {
            let audioCycles = tap.realtimeState.audioCycleCount.load(ordering: .relaxed)
            let cyclesWithSound = tap.realtimeState.audioCyclesWithSound.load(ordering: .relaxed)
            let isPlayingSound = apps.first { $0.id == appID }?.isPlayingSound ?? false
            // A silent app gets no audio cycles at all (Core Audio pauses the tap), so only a playing app can stall.
            if isPlayingSound && audioCycles == audioCycleCountAtLastCheck[appID] {
                writeToSpikeLog("STALL \(appID): app is playing but no audio cycle ran in the last second")
            }
            audioCycleCountAtLastCheck[appID] = audioCycles
            let slider = volumeSliderByApp[appID] ?? 1
            writeToSpikeLog("STAT \(appID) audioCycles=\(audioCycles) cyclesWithSound=\(cyclesWithSound) "
                + "level=\(String(format: "%.3f", soundLevelByApp[appID] ?? 0)) "
                + "slider=\(String(format: "%.2f", slider)) volume=\(String(format: "%.2f", slider * slider)) "
                + "muted=\(isMutedByApp[appID] ?? false) appPlaying=\(isPlayingSound)")
        }
    }

    func refreshAppList() {
        permissionStatus = systemAudioRecordingPermission()
        outputDeviceDescription = "\(displayName(of: currentOutputDevice)) [\(connectionType(of: currentOutputDevice))]"
        let ourProcessID = getpid()
        var appsByID: [String: AudioApp] = [:]
        for process in listProcessesUsingAudio() where process.processID != ourProcessID {
            let owningApp = NSRunningApplication(processIdentifier: owningAppProcessID(of: process.processID) ?? process.processID)
            let appID = owningApp?.bundleIdentifier ?? (process.bundleID.isEmpty ? "pid:\(process.processID)" : process.bundleID)
            let appName = owningApp?.localizedName ?? (process.bundleID.isEmpty ? executableName(of: process.processID) : process.bundleID)
            appsByID[appID, default: AudioApp(id: appID, name: appName, icon: owningApp?.icon, processes: [])].processes.append(process)
        }
        let updatedApps = appsByID.values.sorted {
            ($0.isPlayingSound ? 0 : 1, $0.name) < ($1.isPlayingSound ? 0 : 1, $1.name)
        }

        let appListForLog = updatedApps.map { "\($0.id) <- \($0.processSummary)" }.joined(separator: " | ")
        if appListForLog != lastLoggedAppList { writeToSpikeLog("GROUPS \(appListForLog)"); lastLoggedAppList = appListForLog }

        // In process mode, a tapped app that starts or stops a helper needs its tap pointed at the new process list.
        for app in updatedApps {
            guard let tap = activeTapByApp[app.id], !useBundleIDTaps,
                  let previous = apps.first(where: { $0.id == app.id }),
                  Set(previous.processes.map(\.coreAudioID)) != Set(app.processes.map(\.coreAudioID)) else { continue }
            let status = tap.retarget(toProcesses: app.processes.map(\.coreAudioID))
            writeToSpikeLog("MEMBERSHIP \(app.id) now \(app.processSummary); live tap update status \(status) (\(readableStatus(status)))")
        }
        apps = updatedApps

        if let searchText = autoTapSearchText?.lowercased(),
           let match = apps.first(where: { $0.id.lowercased().contains(searchText) || $0.name.lowercased().contains(searchText) }) {
            autoTapSearchText = nil
            volumeSliderByApp[match.id] = UserDefaults.standard.object(forKey: "gain") == nil ? 1 : UserDefaults.standard.double(forKey: "gain")
            writeToSpikeLog("AUTOTAP \(match.id) slider \(volumeSliderByApp[match.id]!)")
            setVolumeControl(for: match, enabled: true)
        }
    }

    // MARK: Taps

    /// Turns per-app volume control on (creates a tap) or off (removes it, so the app plays normally again).
    func setVolumeControl(for app: AudioApp, enabled: Bool) {
        guard enabled else {
            activeTapByApp.removeValue(forKey: app.id)?.stop()
            tapDiagnosticsByApp[app.id] = nil
            return
        }
        do {
            let tap = try AppVolumeTap(
                appID: app.id,
                processes: app.processes.map(\.coreAudioID),
                bundleIDs: useBundleIDTaps ? Array(Set(app.processes.map(\.bundleID))).filter { !$0.isEmpty } : nil,
                outputDevice: currentOutputDevice)
            activeTapByApp[app.id] = tap
            tapDiagnosticsByApp[app.id] = tap.diagnostics
            tapErrorByApp[app.id] = nil
            sendVolumeToTap(appID: app.id)
        } catch {
            tapErrorByApp[app.id] = "\(error)"
            writeToSpikeLog("TAP ERROR \(app.id): \(error)")
        }
    }

    func sendVolumeToTap(appID: String) {
        guard let tap = activeTapByApp[appID] else { return }
        let slider = volumeSliderByApp[appID] ?? 1
        // ponytail: slider² approximates how loud people expect each slider position to sound; the real curve is a Phase 1 choice.
        tap.realtimeState.targetVolumeMultiplier.store(Float(slider * slider).bitPattern, ordering: .relaxed)
        tap.realtimeState.isMuted.store(isMutedByApp[appID] ?? false, ordering: .relaxed)
    }

    private func stopAllTaps(reason: String) {
        writeToSpikeLog("STOP ALL: \(reason)")
        for tap in activeTapByApp.values { tap.stop() }
        activeTapByApp.removeAll()
    }

    /// Rebuilds every tap on the current output device (device switched, sample rate changed, device disappeared).
    private func rebuildTapsAfterOutputChange(reason: String) {
        writeToSpikeLog("EVENT \(reason) -> \(displayName(of: currentOutputDevice)) [\(connectionType(of: currentOutputDevice))]")
        watchCurrentOutputDevice()
        for appID in Array(activeTapByApp.keys) {
            activeTapByApp.removeValue(forKey: appID)?.stop()
            if let app = apps.first(where: { $0.id == appID }) { setVolumeControl(for: app, enabled: true) }
        }
        refreshAppList()
    }

    // MARK: Core Audio change notifications

    private var watchedOutputDevice = AudioDeviceID(kAudioObjectUnknown)

    private func watchCurrentOutputDevice() {
        let device = currentOutputDevice
        guard device != watchedOutputDevice else { return }
        watchedOutputDevice = device
        whenCoreAudioPropertyChanges(kAudioDevicePropertyNominalSampleRate, of: device) { model in
            guard device == model.watchedOutputDevice else { return }
            model.rebuildTapsAfterOutputChange(reason: "output sample rate changed")
        }
        whenCoreAudioPropertyChanges(kAudioDevicePropertyDeviceIsAlive, of: device) { model in
            guard device == model.watchedOutputDevice else { return }
            writeToSpikeLog("EVENT output device alive=\(readProperty(kAudioDevicePropertyDeviceIsAlive, of: device, orDefault: UInt32(0)))")
        }
    }

    // ponytail: these listeners are never removed; a spike runs for minutes, not days.
    private func whenCoreAudioPropertyChanges(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                                              run action: @escaping @MainActor (MixerModel) -> Void) {
        var address = propertyAddress(property)
        AudioObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
    }

    private static func describeAllDevices() -> String {
        readPropertyList(kAudioHardwarePropertyDevices, of: coreAudioSystem, elementType: AudioDeviceID.self)
            .map { "\(displayName(of: $0)) [\(connectionType(of: $0))]" }.joined(separator: ", ")
    }
}

// MARK: - Window

@main
struct SpikeApp: App {
    @State private var mixer = MixerModel()
    var body: some Scene {
        WindowGroup("EarSax Spike") { MixerWindow(mixer: mixer).frame(minWidth: 760, minHeight: 420) }
    }
}

struct MixerWindow: View {
    @Bindable var mixer: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, verticalSpacing: 4) {
                GridRow { Text("Output").foregroundStyle(.secondary); Text(mixer.outputDeviceDescription) }
                GridRow { Text("Permission").foregroundStyle(.secondary); Text(mixer.permissionStatus) }
                GridRow {
                    Text("Log").foregroundStyle(.secondary)
                    Button(spikeLogFile.path) { NSWorkspace.shared.open(spikeLogFile) }.buttonStyle(.link)
                }
            }
            Toggle("Tap by bundle ID (macOS 26 API, applies to new taps)", isOn: $mixer.useBundleIDTaps)
            Divider()
            List(mixer.apps) { app in AppRow(app: app, mixer: mixer) }
        }
        .padding()
    }
}

struct AppRow: View {
    let app: AudioApp
    let mixer: MixerModel

    var body: some View {
        let hasVolumeControl = mixer.activeTapByApp[app.id] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                VStack(alignment: .leading) {
                    Text(app.name).font(.headline)
                    Text(app.processSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Circle().fill(app.isPlayingSound ? .green : .gray.opacity(0.3)).frame(width: 8, height: 8)
                Toggle("Tap", isOn: Binding(get: { hasVolumeControl },
                                            set: { mixer.setVolumeControl(for: app, enabled: $0) }))
                    .toggleStyle(.switch)
            }
            if hasVolumeControl {
                HStack {
                    Slider(value: Binding(get: { mixer.volumeSliderByApp[app.id] ?? 1 },
                                          set: { mixer.volumeSliderByApp[app.id] = $0; mixer.sendVolumeToTap(appID: app.id) }),
                           in: 0...1)
                    Toggle("Mute", isOn: Binding(get: { mixer.isMutedByApp[app.id] ?? false },
                                                 set: { mixer.isMutedByApp[app.id] = $0; mixer.sendVolumeToTap(appID: app.id) }))
                    ProgressView(value: Double(min(mixer.soundLevelByApp[app.id] ?? 0, 1))).frame(width: 120)
                }
                Text(mixer.tapDiagnosticsByApp[app.id] ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let error = mixer.tapErrorByApp[app.id] { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }
}
