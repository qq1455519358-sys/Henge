import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(OpenMacAtLaunch.key) private var openMacAtLaunch = OpenMacAtLaunch.defaultValue
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    @AppStorage(VolumeClicks.swapKey) private var swapButtons = false
    @AppStorage(PhysicalMouseButtons.swapKey) private var swapMouseButtons = false
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(EngineTuning.groupsKey) private var groups = true
    @AppStorage(EngineTuning.qosUIKey) private var qosUI = EngineTuning.defaultQosUI
    @AppStorage(EngineTuning.sharedKeepKey) private var sharedKeep = false
    @AppStorage(EngineTuning.el0WindowKey) private var el0Window = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(InstantResume.key) private var instantResume = false
    @AppStorage(KeepAlive.key) private var keepAlive = true
    @AppStorage(MacAppsFeature.key) private var macApps = false

    /// The second footer paragraph: how you click, given the selected input mode.
    private var inputDescription: String {
        if inputMode == .touchscreen {
            return "Tap to click once. Tap then hold to begin dragging. Quickly tap with two fingers to right-click."
        }
        switch volumeMode {
        case .delayHold:
            return "Delay hold waits to see if you're holding or just clicking the volume button, which results in all clicks being ~0.5s long."
        case .tapThenDrag:
            return "Tap then drag waits to see if you're holding or just clicking the volume button, but it unconditionally sends a single click regardless of whether you tap or hold, which results in shorter clicks at the cost of sending a click before holding."
        case .intercept:
            return "Activates the camera in order to intercept volume keys properly. This causes the volume keys to behave in the same way a mouse's buttons do, but it causes higher temperatures, as the camera is always on."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: JITBootstrap.ready ? "On" : "Off")
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge uses \(jit.method.title).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Set up JIT") { jit.showSetup = true }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("Henge connects LocalDevVPN first when it is off, and comes back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Open the Mac when Henge opens", isOn: $openMacAtLaunch)
                    Text("Once JIT is on, the Mac you used last starts by itself, so Henge opens into macOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Code region", value: "\(JITBootstrap.jitBytes >> 20) MB, claimed once per launch")
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Henge's limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Free for Henge", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "A Mac's memory is kept out of this limit once JIT is on. If iOS refuses that, it uses free storage instead."
                         : "This install isn't signed with the increased memory limit entitlement. Reinstall Henge with a certificate that has it. Export your Mac first if the reinstall replaces the app's data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scroll speed")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Toggle("Swap physical right and middle buttons", isOn: $swapMouseButtons)
                        Text("Only enable this if your physical mouse's right and middle buttons are reversed in the Mac. Touch controls stay unchanged. Restart the Mac session to apply.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("A Magic Keyboard or a Bluetooth mouse moves the Mac's pointer. Pointer speed changes apply the next time a Mac starts; scroll speed changes apply immediately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                if !Device.isPad {
                    Section("Trackpad") {
                        Picker("Input mode", selection: $inputMode) {
                            Text("Touchscreen").tag(VolumeClicks.InputMode.touchscreen)
                            Text("Volume buttons").tag(VolumeClicks.InputMode.volumeButtons)
                        }
                        .pickerStyle(.menu)
                        if inputMode == .volumeButtons {
                            Picker("Button mode", selection: $volumeMode) {
                                Text("Delay hold").tag(VolumeClicks.Mode.delayHold)
                                Text("Tap then drag").tag(VolumeClicks.Mode.tapThenDrag)
                                Text("Camera intercept").tag(VolumeClicks.Mode.intercept)
                            }
                            .pickerStyle(.menu)
                            Toggle("Swap buttons", isOn: $swapButtons)
                        }
                        Text("Henge is able to emulate a Magic Trackpad, allowing you to perform native macOS gestures using your device's touchscreen.\n\n\(inputDescription)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Performance") {
                    Picker("Mac refresh rate", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Faster disk writes", isOn: $fastFlush)
                    Toggle("High-priority vCPUs (P-core preference)", isOn: $qosUI)
                    Toggle("Quicker wake from idle", isOn: $wfiSpin)
                    Toggle("Grouped memory accesses", isOn: $groups)
                    Toggle("Superblocks (experimental)", isOn: $superblocks)
                    Toggle("Keep shared dyld TLB (experimental)", isOn: $sharedKeep)
                    Toggle("Direct user memory / NCE (experimental)", isOn: $el0Window)
                    Picker("Code cache", selection: $codeCacheMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                        Text("2 GB").tag(2048)
                    }
                    Text("A bigger code cache empties less often and takes more memory (about 1.75 times its size); Henge picks 2 GB on 16 GB iPads, 1.5 GB where there is plenty, 512 MB where there is little. Applies the next time Henge opens. If JIT stops turning on, or a Mac closes Henge during setup, choose a smaller one.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("macOS draws a frame for every refresh: 30 Hz leaves the most of the emulated CPU to apps, at the cost of choppier animation; 60 Hz is smoother. High-priority vCPUs keeps guest threads on performance cores (HV_QOS=ui). Grouped memory accesses check a page once for neighbouring accesses. Keep shared dyld TLB retains verified shared-cache mappings across process switches (HV_SHARED_KEEP=1), and Direct user memory maps 8 GB per CPU straight onto the hardware MMU via vm_remap (HV_EL0_WINDOW=33; requires Extended Virtual Addressing). Changes apply the next time a Mac starts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("In the Background") {
                    Toggle("Keep Henge awake", isOn: $keepAlive)
                    Text("While a Mac is open or macOS is installing, Henge stays awake when you leave it or the screen locks, so iOS is much less likely to close it and an install goes on. A running Mac waits, paused, until you are back. Henge plays silence to do this; other apps' audio is not interrupted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Instant Resume") {
                    Toggle("Resume where you left off", isOn: $instantResume)
                    Text("When you leave Henge, the running Mac is saved to storage, and opening it again picks up where it was in a few seconds, even after iOS closes Henge. The save is about the size of the Mac's memory in use, compressed. The Mac pauses while Henge is in the background, so its sound stops. Experimental.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Mac Apps") {
                    Toggle("Mac apps without macOS", isOn: $macApps)
                    Text("Bring in a .dmg or an .app (Mac Apps… on Home) and run arm64 Mac programs directly on this \(Device.name)'s hardware MMU through Henge's translation layer, without starting a virtual Mac. Command-line tools run one after another with arguments and stdin; supported AppKit/Qt/SDL apps open windows directly. Experimental.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("System follows the \(Device.name)'s Light or Dark setting. Henge stays dark while a Mac is running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Log") {
                    ShareLink(item: HengeLog.logFileURL) { Label("Share henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
        }
    }
}
