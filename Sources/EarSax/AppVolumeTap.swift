import CoreAudio
import Foundation
import Synchronization

/// An app's volume, set by the main thread (slider, mute) and read by the real-time audio thread.
/// Atomics only: the audio thread must never wait on a lock or allocate memory.
final class RealtimeVolumeState: Sendable {
    /// What the audio should be multiplied by (0 = silent, 1 = unchanged).
    private let targetVolumeMultiplier = Atomic<UInt32>(Float(1).bitPattern)

    func setTargetVolumeMultiplier(_ multiplier: Float) {
        targetVolumeMultiplier.store(multiplier.bitPattern, ordering: .relaxed)
    }

    var currentTargetVolumeMultiplier: Float {
        Float(bitPattern: targetVolumeMultiplier.load(ordering: .relaxed))
    }
}

/// One tap's audio callback: copies the app's captured audio to the speakers with its volume applied.
/// Each tap has its own copier, so two taps briefly overlapping during a device switch never disturb each other's glide
/// (code review, finding 3).
final class TapAudioCopier: Sendable {
    private let volume: RealtimeVolumeState
    /// The multiplier applied at the end of the last audio cycle; lets the volume glide to a new target without a click.
    /// Starts at the app's current volume, so a new tap never glides down from 100% (no blip when a tap is rebuilt).
    private let appliedVolumeMultiplier: Atomic<UInt32>

    init(volume: RealtimeVolumeState) {
        self.volume = volume
        appliedVolumeMultiplier = Atomic(volume.currentTargetVolumeMultiplier.bitPattern)
    }

    /// Runs on the real-time audio thread: no allocation, no locks.
    /// Glides from the last volume to the new one across the cycle, so a moving slider never clicks.
    /// ponytail: speaker channel N plays captured channel (N mod capturedChannelCount), so 5.1 outputs get stereo on every
    /// speaker. Proper surround mapping when someone needs it.
    func copyAppAudioToSpeakers(captured: UnsafeMutableAudioBufferListPointer, speakers: UnsafeMutableAudioBufferListPointer) {
        let targetMultiplier = volume.currentTargetVolumeMultiplier
        let startMultiplier = Float(bitPattern: appliedVolumeMultiplier.load(ordering: .relaxed))

        var capturedChannelCount = 0
        for capturedBuffer in captured { capturedChannelCount += Int(capturedBuffer.mNumberChannels) }

        var firstChannelOfThisBuffer = 0
        for speakerBuffer in speakers {
            let channelCount = Int(speakerBuffer.mNumberChannels)
            defer { firstChannelOfThisBuffer += channelCount }   // also when a buffer is skipped (review finding 10)
            guard channelCount > 0, let speakerSamples = speakerBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frameCount = Int(speakerBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            let glideStepPerFrame = frameCount > 0 ? (targetMultiplier - startMultiplier) / Float(frameCount) : 0
            for frame in 0..<frameCount {
                let multiplierAtThisFrame = startMultiplier + glideStepPerFrame * Float(frame + 1)
                for channel in 0..<channelCount {
                    let capturedSample = capturedChannelCount > 0
                        ? Self.sample(in: captured, channel: (firstChannelOfThisBuffer + channel) % capturedChannelCount, frame: frame)
                        : 0
                    speakerSamples[frame * channelCount + channel] = capturedSample * multiplierAtThisFrame
                }
            }
        }
        appliedVolumeMultiplier.store(targetMultiplier.bitPattern, ordering: .relaxed)
    }

    /// Runs on the real-time audio thread. Finds one sample by overall channel number, whatever the buffer layout.
    private static func sample(in buffers: UnsafeMutableAudioBufferListPointer, channel: Int, frame: Int) -> Float {
        var channelWithinBuffer = channel
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            if channelWithinBuffer < channelCount {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
                return frame < frameCount ? samples[frame * channelCount + channelWithinBuffer] : 0
            }
            channelWithinBuffer -= channelCount
        }
        return 0
    }
}

/// The buffer EarSax asks its private devices for: about 5.8 ms of audio (256 frames at 44.1 kHz), so the deadline stays
/// the same at higher rates (code review, finding 2), clamped to what the device allows. nil when the device
/// reports nothing usable; the device's default then stays (never trap on odd values).
func smallBufferFrames(sampleRate: Float64, allowed: AudioValueRange) -> UInt32? {
    guard sampleRate.isFinite, sampleRate > 0 else { return nil }
    let wanted = (sampleRate * 256 / 44_100).rounded()
    guard allowed.mMaximum > 0 else { return UInt32(wanted) }   // no range reported: ask anyway; a refusal keeps the default
    guard allowed.mMinimum.isFinite, allowed.mMaximum.isFinite, allowed.mMinimum >= 0,
          allowed.mMinimum <= allowed.mMaximum, allowed.mMaximum <= Double(UInt32.max) else { return nil }
    return UInt32(min(max(wanted, allowed.mMinimum.rounded(.up)), allowed.mMaximum))
}

struct TapSetupError: Error, CustomStringConvertible {
    let failedStep: String
    let status: OSStatus
    var description: String { "\(failedStep) failed (\(readableStatus(status)))" }
}

/// Per-app volume for one app. Three Core Audio pieces, created in order and destroyed in reverse:
/// 1. a process tap: captures the app's audio and silences its normal output;
/// 2. a private device: the tap as input, the real speakers or headphones as output (invisible to other apps);
/// 3. an audio callback on that device: copies input to output with the app's volume applied.
/// Used only on TapController's queue.
final class AppVolumeTap {
    /// The speakers or headphones this tap plays to.
    private(set) var outputDevicePersistentID: String
    private let tapDescription: CATapDescription
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var privateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var audioCallbackID: AudioDeviceIOProcID?

    init(appID: String, target: TapTarget, realtimeState: RealtimeVolumeState, outputDevicePersistentID: String) throws {
        self.outputDevicePersistentID = outputDevicePersistentID
        switch target {
        case .bundleIDs(let bundleIDs):
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
            tapDescription.bundleIDs = bundleIDs
            tapDescription.isProcessRestoreEnabled = true
        case .processes(let processes):
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        tapDescription.uuid = UUID()
        tapDescription.name = "EarSax: \(appID)"
        // Silence the app for as long as the tap exists. `.mutedWhenTapped` only silences it while EarSax is reading, and the
        // private device waits for the app's first audio before reading (tap auto-start), so a restarting app played at full
        // volume for a moment before dropping to its setting. The tap is private and dies with EarSax, so a crash still
        // gives the app its normal sound back (re-verified by force-quit test).
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true
        do {
            try start(appID: appID, realtimeState: realtimeState, outputDevicePersistentID: outputDevicePersistentID)
        } catch {
            stop()
            throw error
        }
    }

    private func start(appID: String, realtimeState: RealtimeVolumeState, outputDevicePersistentID: String) throws {
        var status = AudioHardwareCreateProcessTap(tapDescription, &processTapID)
        guard status == noErr else { throw TapSetupError(failedStep: "Creating the audio tap", status: status) }

        let privateDeviceSettings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EarSax \(appID)",
            kAudioAggregateDeviceUIDKey: earSaxPrivateDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDevicePersistentID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevicePersistentID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(privateDeviceSettings as CFDictionary, &privateDeviceID)
        guard status == noErr else { throw TapSetupError(failedStep: "Creating the private output", status: status) }
        useSmallAudioBuffer()

        status = AudioDeviceCreateIOProcIDWithBlock(&audioCallbackID, privateDeviceID, nil, Self.makeRealtimeAudioCallback(TapAudioCopier(volume: realtimeState)))
        guard status == noErr else { throw TapSetupError(failedStep: "Registering the audio callback", status: status) }

        status = AudioDeviceStart(privateDeviceID, audioCallbackID)
        guard status == noErr else { throw TapSetupError(failedStep: "Starting the audio", status: status) }
    }

    /// Asks the private device for small audio buffers, which set the delay EarSax adds: two buffers from capture to playback.
    /// Measured on Bluetooth earbuds (in the callback): 23.2 ms at the default 512 frames, still a visible lag on video;
    /// 11.6 ms at 256 frames, no visible lag and no crackles. Clamped to what the device allows; if it refuses, the
    /// default stays. ponytail: a fixed size; if some device crackles at 256, raise it for that device.
    /// Also re-run after a quick move, because the new speakers may allow other sizes (code review, finding 1).
    private func useSmallAudioBuffer() {
        let sampleRate = readProperty(kAudioDevicePropertyNominalSampleRate, of: privateDeviceID, orDefault: Float64(0))
        let allowed = readProperty(kAudioDevicePropertyBufferFrameSizeRange, of: privateDeviceID,
                                   orDefault: AudioValueRange(mMinimum: 0, mMaximum: 0))
        guard let frames = smallBufferFrames(sampleRate: sampleRate, allowed: allowed) else { return }
        let status = writeProperty(kAudioDevicePropertyBufferFrameSize, of: privateDeviceID, value: frames)
        if status != noErr { earSaxLog.error("Couldn't set a \(frames)-frame buffer (\(readableStatus(status))); keeping the default") }
    }

    /// Built outside any actor on purpose: Swift 6 crashes (EXC_BREAKPOINT) when Core Audio calls a main-actor closure on
    /// its real-time thread (Phase 0 crash, 2026-11-16).
    private static func makeRealtimeAudioCallback(_ copier: TapAudioCopier) -> AudioDeviceIOBlock {
        { @Sendable _, capturedAudio, _, speakerAudio, _ in
            copier.copyAppAudioToSpeakers(
                captured: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: capturedAudio)),
                speakers: UnsafeMutableAudioBufferListPointer(speakerAudio))
        }
    }

    /// Points the tap at new processes or bundle IDs (a helper started or quit) without rebuilding it, which would cause a
    /// short dropout. Only within the same kind of target. False if Core Audio refused; the caller then rebuilds.
    /// Retargeting bundle IDs on a live tap is unverified on macOS 26; the rebuild fallback covers it if it's refused.
    func retarget(to target: TapTarget) -> Bool {
        switch target {
        case .processes(let processes): tapDescription.processes = processes
        case .bundleIDs(let bundleIDs): tapDescription.bundleIDs = bundleIDs
        }
        var address = propertyAddress(kAudioTapPropertyDescription)
        var descriptionReference: CATapDescription = tapDescription
        let status = withUnsafePointer(to: &descriptionReference) {
            AudioObjectSetPropertyData(processTapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        return status == noErr
    }

    /// Sends this tap's sound to another output by changing its private device's speakers in place. The tap itself (which
    /// keeps the app silenced) is untouched, so a switch costs one short gap instead of rebuilding the whole tap, which took
    /// 0.5 to 1 s per app and left the old speakers playing meanwhile.
    /// Returns Core Audio's status; on failure the caller rebuilds the tap instead.
    func moveOutput(toDevice newOutputDevicePersistentID: String, sampleRate newSampleRate: Float64) -> OSStatus {
        let speakersStatus = writeProperty(kAudioAggregateDevicePropertyFullSubDeviceList, of: privateDeviceID,
                                           value: [newOutputDevicePersistentID] as CFArray)
        guard speakersStatus == noErr else { return speakersStatus }
        // The speakers list decides where the sound goes, so record the new device now: if the next step fails, the rebuild
        // then knows it's on the same device and pauses this tap first, instead of playing doubled sound (code review, finding 3).
        outputDevicePersistentID = newOutputDevicePersistentID
        let mainStatus = writeProperty(kAudioAggregateDevicePropertyMainSubDevice, of: privateDeviceID,
                                       value: newOutputDevicePersistentID as CFString)
        guard mainStatus == noErr else { return mainStatus }
        // New speakers at another rate (Bluetooth earbuds at 44.1 kHz, desk speakers at 48 kHz): the private device follows
        // them, and the tap's sound is resampled to it, as it already is for an app on a device of its own. Before, any rate
        // difference rebuilt the tap, which left the old speakers playing for about a second (listening test, 2026-11-16).
        if abs(sampleRate - newSampleRate) >= 1 {
            let rateStatus = writeProperty(kAudioDevicePropertyNominalSampleRate, of: privateDeviceID, value: newSampleRate)
            guard rateStatus == noErr else { return rateStatus }
            // The write is only a request; Core Audio applies it a moment later. Wait for it, or the caller rebuilds the tap
            // (code review of the cross-rate move, finding 1).
            // ponytail: polls on the tap queue for at most 250 ms; a listener on the rate if that ever shows up as a delay.
            let deadline = ContinuousClock.now + .milliseconds(250)
            while abs(sampleRate - newSampleRate) >= 1 {
                guard ContinuousClock.now < deadline else { return kAudioHardwareUnspecifiedError }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        useSmallAudioBuffer()
        return noErr
    }

    /// The rate the private device runs at.
    var sampleRate: Float64 {
        readProperty(kAudioDevicePropertyNominalSampleRate, of: privateDeviceID, orDefault: Float64(0))
    }

    /// Stops this tap's sound but keeps the tap, so its app stays silenced. Used just before a replacement on the same device.
    func pauseAudio() {
        if privateDeviceID != kAudioObjectUnknown, let audioCallbackID { AudioDeviceStop(privateDeviceID, audioCallbackID) }
    }

    func stop() {
        if privateDeviceID != kAudioObjectUnknown {
            if let audioCallbackID {
                AudioDeviceStop(privateDeviceID, audioCallbackID)
                AudioDeviceDestroyIOProcID(privateDeviceID, audioCallbackID)
            }
            AudioHardwareDestroyAggregateDevice(privateDeviceID)
        }
        if processTapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(processTapID) }
        audioCallbackID = nil
        privateDeviceID = AudioObjectID(kAudioObjectUnknown)
        processTapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// Owns every tap. All tap work runs on one background queue, because creating the first tap waits for the user to answer
/// macOS's permission prompt (2.5 minutes in Phase 0) and the menu bar must keep working meanwhile.
// ponytail: thread safety by confinement: `tapsByApp` is only read or written on `tapQueue`, hence @unchecked Sendable.
final class TapController: @unchecked Sendable {
    /// Called on the tap queue with nil when a tap is working, or a short description of what failed.
    typealias ProblemReport = @Sendable (_ problem: String?) -> Void

    private struct ActiveTap {
        let tap: AppVolumeTap
        let target: TapTarget
        let realtimeState: RealtimeVolumeState
        let reportProblem: ProblemReport
        /// When this tap's build started, so a sample-rate rebuild can skip a tap built entirely after the change. The start,
        /// not the end: a rate that changes while a tap is being built must still rebuild it (code review, finding 1).
        let builtAt: ContinuousClock.Instant
    }

    /// A tap that failed, so the same attempt isn't retried every second (permission refused, device gone).
    /// A different target or output device, or removing the tap, clears it (review finding 3).
    private struct FailedAttempt: Equatable {
        let target: TapTarget
        let outputDevicePersistentID: String
    }

    private let tapQueue = DispatchQueue(label: "app.earsax.taps", qos: .userInitiated)
    private var tapsByApp: [String: ActiveTap] = [:]
    private var failedAttemptByApp: [String: FailedAttempt] = [:]

    /// Makes sure `appID` has a working tap aimed at `target`. Cheap when nothing changed, so it can be called on every refresh.
    func ensureTap(appID: String, target: TapTarget, realtimeState: RealtimeVolumeState,
                   outputDevicePersistentID: String, reportProblem: @escaping ProblemReport) {
        tapQueue.async { [self] in
            moveTapIfNeeded(appID: appID, toOutputDevice: outputDevicePersistentID)
            if let existing = tapsByApp[appID] {
                if existing.target == target { return }
                // A helper that stopped playing leaves its bundle ID in the tap; that's harmless and avoids a dropout (finding 5).
                if case .bundleIDs(let wanted) = target, case .bundleIDs(let current) = existing.target,
                   Set(wanted).isSubset(of: Set(current)) { return }
                if Self.isSameKind(existing.target, target), existing.tap.retarget(to: target) {
                    tapsByApp[appID] = ActiveTap(tap: existing.tap, target: target, realtimeState: realtimeState,
                                                 reportProblem: reportProblem, builtAt: existing.builtAt)
                    earSaxLog.notice("Tap for \(appID) retargeted to \(String(describing: target))")
                    return
                }
                replaceTap(appID: appID, oldTap: existing.tap, target: target, realtimeState: realtimeState,
                           outputDevicePersistentID: outputDevicePersistentID, reportProblem: reportProblem,
                           reason: "its processes changed")
                return
            } else if failedAttemptByApp[appID] == FailedAttempt(target: target, outputDevicePersistentID: outputDevicePersistentID) {
                return
            }
            createTap(appID: appID, target: target, realtimeState: realtimeState,
                      outputDevicePersistentID: outputDevicePersistentID, reportProblem: reportProblem)
        }
    }

    func removeTap(appID: String) {
        tapQueue.async { [self] in
            failedAttemptByApp[appID] = nil
            guard let removed = tapsByApp.removeValue(forKey: appID) else { return }
            removed.tap.stop()
            earSaxLog.notice("Tap removed for \(appID)")
        }
    }

    /// Plays `appID`'s tap on another output: the main output changed, or the app got its own device. Nothing happens when
    /// the app has no tap or already plays there, so it can be called on every refresh.
    func moveTap(appID: String, toOutputDevice outputDevicePersistentID: String) {
        tapQueue.async { [self] in moveTapIfNeeded(appID: appID, toOutputDevice: outputDevicePersistentID) }
    }

    /// Rebuilds the taps that match, each on the device it already plays on, because a sample rate changed (Bluetooth
    /// switching to call quality, for example). A tap built at or after `changedAt` already runs at the new rate and is left
    /// alone: when headphones connected, the move to them rebuilt the tap and then this rebuilt it again, a second gap in
    /// the sound for nothing.
    func rebuildTaps(changedAt: ContinuousClock.Instant,
                     where isAffected: @escaping @Sendable (_ appID: String, _ outputDevicePersistentID: String) -> Bool) {
        tapQueue.async { [self] in
            for (appID, active) in tapsByApp where active.builtAt < changedAt && isAffected(appID, active.tap.outputDevicePersistentID) {
                replaceTap(appID: appID, oldTap: active.tap, target: active.target, realtimeState: active.realtimeState,
                           outputDevicePersistentID: active.tap.outputDevicePersistentID, reportProblem: active.reportProblem,
                           reason: "a sample rate changed")
            }
        }
    }

    /// Triggers macOS's permission prompt without touching any app: a tap on no process, in a private device on the current
    /// output, started and then torn down. Creating the tap alone doesn't make macOS ask; reading
    /// through it does. `whenAnswered` runs once the probe is finished, normally after the user answers.
    func askForSystemAudioPermission(outputDevicePersistentID: String, whenAnswered: @escaping @Sendable () -> Void) {
        tapQueue.async {
            defer { whenAnswered() }
            let emptyTap = CATapDescription(stereoMixdownOfProcesses: [])
            emptyTap.uuid = UUID()
            emptyTap.isPrivate = true
            var emptyTapID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(emptyTap, &emptyTapID) == noErr else { return }
            defer { AudioHardwareDestroyProcessTap(emptyTapID) }

            let probeDeviceSettings: [String: Any] = [
                kAudioAggregateDeviceNameKey: "EarSax permission check",
                kAudioAggregateDeviceUIDKey: earSaxPrivateDevicePrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputDevicePersistentID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevicePersistentID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: emptyTap.uuid.uuidString]],
            ]   // no tap auto-start: an empty tap never sends audio, so a start that waited for it would never return
            var probeDeviceID = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(probeDeviceSettings as CFDictionary, &probeDeviceID) == noErr else { return }
            defer { AudioHardwareDestroyAggregateDevice(probeDeviceID) }

            var probeCallbackID: AudioDeviceIOProcID?
            guard AudioDeviceCreateIOProcIDWithBlock(&probeCallbackID, probeDeviceID, nil, Self.makeSilentProbeCallback()) == noErr,
                  let probeCallbackID else { return }
            defer { AudioDeviceDestroyIOProcID(probeDeviceID, probeCallbackID) }
            if AudioDeviceStart(probeDeviceID, probeCallbackID) == noErr { AudioDeviceStop(probeDeviceID, probeCallbackID) }
        }
    }

    /// Writes nothing: Core Audio hands the probe zeroed output buffers, so it plays silence for the instant it runs.
    private static func makeSilentProbeCallback() -> AudioDeviceIOBlock { { @Sendable _, _, _, _, _ in } }

    /// Removes every tap without waiting (the permission was taken away).
    func removeAllTaps() {
        tapQueue.async { [self] in
            for active in tapsByApp.values { active.tap.stop() }
            tapsByApp.removeAll()
            failedAttemptByApp.removeAll()
            earSaxLog.notice("All taps removed")
        }
    }

    /// Runs on the tap queue.
    private func moveTapIfNeeded(appID: String, toOutputDevice outputDevicePersistentID: String) {
        guard let active = tapsByApp[appID], active.tap.outputDevicePersistentID != outputDevicePersistentID else { return }
        // A quick move whenever the old output still exists, at any sample rate (the move sets the new rate). A device that
        // just disappeared, or a refused move, rebuilds the tap (code review, findings 1 and 2).
        let movedAt = ContinuousClock.now
        let previousOutputStillConnected = deviceID(forPersistentID: active.tap.outputDevicePersistentID) != kAudioObjectUnknown
        let newSampleRate = readProperty(kAudioDevicePropertyNominalSampleRate,
                                         of: deviceID(forPersistentID: outputDevicePersistentID), orDefault: Float64(0))
        if previousOutputStillConnected, newSampleRate > 0 {
            let previousSampleRate = active.tap.sampleRate
            let startedAt = ContinuousClock.now
            let status = active.tap.moveOutput(toDevice: outputDevicePersistentID, sampleRate: newSampleRate)
            let elapsed = (ContinuousClock.now - startedAt).components
            let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            if status == noErr {
                // The rates in the log let QA tell a cross-rate move from a same-rate one.
                let rates = abs(previousSampleRate - newSampleRate) >= 1 ? ", \(Int(previousSampleRate)) to \(Int(newSampleRate)) Hz" : ""
                earSaxLog.notice("Moved \(appID) to \(outputDevicePersistentID) in \(milliseconds) ms\(rates)")
                // Counts as built now, so a sample-rate notice from before the move doesn't rebuild it (code review of the
                // cross-rate move, finding 5).
                tapsByApp[appID] = ActiveTap(tap: active.tap, target: active.target, realtimeState: active.realtimeState,
                                             reportProblem: active.reportProblem, builtAt: movedAt)
                return
            }
            earSaxLog.error("Moving \(appID) to \(outputDevicePersistentID) failed (\(readableStatus(status))); rebuilding its tap")
        }
        replaceTap(appID: appID, oldTap: active.tap, target: active.target, realtimeState: active.realtimeState,
                   outputDevicePersistentID: outputDevicePersistentID, reportProblem: active.reportProblem,
                   reason: previousOutputStillConnected ? "the quick move didn't work" : "its device disconnected")
    }

    /// Called when EarSax quits, so apps go straight back to normal. Waits at most two seconds: if the queue is stuck on the
    /// permission prompt, quitting must still work (macOS removes the taps when EarSax exits anyway).
    func removeAllTapsBeforeQuitting() {
        let finished = DispatchSemaphore(value: 0)
        tapQueue.async { [self] in
            for active in tapsByApp.values { active.tap.stop() }
            tapsByApp.removeAll()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 2)
    }

    /// Make before break: the new tap starts before the old one stops, so the app is never left untapped for a moment,
    /// which plays it at full volume (heard as a jump when switching from a Bluetooth speaker to USB desk speakers).
    private func replaceTap(appID: String, oldTap: AppVolumeTap, target: TapTarget, realtimeState: RealtimeVolumeState,
                            outputDevicePersistentID: String, reportProblem: @escaping ProblemReport, reason: String) {
        earSaxLog.notice("Rebuilding the tap for \(appID) on \(outputDevicePersistentID): \(reason)")
        // On the same device both taps would play to the same speakers for a moment (doubled sound). Pause the old tap's
        // sound first; it keeps the app silenced, so the cost is a brief silence, never a loud moment (review of c517aef, 1).
        if oldTap.outputDevicePersistentID == outputDevicePersistentID { oldTap.pauseAudio() }
        // A failure here isn't reported yet: the retry below decides the outcome, so the panel never flashes a stale error.
        createTap(appID: appID, target: target, realtimeState: realtimeState,
                  outputDevicePersistentID: outputDevicePersistentID, reportProblem: reportProblem, reportsFailure: false)
        oldTap.stop()
        guard tapsByApp[appID]?.tap === oldTap else { return }
        // The new tap failed, possibly because the old one still existed. Try once more without it (review of c517aef, 2).
        tapsByApp[appID] = nil
        failedAttemptByApp[appID] = nil
        createTap(appID: appID, target: target, realtimeState: realtimeState,
                  outputDevicePersistentID: outputDevicePersistentID, reportProblem: reportProblem)
    }

    private static func isSameKind(_ first: TapTarget, _ second: TapTarget) -> Bool {
        switch (first, second) {
        case (.processes, .processes), (.bundleIDs, .bundleIDs): true
        default: false
        }
    }

    private func createTap(appID: String, target: TapTarget, realtimeState: RealtimeVolumeState,
                           outputDevicePersistentID: String, reportProblem: @escaping ProblemReport, reportsFailure: Bool = true) {
        let startedBuildingAt = ContinuousClock.now
        do {
            let tap = try AppVolumeTap(appID: appID, target: target, realtimeState: realtimeState,
                                       outputDevicePersistentID: outputDevicePersistentID)
            tapsByApp[appID] = ActiveTap(tap: tap, target: target, realtimeState: realtimeState, reportProblem: reportProblem,
                                         builtAt: startedBuildingAt)
            failedAttemptByApp[appID] = nil
            earSaxLog.notice("Tap started for \(appID) on \(outputDevicePersistentID) (\(String(describing: target)))")
            reportProblem(nil)
        } catch {
            failedAttemptByApp[appID] = FailedAttempt(target: target, outputDevicePersistentID: outputDevicePersistentID)
            earSaxLog.error("Tap failed for \(appID): \(String(describing: error))")
            if reportsFailure { reportProblem("\(error)") }
        }
    }
}
