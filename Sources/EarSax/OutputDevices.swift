import CoreAudio
import Foundation

/// A device the Mac can play sound through (speakers, headphones, a display, a USB interface).
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnections; Core Audio needs it to build EarSax's private devices.
    let persistentID: String
    let name: String
    /// SF Symbol for the panel, chosen from what the device says it is.
    let symbolName: String
    /// Bluetooth adds a long output delay (about 160 ms on Bluetooth earbuds), which matters for video on an app sent there.
    var isBluetooth = false
}

func listOutputDevices() -> [OutputDevice] {
    readPropertyList(kAudioHardwarePropertyDevices, of: coreAudioSystem, elementType: AudioDeviceID.self).compactMap { deviceID in
        let outputStreams = readPropertyList(kAudioDevicePropertyStreams, of: deviceID,
                                             scope: kAudioObjectPropertyScopeOutput, elementType: AudioStreamID.self)
        let isHidden: UInt32 = readProperty(kAudioDevicePropertyIsHidden, of: deviceID, orDefault: 0)
        guard !outputStreams.isEmpty, isHidden == 0,
              let persistentID = readTextProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
              !isEarSaxPrivateDevice(persistentID: persistentID) else { return nil }
        let transportType: UInt32 = readProperty(kAudioDevicePropertyTransportType, of: deviceID, orDefault: 0)
        return OutputDevice(id: deviceID,
                            persistentID: persistentID,
                            name: readTextProperty(kAudioObjectPropertyName, of: deviceID) ?? "Unnamed device",
                            symbolName: outputSymbolName(
                                transportType: transportType,
                                terminalType: readProperty(kAudioStreamPropertyTerminalType, of: outputStreams[0], orDefault: UInt32(0)),
                                dataSource: readProperty(kAudioDevicePropertyDataSource, of: deviceID,
                                                         scope: kAudioObjectPropertyScopeOutput, orDefault: UInt32(0))),
                            isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE)
    }
}

/// The private devices EarSax builds for its taps. Other apps can't see them, but EarSax can, and choosing one as the
/// Mac's output would send sound into EarSax itself (seen in the first Phase 1 run, 2026-11-16).
let earSaxPrivateDevicePrefix = "app.earsax.private."

func isEarSaxPrivateDevice(persistentID: String) -> Bool {
    persistentID.hasPrefix(earSaxPrivateDevicePrefix)
}

/// The icon says what the device is, not how it's plugged in: a USB speaker system is a speaker, not a cable.
/// - `terminalType`: what the device's output stream says it feeds (USB desk speakers report a speaker).
/// - `dataSource`: which built-in output is in use (the Mac's speakers or its headphone jack).
func outputSymbolName(transportType: UInt32, terminalType: UInt32, dataSource: UInt32) -> String {
    let builtInHeadphoneJack: UInt32 = 0x6864_706E   // 'hdpn'
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn: return dataSource == builtInHeadphoneJack ? "headphones" : "laptopcomputer"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
    case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
    case kAudioDeviceTransportTypeVirtual: return "waveform"   // an app's own audio device (Zoom, Teams), not hardware
    default: break
    }
    switch terminalType {
    case kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeHeadsetMicrophone: return "headphones"
    case kAudioStreamTerminalTypeSpeaker: return "hifispeaker.fill"
    default:
        // A device that doesn't say: most Bluetooth audio is headphones, anything else is treated as a speaker.
        let isBluetooth = transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
        return isBluetooth ? "headphones" : "hifispeaker.fill"
    }
}

/// The device currently connected under this persistent ID, or kAudioObjectUnknown if it's gone (switched off, unplugged).
func deviceID(forPersistentID persistentID: String) -> AudioDeviceID {
    var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
    var lookedUpID = persistentID as CFString
    var device = AudioDeviceID(kAudioObjectUnknown)
    var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &lookedUpID) { idPointer in
        withUnsafeMutablePointer(to: &device) { devicePointer in
            AudioObjectGetPropertyData(coreAudioSystem, &address, UInt32(MemoryLayout<CFString>.size), idPointer, &byteCount, devicePointer)
        }
    }
    return status == noErr ? device : AudioDeviceID(kAudioObjectUnknown)
}

// MARK: - The Mac's current output

func systemOutputDeviceID() -> AudioDeviceID {
    readProperty(kAudioHardwarePropertyDefaultOutputDevice, of: coreAudioSystem, orDefault: AudioDeviceID(kAudioObjectUnknown))
}

/// False if macOS refused the switch (the device just disappeared, for example).
@discardableResult
func makeSystemOutputDevice(_ device: AudioDeviceID) -> Bool {
    let status = writeProperty(kAudioHardwarePropertyDefaultOutputDevice, of: coreAudioSystem, value: device)
    if status != noErr { earSaxLog.error("Switching output to device \(device) failed: \(readableStatus(status))") }
    return status == noErr
}

// MARK: - Device volume and mute

/// Where a device keeps its volume control: one main control, or one per channel (left and right).
/// Empty when macOS can't set the device's volume (some HDMI and USB devices; their volume is set on the device).
private func volumeControls(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
    if canChangeProperty(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput) {
        return [kAudioObjectPropertyElementMain]
    }
    return [1, 2].filter { canChangeProperty(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput, element: $0) }
}

/// 0...1, or nil when macOS can't control this device's volume.
/// Note: some Bluetooth devices report a volume that doesn't match what you hear (Phase 0: Bluetooth earbuds read 0 while playing).
/// A software-volume fallback for those is Phase 2.
func readOutputVolume(of device: AudioDeviceID) -> Float? {
    let controls = volumeControls(of: device)
    guard !controls.isEmpty else { return nil }
    let levels = controls.map { readProperty(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput,
                                             element: $0, orDefault: Float32(0)) }
    return levels.reduce(0, +) / Float(levels.count)
}

/// The default volume, one channel at a time, so a device with left and right volumes never has its quieter channel turned
/// up (code review of Settings, finding 3). Returns true if any channel was turned down.
func turnOutputDown(of device: AudioDeviceID, toAtMost limit: Double) -> Bool {
    var turnedDown = false
    for control in volumeControls(of: device) {
        let current: Float32 = readProperty(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput,
                                            element: control, orDefault: 0)
        guard let lowered = volumeAfterOutputChange(current: current, limit: limit, isOn: true) else { continue }
        writeProperty(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput, element: control, value: lowered)
        turnedDown = true
    }
    return turnedDown
}

func writeOutputVolume(_ volume: Float, to device: AudioDeviceID) {
    for control in volumeControls(of: device) {
        writeProperty(kAudioDevicePropertyVolumeScalar, of: device, scope: kAudioObjectPropertyScopeOutput,
                      element: control, value: Float32(min(max(volume, 0), 1)))
    }
}

func readOutputMute(of device: AudioDeviceID) -> Bool {
    readProperty(kAudioDevicePropertyMute, of: device, scope: kAudioObjectPropertyScopeOutput, orDefault: UInt32(0)) != 0
}

func canMuteOutput(of device: AudioDeviceID) -> Bool {
    canChangeProperty(kAudioDevicePropertyMute, of: device, scope: kAudioObjectPropertyScopeOutput)
}

func writeOutputMute(_ isMuted: Bool, to device: AudioDeviceID) {
    writeProperty(kAudioDevicePropertyMute, of: device, scope: kAudioObjectPropertyScopeOutput, value: UInt32(isMuted ? 1 : 0))
}
