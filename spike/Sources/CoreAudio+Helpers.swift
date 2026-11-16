import AppKit
import CoreAudio
import Foundation

// Small wrappers around Core Audio's C property API, so the rest of the spike reads like plain Swift.
// ponytail: throwaway spike helpers; failures fall back to a default value and get logged by the caller.

/// Core Audio's root object: the one you ask for the device list, the default output, and the list of processes using audio.
let coreAudioSystem = AudioObjectID(kAudioObjectSystemObject)

func propertyAddress(_ property: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: property, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readProperty<Value>(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         orDefault defaultValue: Value) -> Value {
    var address = propertyAddress(property, scope: scope)
    var value = defaultValue
    var byteCount = UInt32(MemoryLayout<Value>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, &value)
    return status == noErr ? value : defaultValue
}

func readPropertyList<Element>(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               elementType _: Element.Type) -> [Element] {
    var address = propertyAddress(property, scope: scope)
    var byteCount: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &byteCount) == noErr, byteCount > 0 else { return [] }
    return Array(unsafeUninitializedCapacity: Int(byteCount) / MemoryLayout<Element>.stride) { buffer, filledCount in
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, buffer.baseAddress!)
        filledCount = status == noErr ? Int(byteCount) / MemoryLayout<Element>.stride : 0
    }
}

func readTextProperty(_ property: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
    var address = propertyAddress(property)
    var byteCount = UInt32(MemoryLayout<CFString?>.size)
    var text: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, &text) == noErr, let text else { return nil }
    return text.takeRetainedValue() as String
}

// MARK: - Output devices

var currentOutputDevice: AudioDeviceID {
    readProperty(kAudioHardwarePropertyDefaultOutputDevice, of: coreAudioSystem, orDefault: AudioDeviceID(kAudioObjectUnknown))
}

/// The stable identifier Core Audio uses to refer to a device across reboots (needed to build the private device).
func persistentID(of device: AudioDeviceID) -> String? { readTextProperty(kAudioDevicePropertyDeviceUID, of: device) }

func displayName(of device: AudioDeviceID) -> String {
    readTextProperty(kAudioObjectPropertyName, of: device) ?? "Device \(device)"
}

func connectionType(of device: AudioDeviceID) -> String {
    let transport: UInt32 = readProperty(kAudioDevicePropertyTransportType, of: device, orDefault: 0)
    switch transport {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "hdmi/dp"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    default: return String(format: "0x%08x", transport)
    }
}

/// The delay Core Audio reports for one side (input or output) of a device, in audio frames:
/// device latency + safety offset + stream latency. Bluetooth devices include their own wireless delay here.
func reportedDelayInFrames(of device: AudioDeviceID, side: AudioObjectPropertyScope) -> UInt32 {
    let deviceDelay: UInt32 = readProperty(kAudioDevicePropertyLatency, of: device, scope: side, orDefault: 0)
    let safetyOffset: UInt32 = readProperty(kAudioDevicePropertySafetyOffset, of: device, scope: side, orDefault: 0)
    let streams = readPropertyList(kAudioDevicePropertyStreams, of: device, scope: side, elementType: AudioStreamID.self)
    let streamDelay: UInt32 = streams.first.map { readProperty(kAudioStreamPropertyLatency, of: $0, orDefault: 0) } ?? 0
    return deviceDelay + safetyOffset + streamDelay
}

// MARK: - Processes using audio

/// One process that has opened audio, as Core Audio sees it. An app can have several (e.g. browser helpers).
struct ProcessUsingAudio: Hashable {
    let coreAudioID: AudioObjectID
    let processID: pid_t
    let bundleID: String       // empty for command-line tools such as afplay
    let isPlayingSound: Bool
}

func listProcessesUsingAudio() -> [ProcessUsingAudio] {
    readPropertyList(kAudioHardwarePropertyProcessObjectList, of: coreAudioSystem, elementType: AudioObjectID.self).map { id in
        ProcessUsingAudio(
            coreAudioID: id,
            processID: readProperty(kAudioProcessPropertyPID, of: id, orDefault: -1),
            bundleID: readTextProperty(kAudioProcessPropertyBundleID, of: id) ?? "",
            isPlayingSound: readProperty(kAudioProcessPropertyIsRunningOutput, of: id, orDefault: UInt32(0)) != 0)
    }
}

/// Executable name for processes that have no app bundle (afplay, background daemons).
func executableName(of processID: pid_t) -> String {
    var nameBuffer = [CChar](repeating: 0, count: 256)
    return proc_name(processID, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : "process \(processID)"
}

// MARK: - Private Apple functions (spike only: we're measuring whether we need them; the App Store would reject them)

private typealias OwningAppLookup = @convention(c) (pid_t) -> pid_t
private let owningAppLookup: OwningAppLookup? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                                      "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: OwningAppLookup.self) }

/// The app a helper process works for (Chrome Helper → Chrome, WebKit audio process → Safari). Private API; nil if unavailable.
func owningAppProcessID(of processID: pid_t) -> pid_t? {
    guard let owningAppLookup else { return nil }
    let ownerID = owningAppLookup(processID)
    return ownerID > 0 ? ownerID : nil
}

private typealias PermissionLookup = @convention(c) (CFString, CFDictionary?) -> Int32
private let permissionLookup: PermissionLookup? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    .flatMap { dlsym($0, "TCCAccessPreflight") }
    .map { unsafeBitCast($0, to: PermissionLookup.self) }

/// Status of the "Screen & System Audio Recording" permission: "granted", "denied", "not asked yet" or "unknown".
/// Private TCC API (the same one AudioCap uses); there is no public way to check this.
func systemAudioRecordingPermission() -> String {
    guard let permissionLookup else { return "unknown" }
    switch permissionLookup("kTCCServiceAudioCapture" as CFString, nil) {
    case 0: return "granted"
    case 1: return "denied"
    default: return "not asked yet"
    }
}

// MARK: - Spike log (~/Library/Logs/EarSaxSpike.log)

let spikeLogFile: URL = {
    let logsFolder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
    try? FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
    return logsFolder.appendingPathComponent("EarSaxSpike.log")
}()

private let logWritingQueue = DispatchQueue(label: "spike-log")

func writeToSpikeLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    print(line, terminator: "")
    logWritingQueue.async {
        if let file = try? FileHandle(forWritingTo: spikeLogFile) {
            file.seekToEndOfFile(); file.write(Data(line.utf8)); try? file.close()
        } else {
            try? Data(line.utf8).write(to: spikeLogFile)
        }
    }
}
