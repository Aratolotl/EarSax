import CoreAudio
import Foundation

/// Which output devices EarSax lists. Hiding only declutters the menus; it never moves sound.
struct DeviceVisibility: Codable, Equatable {
    /// The user's own choices from Settings, by persistent ID. Devices without one use the default.
    var choiceByDevice: [String: Choice] = [:]

    struct Choice: Codable, Equatable {
        var isShown: Bool
        /// Kept so Settings can name a hidden device while it's away.
        var name: String
    }

    /// Zoom's and Teams' own virtual devices start hidden: an app sent there goes silent. Matched by
    /// the start of their persistent IDs ("zoom.us.zoomaudiodevice.001", "MSLoopbackDriverDevice_UID"). Everything else, BlackHole included, starts shown.
    static func isMeetingAppDevice(persistentID: String) -> Bool {
        persistentID.hasPrefix("zoom.us.zoomaudiodevice") || persistentID.hasPrefix("MSLoopbackDriverDevice")
    }

    func isShown(persistentID: String) -> Bool {
        choiceByDevice[persistentID]?.isShown ?? !Self.isMeetingAppDevice(persistentID: persistentID)
    }

    /// "Play everything on": shown devices, plus the main output even when hidden, so the checkmark is never missing.
    func listedForPlayEverythingOn(_ devices: [OutputDevice], mainOutput: AudioDeviceID) -> [OutputDevice] {
        devices.filter { isShown(persistentID: $0.persistentID) || $0.id == mainOutput }
    }

    /// One app's list: shown devices, plus its own pinned or chosen device even when hidden, so that choice can be undone.
    func listedForApp(_ devices: [OutputDevice], setting: AppVolumeSetting) -> [OutputDevice] {
        var ownDevices: Set<String> = []
        if let pinned = setting.alwaysOn?.persistentID { ownDevices.insert(pinned) }
        if case .device(let chosen) = setting.forNow { ownDevices.insert(chosen.persistentID) }
        return devices.filter { isShown(persistentID: $0.persistentID) || ownDevices.contains($0.persistentID) }
    }

    // MARK: Saving

    private static let storageKey = "deviceVisibility"

    static func load(from preferences: UserDefaults) -> DeviceVisibility {
        guard let json = preferences.string(forKey: storageKey),
              let saved = try? JSONDecoder().decode(DeviceVisibility.self, from: Data(json.utf8)) else { return DeviceVisibility() }
        return saved
    }

    func save(to preferences: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(self) else { return }
        preferences.set(String(decoding: json, as: UTF8.self), forKey: Self.storageKey)
    }
}

/// One line in Settings' device list.
struct SettingsDeviceRow: Identifiable, Equatable {
    let persistentID: String
    let name: String
    let symbolName: String
    let isConnected: Bool
    let isShown: Bool
    var id: String { persistentID }
}
