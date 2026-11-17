import CoreAudio
import Foundation
import Testing
@testable import EarSax

// The checks from the Phase 1 design, section 5 (automated part).

// MARK: - Grouping processes into apps

private func process(_ id: AudioObjectID, _ bundleID: String, playing: Bool = false) -> ProcessUsingAudio {
    ProcessUsingAudio(coreAudioID: id, processID: pid_t(id), bundleID: bundleID, isPlayingSound: playing)
}

private let browser = AppIdentity(bundleID: "com.example.browser", name: "Browser", bundleURL: nil)
private let safari = AppIdentity(bundleID: "com.apple.Safari", name: "Safari", bundleURL: nil)

@Test func helperProcessesMergeIntoTheirApp() {
    let processes = [process(1, "com.example.browser"), process(2, "com.example.browser.helper", playing: true),
                     process(3, "com.apple.audiomxd")]
    let apps = groupProcessesIntoApps(processes) { candidate in
        candidate.bundleID.hasPrefix("com.example.browser") ? browser : nil   // audiomxd is a system process: not an app
    }
    #expect(apps.count == 1)
    #expect(apps[0].id == "com.example.browser")
    #expect(apps[0].processes.count == 2)
    #expect(apps[0].isPlayingSound)
}

@Test func twoCopiesOfTheSameAppAreOneRow() {
    // Same bundle ID installed in two places: one row, one setting (review finding 8).
    let installed = AppIdentity(bundleID: "com.example.music", name: "Music", bundleURL: URL(fileURLWithPath: "/Applications/Music.app"))
    let copy = AppIdentity(bundleID: "com.example.music", name: "Music", bundleURL: URL(fileURLWithPath: "/Users/me/Music.app"))
    let apps = groupProcessesIntoApps([process(1, "com.example.music"), process(2, "com.example.music")]) { $0.coreAudioID == 1 ? installed : copy }
    #expect(apps.count == 1)
    #expect(apps[0].processes.count == 2)
}

@Test func appsStayInNameOrderWhetherPlayingOrNot() {
    // Playing or paused must not change a row's place, or the list reshuffles.
    let identify: (ProcessUsingAudio) -> AppIdentity? = { $0.bundleID == "com.apple.Safari" ? safari : browser }
    let safariPlaying = groupProcessesIntoApps([process(1, "com.apple.Safari", playing: true), process(2, "com.example.browser")], identifyApp: identify)
    let browserPlaying = groupProcessesIntoApps([process(1, "com.apple.Safari"), process(2, "com.example.browser", playing: true)], identifyApp: identify)
    #expect(safariPlaying.map(\.name) == ["Browser", "Safari"])
    #expect(browserPlaying.map(\.name) == ["Browser", "Safari"])
}

// MARK: - Bundle-ID tap or process tap

@Test func appWithOwnHelpersIsTappedByBundleID() {
    let target = chooseTapTarget(appBundleID: "com.example.browser",
                                 processes: [process(1, "com.example.browser"), process(2, "com.example.browser.helper")])
    #expect(target == .bundleIDs(["com.example.browser", "com.example.browser.helper"]))
}

@Test func safariIsTappedByProcessBecauseWebKitIsShared() {
    // Tapping "com.apple.WebKit.GPU" by bundle ID would also capture every other app that shows web content.
    let target = chooseTapTarget(appBundleID: "com.apple.Safari", processes: [process(7, "com.apple.WebKit.GPU")])
    #expect(target == .processes([7]))
}

// MARK: - The tap rule and the volume curve

@Test func onlyChangedAppsNeedATap() {
    #expect(AppVolumeSetting.untouched.needsTap == false)
    #expect(AppVolumeSetting(volumeSlider: 0.5).needsTap)
    #expect(AppVolumeSetting(volumeSlider: 1, isMuted: true).needsTap)
}

@Test func volumeCurveEndpoints() {
    #expect(AppVolumeSetting(volumeSlider: 0).volumeMultiplier == 0)
    #expect(AppVolumeSetting(volumeSlider: 1).volumeMultiplier == 1)
    #expect(AppVolumeSetting(volumeSlider: 0.5).volumeMultiplier == 0.25)
    #expect(AppVolumeSetting(volumeSlider: 0.8, isMuted: true).volumeMultiplier == 0)
}

@Test func noTapWithoutThePermission() {
    // A tap made without the permission silences the app. Turned down or not, no permission
    // means no tap, so the app keeps playing at its normal volume.
    let turnedDown = AppVolumeSetting(volumeSlider: 0.3)
    #expect(shouldTap(turnedDown, permission: .granted))
    #expect(!shouldTap(turnedDown, permission: .refused))
    #expect(!shouldTap(turnedDown, permission: .notAskedYet))
    #expect(!shouldTap(.untouched, permission: .granted))
}

// MARK: - Saved settings

@Test func settingsSurviveSaveAndReload() throws {
    let preferences = try #require(UserDefaults(suiteName: "EarSaxTests-\(UUID().uuidString)"))
    let store = AppVolumeSettingsStore(preferences: preferences)
    store.save(["com.example.music": AppVolumeSetting(volumeSlider: 0.3),
                "com.apple.Safari": .untouched])                                  // untouched apps aren't stored
    let reloaded = AppVolumeSettingsStore(preferences: preferences).load()
    #expect(reloaded == ["com.example.music": AppVolumeSetting(volumeSlider: 0.3)])
}

@Test func damagedSavedVolumesAreMadeSafe() throws {
    let preferences = try #require(UserDefaults(suiteName: "EarSaxTests-\(UUID().uuidString)"))
    preferences.set(#"{"a":{"volumeSlider":7,"isMuted":false},"b":{"volumeSlider":-2,"isMuted":false}}"#, forKey: "appVolumeSettings")
    let loaded = AppVolumeSettingsStore(preferences: preferences).load()
    #expect(loaded["a"]?.volumeSlider == 1)
    #expect(loaded["b"]?.volumeSlider == 0)
}

// MARK: - Per-app output

private let display = SavedDevice(persistentID: "display", name: "Studio Display")
private let speaker = SavedDevice(persistentID: "speaker", name: "Bluetooth Speaker")
private let everything: Set<String> = ["laptop", "display", "speaker"]

@Test func anAppPlaysOnItsOwnDeviceOnlyWhileThatIsConnected() {
    let sentToDisplay = AppVolumeSetting(forNow: .device(display))
    #expect(sentToDisplay.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: everything) == "display")
    #expect(sentToDisplay.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: ["laptop"]) == "laptop")
    #expect(AppVolumeSetting.untouched.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: everything) == "laptop")
    // Tapped while its device is connected, even at 100% and even when that device is also the main output.
    #expect(sentToDisplay.playsOnItsOwnDevice(connectedDevices: everything))
    #expect(!sentToDisplay.playsOnItsOwnDevice(connectedDevices: ["laptop"]))
    #expect(!AppVolumeSetting.untouched.playsOnItsOwnDevice(connectedDevices: everything))
}

@Test func aPinnedDeviceStaysPinnedWhileTheAppPlaysElsewhereForNow() {
    // Picking another device must not forget the pin.
    var setting = AppVolumeSetting()
    setting.togglePin(speaker, isConnected: true)                                // pin: plays there now, and always
    #expect(setting.alwaysOn == speaker && setting.forNow == nil)
    #expect(setting.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: everything) == "speaker")

    setting.playForNow(on: display)                                              // elsewhere for now: the pin stays
    #expect(setting.alwaysOn == speaker)
    #expect(setting.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: everything) == "display")

    setting.playForNow(on: nil)                                                  // "Same as everything else", for now
    #expect(setting.alwaysOn == speaker)
    #expect(setting.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: everything) == "laptop")

    setting.forNow = nil                                                         // "Play everything on" ends "for now"
    #expect(setting.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: everything) == "speaker")
    #expect(setting.outputDevicePersistentID(mainOutput: "laptop", connectedDevices: ["laptop"]) == "laptop")   // pin away

    setting.playForNow(on: speaker)                                              // picking the pinned device: no "for now"
    #expect(setting.forNow == nil)
}

@Test func unpinningKeepsTheAppWhereItPlays() {
    var setting = AppVolumeSetting(alwaysOn: speaker)
    setting.togglePin(speaker, isConnected: true)
    #expect(setting.alwaysOn == nil && setting.forNow == .device(speaker))      // no surprise move; ends at the next switch
    setting.togglePin(display, isConnected: true)                                // pinning another device moves it there
    #expect(setting.alwaysOn == display && setting.forNow == nil)

    var away = AppVolumeSetting(alwaysOn: speaker)
    away.togglePin(speaker, isConnected: false)                                  // unpinned while away: no jump on return
    #expect(away == .untouched)

    var mainForNow = AppVolumeSetting(alwaysOn: speaker, forNow: .mainOutput)
    mainForNow.togglePin(speaker, isConnected: true)                             // nothing left to save
    #expect(mainForNow == .untouched)
}

// MARK: - Hidden devices (Settings)

private func outputDevice(_ id: AudioDeviceID, _ persistentID: String) -> AudioDevice {
    AudioDevice(id: id, persistentID: persistentID, name: persistentID, symbolName: "hifispeaker.fill")
}

@Test func hidingOnlyDecluttersTheLists() {
    // Meeting-app devices start hidden; hiding never hides what's in use.
    let devices = [outputDevice(1, "speaker"), outputDevice(2, "zoom.us.zoomaudiodevice.001"),
                   outputDevice(3, "MSLoopbackDriverDevice_UID"), outputDevice(4, "BlackHole2ch_UID"), outputDevice(5, "display")]
    var visibility = DeviceVisibility()
    #expect(visibility.listedForMainMenu(devices, current: 1).map(\.persistentID) == ["speaker", "BlackHole2ch_UID", "display"])

    visibility.choiceByDevice["display"] = .init(isShown: false, name: "Studio Display")
    visibility.choiceByDevice["zoom.us.zoomaudiodevice.001"] = .init(isShown: true, name: "ZoomAudioDevice")   // the user wins
    #expect(visibility.listedForMainMenu(devices, current: 1).map(\.persistentID) == ["speaker", "zoom.us.zoomaudiodevice.001", "BlackHole2ch_UID"])
    #expect(visibility.listedForMainMenu(devices, current: 5).map(\.persistentID).contains("display"))   // hidden but in use

    let pinnedToDisplay = AppVolumeSetting(alwaysOn: SavedDevice(persistentID: "display", name: "Studio Display"))
    #expect(visibility.listedForApp(devices, setting: pinnedToDisplay).map(\.persistentID).contains("display"))
    #expect(!visibility.listedForApp(devices, setting: .untouched).map(\.persistentID).contains("display"))
}

@Test func settingsListEachDeviceOnceForOutputAndInput() {
    // A headset is both an output and an input: one row, one choice for both dropdowns.
    let headset = outputDevice(1, "headset")
    let microphone = AudioDevice(id: 2, persistentID: "usb-mic", name: "usb-mic", symbolName: "mic")
    var visibility = DeviceVisibility()
    visibility.choiceByDevice["away"] = .init(isShown: false, name: "Away Speaker")
    visibility.choiceByDevice["headset"] = .init(isShown: false, name: "headset")
    let rows = visibility.settingsRows(outputs: [headset], inputs: [headset, microphone])
    #expect(rows.map(\.persistentID) == ["headset", "usb-mic", "away"])
    #expect(rows.map(\.isConnected) == [true, true, false])
    #expect(visibility.listedForMainMenu([headset, microphone], current: 2).map(\.persistentID) == ["usb-mic"])   // hidden in the input menu too
}

@Test func aBluetoothHeadsetsTwoHalvesShareOneChoice() {
    // macOS lists a Bluetooth headset as "<address>:output" and "<address>:input".
    let earbudsOut = outputDevice(1, "AA-BB:output")
    let earbudsIn = AudioDevice(id: 2, persistentID: "AA-BB:input", name: "AA-BB:input", symbolName: "headphones")
    var visibility = DeviceVisibility()
    visibility.setShown(false, persistentID: "AA-BB:output", name: "Earbuds")
    #expect(visibility.settingsRows(outputs: [earbudsOut], inputs: [earbudsIn]).map(\.persistentID) == ["AA-BB:output"])
    #expect(visibility.listedForMainMenu([earbudsIn], current: 9).isEmpty)   // hidden from the input menu too

    // A choice saved before keys were shared still counts, and the next change replaces it.
    var older = DeviceVisibility()
    older.choiceByDevice["AA-BB:output"] = .init(isShown: false, name: "Earbuds")
    #expect(!older.isShown(persistentID: "AA-BB:output"))
    #expect(older.settingsRows(outputs: [], inputs: []).count == 1)
    older.setShown(true, persistentID: "AA-BB:output", name: "Earbuds")
    #expect(older.choiceByDevice.keys.sorted() == ["AA-BB"])
    #expect(older.isShown(persistentID: "AA-BB:input"))
}

@Test func hiddenDeviceChoicesSurviveSaveAndReload() throws {
    let preferences = try #require(UserDefaults(suiteName: "EarSaxTests-\(UUID().uuidString)"))
    var visibility = DeviceVisibility()
    visibility.choiceByDevice["display"] = .init(isShown: false, name: "Studio Display")
    visibility.save(to: preferences)
    #expect(DeviceVisibility.load(from: preferences) == visibility)
}

// MARK: - Default volume and updates (Settings)

@Test func defaultVolumeOnlyEverTurnsDown() {
    // Any output change, only down, 75% out of the box.
    #expect(volumeAfterOutputChange(current: 1, limit: 0.75, isOn: true) == 0.75)
    #expect(volumeAfterOutputChange(current: 0.4, limit: 0.75, isOn: true) == nil)     // quieter: left alone
    #expect(volumeAfterOutputChange(current: 0.752, limit: 0.75, isOn: true) == nil)   // at the limit: left alone
    #expect(volumeAfterOutputChange(current: 0.81, limit: 0.80, isOn: true) == nil)    // a device's volume step above it: left alone
    #expect(volumeAfterOutputChange(current: 1, limit: 0.75, isOn: false) == nil)      // switched off
    #expect(volumeAfterOutputChange(current: nil, limit: 0.75, isOn: true) == nil)     // volume set on the device itself
}

@Test func versionsCompareByNumberNotByText() {
    #expect(isNewerVersion("1.10.0", than: "1.9.2"))
    #expect(isNewerVersion("0.2", than: "0.1.0"))
    #expect(!isNewerVersion("0.1.0", than: "0.1"))
    #expect(!isNewerVersion("0.1.0", than: "0.2.0"))
    #expect(!isNewerVersion("1.2.0-beta.1", than: "1.2.0"))
}

@Test func outputsSurviveSaveAndReloadAndPhase1SettingsStillLoad() throws {
    let preferences = try #require(UserDefaults(suiteName: "EarSaxTests-\(UUID().uuidString)"))
    let store = AppVolumeSettingsStore(preferences: preferences)
    let saved = ["com.example.music": AppVolumeSetting(alwaysOn: speaker),                // at 100%, but still worth saving
                 "com.example.browser": AppVolumeSetting(volumeSlider: 0.4, alwaysOn: speaker, forNow: .device(display)),
                 "com.apple.Music": AppVolumeSetting(alwaysOn: speaker, forNow: .mainOutput)]
    store.save(saved)
    #expect(store.load() == saved)

    // What Phase 1 wrote: no output keys at all.
    preferences.set(#"{"com.apple.Safari":{"isMuted":true,"volumeSlider":0.3}}"#, forKey: "appVolumeSettings")
    #expect(store.load() == ["com.apple.Safari": AppVolumeSetting(volumeSlider: 0.3, isMuted: true)])
}

// MARK: - The audio math

/// Runs one audio cycle of `frameCount` stereo frames, every captured sample = 1, and returns the speaker samples.
private func runOneAudioCycle(_ copier: TapAudioCopier, frameCount: Int) -> [Float] {
    let sampleCount = frameCount * 2
    let capturedSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    let speakerSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    defer { capturedSamples.deallocate(); speakerSamples.deallocate() }
    capturedSamples.initialize(repeating: 1, count: sampleCount)
    speakerSamples.initialize(repeating: 0, count: sampleCount)

    let captured = AudioBufferList.allocate(maximumBuffers: 1)
    let speakers = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(captured.unsafeMutablePointer); free(speakers.unsafeMutablePointer) }
    let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)
    captured[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: capturedSamples)
    speakers[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: speakerSamples)

    copier.copyAppAudioToSpeakers(captured: captured, speakers: speakers)
    return Array(UnsafeBufferPointer(start: speakerSamples, count: sampleCount))
}

@Test func volumeGlidesToItsTargetWithinOneCycle() {
    let state = RealtimeVolumeState()
    let copier = TapAudioCopier(volume: state)                     // tap built while the app was at 100%
    state.setTargetVolumeMultiplier(0.25)
    let firstCycle = runOneAudioCycle(copier, frameCount: 4)
    #expect(firstCycle.first! < 1 && firstCycle.first! > 0.25)    // starts gliding down from 1, no jump (no click)
    #expect(firstCycle.suffix(2) == [0.25, 0.25])                 // reaches the target on the last frame
    #expect(firstCycle == firstCycle.sorted(by: >))               // only ever goes down on the way

    let secondCycle = runOneAudioCycle(copier, frameCount: 4)
    #expect(secondCycle.allSatisfy { $0 == 0.25 })                // then holds steady
}

@Test func mutedAppIsSilent() {
    let state = RealtimeVolumeState()
    state.setTargetVolumeMultiplier(AppVolumeSetting(volumeSlider: 1, isMuted: true).volumeMultiplier)
    #expect(runOneAudioCycle(TapAudioCopier(volume: state), frameCount: 8).allSatisfy { $0 == 0 })
}

@Test func aRebuiltTapStartsAtTheAppsVolumeWithoutABlip() {
    // A tap rebuilt for an app at 30% must play its first samples at 30%, not glide down from 100% (code review).
    let state = RealtimeVolumeState()
    state.setTargetVolumeMultiplier(0.09)
    #expect(runOneAudioCycle(TapAudioCopier(volume: state), frameCount: 4).allSatisfy { $0 == 0.09 })
}

// MARK: - Output list

@Test func smallBuffersKeepTheSameDurationAndStayInRange() {
    let wide = AudioValueRange(mMinimum: 15, mMaximum: 4096)
    #expect(smallBufferFrames(sampleRate: 44_100, allowed: wide) == 256)               // 11.6 ms, measured on Bluetooth earbuds
    #expect(smallBufferFrames(sampleRate: 96_000, allowed: wide) == 557)               // same 5.8 ms at a higher rate
    #expect(smallBufferFrames(sampleRate: 44_100, allowed: AudioValueRange(mMinimum: 512, mMaximum: 4096)) == 512)
    #expect(smallBufferFrames(sampleRate: 44_100, allowed: AudioValueRange(mMinimum: 0, mMaximum: 0)) == 256)
    #expect(smallBufferFrames(sampleRate: 44_100, allowed: AudioValueRange(mMinimum: .infinity, mMaximum: .infinity)) == nil)
    #expect(smallBufferFrames(sampleRate: 44_100, allowed: AudioValueRange(mMinimum: 512, mMaximum: 256)) == nil)
    #expect(smallBufferFrames(sampleRate: 0, allowed: wide) == nil)
}

@Test func deviceIconsSayWhatTheDeviceIs() {
    // USB desk speakers report a speaker, so they get the speaker icon, not a cable.
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeUSB, terminalType: kAudioStreamTerminalTypeSpeaker, dataSource: 0) == "hifispeaker.fill")
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeUSB, terminalType: kAudioStreamTerminalTypeHeadphones, dataSource: 0) == "headphones")
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeBluetooth, terminalType: kAudioStreamTerminalTypeSpeaker, dataSource: 0) == "hifispeaker.fill")
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeBluetooth, terminalType: 0, dataSource: 0) == "headphones")
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeBuiltIn, terminalType: 769, dataSource: 0x6973_706B) == "laptopcomputer")   // 'ispk'
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeBuiltIn, terminalType: 0, dataSource: 0x6864_706E) == "headphones")        // 'hdpn'
    #expect(outputSymbolName(transportType: kAudioDeviceTransportTypeDisplayPort, terminalType: 0, dataSource: 0) == "display")
    #expect(inputSymbolName(transportType: kAudioDeviceTransportTypeBuiltIn) == "laptopcomputer")
    #expect(inputSymbolName(transportType: kAudioDeviceTransportTypeUSB) == "mic")
    #expect(inputSymbolName(transportType: kAudioDeviceTransportTypeVirtual) == "waveform")
}

@Test func earSaxOwnPrivateDevicesAreNotOfferedAsOutputs() {
    #expect(isEarSaxPrivateDevice(persistentID: earSaxPrivateDevicePrefix + UUID().uuidString))
    #expect(!isEarSaxPrivateDevice(persistentID: "BuiltInSpeakerDevice"))
}

// MARK: - Keeping the Mac's microphone (R26 to R28)

@Test func bluetoothHeadphonesDontKeepTheMicrophoneTheyTookOnConnecting() {
    let builtIn = AudioDevice(id: 1, persistentID: "BuiltInMicrophoneDevice", name: "Built-in", symbolName: "laptopcomputer", isBuiltIn: true)
    let usb = AudioDevice(id: 2, persistentID: "usb-mic", name: "USB", symbolName: "mic")
    let earbuds = AudioDevice(id: 3, persistentID: "AA-BB:input", name: "Earbuds", symbolName: "headphones", isBluetooth: true)
    let all = [builtIn, usb, earbuds]
    // Back to the one used before; if it's gone, the built-in microphone.
    #expect(microphoneToKeep(lastNonBluetoothInput: "usb-mic", current: earbuds, justConnected: true, inputs: all) == usb)
    #expect(microphoneToKeep(lastNonBluetoothInput: "usb-mic", current: earbuds, justConnected: true, inputs: [builtIn, earbuds]) == builtIn)
    #expect(microphoneToKeep(lastNonBluetoothInput: nil, current: earbuds, justConnected: true, inputs: all) == builtIn)
    // Left alone: the user's own later pick, a non-Bluetooth input, or headphones that are the only microphone.
    #expect(microphoneToKeep(lastNonBluetoothInput: "usb-mic", current: earbuds, justConnected: false, inputs: all) == nil)
    #expect(microphoneToKeep(lastNonBluetoothInput: "BuiltInMicrophoneDevice", current: usb, justConnected: true, inputs: all) == nil)
    #expect(microphoneToKeep(lastNonBluetoothInput: nil, current: earbuds, justConnected: true, inputs: [earbuds]) == nil)
}
