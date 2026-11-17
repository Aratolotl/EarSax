import AppKit
import SwiftUI

/// The panel under the menu-bar icon: output device and volume, then one row per app.
struct MixerPanel: View {
    let mixer: MixerModel
    let updates: UpdateChecker
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionNote(mixer: mixer)
            OutputSection(mixer: mixer)
            InputRow(mixer: mixer)
            Divider()
            AppsSection(mixer: mixer)
            AlertSoundsRow(mixer: mixer)
            Divider()
            if case .available(let version, let downloadPage) = updates.status {
                // Shown only when a newer version exists.
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    Text("EarSax \(version) is available")
                    Spacer()
                    Link("Download", destination: downloadPage)
                }
                .font(.callout)
            }
            PanelFooter(openSettings: openSettings)
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - First run

/// Shown until EarSax may change app volumes. Apps play normally meanwhile; saved volumes wait for the permission.
private struct PermissionNote: View {
    let mixer: MixerModel

    var body: some View {
        switch mixer.permission {
        case .notAskedYet:
            note(text: "To change an app's volume or where it plays, EarSax needs the System Audio Recording permission. macOS calls it recording, but EarSax never records or saves anything.",
                 buttonTitle: mixer.isAskingForPermission ? "Waiting for your answer…" : "Continue",
                 action: mixer.requestPermission)
                .disabled(mixer.isAskingForPermission)
        case .refused:
            VStack(alignment: .leading, spacing: 8) {
                Text("EarSax can't change an app's volume or where it plays without the System Audio Recording permission, so your apps play normally. Turn on EarSax under Privacy & Security, System Audio Recording Only (add it with the + button if it isn't listed), then restart EarSax.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Restart EarSax", action: restartEarSax)
                    Button("Open System Settings", action: openSystemAudioPermissionSettings)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .granted, .unknown:
            EmptyView()
        }
    }

    private func note(text: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Output

private struct OutputSection: View {
    let mixer: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One row and a dropdown instead of a device list. The menu's title says what a click does: everything moves,
            // so there is no question about apps that were sent elsewhere.
            Menu {
                Section("Play everything on") {
                    ForEach(mixer.devicesForPlayEverythingOn) { device in
                        // A toggle, so the current device shows a checkmark; picking it again still clears per-app outputs.
                        Toggle(isOn: Binding(get: { device.id == mixer.shownOutputDevice?.id },
                                             set: { _ in mixer.selectOutputDevice(device) })) {
                            Label(device.name, systemImage: device.symbolName)
                        }
                    }
                }
            } label: {
                Label(mixer.shownOutputDevice?.name ?? "No output device",
                      systemImage: mixer.shownOutputDevice?.symbolName ?? "speaker.slash")
                    .fontWeight(.semibold)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Output device")
            .accessibilityValue(mixer.shownOutputDevice?.name ?? "None")
            if let volume = mixer.outputVolume {
                HStack(spacing: 8) {
                    if mixer.canMuteOutputDevice {
                        MuteButton(isMuted: mixer.isOutputMuted, whatItMutes: "output") { mixer.toggleOutputMute() }
                    }
                    Slider(value: Binding(get: { Double(volume) }, set: { mixer.setOutputVolume(Float($0)) }))
                        .accessibilityLabel("Output volume")
                    // A percentage like the app rows have, so the main volume can be compared with the default volume in
                    // Settings.
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            } else {
                Text("Volume is set on the device").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Input

/// The Mac's sound input, a dropdown like the output's. Picker only, no level slider (ruling R24). Shown only with two or
/// more microphones (R27): it's there to see and override what EarSax chose when Bluetooth headphones connect.
private struct InputRow: View {
    let mixer: MixerModel

    var body: some View {
        if mixer.devicesForSoundInput.count >= 2 {
            Menu {
                Section("Sound input") {
                    ForEach(mixer.devicesForSoundInput) { device in
                        Toggle(isOn: Binding(get: { device.id == mixer.currentInputDeviceID },
                                             set: { _ in mixer.selectInputDevice(device) })) {
                            Label(device.name, systemImage: device.symbolName)
                        }
                    }
                }
            } label: {
                // Always the microphone icon, so the row reads as the input even when the device is a headset.
                Label(mixer.mainInputDevice?.name ?? "No input device", systemImage: mixer.mainInputDevice == nil ? "mic.slash" : "mic")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Input device")
            .accessibilityValue(mixer.mainInputDevice?.name ?? "None")
        }
    }
}

// MARK: - Apps

private struct AppsSection: View {
    let mixer: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Apps")
            if mixer.visibleApps.isEmpty {
                Text("Apps appear here when they play sound.").font(.callout).foregroundStyle(.secondary)
            }
            // Past six apps the list scrolls, so the panel never grows taller than the screen (review finding 6).
            if mixer.visibleApps.count > 6 {
                ScrollView { appRows }.frame(height: 340)
            } else {
                appRows
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(mixer.visibleApps) { app in
                AppVolumeRow(app: app, mixer: mixer)
                    .transition(rowTransition)
            }
        }
        // Rows ease in and out instead of popping. Ease-out only, exit faster than entry, and the height change animates
        // with the fade. Reduce Motion keeps the fade and drops the slide.
        .animation(.easeOut(duration: 0.2), value: mixer.visibleApps.map(\.id))
    }

    private var rowTransition: AnyTransition {
        let entry: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6))
        return .asymmetric(insertion: entry.animation(.easeOut(duration: 0.25)),
                           removal: .opacity.animation(.easeOut(duration: 0.2)))
    }
}

/// macOS's alert volume (ruling R30): a row under the apps, shaped like theirs. No tap: EarSax sets macOS's own value.
/// The alert sound plays when the slider is let go, so the new level can be heard, as in System Settings.
private struct AlertSoundsRow: View {
    let mixer: MixerModel

    var body: some View {
        if let volume = mixer.alertVolume {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Alert sounds").lineLimit(1)
                        // macOS can play alerts on a device of their own; EarSax leaves that choice alone (R32), so say it.
                        if let device = mixer.alertDeviceNameIfElsewhere {
                            Text("On \(device)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(volume) }, set: { mixer.setAlertVolume(Float($0)) }),
                       onEditingChanged: { isDragging in if !isDragging { NSSound.beep() } })
                    .accessibilityLabel("Alert sounds volume")
                    .padding(.leading, 26)   // lines up with the app sliders, which start after their mute button
            }
        }
    }
}

private struct AppVolumeRow: View {
    let app: AudioApp
    let mixer: MixerModel
    @State private var isChoosingOutput = false

    var body: some View {
        let setting = mixer.setting(for: app.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AppIcon(bundleURL: app.identity.bundleURL)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name).lineLimit(1)
                    OwnOutputLine(playsOn: mixer.ownOutput(for: app.id), alwaysOn: setting.alwaysOn,
                                  alwaysOnIsConnected: setting.alwaysOn.map(mixer.isConnected) ?? false)
                }
                Spacer()
                Text("\(Int((setting.volumeSlider * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { isChoosingOutput = true } label: {
                    // The icon of the device the app plays on now, large enough to read as "this is where it plays".
                    Image(systemName: mixer.outputDevice(for: app.id)?.symbolName ?? "speaker.slash")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 20)
                        .foregroundStyle(mixer.ownOutput(for: app.id) == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Choose where \(app.name) plays")
                .accessibilityLabel("Output for \(app.name)")
                .popover(isPresented: $isChoosingOutput, arrowEdge: .trailing) {
                    AppOutputChooser(app: app, mixer: mixer)
                }
            }
            HStack(spacing: 8) {
                MuteButton(isMuted: setting.isMuted, whatItMutes: app.name) { mixer.toggleMute(for: app) }
                Slider(value: Binding(get: { setting.volumeSlider }, set: { mixer.setVolumeSlider($0, for: app) }))
                    .accessibilityLabel("\(app.name) volume")
            }
            if let problem = mixer.tapProblemByApp[app.id] {
                Text("Couldn't change this app's sound: \(problem)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Under an app's name, only when it has a device of its own: "On X" for now, a pin and "Always on X" for its pinned
/// device, or both ("On X" then the pin) when it plays elsewhere for now.
private struct OwnOutputLine: View {
    let playsOn: SavedDevice?
    let alwaysOn: SavedDevice?
    let alwaysOnIsConnected: Bool

    var body: some View {
        if playsOn != nil || alwaysOn != nil {
            HStack(spacing: 3) {
                if let playsOn, playsOn.persistentID != alwaysOn?.persistentID {
                    Text("On \(playsOn.name)").foregroundStyle(.tint)
                    if alwaysOn != nil { Text("·").foregroundStyle(.secondary) }
                }
                if let alwaysOn {
                    let isPlayingThere = playsOn?.persistentID == alwaysOn.persistentID
                    Group {
                        Image(systemName: "pin.fill").accessibilityHidden(true)
                        Text(alwaysOnIsConnected ? "Always on \(alwaysOn.name)" : "Always on \(alwaysOn.name), not connected")
                    }
                    .foregroundStyle(isPlayingThere ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}

/// The list behind an app's device button. It stays open. A click on a device plays the app there for now; the pin next
/// to a device makes the app always play there when it's connected, and the pinned device keeps its blue pin whatever is
/// picked for now.
private struct AppOutputChooser: View {
    let app: AudioApp
    let mixer: MixerModel

    var body: some View {
        let alwaysOn = mixer.setting(for: app.id).alwaysOn
        let playsOn = mixer.ownOutput(for: app.id)
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Play \(app.name) on")
            row(name: "Same as everything else", symbolName: nil, isChosen: playsOn == nil, pin: nil) {
                mixer.playForNow(on: nil, for: app)
            }
            ForEach(mixer.devicesForAppList(app.id)) { device in
                let saved = SavedDevice(persistentID: device.persistentID, name: device.name)
                row(name: device.name, symbolName: device.symbolName,
                    isChosen: playsOn?.persistentID == device.persistentID,
                    pin: (saved, isPinned: alwaysOn?.persistentID == device.persistentID),
                    videoDelayNote: device.isBluetooth && device.id != mixer.currentOutputDeviceID) {
                    mixer.playForNow(on: device, for: app)
                }
            }
            if let alwaysOn, !mixer.isConnected(alwaysOn) {
                row(name: "\(alwaysOn.name), not connected", symbolName: "powerplug", isChosen: false,
                    pin: (alwaysOn, isPinned: true)) {}
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Pin a device to always play \(app.name) there when it's connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 270, alignment: .leading)
    }

    private func row(name: String, symbolName: String?, isChosen: Bool, pin: (device: SavedDevice, isPinned: Bool)?,
                     videoDelayNote: Bool = false, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: choose) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").opacity(isChosen ? 1 : 0).accessibilityHidden(true)
                    if let symbolName { Image(systemName: symbolName).frame(width: 18) }
                    Text(name).lineLimit(1)
                    if videoDelayNote { VideoDelayNote() }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // On the button itself: macOS ignores a tooltip placed on a view inside a button's label, which is where the
            // (i) icon sits, so it showed nothing. It now shows over the row.
            .help(videoDelayNote ? VideoDelayNote.text : "")
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            if let pin {
                Button { mixer.togglePin(pin.device, for: app) } label: {
                    Image(systemName: pin.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(pin.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(pin.isPinned ? "Stop always playing \(app.name) on \(pin.device.name)"
                                   : "Always play \(app.name) on \(pin.device.name) when it's connected")
                .accessibilityLabel(pin.isPinned ? "Unpin \(pin.device.name)" : "Pin \(pin.device.name)")
            }
        }
    }
}

/// Next to a Bluetooth device that isn't the main output. The app times its video for the main output, so on Bluetooth
/// the sound runs behind the picture (about 150 ms measured on Bluetooth earbuds). The note is a
/// tooltip on the device name.
private struct VideoDelayNote: View {
    static let text = "Video may run ahead of the sound here. To keep them in sync, play everything on this device."

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Self.text)
    }
}

private struct AppIcon: View {
    let bundleURL: URL?
    var body: some View {
        Image(nsImage: bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
            .resizable()
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

private struct MuteButton: View {
    let isMuted: Bool
    let whatItMutes: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 18)
                .foregroundStyle(isMuted ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .help(isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(isMuted ? "Unmute \(whatItMutes)" : "Mute \(whatItMutes)")
    }
}

// MARK: - Footer

/// "Open at login" moved into Settings, so the footer is just Settings and Quit.
private struct PanelFooter: View {
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Button("Settings…", action: openSettings)
                .keyboardShortcut(",")
            Spacer()
            Button("Quit EarSax") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.callout)
    }
}
