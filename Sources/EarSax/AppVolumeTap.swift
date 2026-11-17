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

/// What one speaker channel plays.
enum SpeakerFeed: Equatable {
    case left, right, bothMixed, silent
}

/// Which captured channel a speaker channel plays. The app's stereo goes to the device's stereo pair only (macOS's
/// "Configure Speakers" choice, 0-based here), so an 8-output audio interface no longer plays music on all 8 outputs;
/// a mono speaker gets left and right mixed, instead of the left channel only (FineTune #105). A pair that doesn't fit
/// the device falls back to the first two channels.
func speakerFeed(channel: Int, speakerChannelCount: Int, stereoPair: (left: Int, right: Int)) -> SpeakerFeed {
    if speakerChannelCount == 1 { return .bothMixed }
    let channels = 0..<speakerChannelCount
    let pairFits = stereoPair.left != stereoPair.right && channels.contains(stereoPair.left) && channels.contains(stereoPair.right)
    let pair = pairFits ? stereoPair : (left: 0, right: 1)
    return channel == pair.left ? .left : channel == pair.right ? .right : .silent
}

/// Equal-power crossfade curve: at `progress` 0 silent, at 1 full. The old path plays `gain(1 - p)` while the new one plays
/// `gain(p)`, and their squares always add up to 1, so the level doesn't dip halfway through the fade.
func equalPowerGain(_ progress: Float) -> Float {
    progress >= 1 ? 1 : progress <= 0 ? 0 : sin(progress * .pi / 2)
}

/// One private device's audio callback: copies the app's captured audio to the speakers with its volume applied, and
/// fades in or out during a crossfade. Each private device has its own copier, so two overlapping during a switch never
/// disturb each other's glide (code review, finding 3).
final class TapAudioCopier: Sendable {
    private let volume: RealtimeVolumeState
    /// The multiplier applied at the end of the last audio cycle; lets the volume glide to a new target without a click.
    /// Starts at the app's current volume, so a new tap never glides down from 100% (no blip when a tap is rebuilt).
    private let appliedVolumeMultiplier: Atomic<UInt32>
    /// Crossfade position, 0 (silent) to 1 (full); moves toward the target by the step on each frame. Written by the audio
    /// thread, except when `jumpFade` sets it for a device that isn't running.
    private let fadeProgress: Atomic<UInt32>
    private let fadeTarget: Atomic<UInt32>
    private let fadeStepPerFrame = Atomic<UInt32>(Float(1).bitPattern)
    /// The device's stereo pair, 0-based (see `speakerFeed`).
    private let leftSpeakerChannel = Atomic<Int>(0)
    private let rightSpeakerChannel = Atomic<Int>(1)
    /// For the crossfade's checks: has the callback run, has it seen sound since it started, and when it last did.
    private let audioCycleCount = Atomic<Int>(0)
    private let lastSoundAtNanoseconds = Atomic<UInt64>(0)
    private let heardSound = Atomic<Bool>(false)

    init(volume: RealtimeVolumeState, fadedIn: Bool = true) {
        self.volume = volume
        appliedVolumeMultiplier = Atomic(volume.currentTargetVolumeMultiplier.bitPattern)
        fadeProgress = Atomic(Float(fadedIn ? 1 : 0).bitPattern)
        fadeTarget = Atomic(Float(fadedIn ? 1 : 0).bitPattern)
    }

    func useStereoPair(_ pair: (left: Int, right: Int)) {
        leftSpeakerChannel.store(pair.left, ordering: .relaxed)
        rightSpeakerChannel.store(pair.right, ordering: .relaxed)
    }

    /// Fades to `target` (0 or 1) over `frames` audio frames, on the audio thread.
    func startFade(to target: Float, overFrames frames: Double) {
        fadeStepPerFrame.store(Float(1 / max(frames, 1)).bitPattern, ordering: .relaxed)
        fadeTarget.store(target.bitPattern, ordering: .relaxed)
    }

    /// Sets the fade at once: for a device whose callback isn't running (the app is silent), so nothing would move it.
    func jumpFade(to target: Float) {
        startFade(to: target, overFrames: 1)
        fadeProgress.store(target.bitPattern, ordering: .relaxed)
    }

    var hasRunAudioCycle: Bool { audioCycleCount.load(ordering: .relaxed) > 0 }
    /// True once a fade-out has reached silence, counted in audio cycles, so a device with large buffers takes longer.
    var hasFadedOut: Bool { Float(bitPattern: fadeProgress.load(ordering: .relaxed)) <= 0 }
    var hasHeardSound: Bool { heardSound.load(ordering: .relaxed) }

    func heardSound(within window: Duration) -> Bool {
        let last = lastSoundAtNanoseconds.load(ordering: .relaxed)
        let windowNanoseconds = UInt64(window.components.seconds) * 1_000_000_000 + UInt64(window.components.attoseconds / 1_000_000_000)
        return last > 0 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last < windowNanoseconds
    }

    /// Runs on the real-time audio thread: no allocation, no locks.
    /// Glides from the last volume to the new one across the cycle, so a moving slider never clicks.
    func copyAppAudioToSpeakers(captured: UnsafeMutableAudioBufferListPointer, speakers: UnsafeMutableAudioBufferListPointer) {
        audioCycleCount.add(1, ordering: .relaxed)
        let targetMultiplier = volume.currentTargetVolumeMultiplier
        let startMultiplier = Float(bitPattern: appliedVolumeMultiplier.load(ordering: .relaxed))
        let fadeGoal = Float(bitPattern: fadeTarget.load(ordering: .relaxed))
        let fadeStep = Float(bitPattern: fadeStepPerFrame.load(ordering: .relaxed))
        let fadeStart = Float(bitPattern: fadeProgress.load(ordering: .relaxed))
        let stereoPair = (left: leftSpeakerChannel.load(ordering: .relaxed), right: rightSpeakerChannel.load(ordering: .relaxed))

        var capturedChannelCount = 0
        for capturedBuffer in captured { capturedChannelCount += Int(capturedBuffer.mNumberChannels) }
        var speakerChannelCount = 0
        for speakerBuffer in speakers { speakerChannelCount += Int(speakerBuffer.mNumberChannels) }

        var fadeAtEnd = fadeStart
        var cycleHadSound = false
        var firstChannelOfThisBuffer = 0
        for speakerBuffer in speakers {
            let channelCount = Int(speakerBuffer.mNumberChannels)
            defer { firstChannelOfThisBuffer += channelCount }   // also when a buffer is skipped (review finding 10)
            guard channelCount > 0, let speakerSamples = speakerBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frameCount = Int(speakerBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            let glideStepPerFrame = frameCount > 0 ? (targetMultiplier - startMultiplier) / Float(frameCount) : 0
            var fade = fadeStart
            for frame in 0..<frameCount {
                fade = fade < fadeGoal ? min(fade + fadeStep, fadeGoal) : max(fade - fadeStep, fadeGoal)
                let gain = (startMultiplier + glideStepPerFrame * Float(frame + 1)) * equalPowerGain(fade)
                let left = capturedChannelCount > 0 ? Self.sample(in: captured, channel: 0, frame: frame) : 0
                let right = capturedChannelCount > 1 ? Self.sample(in: captured, channel: 1, frame: frame) : left
                if left != 0 || right != 0 { cycleHadSound = true }
                for channel in 0..<channelCount {
                    let source: Float = switch speakerFeed(channel: firstChannelOfThisBuffer + channel,
                                                           speakerChannelCount: speakerChannelCount, stereoPair: stereoPair) {
                    case .left: left
                    case .right: right
                    case .bothMixed: (left + right) * 0.5
                    case .silent: 0
                    }
                    speakerSamples[frame * channelCount + channel] = source * gain
                }
            }
            fadeAtEnd = fade
        }
        appliedVolumeMultiplier.store(targetMultiplier.bitPattern, ordering: .relaxed)
        fadeProgress.store(fadeAtEnd.bitPattern, ordering: .relaxed)
        if cycleHadSound {
            heardSound.store(true, ordering: .relaxed)
            lastSoundAtNanoseconds.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        }
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

/// Where a private device sends its sound: the sub-devices to list and the one that keeps time. A Multi-Output or other
/// aggregate device the user made is unpacked into its own sub-devices, because a private device holding another
/// aggregate device plays silence (FineTune #186). Any other device is used as it is.
struct SpeakerLayout {
    let subDevices: [[String: Any]]
    let mainSubDevice: String
    let isStacked: Bool

    var isSingleDevice: Bool { subDevices.count == 1 && !isStacked }

    static func plain(_ persistentID: String) -> SpeakerLayout {
        SpeakerLayout(subDevices: [[kAudioSubDeviceUIDKey: persistentID]], mainSubDevice: persistentID, isStacked: false)
    }

    static func of(_ persistentID: String) -> SpeakerLayout {
        let device = deviceID(forPersistentID: persistentID)
        guard readProperty(kAudioDevicePropertyTransportType, of: device, orDefault: UInt32(0)) == kAudioDeviceTransportTypeAggregate,
              let composition = readDictionaryProperty(kAudioAggregateDevicePropertyComposition, of: device),
              // Sub-devices with no speakers (a microphone in the user's aggregate) stay out: their input would sit next to
              // the tap's in the callback (code review, unverified point).
              let subDevices = (composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])?.filter({
                  hasOutputStreams(($0[kAudioSubDeviceUIDKey] as? String) ?? "")
              }), !subDevices.isEmpty,
              let main = composition[kAudioAggregateDeviceMainSubDeviceKey] as? String
                ?? subDevices.first?[kAudioSubDeviceUIDKey] as? String
        else { return .plain(persistentID) }
        return SpeakerLayout(subDevices: subDevices, mainSubDevice: main,
                             isStacked: (composition[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.boolValue ?? false)
    }
}

/// The device's stereo pair (Audio MIDI Setup, "Configure Speakers"), 0-based; the first two channels if it reports none.
func stereoPair(ofOutput persistentID: String) -> (left: Int, right: Int) {
    let pair = readPropertyList(kAudioDevicePropertyPreferredChannelsForStereo, of: deviceID(forPersistentID: persistentID),
                                scope: kAudioObjectPropertyScopeOutput, elementType: UInt32.self)
    guard pair.count == 2, pair[0] >= 1, pair[1] >= 1 else { return (0, 1) }
    return (Int(pair[0]) - 1, Int(pair[1]) - 1)
}

/// One private device: the app's tap as input, real speakers or headphones as output, and the audio callback between
/// them. An app normally has one; a crossfade runs a second on the new speakers for a moment.
/// Used only on TapController's queue.
final class SpeakerPath {
    /// The speakers or headphones this path plays to.
    private(set) var outputDevicePersistentID: String
    let copier: TapAudioCopier
    private var privateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var audioCallbackID: AudioDeviceIOProcID?

    init(appID: String, tapUUID: String, realtimeState: RealtimeVolumeState, outputDevicePersistentID: String,
         fadedIn: Bool) throws {
        self.outputDevicePersistentID = outputDevicePersistentID
        copier = TapAudioCopier(volume: realtimeState, fadedIn: fadedIn)
        do {
            let layout = SpeakerLayout.of(outputDevicePersistentID)
            var status = createPrivateDevice(appID: appID, tapUUID: tapUUID, layout: layout)
            if status != noErr, !layout.isSingleDevice {
                // ponytail: unpacking a user's aggregate device is unverified with a tap inside; if Core Audio refuses it,
                // use the device as it is, as before.
                earSaxLog.error("Unpacking \(outputDevicePersistentID) failed (\(readableStatus(status))); using it as it is")
                status = createPrivateDevice(appID: appID, tapUUID: tapUUID, layout: .plain(outputDevicePersistentID))
            }
            guard status == noErr else { throw TapSetupError(failedStep: "Creating the private output", status: status) }
            useSmallAudioBuffer()
            copier.useStereoPair(stereoPair(ofOutput: outputDevicePersistentID))

            status = AudioDeviceCreateIOProcIDWithBlock(&audioCallbackID, privateDeviceID, nil, Self.makeRealtimeAudioCallback(copier))
            guard status == noErr else { throw TapSetupError(failedStep: "Registering the audio callback", status: status) }

            status = AudioDeviceStart(privateDeviceID, audioCallbackID)
            guard status == noErr else { throw TapSetupError(failedStep: "Starting the audio", status: status) }
        } catch {
            stop()
            throw error
        }
    }

    private func createPrivateDevice(appID: String, tapUUID: String, layout: SpeakerLayout) -> OSStatus {
        let privateDeviceSettings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EarSax \(appID)",
            kAudioAggregateDeviceUIDKey: earSaxPrivateDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: layout.mainSubDevice,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: layout.isStacked,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: layout.subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        return AudioHardwareCreateAggregateDevice(privateDeviceSettings as CFDictionary, &privateDeviceID)
    }

    /// Asks the private device for small audio buffers, which set the delay EarSax adds: two buffers from capture to playback.
    /// Measured on Bluetooth earbuds (in the callback): 23.2 ms at the default 512 frames, still a visible lag on video;
    /// 11.6 ms at 256 frames, no visible lag and no crackles. Clamped to what the device allows; if it refuses, the
    /// default stays. ponytail: a fixed size; if some device crackles at 256, raise it for that device.
    /// Also re-run after a quick move, because the new speakers may allow other sizes (code review, finding 1).
    private func useSmallAudioBuffer() {
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

    /// The quick move, now the fallback when a crossfade can't run: changes this private device's speakers in place, one
    /// short gap. The tap (which keeps the app silenced) is untouched.
    /// Returns Core Audio's status; on failure the caller rebuilds the tap instead.
    func moveOutput(toDevice newOutputDevicePersistentID: String, sampleRate newSampleRate: Float64) -> OSStatus {
        // A user's aggregate device needs its sub-devices unpacked, which only a new private device does.
        // (A user's aggregate with one sub-device is single too, but its own ID would still nest it: review finding 5.)
        let layout = SpeakerLayout.of(newOutputDevicePersistentID)
        guard layout.isSingleDevice, layout.mainSubDevice == newOutputDevicePersistentID else {
            return kAudioHardwareUnsupportedOperationError
        }
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
        // them, and the tap's sound is resampled to it (listening test, 2026-11-16).
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
        copier.useStereoPair(stereoPair(ofOutput: newOutputDevicePersistentID))
        return noErr
    }

    /// The rate the private device runs at.
    var sampleRate: Float64 {
        readProperty(kAudioDevicePropertyNominalSampleRate, of: privateDeviceID, orDefault: Float64(0))
    }

    /// Stops this path's sound; the tap keeps the app silenced.
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
        audioCallbackID = nil
        privateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// Per-app volume for one app: a process tap, which captures the app's audio and silences its normal output, and the
/// speaker path that plays it (two for a moment during a crossfade). Created in that order, destroyed in reverse.
/// Used only on TapController's queue.
final class AppVolumeTap {
    private let appID: String
    private let realtimeState: RealtimeVolumeState
    private let tapDescription: CATapDescription
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var speakers: SpeakerPath?
    /// The new speakers during a crossfade, silent until the fade starts.
    private var incomingSpeakers: SpeakerPath?

    /// The speakers or headphones this tap plays to.
    var outputDevicePersistentID: String { speakers?.outputDevicePersistentID ?? "" }
    var incomingOutputDevicePersistentID: String? { incomingSpeakers?.outputDevicePersistentID }

    init(appID: String, target: TapTarget, realtimeState: RealtimeVolumeState, outputDevicePersistentID: String) throws {
        self.appID = appID
        self.realtimeState = realtimeState
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
        let status = AudioHardwareCreateProcessTap(tapDescription, &processTapID)
        guard status == noErr else { throw TapSetupError(failedStep: "Creating the audio tap", status: status) }
        do {
            speakers = try SpeakerPath(appID: appID, tapUUID: tapDescription.uuid.uuidString, realtimeState: realtimeState,
                                       outputDevicePersistentID: outputDevicePersistentID, fadedIn: true)
        } catch {
            stop()
            throw error
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

    func moveOutput(toDevice newOutputDevicePersistentID: String, sampleRate newSampleRate: Float64) -> OSStatus {
        speakers?.moveOutput(toDevice: newOutputDevicePersistentID, sampleRate: newSampleRate) ?? kAudioHardwareNotRunningError
    }

    var sampleRate: Float64 { speakers?.sampleRate ?? 0 }

    // MARK: Crossfade (ruling R29)

    /// Step 1: a second private device on the new speakers, fed by the same tap, silent. The old one keeps playing.
    func startCrossfade(toDevice newOutputDevicePersistentID: String) throws {
        cancelCrossfade()
        incomingSpeakers = try SpeakerPath(appID: appID, tapUUID: tapDescription.uuid.uuidString, realtimeState: realtimeState,
                                           outputDevicePersistentID: newOutputDevicePersistentID, fadedIn: false)
    }

    /// The new device's callback has run: it is playing (silence, until the fade).
    var incomingIsRunning: Bool { incomingSpeakers?.copier.hasRunAudioCycle ?? false }
    var incomingHasHeardSound: Bool { incomingSpeakers?.copier.hasHeardSound ?? false }
    /// The app played something on the old speakers just now, so a fade is worth waiting for.
    func isPlaying(within window: Duration) -> Bool { speakers?.copier.heardSound(within: window) ?? false }

    /// Step 2: the new speakers fade in, then the old ones fade out (TapController times the two).
    func fadeInIncoming(over duration: Duration) {
        guard let incomingSpeakers else { return }
        if incomingSpeakers.copier.hasRunAudioCycle {
            incomingSpeakers.copier.startFade(to: 1, overFrames: seconds(duration) * incomingSpeakers.sampleRate)
        } else {
            incomingSpeakers.copier.jumpFade(to: 1)   // not running: nothing would move its fade
        }
    }

    func fadeOutOutgoing(over duration: Duration) {
        guard let speakers else { return }
        speakers.copier.startFade(to: 0, overFrames: seconds(duration) * speakers.sampleRate)
    }

    var outgoingHasFadedOut: Bool { speakers?.copier.hasFadedOut ?? true }

    /// Step 3: the old private device goes; the new one is now the tap's speakers.
    func finishCrossfade() {
        guard let incomingSpeakers else { return }
        speakers?.stop()
        speakers = incomingSpeakers
        self.incomingSpeakers = nil
    }

    func cancelCrossfade() {
        incomingSpeakers?.stop()
        incomingSpeakers = nil
    }

    /// Stops this tap's sound but keeps the tap, so its app stays silenced. Used just before a replacement on the same device.
    func pauseAudio() {
        speakers?.pauseAudio()
    }

    func stop() {
        cancelCrossfade()
        speakers?.stop()
        speakers = nil
        if processTapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(processTapID) }
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
            moveTapsIfNeeded([appID: outputDevicePersistentID])
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

    /// Runs `action` on the main thread once every tap change asked for before it is done (the queue is serial).
    func afterQueuedWork(_ action: @escaping @MainActor @Sendable () -> Void) {
        tapQueue.async { Task { @MainActor in action() } }
    }

    func removeTap(appID: String) {
        tapQueue.async { [self] in
            failedAttemptByApp[appID] = nil
            guard let removed = tapsByApp.removeValue(forKey: appID) else { return }
            removed.tap.stop()
            earSaxLog.notice("Tap removed for \(appID)")
        }
    }

    /// Plays each app's tap on the output given for it: the main output changed, or an app got its own device. Apps with no
    /// tap or already there are skipped, so it can be called on every refresh. All moves crossfade together.
    func moveTaps(_ outputByApp: [String: String]) {
        tapQueue.async { [self] in moveTapsIfNeeded(outputByApp) }
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

    /// Crossfade timing (ruling R29): how long a new device runs silently before the fade, then the fade itself. The warm-up
    /// covers the moment a device takes to really sound after it starts; Bluetooth takes longer (FineTune uses the same
    /// figures).
    private static let wiredWarmUp = Duration.milliseconds(50)
    private static let bluetoothWarmUp = Duration.milliseconds(300)
    private static let fadeLength = Duration.milliseconds(50)
    /// An app that played nothing for this long counts as silent: no crossfade.
    private static let recentSound = Duration.milliseconds(500)

    /// Runs on the tap queue. Every move is a crossfade: a second private device on the new speakers, a short warm-up, then
    /// the old speakers fade out while the new ones fade in, so no silence is heard. All the apps moving at once share one
    /// warm-up. A device that just disappeared, or a crossfade that can't start, falls back to the quick move and then a
    /// rebuild, as before.
    private func moveTapsIfNeeded(_ outputByApp: [String: String]) {
        let movedAt = ContinuousClock.now
        var crossfading: [(appID: String, active: ActiveTap)] = []
        for (appID, newOutput) in outputByApp {
            guard let active = tapsByApp[appID], active.tap.outputDevicePersistentID != newOutput else { continue }
            let bothConnected = deviceID(forPersistentID: active.tap.outputDevicePersistentID) != kAudioObjectUnknown
                && deviceID(forPersistentID: newOutput) != kAudioObjectUnknown
            // Only an app heard right now is worth a crossfade. A silent or muted one takes the quick move (a few ms), so it
            // never makes the switch wait (code review, finding 3).
            let isAudible = active.tap.isPlaying(within: Self.recentSound) && active.realtimeState.currentTargetVolumeMultiplier > 0
            guard bothConnected, isAudible else {
                quickMoveOrRebuild(appID: appID, active: active, toOutputDevice: newOutput, movedAt: movedAt)
                continue
            }
            do {
                try active.tap.startCrossfade(toDevice: newOutput)
                crossfading.append((appID, active))
            } catch {
                earSaxLog.error("Crossfade for \(appID) couldn't start: \(String(describing: error)); moving it directly")
                quickMoveOrRebuild(appID: appID, active: active, toOutputDevice: newOutput, movedAt: movedAt)
            }
        }
        guard !crossfading.isEmpty else { return }

        // Wait for each new device to run, at most a second, then let it warm up.
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline, !crossfading.allSatisfy({ $0.active.tap.incomingIsRunning }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let anyBluetooth = crossfading.contains { isBluetoothDevice($0.active.tap.incomingOutputDevicePersistentID ?? "") }
        Thread.sleep(forTimeInterval: seconds(anyBluetooth ? Self.bluetoothWarmUp : Self.wiredWarmUp))

        var fading: [(appID: String, active: ActiveTap, fadeOutDelay: TimeInterval)] = []
        for (appID, active) in crossfading {
            let tap = active.tap
            let newOutput = tap.incomingOutputDevicePersistentID ?? ""
            // Both private devices read the same tap. If the new one has had no sound while the app still plays (it never
            // started, or sharing the tap doesn't work), fall back rather than fade into silence (code review, finding 1).
            if tap.isPlaying(within: Self.recentSound), !tap.incomingHasHeardSound {
                earSaxLog.error("Crossfade for \(appID): the new device got no sound from the tap; moving it directly")
                tap.cancelCrossfade()
                quickMoveOrRebuild(appID: appID, active: active, toOutputDevice: newOutput, movedAt: movedAt)
                continue
            }
            // A device with more output delay (Bluetooth) is heard later; the old one keeps playing that much longer, or the
            // gap comes back between them (code review, finding 2). Capped, in case a device reports nonsense.
            let delayDifference = outputDelaySeconds(newOutput) - outputDelaySeconds(tap.outputDevicePersistentID)
            fading.append((appID, active, min(max(delayDifference, 0), 0.5)))
        }
        for (_, active, _) in fading { active.tap.fadeInIncoming(over: Self.fadeLength) }
        var waited: TimeInterval = 0
        for (_, active, fadeOutDelay) in fading.sorted(by: { $0.fadeOutDelay < $1.fadeOutDelay }) {
            if fadeOutDelay > waited { Thread.sleep(forTimeInterval: fadeOutDelay - waited); waited = fadeOutDelay }
            active.tap.fadeOutOutgoing(over: Self.fadeLength)
        }
        // The fades run in audio cycles; wait until every old path is silent (a device with large buffers takes longer),
        // at most 300 ms past the fade (code review, finding 6).
        let fadeDeadline = ContinuousClock.now + Self.fadeLength + .milliseconds(300)
        while ContinuousClock.now < fadeDeadline, !fading.allSatisfy({ $0.active.tap.outgoingHasFadedOut }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        for (appID, active, fadeOutDelay) in fading {
            let newOutput = active.tap.incomingOutputDevicePersistentID ?? ""
            active.tap.finishCrossfade()
            // Counts as built at the start of the move, so a sample-rate notice from before it doesn't rebuild it (code review
            // of the cross-rate move, finding 5).
            tapsByApp[appID] = ActiveTap(tap: active.tap, target: active.target, realtimeState: active.realtimeState,
                                         reportProblem: active.reportProblem, builtAt: movedAt)
            earSaxLog.notice("Crossfaded \(appID) to \(newOutput) in \(milliseconds(since: movedAt)) ms (old device kept \(Int(fadeOutDelay * 1000)) ms longer)")
        }
    }

    /// Runs on the tap queue. The move from before crossfades: the private device's speakers changed in place (one short
    /// gap), or the whole tap rebuilt when that fails or the old device is gone.
    private func quickMoveOrRebuild(appID: String, active: ActiveTap, toOutputDevice outputDevicePersistentID: String,
                                    movedAt: ContinuousClock.Instant) {
        let previousOutputStillConnected = deviceID(forPersistentID: active.tap.outputDevicePersistentID) != kAudioObjectUnknown
        let newSampleRate = readProperty(kAudioDevicePropertyNominalSampleRate,
                                         of: deviceID(forPersistentID: outputDevicePersistentID), orDefault: Float64(0))
        if previousOutputStillConnected, newSampleRate > 0 {
            let previousSampleRate = active.tap.sampleRate
            let startedAt = ContinuousClock.now
            let status = active.tap.moveOutput(toDevice: outputDevicePersistentID, sampleRate: newSampleRate)
            if status == noErr {
                // The rates in the log let QA tell a cross-rate move from a same-rate one.
                let rates = abs(previousSampleRate - newSampleRate) >= 1 ? ", \(Int(previousSampleRate)) to \(Int(newSampleRate)) Hz" : ""
                earSaxLog.notice("Moved \(appID) to \(outputDevicePersistentID) in \(milliseconds(since: startedAt)) ms\(rates)")
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

private func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
    let elapsed = (ContinuousClock.now - start).components
    return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
}

private func isBluetoothDevice(_ persistentID: String) -> Bool {
    let transport = readProperty(kAudioDevicePropertyTransportType, of: deviceID(forPersistentID: persistentID), orDefault: UInt32(0))
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
}

private func hasOutputStreams(_ persistentID: String) -> Bool {
    !readPropertyList(kAudioDevicePropertyStreams, of: deviceID(forPersistentID: persistentID),
                      scope: kAudioObjectPropertyScopeOutput, elementType: AudioStreamID.self).isEmpty
}

/// How long after the audio callback a device's sound is heard: its latency, safety offset and output stream latency.
private func outputDelaySeconds(_ persistentID: String) -> TimeInterval {
    let device = deviceID(forPersistentID: persistentID)
    let sampleRate = readProperty(kAudioDevicePropertyNominalSampleRate, of: device, orDefault: Float64(0))
    guard sampleRate > 0 else { return 0 }
    let output = kAudioObjectPropertyScopeOutput
    let deviceFrames = readProperty(kAudioDevicePropertyLatency, of: device, scope: output, orDefault: UInt32(0))
    let safetyFrames = readProperty(kAudioDevicePropertySafetyOffset, of: device, scope: output, orDefault: UInt32(0))
    let streamFrames = readPropertyList(kAudioDevicePropertyStreams, of: device, scope: output, elementType: AudioStreamID.self)
        .first.map { readProperty(kAudioStreamPropertyLatency, of: $0, orDefault: UInt32(0)) } ?? 0
    return Double(deviceFrames) / sampleRate + Double(safetyFrames) / sampleRate + Double(streamFrames) / sampleRate
}
