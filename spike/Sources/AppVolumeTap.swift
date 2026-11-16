import CoreAudio
import Foundation
import Synchronization

/// Values shared between the main thread (slider, mute, level meter) and the real-time audio thread.
/// Atomics only: the audio thread must never wait on a lock or allocate memory.
final class RealtimeVolumeState: Sendable {
    /// What the audio should be multiplied by (0 = silent, 1 = unchanged). Set by the main thread.
    let targetVolumeMultiplier = Atomic<UInt32>(Float(1).bitPattern)
    /// The multiplier actually applied at the end of the last audio cycle. Audio thread only; used to glide to the target.
    let appliedVolumeMultiplier = Atomic<UInt32>(Float(1).bitPattern)
    let isMuted = Atomic<Bool>(false)
    /// Loudest output sample since the main thread last read it (drives the level meter).
    let loudestSampleSinceLastRead = Atomic<UInt32>(0)
    /// How many times Core Audio has asked for audio (about 90 per second while the app plays).
    let audioCycleCount = Atomic<UInt64>(0)
    /// Audio cycles in which the tapped app actually sent sound (not silence).
    let audioCyclesWithSound = Atomic<UInt64>(0)

    /// Runs on the real-time audio thread: no allocation, no locks.
    /// Copies the app's captured audio to the speakers, applying volume with a smooth glide (no clicks when the slider moves).
    /// ponytail: output channel N plays captured channel (N mod capturedChannelCount), so a 5.1 output gets stereo copied
    /// to every speaker. Good enough for a spike.
    func copyAppAudioToSpeakers(captured: UnsafeMutableAudioBufferListPointer, speakers: UnsafeMutableAudioBufferListPointer) {
        audioCycleCount.add(1, ordering: .relaxed)
        let targetMultiplier = isMuted.load(ordering: .relaxed) ? 0 : Float(bitPattern: targetVolumeMultiplier.load(ordering: .relaxed))
        let startMultiplier = Float(bitPattern: appliedVolumeMultiplier.load(ordering: .relaxed))

        var capturedChannelCount = 0
        for capturedBuffer in captured { capturedChannelCount += Int(capturedBuffer.mNumberChannels) }

        var loudestCaptured: Float = 0
        var loudestOutput: Float = 0
        var firstChannelOfThisBuffer = 0
        for speakerBuffer in speakers {
            let channelCount = Int(speakerBuffer.mNumberChannels)
            guard channelCount > 0, let speakerSamples = speakerBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frameCount = Int(speakerBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            let glideStepPerFrame = frameCount > 0 ? (targetMultiplier - startMultiplier) / Float(frameCount) : 0
            for frame in 0..<frameCount {
                let multiplierAtThisFrame = startMultiplier + glideStepPerFrame * Float(frame + 1)
                for channel in 0..<channelCount {
                    let capturedSample = capturedChannelCount > 0
                        ? Self.sample(in: captured, channel: (firstChannelOfThisBuffer + channel) % capturedChannelCount, frame: frame)
                        : 0
                    let outputSample = capturedSample * multiplierAtThisFrame
                    speakerSamples[frame * channelCount + channel] = outputSample
                    loudestCaptured = max(loudestCaptured, abs(capturedSample))
                    loudestOutput = max(loudestOutput, abs(outputSample))
                }
            }
            firstChannelOfThisBuffer += channelCount
        }
        appliedVolumeMultiplier.store(targetMultiplier.bitPattern, ordering: .relaxed)
        if loudestCaptured > 0.0001 { audioCyclesWithSound.add(1, ordering: .relaxed) }
        if loudestOutput > Float(bitPattern: loudestSampleSinceLastRead.load(ordering: .relaxed)) {
            loudestSampleSinceLastRead.store(loudestOutput.bitPattern, ordering: .relaxed)
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

struct TapSetupError: Error, CustomStringConvertible {
    let failedStep: String
    let status: OSStatus
    var description: String { "\(failedStep) failed: OSStatus \(status) (\(readableStatus(status)))" }
}

/// Core Audio errors are often four letters packed into a number ('!obj', 'who?'); show them as text when they are.
func readableStatus(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : "\(status)"
}

/// Per-app volume control for one app. Three Core Audio pieces, created in order and destroyed in reverse:
/// 1. a process tap: captures the app's audio and silences its normal output;
/// 2. a private device: the tap as its input, the real speakers or headphones as its output (invisible to other apps);
/// 3. an audio callback on that device: copies input to output with our volume applied.
@MainActor
final class AppVolumeTap {
    let realtimeState = RealtimeVolumeState()
    let appID: String
    let outputDevice: AudioDeviceID
    private(set) var diagnostics = ""
    private var tapDescription: CATapDescription
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var privateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var audioCallbackID: AudioDeviceIOProcID?

    /// - Parameter bundleIDs: pass bundle IDs to use macOS 26's tap-by-bundle-ID mode (follows the app across restarts);
    ///   pass nil to tap the given processes only.
    init(appID: String, processes: [AudioObjectID], bundleIDs: [String]?, outputDevice: AudioDeviceID) throws {
        self.appID = appID
        self.outputDevice = outputDevice
        if let bundleIDs, #available(macOS 26.0, *) {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
            tapDescription.bundleIDs = bundleIDs
            tapDescription.isProcessRestoreEnabled = true
        } else {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        tapDescription.uuid = UUID()
        tapDescription.name = "EarSax spike: \(appID)"
        tapDescription.muteBehavior = .mutedWhenTapped   // if we stop reading (or crash), the app is heard normally again
        tapDescription.isPrivate = true
        do { try start() } catch { stop(); throw error }
    }

    private func start() throws {
        var status = AudioHardwareCreateProcessTap(tapDescription, &processTapID)
        guard status == noErr else { throw TapSetupError(failedStep: "Create process tap", status: status) }

        guard let outputDeviceID = persistentID(of: outputDevice) else {
            throw TapSetupError(failedStep: "Read output device ID", status: -1)
        }
        let privateDeviceSettings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EarSax Spike \(appID)",
            kAudioAggregateDeviceUIDKey: "earsax.spike.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(privateDeviceSettings as CFDictionary, &privateDeviceID)
        guard status == noErr else { throw TapSetupError(failedStep: "Create private device", status: status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&audioCallbackID, privateDeviceID, nil,
                                                    Self.makeRealtimeAudioCallback(realtimeState))
        guard status == noErr else { throw TapSetupError(failedStep: "Register audio callback", status: status) }

        status = AudioDeviceStart(privateDeviceID, audioCallbackID)
        guard status == noErr else { throw TapSetupError(failedStep: "Start private device", status: status) }

        diagnostics = Self.describeAudioPath(processTap: processTapID, privateDevice: privateDeviceID)
        writeToSpikeLog("TAP START \(appID) on \(displayName(of: outputDevice)) [\(connectionType(of: outputDevice))] :: \(diagnostics)")
    }

    /// Built outside the main actor on purpose: a closure written inside a @MainActor method inherits main-actor
    /// isolation, and Swift 6 crashes (EXC_BREAKPOINT) when Core Audio calls it on its real-time thread.
    nonisolated private static func makeRealtimeAudioCallback(_ realtimeState: RealtimeVolumeState) -> AudioDeviceIOBlock {
        { @Sendable _, capturedAudio, _, speakerAudio, _ in
            realtimeState.copyAppAudioToSpeakers(
                captured: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: capturedAudio)),
                speakers: UnsafeMutableAudioBufferListPointer(speakerAudio))
        }
    }

    /// Points the existing tap at a new set of processes (e.g. the app started a helper) without tearing it down.
    func retarget(toProcesses processes: [AudioObjectID]) -> OSStatus {
        tapDescription.processes = processes
        var address = propertyAddress(kAudioTapPropertyDescription)
        var descriptionReference: CATapDescription = tapDescription
        return AudioObjectSetPropertyData(processTapID, &address, 0, nil,
                                          UInt32(MemoryLayout<CATapDescription>.size), &descriptionReference)
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
        writeToSpikeLog("TAP STOP \(appID)")
    }

    private static func describeAudioPath(processTap: AudioObjectID, privateDevice: AudioDeviceID) -> String {
        let capturedFormat: AudioStreamBasicDescription =
            readProperty(kAudioTapPropertyFormat, of: processTap, orDefault: AudioStreamBasicDescription())
        let sampleRate: Float64 = readProperty(kAudioDevicePropertyNominalSampleRate, of: privateDevice, orDefault: 0)
        let framesPerCycle: UInt32 = readProperty(kAudioDevicePropertyBufferFrameSize, of: privateDevice, orDefault: 0)
        let inputDelay = reportedDelayInFrames(of: privateDevice, side: kAudioObjectPropertyScopeInput)
        let outputDelay = reportedDelayInFrames(of: privateDevice, side: kAudioObjectPropertyScopeOutput)
        let milliseconds = { (frames: UInt32) in sampleRate > 0 ? String(format: "%.1f", Double(frames) / sampleRate * 1000) : "?" }
        let speakerStreams = readPropertyList(kAudioDevicePropertyStreams, of: privateDevice,
                                              scope: kAudioObjectPropertyScopeOutput, elementType: AudioStreamID.self)
        let speakerFormat: AudioStreamBasicDescription = speakerStreams.first.map {
            readProperty(kAudioStreamPropertyVirtualFormat, of: $0, orDefault: AudioStreamBasicDescription())
        } ?? AudioStreamBasicDescription()
        let sampleType = { (format: AudioStreamBasicDescription) in
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "NOT-float"
        }
        return "rate \(Int(sampleRate)) Hz, cycle \(framesPerCycle) frames (\(milliseconds(framesPerCycle)) ms), "
            + "reported input delay \(milliseconds(inputDelay)) ms, output delay \(milliseconds(outputDelay)) ms "
            + "(Bluetooth figures include the device's own wireless delay) | "
            + "captured \(capturedFormat.mChannelsPerFrame)ch \(Int(capturedFormat.mSampleRate)) Hz \(sampleType(capturedFormat)), "
            + "speakers \(speakerFormat.mChannelsPerFrame)ch \(sampleType(speakerFormat))"
    }
}
