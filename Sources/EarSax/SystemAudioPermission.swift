import AppKit
import Foundation

/// The macOS "System Audio Recording" permission, which every tap needs.
enum SystemAudioPermission: Equatable {
    case granted
    /// Refused, OR allowed but not applied yet: macOS only applies a newly allowed permission when EarSax restarts
    /// ("granted" appears only after a restart), so the two look the same until then.
    case refused
    case notAskedYet
    /// The check itself isn't available (see `currentSystemAudioPermission`); EarSax then just tries. Deliberate: failing safe
    /// here would mean EarSax never works on a macOS without the private check (code review, finding 3, declined).
    case unknown

    /// Tested: macOS lets EarSax create a tap without the permission but passes no sound through it,
    /// and since a tap silences its app, the app went silent. So taps are only made once the permission is granted.
    var allowsTaps: Bool { self == .granted || self == .unknown }
}

/// The tap rule with the permission folded in: an app is tapped only when it's turned down or muted AND EarSax may tap.
func shouldTap(_ setting: AppVolumeSetting, permission: SystemAudioPermission) -> Bool {
    setting.needsTap && permission.allowsTaps
}

// ponytail: a private macOS function (TCC), the same one Apple's AudioCap sample uses; there is no public way to read this
// permission. App Store builds would need it replaced (plan decision D4). If it disappears, the status is `.unknown`.
// A dlopen handle is only read after loading, so sharing it across threads is safe.
nonisolated(unsafe) private let privacyFramework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

private typealias PermissionLookup = @convention(c) (CFString, CFDictionary?) -> Int32
private let permissionLookup: PermissionLookup? = privacyFramework
    .flatMap { dlsym($0, "TCCAccessPreflight") }
    .map { unsafeBitCast($0, to: PermissionLookup.self) }

// C `Boolean` is one byte, so the answer is read as UInt8 (code review, finding 5).
private typealias PermissionRequest = @convention(c) (CFString, CFDictionary?, @escaping @Sendable @convention(block) (UInt8) -> Void) -> UInt8
private let permissionRequest: PermissionRequest? = privacyFramework
    .flatMap { dlsym($0, "TCCAccessRequest") }
    .map { unsafeBitCast($0, to: PermissionRequest.self) }

/// Shows macOS's prompt and hands back the user's answer. Unlike `currentSystemAudioPermission`, which keeps returning the
/// old answer until EarSax restarts, this answer is live, and taps work at once after Allow
/// (Phase 0 spike). Returns false when the function isn't available; the caller then falls back to the probe tap.
func askForSystemAudioPermission(whenAnswered: @escaping @Sendable (_ granted: Bool) -> Void) -> Bool {
    guard let permissionRequest else { return false }
    _ = permissionRequest("kTCCServiceAudioCapture" as CFString, nil) { granted in whenAnswered(granted != 0) }
    return true
}

func currentSystemAudioPermission() -> SystemAudioPermission {
    guard let permissionLookup else { return .unknown }
    switch permissionLookup("kTCCServiceAudioCapture" as CFString, nil) {
    case 0: return .granted
    case 1: return .refused
    default: return .notAskedYet
    }
}

/// Quits EarSax and opens it again, so a permission allowed in System Settings takes effect. The reopen is handed to a separate
/// process that waits until this EarSax has really exited (up to 5 s; quitting can take 2 s while taps are removed), so
/// macOS starts a fresh copy instead of re-activating the one that's quitting (code review, finding 1).
@MainActor
func restartEarSax() {
    let reopen = Process()
    reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
    let waitThenReopen = #"waited=0; while kill -0 "$1" 2>/dev/null && [ $waited -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done; /usr/bin/open "$2""#
    reopen.arguments = ["-c", waitThenReopen, "earsax-restart", "\(getpid())", Bundle.main.bundlePath]
    do {
        try reopen.run()
        NSApp.terminate(nil)
    } catch {
        earSaxLog.error("Couldn't restart EarSax: \(String(describing: error))")
    }
}

/// Opens Privacy & Security in System Settings. The anchor for the audio list is unverified; if System Settings ignores it,
/// the Privacy & Security page still opens and the panel's text says where to look.
@MainActor
func openSystemAudioPermissionSettings() {
    let audioRecordingPage = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    let privacyPage = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    if !NSWorkspace.shared.open(audioRecordingPage) { NSWorkspace.shared.open(privacyPage) }
}
