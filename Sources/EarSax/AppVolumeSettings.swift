import Foundation

/// What the user chose for one app. Saved per bundle ID, so it survives quitting EarSax or the app.
struct AppVolumeSetting: Codable, Hashable {
    /// Slider position, 0...1 (1 = 100%).
    var volumeSlider: Double = 1
    var isMuted = false
    /// The pinned device: the app always plays there while it's connected, through every switch.
    var alwaysOn: SavedDevice?
    /// Where the app plays for now, from its device list, until the next "Play everything on". The pinned device stays
    /// while this is set: picking another device must not forget the pin.
    var forNow: OutputForNow?

    static let untouched = AppVolumeSetting()

    /// An untouched app plays exactly as it would without EarSax: no tap, no added delay, no risk.
    /// An app playing on another device also needs a tap; that depends on what's connected, so MixerModel adds it.
    var needsTap: Bool { isMuted || volumeSlider < 1 }

    /// The device this app plays on instead of the main output, or nil when it plays on the main output: the device picked
    /// for now while it's connected, otherwise the pinned device while that's connected.
    func ownOutput(connectedDevices: Set<String>) -> SavedDevice? {
        switch forNow {
        case .device(let device) where connectedDevices.contains(device.persistentID): return device
        case .mainOutput: return nil
        default: break
        }
        guard let alwaysOn, connectedDevices.contains(alwaysOn.persistentID) else { return nil }
        return alwaysOn
    }

    func outputDevicePersistentID(mainOutput: String, connectedDevices: Set<String>) -> String {
        ownOutput(connectedDevices: connectedDevices)?.persistentID ?? mainOutput
    }

    /// An app with a device of its own is tapped whenever that device is connected, even while it is also the main output.
    /// Otherwise the app would play on the new main output for a moment each time the main output moves away.
    func playsOnItsOwnDevice(connectedDevices: Set<String>) -> Bool {
        ownOutput(connectedDevices: connectedDevices) != nil
    }

    /// A pick in the app's device list: play there for now, keeping the pin. nil = "Same as everything else".
    mutating func playForNow(on device: SavedDevice?) {
        if let device {
            forNow = device.persistentID == alwaysOn?.persistentID ? nil : .device(device)   // the pin already covers it
        } else {
            forNow = alwaysOn == nil ? nil : .mainOutput
        }
    }

    /// The pin next to a device: pin it (and play there now), or unpin it. Unpinning the device the app plays on keeps it
    /// playing there for now, so taking the pin away never moves the sound by surprise. Unpinning a device that's away
    /// leaves nothing behind, so the app doesn't jump to it when it reconnects (code review, findings 2 and 3).
    mutating func togglePin(_ device: SavedDevice, isConnected: Bool) {
        if alwaysOn?.persistentID == device.persistentID {
            alwaysOn = nil
            switch forNow {
            case nil where isConnected: forNow = .device(device)
            case .mainOutput: forNow = nil   // "main output for now" means nothing without a pin
            default: break
            }
        } else {
            alwaysOn = device
            forNow = nil
        }
    }

    /// What the app's audio is multiplied by. Squaring the slider matches how loud people expect each position to sound
    /// (in Phase 0 testing, 23% sounded clearly less than half).
    var volumeMultiplier: Float { isMuted ? 0 : Float(volumeSlider * volumeSlider) }
}

/// The default volume rule: the volume to set after the main output changed, or nil to leave
/// it. Only ever turns down; a device whose volume macOS can't read is left alone. Within 2 points of the limit counts as
/// at it: some USB desk speakers only take volume in steps, so 80% lands on 81%, and the 1.5 s re-check turned it down
/// a second time for nothing.
func volumeAfterOutputChange(current: Float?, limit: Double, isOn: Bool) -> Float? {
    guard isOn, let current, Double(current) > limit + 0.02 else { return nil }
    return Float(limit)
}

/// A device remembered for an app. The name is kept so the row can still name it while it's disconnected.
struct SavedDevice: Codable, Hashable {
    let persistentID: String
    let name: String
}

/// Where an app plays for now, until the next "Play everything on" (or until that device disconnects).
enum OutputForNow: Codable, Hashable {
    case device(SavedDevice)
    /// "Same as everything else" picked while the app has a pinned device: the main output, for now.
    case mainOutput
}

/// Saves settings in EarSax's preferences as readable JSON:
/// defaults read app.earsax.EarSax appVolumeSettings
struct AppVolumeSettingsStore {
    let preferences: UserDefaults
    private let storageKey = "appVolumeSettings"

    func load() -> [String: AppVolumeSetting] {
        guard let json = preferences.string(forKey: storageKey),
              let settings = try? JSONDecoder().decode([String: AppVolumeSetting].self, from: Data(json.utf8)) else { return [:] }
        // A damaged value (NaN, below 0, above 1) must never reach the audio path; another per-app volume app shipped that bug.
        return settings.mapValues { saved in
            var safe = saved
            safe.volumeSlider = saved.volumeSlider.isFinite ? min(max(saved.volumeSlider, 0), 1) : 1
            return safe
        }
    }

    /// Untouched apps are not stored, so the list only holds apps the user actually changed.
    func save(_ settingByApp: [String: AppVolumeSetting]) {
        let changedApps = settingByApp.filter { $0.value != .untouched }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(changedApps) else { return }
        preferences.set(String(decoding: json, as: UTF8.self), forKey: storageKey)
    }
}
