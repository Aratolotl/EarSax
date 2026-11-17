import CoreAudio
import Foundation

/// Which devices EarSax lists, outputs and inputs alike. Hiding only declutters the menus; it never moves sound.
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

    /// One key per physical device. macOS lists a Bluetooth headset as two devices, "<address>:output" and
    /// "<address>:input", so both halves share one choice (code review of the input picker, finding 1).
    static func choiceKey(persistentID: String) -> String {
        for suffix in [":output", ":input"] where persistentID.hasSuffix(suffix) { return String(persistentID.dropLast(suffix.count)) }
        return persistentID
    }

    func isShown(persistentID: String) -> Bool {
        // The raw ID is the fallback for a choice saved before keys were shared.
        (choiceByDevice[Self.choiceKey(persistentID: persistentID)] ?? choiceByDevice[persistentID])?.isShown
            ?? !Self.isMeetingAppDevice(persistentID: persistentID)
    }

    mutating func setShown(_ isShown: Bool, persistentID: String, name: String) {
        choiceByDevice[persistentID] = nil
        choiceByDevice[Self.choiceKey(persistentID: persistentID)] = Choice(isShown: isShown, name: name)
    }

    /// The panel's two dropdowns, "Play everything on" and "Sound input": shown devices, plus the one in use even when
    /// hidden, so the checkmark is never missing.
    func listedForMainMenu(_ devices: [AudioDevice], current: AudioDeviceID) -> [AudioDevice] {
        devices.filter { isShown(persistentID: $0.persistentID) || $0.id == current }
    }

    /// One app's list: shown devices, plus its own pinned or chosen device even when hidden, so that choice can be undone.
    func listedForApp(_ devices: [AudioDevice], setting: AppVolumeSetting) -> [AudioDevice] {
        var ownDevices: Set<String> = []
        if let pinned = setting.alwaysOn?.persistentID { ownDevices.insert(pinned) }
        if case .device(let chosen) = setting.forNow { ownDevices.insert(chosen.persistentID) }
        return devices.filter { isShown(persistentID: $0.persistentID) || ownDevices.contains($0.persistentID) }
    }

    /// Settings' list: every connected device once (a headset is both an output and an input), then the hidden devices
    /// that are away, so they can be shown again. One choice per device covers both dropdowns.
    func settingsRows(outputs: [AudioDevice], inputs: [AudioDevice]) -> [SettingsDeviceRow] {
        var listedKeys: Set<String> = []
        let connected = (outputs + inputs)
            .filter { listedKeys.insert(Self.choiceKey(persistentID: $0.persistentID)).inserted }
            .map {
                SettingsDeviceRow(persistentID: $0.persistentID, name: $0.name, symbolName: $0.symbolName, isConnected: true,
                                  isShown: isShown(persistentID: $0.persistentID))
            }
        let hiddenAndAway = choiceByDevice
            .filter { !$0.value.isShown && listedKeys.insert(Self.choiceKey(persistentID: $0.key)).inserted }
            .map { SettingsDeviceRow(persistentID: $0.key, name: $0.value.name, symbolName: "powerplug", isConnected: false, isShown: false) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return connected + hiddenAndAway
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
