import Foundation
import GameController

/// Physical Bluetooth or USB-C game controllers (DualSense, DualShock, Xbox, MFi) attached to the iPad, in one
/// of two modes, chosen by UserDefaults "henge.gamepad.mode":
///   "controller" (the default): the Mac sees a real USB game controller, a DualShock 4 on its xHCI's port 7
///     (devices/xhci.c), so games, Steam, the browser's Gamepad API and macOS's GameController framework get its
///     buttons and sticks. The controller is plugged into the Mac while one is attached here and pulled when it
///     goes; its state goes over at 120 Hz while it changes, and once a second when it doesn't, so the report's
///     counter keeps moving the way a real one's does.
///   "pointer": the controller drives the Mac's pointer and keys (right stick the pointer, left stick WASD, ...).
final class GamepadBridge: ObservableObject {
    static let shared = GamepadBridge()
    static let enabledKey = "henge.gamepad.enabled"
    static let modeKey = "henge.gamepad.mode"

    enum Mode: String {
        case controller
        case pointer
    }

    /// The DualShock 4's buttons, as henge_vm_gamepad_state takes them (HENGE_PAD_* in henge-vm.h).
    enum PadButton {
        static let square: UInt32 = 0x0001
        static let cross: UInt32 = 0x0002
        static let circle: UInt32 = 0x0004
        static let triangle: UInt32 = 0x0008
        static let l1: UInt32 = 0x0010
        static let r1: UInt32 = 0x0020
        static let l2: UInt32 = 0x0040
        static let r2: UInt32 = 0x0080
        static let share: UInt32 = 0x0100
        static let options: UInt32 = 0x0200
        static let l3: UInt32 = 0x0400
        static let r3: UInt32 = 0x0800
        static let ps: UInt32 = 0x1000
        static let touchpad: UInt32 = 0x2000
    }

    /// One state of the Mac's controller: what henge_vm_gamepad_state is sent.
    struct PadState: Equatable {
        var buttons: UInt32 = 0
        var hat: Int8 = 8 // 0 up, clockwise to 7 up-left; 8 none
        var lx: UInt8 = 0x80, ly: UInt8 = 0x80, rx: UInt8 = 0x80, ry: UInt8 = 0x80 // 0x80 centred, 0x00 left and up
        var l2: UInt8 = 0, r2: UInt8 = 0
    }

    @Published private(set) var controllerName: String?

    private var timer: Timer?
    private var timerMode: Mode?
    private var observers: [NSObjectProtocol] = []
    // Pointer mode.
    private var heldUsages = Set<UInt8>()
    private var leftButtonDown = false
    private var rightButtonDown = false
    private var menuChordDown = false
    private var scrollTick = 0
    // Controller mode.
    private var pluggedIn = false
    private var lastSent: PadState?
    private var lastSentAt = Date.distantPast
    // The autopilot's controller (Autopilot.swift "pad ..."): plugged in with no physical one, its presses
    // added to whatever a physical one holds.
    private var forced = false
    private var virtualButtons: UInt32 = 0
    private var virtualHat: Int8 = 8
    private var virtualLeft: (UInt8, UInt8)?
    private var virtualRight: (UInt8, UInt8)?

    var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { releaseAll() }
            refreshControllers()
        }
    }

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .controller }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            refreshControllers()
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refreshControllers() },
            nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                self?.releaseAll()
                self?.refreshControllers()
            }
        ]
        refreshControllers()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        timerMode = nil
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
        observers.removeAll()
        releaseAll()
        forced = false
        resetVirtual()
        setPlugged(false)
        controllerName = nil
    }

    private func refreshControllers() {
        let active = GCController.controllers().first { $0.extendedGamepad != nil }
        controllerName = active.map { $0.vendorName ?? "Game Controller" }
        let physical = active != nil && isEnabled
        // HV_NO_GAMEPAD (the engine's kill switch) leaves the Mac's port empty: the controller drives the pointer then.
        let macController = mode == .controller && getenv("HV_NO_GAMEPAD") == nil
        let plug = (physical && macController) || forced
        setPlugged(plug)
        let runMode: Mode? = plug ? .controller : (physical ? .pointer : nil)
        if runMode != .pointer { releaseAll() } // nothing stays held from pointer mode
        guard runMode != timerMode else { return }
        timer?.invalidate()
        timer = nil
        timerMode = runMode
        if let runMode {
            let t = Timer(timeInterval: runMode == .controller ? 1.0 / 120.0 : 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        switch timerMode {
        case .controller?: sendState()
        case .pointer?: poll()
        case nil: break
        }
    }

    // MARK: Controller mode

    /// Plug the Mac's controller in or pull it. A pull first lets go of everything, so nothing stays held in a game.
    private func setPlugged(_ on: Bool) {
        guard on != pluggedIn else { return }
        if !on {
            let s = PadState()
            henge_vm_gamepad_state(s.buttons, s.hat, s.lx, s.ly, s.rx, s.ry, s.l2, s.r2)
        }
        pluggedIn = on
        lastSent = nil
        henge_vm_gamepad_set_connected(on ? 1 : 0)
        HengeLog.log("gamepad", on ? "controller plugged into the Mac" : "controller pulled from the Mac")
    }

    /// The state now, sent when it changed or a second has passed.
    private func sendState(force: Bool = false) {
        guard pluggedIn else { return }
        let s = currentState()
        let now = Date()
        guard force || s != lastSent || now.timeIntervalSince(lastSentAt) >= 1.0 else { return }
        henge_vm_gamepad_state(s.buttons, s.hat, s.lx, s.ly, s.rx, s.ry, s.l2, s.r2)
        lastSent = s
        lastSentAt = now
    }

    private func currentState() -> PadState {
        var s = PadState()
        if isEnabled, let pad = GCController.controllers().compactMap(\.extendedGamepad).first {
            s = Self.state(of: pad)
        }
        s.buttons |= virtualButtons
        if virtualHat != 8 { s.hat = virtualHat }
        if let v = virtualLeft { s.lx = v.0; s.ly = v.1 }
        if let v = virtualRight { s.rx = v.0; s.ry = v.1 }
        if virtualButtons & PadButton.l2 != 0 { s.l2 = 255 }
        if virtualButtons & PadButton.r2 != 0 { s.r2 = 255 }
        return s
    }

    /// Buttons by position: the bottom face button (A) is the DualShock's cross, right (B) circle, left (X)
    /// square, top (Y) triangle. Menu is Options, the Options/View/Share button Share, Home the PS button.
    static func state(of pad: GCExtendedGamepad) -> PadState {
        var s = PadState()
        var b: UInt32 = 0
        if pad.buttonA.isPressed { b |= PadButton.cross }
        if pad.buttonB.isPressed { b |= PadButton.circle }
        if pad.buttonX.isPressed { b |= PadButton.square }
        if pad.buttonY.isPressed { b |= PadButton.triangle }
        if pad.leftShoulder.isPressed { b |= PadButton.l1 }
        if pad.rightShoulder.isPressed { b |= PadButton.r1 }
        if pad.leftTrigger.isPressed { b |= PadButton.l2 }
        if pad.rightTrigger.isPressed { b |= PadButton.r2 }
        if pad.buttonMenu.isPressed { b |= PadButton.options }
        if pad.buttonOptions?.isPressed == true { b |= PadButton.share }
        if pad.buttonHome?.isPressed == true { b |= PadButton.ps }
        if pad.leftThumbstickButton?.isPressed == true { b |= PadButton.l3 }
        if pad.rightThumbstickButton?.isPressed == true { b |= PadButton.r3 }
        if let ds4 = pad as? GCDualShockGamepad, ds4.touchpadButton.isPressed { b |= PadButton.touchpad }
        if let ds5 = pad as? GCDualSenseGamepad, ds5.touchpadButton.isPressed { b |= PadButton.touchpad }
        s.buttons = b
        s.hat = hat(up: pad.dpad.up.isPressed, right: pad.dpad.right.isPressed,
                    down: pad.dpad.down.isPressed, left: pad.dpad.left.isPressed)
        s.lx = axis(pad.leftThumbstick.xAxis.value)
        s.ly = axis(-pad.leftThumbstick.yAxis.value) // GameController: +1 up; the DualShock: 0x00 up
        s.rx = axis(pad.rightThumbstick.xAxis.value)
        s.ry = axis(-pad.rightThumbstick.yAxis.value)
        s.l2 = trigger(pad.leftTrigger.value)
        s.r2 = trigger(pad.rightTrigger.value)
        return s
    }

    /// -1...1 to 0...255, 0 to 0x80.
    static func axis(_ v: Float) -> UInt8 {
        let c = Double(max(-1, min(1, v)))
        return UInt8(max(0, min(255, ((c + 1) * 127.5).rounded())))
    }

    static func trigger(_ v: Float) -> UInt8 {
        let c = Double(max(0, min(1, v)))
        return UInt8(max(0, min(255, (c * 255).rounded())))
    }

    static func hat(up: Bool, right: Bool, down: Bool, left: Bool) -> Int8 {
        switch (up, right, down, left) {
        case (true, false, false, false): return 0
        case (true, true, false, false): return 1
        case (false, true, false, false): return 2
        case (false, true, true, false): return 3
        case (false, false, true, false): return 4
        case (false, false, true, true): return 5
        case (false, false, false, true): return 6
        case (true, false, false, true): return 7
        default: return 8
        }
    }

    // MARK: The autopilot's controller

    /// Plug the controller into the Mac (or pull it) with no physical one attached.
    func autopilotConnect(_ on: Bool) {
        forced = on
        if !on { resetVirtual() }
        refreshControllers()
        sendState(force: true)
    }

    private func resetVirtual() {
        virtualButtons = 0
        virtualHat = 8
        virtualLeft = nil
        virtualRight = nil
    }

    /// Hold or let go of a button by name (cross, circle, square, triangle, l1, r1, l2, r2, l3, r3, share,
    /// options, ps, touchpad, up, down, left, right). False for a name it doesn't know.
    func autopilotButton(_ name: String, down: Bool) -> Bool {
        let buttons: [String: UInt32] = [
            "cross": PadButton.cross, "circle": PadButton.circle, "square": PadButton.square, "triangle": PadButton.triangle,
            "l1": PadButton.l1, "r1": PadButton.r1, "l2": PadButton.l2, "r2": PadButton.r2, "l3": PadButton.l3,
            "r3": PadButton.r3, "share": PadButton.share, "options": PadButton.options, "ps": PadButton.ps,
            "touchpad": PadButton.touchpad,
        ]
        let hats: [String: Int8] = ["up": 0, "right": 2, "down": 4, "left": 6]
        if let bit = buttons[name] {
            if down { virtualButtons |= bit } else { virtualButtons &= ~bit }
        } else if let h = hats[name] {
            virtualHat = down ? h : 8
        } else {
            return false
        }
        sendState(force: true)
        return true
    }

    /// Hold a stick ("left" or "right") at x, y in -1...1, +1 right and up; 0 0 centres it.
    func autopilotStick(_ side: String, x: Double, y: Double) -> Bool {
        let v = (Self.axis(Float(x)), Self.axis(Float(-y)))
        switch side {
        case "left": virtualLeft = v
        case "right": virtualRight = v
        default: return false
        }
        sendState(force: true)
        return true
    }

    /// Whether the Mac has the controller and reads it.
    var macReadsController: Bool { henge_vm_gamepad_ready() != 0 }

    // MARK: Pointer mode

    private func setUsage(_ usage: UInt8, down: Bool) {
        if down {
            if heldUsages.insert(usage).inserted { henge_vm_key_hid(usage, 1) }
        } else {
            if heldUsages.remove(usage) != nil { henge_vm_key_hid(usage, 0) }
        }
    }

    private func setMouse(button: Int32, down: Bool, state: inout Bool) {
        guard state != down else { return }
        state = down
        henge_vm_mouse_button(button, down ? 1 : 0)
    }

    private func poll() {
        guard isEnabled, let pad = GCController.controllers().compactMap(\.extendedGamepad).first else {
            releaseAll()
            return
        }

        // Right stick -> smooth Mac cursor movement
        let rx = Double(pad.rightThumbstick.xAxis.value)
        let ry = Double(pad.rightThumbstick.yAxis.value)
        let dead = 0.12
        if abs(rx) > dead || abs(ry) > dead {
            let sx = abs(rx) > dead ? (rx - (rx > 0 ? dead : -dead)) / (1.0 - dead) : 0
            let sy = abs(ry) > dead ? (ry - (ry > 0 ? dead : -dead)) / (1.0 - dead) : 0
            let dx = Int32((sx * (6.0 + 16.0 * abs(sx))).rounded())
            let dy = Int32((-sy * (6.0 + 16.0 * abs(sy))).rounded())
            if dx != 0 || dy != 0 {
                if henge_vm_usb_mouse_ready() != 0 {
                    henge_vm_usb_mouse_move(dx, dy)
                } else {
                    henge_vm_mouse_move(dx, dy)
                }
            }
        }

        // Left stick -> WASD
        let lx = pad.leftThumbstick.xAxis.value
        let ly = pad.leftThumbstick.yAxis.value
        setUsage(0x1a, down: ly > 0.38)  // W
        setUsage(0x16, down: ly < -0.38) // S
        setUsage(0x04, down: lx < -0.38) // A
        setUsage(0x07, down: lx > 0.38)  // D

        // D-pad -> Arrow keys
        setUsage(0x52, down: pad.dpad.up.isPressed)
        setUsage(0x51, down: pad.dpad.down.isPressed)
        setUsage(0x50, down: pad.dpad.left.isPressed)
        setUsage(0x4f, down: pad.dpad.right.isPressed)

        // Face buttons -> Space, Escape, Return, Tab
        setUsage(0x2c, down: pad.buttonA.isPressed)
        setUsage(0x29, down: pad.buttonB.isPressed)
        setUsage(0x28, down: pad.buttonX.isPressed)
        setUsage(0x2b, down: pad.buttonY.isPressed)

        // Triggers -> Left & Right click
        setMouse(button: 0, down: pad.rightTrigger.value > 0.35, state: &leftButtonDown)
        setMouse(button: 1, down: pad.leftTrigger.value > 0.35, state: &rightButtonDown)

        // Shoulders -> Smooth vertical scroll
        if pad.leftShoulder.isPressed || pad.rightShoulder.isPressed {
            scrollTick += 1
            if scrollTick % 3 == 0 {
                let dy: Int32 = pad.leftShoulder.isPressed ? 2 : -2
                henge_vm_mouse_scroll(0, dy)
            }
        } else {
            scrollTick = 0
        }

        // Menu button -> Command+Space (Spotlight)
        let menuPressed = pad.buttonMenu.isPressed
        if menuPressed != menuChordDown {
            menuChordDown = menuPressed
            if menuPressed {
                henge_vm_key_hid(0xe3, 1)
                henge_vm_key_hid(0x2c, 1)
                henge_vm_key_hid(0x2c, 0)
                henge_vm_key_hid(0xe3, 0)
            }
        }
    }

    func releaseAll() {
        for u in heldUsages { henge_vm_key_hid(u, 0) }
        heldUsages.removeAll()
        if leftButtonDown { henge_vm_mouse_button(0, 0); leftButtonDown = false }
        if rightButtonDown { henge_vm_mouse_button(1, 0); rightButtonDown = false }
        menuChordDown = false
    }
}
