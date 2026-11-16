import AppKit
import CoreAudio

/// One process that has opened audio, as Core Audio sees it. An app can have several (browser helpers, web content).
struct ProcessUsingAudio: Hashable, Sendable {
    let coreAudioID: AudioObjectID
    let processID: pid_t
    let bundleID: String          // empty for command-line tools
    let isPlayingSound: Bool
}

/// The app a process belongs to, as the panel shows it.
struct AppIdentity: Hashable {
    let bundleID: String
    let name: String
    let bundleURL: URL?
}

/// One row in the panel: an app and every process it plays audio through.
struct AudioApp: Identifiable, Hashable {
    let identity: AppIdentity
    let processes: [ProcessUsingAudio]
    var id: String { identity.bundleID }
    var name: String { identity.name }
    var isPlayingSound: Bool { processes.contains { $0.isPlayingSound } }
    var tapTarget: TapTarget { chooseTapTarget(appBundleID: identity.bundleID, processes: processes) }
}

/// How a tap finds an app's audio.
enum TapTarget: Hashable, Sendable {
    /// macOS 26: follows the app by bundle ID, including after it restarts (Phase 0 test F).
    case bundleIDs([String])
    /// The exact processes; EarSax updates the list when helpers come and go.
    case processes([AudioObjectID])
}

/// Bundle-ID taps are only safe when every audio process belongs to this app alone. Safari plays through
/// "com.apple.WebKit.GPU", a bundle ID shared by every app that shows web content, so a bundle-ID tap there would
/// also capture Mail and others. Rule: tap by bundle ID when each process's bundle ID is the app's own or
/// starts with it (a browser's "com.example.browser.helper"); otherwise tap the processes.
func chooseTapTarget(appBundleID: String, processes: [ProcessUsingAudio]) -> TapTarget {
    let processBundleIDs = Set(processes.map(\.bundleID))
    let allBelongToThisApp = processBundleIDs.allSatisfy { $0 == appBundleID || $0.hasPrefix(appBundleID + ".") }
    return allBelongToThisApp
        ? .bundleIDs(processBundleIDs.union([appBundleID]).sorted())
        : .processes(processes.map(\.coreAudioID).sorted())
}

/// Groups processes into one entry per app, in name order. `identifyApp` returns nil for processes that are not
/// a user-facing app (system daemons, EarSax itself); those are left out.
func groupProcessesIntoApps(_ processes: [ProcessUsingAudio], identifyApp: (ProcessUsingAudio) -> AppIdentity?) -> [AudioApp] {
    // Keyed by bundle ID alone: two copies of the same app (different locations) are one row with one setting (finding 8).
    var appsByBundleID: [String: (identity: AppIdentity, processes: [ProcessUsingAudio])] = [:]
    for process in processes {
        guard let identity = identifyApp(process) else { continue }
        appsByBundleID[identity.bundleID, default: (identity, [])].processes.append(process)
    }
    return appsByBundleID.values
        .map { AudioApp(identity: $0.identity, processes: $0.processes) }
        // Name order only, so rows never trade places. Sorting playing apps first made the list reshuffle whenever an app
        // paused for a moment, such as while its tap was rebuilt.
        .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
}

// MARK: - Reading the system

func listProcessesUsingAudio() -> [ProcessUsingAudio] {
    readPropertyList(kAudioHardwarePropertyProcessObjectList, of: coreAudioSystem, elementType: AudioObjectID.self).map { processObject in
        ProcessUsingAudio(
            coreAudioID: processObject,
            processID: readProperty(kAudioProcessPropertyPID, of: processObject, orDefault: -1),
            bundleID: readTextProperty(kAudioProcessPropertyBundleID, of: processObject) ?? "",
            isPlayingSound: readProperty(kAudioProcessPropertyIsRunningOutput, of: processObject, orDefault: UInt32(0)) != 0)
    }
}

/// The user-facing app a process works for, or nil for background system processes and EarSax itself.
@MainActor
func identifyOwningApp(of process: ProcessUsingAudio) -> AppIdentity? {
    guard process.processID != getpid() else { return nil }
    let ownerProcessID = owningAppProcessID(of: process.processID) ?? process.processID
    guard let app = NSRunningApplication(processIdentifier: ownerProcessID),
          app.activationPolicy != .prohibited,
          let bundleID = app.bundleIdentifier,
          bundleID != Bundle.main.bundleIdentifier else { return nil }
    return AppIdentity(bundleID: bundleID, name: app.localizedName ?? bundleID, bundleURL: app.bundleURL)
}

// ponytail: a private macOS function, the only way to know which app a helper process works for (Chrome Helper → Chrome,
// WebKit audio → Safari). Verified in Phase 0. The Mac App Store would reject it; swap this one function if that becomes
// the channel (plan decision D4). Returns nil if the function disappears in a future macOS.
private typealias OwningAppLookup = @convention(c) (pid_t) -> pid_t
private let owningAppLookup: OwningAppLookup? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                                      "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: OwningAppLookup.self) }

private func owningAppProcessID(of processID: pid_t) -> pid_t? {
    guard let owningAppLookup else { return nil }
    let ownerID = owningAppLookup(processID)
    return ownerID > 0 ? ownerID : nil
}
