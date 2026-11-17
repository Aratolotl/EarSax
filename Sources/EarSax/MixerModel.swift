import CoreAudio
import Foundation
import Observation

/// Everything the panel shows, and the rules for when an app gets a tap.
@Observable @MainActor
final class MixerModel {
    // MARK: Output

    private(set) var outputDevices: [AudioDevice] = []
    private(set) var currentOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    /// 0...1, or nil when macOS can't set this device's volume.
    private(set) var outputVolume: Float?
    private(set) var isOutputMuted = false
    /// False for devices whose volume macOS can set but not mute (some USB interfaces): the mute button is hidden.
    private(set) var canMuteOutputDevice = false

    // MARK: Input

    /// Microphones and other inputs. EarSax only switches which one the Mac uses; it never reads their sound.
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var currentInputDeviceID = AudioDeviceID(kAudioObjectUnknown)

    var mainInputDevice: AudioDevice? {
        inputDevices.first { $0.id == currentInputDeviceID }
    }

    // MARK: Apps

    /// Apps shown in the panel: only those playing now, plus a 5-second grace so a row doesn't flicker between songs.
    /// A paused app leaves the list.
    /// Note: macOS reports any app holding its audio open as playing, so a silent but open app (a browser, say) still shows.
    private(set) var visibleApps: [AudioApp] = []
    private(set) var settingByApp: [String: AppVolumeSetting]
    /// Why an app's volume couldn't be changed, shown under its row.
    private(set) var tapProblemByApp: [String: String] = [:]

    /// No app is tapped until this is `.granted`; until then every app plays at its normal volume.
    private(set) var permission: SystemAudioPermission = .unknown
    /// True from the moment the user clicks Continue until they answer macOS's prompt.
    private(set) var isAskingForPermission = false
    /// The answer the user gave in this run. macOS's own check keeps returning the old answer until EarSax restarts,
    /// so a live answer wins over it.
    @ObservationIgnored private var answerGivenThisRun: SystemAudioPermission?

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let settingsStore: AppVolumeSettingsStore
    @ObservationIgnored private let tapController = TapController()
    @ObservationIgnored private var realtimeStateByApp: [String: RealtimeVolumeState] = [:]
    @ObservationIgnored private var tappedAppIDs: Set<String> = []
    @ObservationIgnored private var pendingTapRemovalByApp: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastPlayingTimeByApp: [String: ContinuousClock.Instant] = [:]
    private static let stillShownAfterStopping: Duration = .seconds(5)
    @ObservationIgnored private var tapTargetByApp: [String: TapTarget] = [:]
    @ObservationIgnored private var watchedOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    /// Devices that already have listeners, so switching back and forth doesn't stack duplicates (review finding 1).
    @ObservationIgnored private var devicesWithListeners: Set<AudioDeviceID> = []
    @ObservationIgnored private var devicesWithSampleRateListener: Set<AudioDeviceID> = []
    /// The main output's sample rate when it was last checked; 0 before the first check.
    @ObservationIgnored private var mainOutputSampleRate: Float64 = 0

    /// Which devices the lists show (Settings).
    private(set) var deviceVisibility: DeviceVisibility

    /// Default volume: when the main output changes, a louder device is turned down to `outputChangeVolumeLimit`
    /// (any change, only down, on at 75%).
    var limitsVolumeOnOutputChange: Bool {
        didSet { preferences.set(limitsVolumeOnOutputChange, forKey: "limitsVolumeOnOutputChange") }
    }
    var outputChangeVolumeLimit: Double {
        didSet { preferences.set(outputChangeVolumeLimit, forKey: "outputChangeVolumeLimit") }
    }
    @ObservationIgnored private var defaultVolumeRecheck: Task<Void, Never>?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        settingsStore = AppVolumeSettingsStore(preferences: preferences)
        settingByApp = settingsStore.load()
        deviceVisibility = DeviceVisibility.load(from: preferences)
        limitsVolumeOnOutputChange = preferences.object(forKey: "limitsVolumeOnOutputChange") as? Bool ?? true
        let savedLimit = preferences.object(forKey: "outputChangeVolumeLimit") as? Double ?? 0.75
        outputChangeVolumeLimit = savedLimit.isFinite ? min(max(savedLimit, 0.05), 1) : 0.75   // damaged: back to 75% (finding 4)
    }

    /// Reads the current state and starts listening for changes. Call once at launch.
    func start() {
        refreshOutputDevices()
        refreshInputDevices()
        refreshApps()
        whenPropertyChanges(kAudioHardwarePropertyDefaultOutputDevice, of: coreAudioSystem) { [weak self] in
            self?.outputDeviceChanged()
        }
        whenPropertyChanges(kAudioHardwarePropertyDefaultInputDevice, of: coreAudioSystem) { [weak self] in
            self?.refreshInputDevices()
        }
        whenPropertyChanges(kAudioHardwarePropertyDevices, of: coreAudioSystem) { [weak self] in
            self?.refreshOutputDevices()
            self?.refreshInputDevices()
            self?.refreshApps()
        }
        whenPropertyChanges(kAudioHardwarePropertyProcessObjectList, of: coreAudioSystem) { [weak self] in
            self?.refreshApps()
        }
        watchCurrentOutputDevice()
        rebuildTapsAfterSampleRateChange(of: nil, changedAt: .now)   // first call: only records the main output's rate
    }

    func stopAllTaps() {
        tapController.removeAllTapsBeforeQuitting()
    }

    // MARK: Refreshing

    func refreshOutputDevices() {
        outputDevices = listOutputDevices()
        currentOutputDeviceID = systemOutputDeviceID()
        refreshOutputVolume()
        watchSampleRates()
        // A "for now" output ends when its device disconnects, so it doesn't come back by surprise later. A rule does.
        let connectedDevices = Set(outputDevices.map(\.persistentID))
        endTemporaryOutputs { forNow in
            if case .device(let device) = forNow { return !connectedDevices.contains(device.persistentID) }
            return false
        }
    }

    func refreshInputDevices() {
        inputDevices = listInputDevices()
        currentInputDeviceID = systemInputDeviceID()
    }

    func refreshOutputVolume() {
        outputVolume = readOutputVolume(of: currentOutputDeviceID)
        isOutputMuted = readOutputMute(of: currentOutputDeviceID)
        canMuteOutputDevice = canMuteOutput(of: currentOutputDeviceID)
    }

    func refreshApps() {
        refreshPermission()
        let allApps = groupProcessesIntoApps(listProcessesUsingAudio(), identifyApp: identifyOwningApp)
        let now = ContinuousClock.now
        for app in allApps where app.isPlayingSound { lastPlayingTimeByApp[app.id] = now }
        visibleApps = allApps.filter { app in
            guard let lastPlaying = lastPlayingTimeByApp[app.id] else { return false }
            return now - lastPlaying < Self.stillShownAfterStopping
        }
        for app in allApps { applySetting(to: app) }
        removeTapsOfAppsThatQuit(stillRunning: Set(allApps.map(\.id)))
        moveTapsToTheirOutputs()
    }

    /// A process tap points at specific processes, so once its app has quit it holds nothing but a private device.
    /// Bundle-ID taps stay: macOS 26 re-attaches them when the app starts again (review finding 4).
    private func removeTapsOfAppsThatQuit(stillRunning runningAppIDs: Set<String>) {
        for appID in tappedAppIDs.subtracting(runningAppIDs) {
            // A bundle-ID tap of a closed app goes too once nothing needs it: its output for now ended, or its own device
            // disconnected, while the app was closed (code review of the per-app output build, finding 2).
            if case .bundleIDs = tapTargetByApp[appID], needsTap(appID) { continue }
            pendingTapRemovalByApp.removeValue(forKey: appID)?.cancel()
            tapController.removeTap(appID: appID)
            tappedAppIDs.remove(appID)
            tapTargetByApp[appID] = nil
            tapProblemByApp[appID] = nil
        }
    }

    // MARK: Per-app volume

    func setting(for appID: String) -> AppVolumeSetting {
        settingByApp[appID] ?? .untouched
    }

    func setVolumeSlider(_ position: Double, for app: AudioApp) {
        var changed = setting(for: app.id)
        // Within half a percent of the top counts as 100%, so dragging to the end really removes the tap.
        changed.volumeSlider = position >= 0.995 ? 1 : max(0, position)
        save(changed, for: app)
    }

    func toggleMute(for app: AudioApp) {
        var changed = setting(for: app.id)
        changed.isMuted.toggle()
        save(changed, for: app)
    }

    private func save(_ changed: AppVolumeSetting, for app: AudioApp) {
        // Changing an app before the permission exists used to do nothing, with only the note at the top to say why
        // (an app sent to another device seemed not to work). Now the change itself brings up
        // macOS's prompt; the setting is saved and applies the moment the user allows it.
        if permission == .notAskedYet { requestPermission() }
        settingByApp[app.id] = changed == .untouched ? nil : changed
        settingsStore.save(settingByApp)
        applySetting(to: app)
    }

    // MARK: Permission

    /// Re-reads the permission. If it was just taken away, every tap goes at once, so no app is left silenced.
    private func refreshPermission() {
        var latest = currentSystemAudioPermission()
        // The live answer only replaces a stale "not asked yet", never a real refusal, so turning the permission off later is
        // still noticed (code review, finding 2).
        if latest == .notAskedYet, let answerGivenThisRun { latest = answerGivenThisRun }
        guard latest != permission else { return }
        let couldTap = permission.allowsTaps
        permission = latest
        earSaxLog.notice("System Audio Recording permission: \(String(describing: latest))")
        if couldTap && !latest.allowsTaps { removeAllTaps() }
    }

    /// Asks macOS for the permission with a tap that captures nothing, so no app goes silent while the prompt is open
    /// (in testing, turning an app down first made it silent until the prompt was answered).
    func requestPermission() {
        guard !isAskingForPermission else { return }
        isAskingForPermission = true
        let askedDirectly = askForSystemAudioPermission { [weak self] granted in
            Task { @MainActor in self?.recordAnswer(granted ? .granted : .refused) }
        }
        guard !askedDirectly else { return }
        // Fallback: a silent probe tap makes macOS ask, but its answer can't be read until a restart, so anything short of
        // granted is shown as refused with a Restart EarSax button.
        guard let outputDevice = outputDevices.first(where: { $0.id == currentOutputDeviceID }) else {
            recordAnswer(.refused)   // no output to probe with: show the settings and restart guidance (finding 4)
            return
        }
        tapController.askForSystemAudioPermission(outputDevicePersistentID: outputDevice.persistentID) { [weak self] in
            Task { @MainActor in self?.recordAnswer(.refused) }
        }
    }

    private func recordAnswer(_ answer: SystemAudioPermission) {
        answerGivenThisRun = answer
        isAskingForPermission = false
        earSaxLog.notice("Permission prompt answered: \(String(describing: answer))")
        refreshApps()
    }

    private func removeAllTaps() {
        for pending in pendingTapRemovalByApp.values { pending.cancel() }
        pendingTapRemovalByApp.removeAll()
        tapController.removeAllTaps()
        tappedAppIDs.removeAll()
        tapTargetByApp.removeAll()
        tapProblemByApp.removeAll()
    }

    /// The tap rule: an app gets a tap only while it's turned down, muted, or playing on a device of its own. When none of
    /// those holds any more, the tap is removed after 3 seconds, so dragging across 100% doesn't rebuild the tap over and over.
    private func needsTap(_ appID: String) -> Bool {
        let appSetting = setting(for: appID)
        // An app on a device of its own needs its tap even at 100%; without the permission nothing is tapped.
        if appSetting.playsOnItsOwnDevice(connectedDevices: Set(outputDevices.map(\.persistentID))) { return permission.allowsTaps }
        return shouldTap(appSetting, permission: permission)
    }

    private func applySetting(to app: AudioApp) {
        if needsTap(app.id) {
            pendingTapRemovalByApp.removeValue(forKey: app.id)?.cancel()
            let realtimeState = realtimeState(for: app.id)
            realtimeState.setTargetVolumeMultiplier(setting(for: app.id).volumeMultiplier)
            guard let playsOnDevice = outputDevicePersistentID(for: app.id) else { return }
            tapController.ensureTap(appID: app.id, target: app.tapTarget, realtimeState: realtimeState,
                                    outputDevicePersistentID: playsOnDevice,
                                    reportProblem: problemReporter(for: app.id))
            tappedAppIDs.insert(app.id)
            tapTargetByApp[app.id] = app.tapTarget
        } else if tappedAppIDs.contains(app.id), pendingTapRemovalByApp[app.id] == nil {
            realtimeStateByApp[app.id]?.setTargetVolumeMultiplier(1)   // full volume right away; the tap goes a moment later
            pendingTapRemovalByApp[app.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                pendingTapRemovalByApp[app.id] = nil
                guard !needsTap(app.id) else { return }
                tapController.removeTap(appID: app.id)
                tappedAppIDs.remove(app.id)
                tapTargetByApp[app.id] = nil
                tapProblemByApp[app.id] = nil
            }
        }
    }

    private func realtimeState(for appID: String) -> RealtimeVolumeState {
        if let existing = realtimeStateByApp[appID] { return existing }
        let created = RealtimeVolumeState()
        realtimeStateByApp[appID] = created
        return created
    }

    private func problemReporter(for appID: String) -> TapController.ProblemReport {
        { [weak self] problem in
            Task { @MainActor in
                // A late failure for an app already back at 100% isn't a problem worth showing (review finding 3).
                guard let self, problem == nil || self.needsTap(appID) else { return }
                self.tapProblemByApp[appID] = problem
            }
        }
    }

    // MARK: Per-app output

    /// The Mac's current output: where every app plays unless it has a device of its own.
    var mainOutputDevice: AudioDevice? {
        outputDevices.first { $0.id == currentOutputDeviceID }
    }

    /// The device an app plays on now: its own while that's connected, otherwise the main output.
    func outputDevice(for appID: String) -> AudioDevice? {
        guard let persistentID = outputDevicePersistentID(for: appID) else { return nil }
        return outputDevices.first { $0.persistentID == persistentID }
    }

    func isConnected(_ device: SavedDevice) -> Bool {
        outputDevices.contains { $0.persistentID == device.persistentID }
    }

    /// The device an app plays on instead of the main output, or nil when it plays on the main output.
    func ownOutput(for appID: String) -> SavedDevice? {
        setting(for: appID).ownOutput(connectedDevices: Set(outputDevices.map(\.persistentID)))
    }

    /// A pick in the app's device list: play there for now; a pinned device stays pinned. nil = "Same as everything else".
    func playForNow(on device: AudioDevice?, for app: AudioApp) {
        var changed = setting(for: app.id)
        changed.playForNow(on: device.map { SavedDevice(persistentID: $0.persistentID, name: $0.name) })
        // The user's clicks are logged too, so a QA log shows what was clicked and not only what moved.
        earSaxLog.notice("\(app.id): picked \(device?.name ?? "Same as everything else") in its device list")
        save(changed, for: app)
        moveTapsToTheirOutputs()
    }

    /// The pin next to a device in the app's list.
    func togglePin(_ device: SavedDevice, for app: AudioApp) {
        var changed = setting(for: app.id)
        changed.togglePin(device, isConnected: isConnected(device))
        earSaxLog.notice("\(app.id): \(changed.alwaysOn == nil ? "unpinned" : "pinned") \(device.name)")
        save(changed, for: app)
        moveTapsToTheirOutputs()
    }

    private func outputDevicePersistentID(for appID: String) -> String? {
        guard let mainOutput = mainOutputDevice else { return nil }
        return setting(for: appID).outputDevicePersistentID(mainOutput: mainOutput.persistentID,
                                                            connectedDevices: Set(outputDevices.map(\.persistentID)))
    }

    /// Ends the "for now" choices that match; pinned devices stay.
    private func endTemporaryOutputs(where shouldEnd: (OutputForNow) -> Bool) {
        var didChange = false
        for (appID, var changed) in settingByApp {
            guard let forNow = changed.forNow, shouldEnd(forNow) else { continue }
            changed.forNow = nil
            settingByApp[appID] = changed == .untouched ? nil : changed
            didChange = true
        }
        if didChange { settingsStore.save(settingByApp) }
    }

    /// Keeps every tap playing where its app should. Covers tapped apps that aren't running: their taps wait for them.
    private func moveTapsToTheirOutputs() {
        for appID in tappedAppIDs {
            guard let playsOnDevice = outputDevicePersistentID(for: appID) else { continue }
            tapController.moveTap(appID: appID, toOutputDevice: playsOnDevice)
        }
    }

    // MARK: Default volume

    /// Turns the new main output down to the default if it's louder. Bluetooth devices often restore their own volume a
    /// moment after they connect, so it's checked once more 1.5 s later.
    /// The 1.5 s re-check is cancelled by the next output change and by the panel's volume slider, so it never undoes a
    /// volume the user just chose (code review of Settings, finding 1).
    private func applyDefaultVolumeAfterOutputChange() {
        defaultVolumeRecheck?.cancel()
        let device = currentOutputDeviceID
        capVolume(of: device)
        defaultVolumeRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, currentOutputDeviceID == device else { return }
            capVolume(of: device)
        }
    }

    private func capVolume(of device: AudioDeviceID) {
        guard limitsVolumeOnOutputChange, turnOutputDown(of: device, toAtMost: outputChangeVolumeLimit) else { return }
        earSaxLog.notice("Turned \(mainOutputDevice?.name ?? "the output") down to \(Int((outputChangeVolumeLimit * 100).rounded()))% (default volume)")
        refreshOutputVolume()
    }

    // MARK: Hidden devices

    var devicesForPlayEverythingOn: [AudioDevice] {
        deviceVisibility.listedForMainMenu(outputDevices, current: currentOutputDeviceID)
    }

    var devicesForSoundInput: [AudioDevice] {
        deviceVisibility.listedForMainMenu(inputDevices, current: currentInputDeviceID)
    }

    func devicesForAppList(_ appID: String) -> [AudioDevice] {
        deviceVisibility.listedForApp(outputDevices, setting: setting(for: appID))
    }

    var devicesForSettings: [SettingsDeviceRow] {
        deviceVisibility.settingsRows(outputs: outputDevices, inputs: inputDevices)
    }

    func setShown(_ isShown: Bool, persistentID: String, name: String) {
        deviceVisibility.choiceByDevice[persistentID] = DeviceVisibility.Choice(isShown: isShown, name: name)
        deviceVisibility.save(to: preferences)
        earSaxLog.notice("\(isShown ? "Showing" : "Hiding") \(name) in EarSax's lists")
    }

    // MARK: Output actions

    /// "Play everything on": the Mac's output changes and every app follows, except apps with an "always" rule.
    func selectOutputDevice(_ device: AudioDevice) {
        earSaxLog.notice("Picked \(device.name) under Play everything on")
        endTemporaryOutputs { _ in true }
        // A switch sends a change notification, which refreshes the panel and moves the taps. Picking the current device, or
        // a switch macOS refused, sends none, so the apps that just lost their own output are moved here.
        if device.id == currentOutputDeviceID || !makeSystemOutputDevice(device.id) { refreshApps() }
    }

    /// "Sound input": the Mac's input changes for every app. No tap is involved. A refused switch sends no change
    /// notification, so the list is re-read to keep the checkmark honest.
    func selectInputDevice(_ device: AudioDevice) {
        earSaxLog.notice("Picked \(device.name) under Sound input")
        if !makeSystemInputDevice(device.id) { refreshInputDevices() }
    }

    func setOutputVolume(_ volume: Float) {
        defaultVolumeRecheck?.cancel()
        writeOutputVolume(volume, to: currentOutputDeviceID)
        outputVolume = volume
        if volume > 0, isOutputMuted { toggleOutputMute() }
    }

    func toggleOutputMute() {
        guard canMuteOutput(of: currentOutputDeviceID) else { return }
        writeOutputMute(!isOutputMuted, to: currentOutputDeviceID)
        refreshOutputVolume()
    }

    // MARK: Following the output device

    private func outputDeviceChanged() {
        let changedAt = ContinuousClock.now
        refreshOutputDevices()
        watchCurrentOutputDevice()
        earSaxLog.notice("Main output is now \(mainOutputDevice?.name ?? "unknown")")
        applyDefaultVolumeAfterOutputChange()
        // Moves the taps of apps that follow the main output, and re-applies every saved setting, so a tap that failed to
        // rebuild gets another try (review finding 2).
        refreshApps()
        rebuildTapsAfterSampleRateChange(of: nil, changedAt: changedAt)
    }

    /// Rebuilds the taps a sample-rate change affects, each once:
    /// - the taps playing on `changedDevicePersistentID`, the device whose rate changed (nil when none did);
    /// - when the main output's rate is no longer what it was (another main device, or the same one changing rate), the
    ///   taps of apps on a device of their own. An app's sound is captured at the main output's rate, because that's where
    ///   the app itself plays, and those taps didn't move with the main output (code review of the per-app output build, finding 1).
    /// At an unchanged rate a tap on its own device is left alone: no dropout for that app when the main output moves.
    /// Taps built at or after `changedAt` already run at the new rate and are skipped (see TapController.rebuildTaps).
    private func rebuildTapsAfterSampleRateChange(of changedDevicePersistentID: String?, changedAt: ContinuousClock.Instant) {
        let sampleRate = readProperty(kAudioDevicePropertyNominalSampleRate, of: currentOutputDeviceID, orDefault: Float64(0))
        let mainRateChanged = mainOutputSampleRate > 0 && abs(sampleRate - mainOutputSampleRate) >= 1
        mainOutputSampleRate = sampleRate
        let connectedDevices = Set(outputDevices.map(\.persistentID))
        let appsOnTheirOwnDevice = mainRateChanged
            ? tappedAppIDs.filter { setting(for: $0).playsOnItsOwnDevice(connectedDevices: connectedDevices) }
            : []
        guard changedDevicePersistentID != nil || !appsOnTheirOwnDevice.isEmpty else { return }
        earSaxLog.notice("Sample rate changed (device: \(changedDevicePersistentID ?? "none"), main output now \(sampleRate)): rebuilding the affected taps")
        tapController.rebuildTaps(changedAt: changedAt) { appID, outputDevicePersistentID in
            outputDevicePersistentID == changedDevicePersistentID || appsOnTheirOwnDevice.contains(appID)
        }
    }

    /// A tap can play on any device, so every device's sample rate is watched, not only the main output's.
    /// ponytail: listeners are never removed (see whenPropertyChanges); a device that reconnects is a new object and gets its own.
    private func watchSampleRates() {
        for device in outputDevices where devicesWithSampleRateListener.insert(device.id).inserted {
            whenPropertyChanges(kAudioDevicePropertyNominalSampleRate, of: device.id) { [weak self] in
                let changedAt = ContinuousClock.now
                guard let self, let changed = outputDevices.first(where: { $0.id == device.id }) else { return }
                rebuildTapsAfterSampleRateChange(of: changed.persistentID, changedAt: changedAt)
            }
        }
    }

    /// Listens to the current device's volume and mute. Listeners on earlier devices stay but are ignored.
    private func watchCurrentOutputDevice() {
        let device = currentOutputDeviceID
        watchedOutputDeviceID = device
        guard devicesWithListeners.insert(device).inserted else { return }
        let volumeElements = [kAudioObjectPropertyElementMain, 1, 2]
        for element in volumeElements {
            whenPropertyChanges(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput, element: element) { [weak self] in
                guard let self, device == watchedOutputDeviceID else { return }
                refreshOutputVolume()
            }
        }
        whenPropertyChanges(kAudioDevicePropertyMute, of: device, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
            guard let self, device == watchedOutputDeviceID else { return }
            refreshOutputVolume()
        }
    }
}
