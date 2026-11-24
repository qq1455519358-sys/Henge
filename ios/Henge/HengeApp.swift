import SwiftUI
import AVFAudio

@main
struct HengeApp: App {
    /// Answers for external display scenes before iOS 27 (LegacyExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(HengeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Order matters: HengeLog takes over stderr, so the engine's and the JIT
        // allocator's first lines land in Documents/henge.log too.
        HengeLog.start()
        PhonePointer.install() // before any view adds a pointer interaction
        HengeLog.log("boot", "address space: \(henge_largest_reservation_gb()) GB can be reserved in one piece")
        EngineTuning.apply()
        HengeLog.logFootprint("app-launch")
        JITBootstrap.noteLaunchState()
        HengeLog.log("app", "increased memory limit: \(Entitlements.increasedMemory ? "yes" : "no"); extended addressing: \(Entitlements.extendedAddressing ? "yes" : "no"); limit \(Entitlements.memoryLimitAtLaunch >> 20) MB")
        // Without the guard, a brk no debugger answers kills the app instead of failing.
        JITBootstrap.installTrapGuard()
        MacShortcuts.configure()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        Machines.shared.collectImports()
        DispatchQueue.main.async { KeepAlive.start() } // once the app is up: it watches the Mac and the installer
        // The display question: does this iOS have Apple's paravirtualized graphics at all?
        for path in ["/System/Library/Frameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics",
                     "/System/Library/PrivateFrameworks/ParavirtualizedGraphics.framework/ParavirtualizedGraphics"] {
            HengeLog.log("app", "\(path): \(dlopen(path, RTLD_LAZY) != nil ? "present" : "absent")")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in HengeLog.log("app", "opened with \(url.absoluteString)") } // henge:// back from LocalDevVPN
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case macs, install, settings }

    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var running: VirtualMac?
    @State private var tab = Tab.macs
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                HomeView(running: $running, tab: $tab)
                    .tabItem { Label("Macs", systemImage: "macwindow") }
                    .tag(Tab.macs)
                InstallView()
                    .tabItem { Label("Install", systemImage: "arrow.down.circle") }
                    .tag(Tab.install)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .tint(Desk.accentLight)
            if let running {
                SessionView(mac: running) { self.running = nil }
                    .environment(\.colorScheme, .dark) // still dark while it fades out over a light page
                    .transition(.opacity)
            }
        }
        .background(WindowStyle(style: running != nil ? .dark : appearance.style))
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            machines.collectImports()
            jit.enableAtLaunchIfAsked()
            // StikDebug can launch Henge before it attaches. A task also runs
            // on the first appearance, when there may be no phase change.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if JITBootstrap.prewarmed || JITBootstrap.isLive {
                    jit.objectWillChange.send()
                    return
                }
                if JITBootstrap.debuggedFlag || JITBootstrap.canGrantOwnJIT {
                    JITBootstrap.prewarm()
                    // Readiness lives outside the observable coordinator.
                    jit.objectWillChange.send()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return } // going into the background cancels this wait
            }
        }
        .onChange(of: jit.attachGeneration) { _ in JITBootstrap.prewarm() } // the built-in helper attached
        .task { await openMacAtLaunch() } // Settings › Open the Mac when Henge opens
        .task { // testing only: HENGE_AUTOPILOT
            await Autopilot.run { mac in
                // A session still on screen (its Mac stopped) is closed first: the same value again would start nothing.
                guard running != nil else { running = mac; return }
                running = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { running = mac }
            }
        }
    }

    /// Once a launch: the Mac used last opens as soon as JIT is on, so Henge opens into macOS. It starts the way the
    /// Start button and the test harness's "mac" command start one (running = mac, and SessionView boots it, or picks
    /// up an Instant Resume save). Henge offers no other start at launch, so the two cannot both start a Mac.
    @MainActor private func openMacAtLaunch() async {
        guard OpenMacAtLaunch.claim() else { return } // once a launch, in whichever window gets here first
        guard !Autopilot.enabled else { return } // the harness decides what starts
        let deadline = Date().addingTimeInterval(60)
        while !Task.isCancelled {
            // A Mac open, starting or paused: Start or Resume already did it (and once it is closed, Home stays).
            if running != nil || [1, 3, 4].contains(henge_vm_state()) { return }
            if Installer.shared.busy {
                HengeLog.log("launch", "not opening a Mac: macOS is installing")
                return
            }
            if JITBootstrap.ready && tab == .macs && !jit.showSetup && UIApplication.shared.applicationState == .active {
                guard let mac = machines.all.max(by: { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }) else {
                    HengeLog.log("launch", "not opening a Mac: there is none yet")
                    return
                }
                HengeLog.log("launch", "opening \(mac.name), the Mac used last")
                running = mac
                return
            }
            if Date() > deadline {
                HengeLog.log("launch", JITBootstrap.ready ? "not opening a Mac: Henge was elsewhere for a minute"
                                                          : "not opening a Mac: JIT was not on within a minute")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

/// Settings › "Open the Mac when Henge opens". On by default on iPad, where Henge should feel like a Mac.
enum OpenMacAtLaunch {
    static let key = "henge.openMacAtLaunch"
    static var defaultValue: Bool { Device.isPad }
    static var enabled: Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue }

    @MainActor private static var claimed = false

    /// True the first time in a launch, and only when the setting is on.
    @MainActor static func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return enabled
    }
}

extension View {
    /// Husk's screens are written against an iOS 15 shim; Henge needs iOS 17, so this is the real thing.
    func hengeDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        navigationDestination(for: data, destination: destination)
    }
}
