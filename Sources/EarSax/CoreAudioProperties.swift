import CoreAudio
import Foundation
import os

// Readable wrappers around Core Audio's C property API, so the rest of EarSax reads like plain Swift.

/// Core Audio's root object: ask it for the devices, the Mac's current output, and the processes using audio.
let coreAudioSystem = AudioObjectID(kAudioObjectSystemObject)

/// EarSax's events (taps started, moved, failed), written to the system log and to ~/Library/Logs/EarSax.log.
/// The file exists because QA needs a record anyone can open; the system log isn't always readable.
let earSaxLog = EventLog()

struct EventLog: Sendable {
    private let systemLog = Logger(subsystem: "app.earsax.EarSax", category: "audio")
    private let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/EarSax.log")
    /// Main thread and the tap queue both log; one queue keeps lines whole and in order (review finding 9).
    private let fileWritingQueue = DispatchQueue(label: "app.earsax.log-file")

    func notice(_ message: String) {
        systemLog.notice("\(message)")
        appendToFile(message)
    }

    func error(_ message: String) {
        systemLog.error("\(message)")
        appendToFile("ERROR " + message)
    }

    // ponytail: no rotation; a line per tap event stays tiny. Add rotation if the file ever grows past a few MB.
    private func appendToFile(_ message: String) {
        // Milliseconds, so QA can measure a switch's gaps from the log.
        let line = Data("\(Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))) \(message)\n".utf8)
        fileWritingQueue.async { [logFile] in
            if let file = try? FileHandle(forWritingTo: logFile) {
                _ = try? file.seekToEnd()
                try? file.write(contentsOf: line)
                try? file.close()
            } else {
                try? line.write(to: logFile)
            }
        }
    }
}

func propertyAddress(_ property: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: property, mScope: scope, mElement: element)
}

func readProperty<Value>(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         orDefault defaultValue: Value) -> Value {
    var address = propertyAddress(property, scope: scope, element: element)
    var value = defaultValue
    var byteCount = UInt32(MemoryLayout<Value>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &byteCount, $0) }
    return status == noErr ? value : defaultValue
}

@discardableResult
func writeProperty<Value>(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                          value: Value) -> OSStatus {
    var address = propertyAddress(property, scope: scope, element: element)
    var newValue = value
    return withUnsafePointer(to: &newValue) { AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), $0) }
}

func canChangeProperty(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
    var address = propertyAddress(property, scope: scope, element: element)
    guard AudioObjectHasProperty(object, &address) else { return false }
    var isChangeable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(object, &address, &isChangeable) == noErr && isChangeable.boolValue
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

/// Runs `action` on the main thread whenever the property changes.
/// ponytail: listeners are never removed. EarSax listens for its whole lifetime, and a removed device simply stops firing.
func whenPropertyChanges(_ property: AudioObjectPropertySelector, of object: AudioObjectID,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         run action: @escaping @MainActor () -> Void) {
    var address = propertyAddress(property, scope: scope, element: element)
    AudioObjectAddPropertyListenerBlock(object, &address, .main) { _, _ in
        MainActor.assumeIsolated { action() }
    }
}

/// Core Audio errors are often four letters packed into a number ('!obj', 'who?'); show them as text when they are.
func readableStatus(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : "\(status)"
}
