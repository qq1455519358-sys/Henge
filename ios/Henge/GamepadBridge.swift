import Foundation
import GameController

/// Maps physical Bluetooth or USB-C game controllers (DualSense, Xbox, MFi) attached to the iPad
/// into smooth 60 Hz Mac pointer/scroll input and standard keyboard controls.
final class GamepadBridge: ObservableObject {
    static let shared = GamepadBridge()
    static let enabledKey = "henge.gamepad.enabled"

    @Published private(set) var controllerName: String?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var heldUsages = Set<UInt8>()
    private var leftButtonDown = false
    private var rightButtonDown = false
    private var menuChordDown = false
    private var scrollTick = 0

    var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { releaseAll() }
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
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
        observers.removeAll()
        releaseAll()
        controllerName = nil
    }

    private func refreshControllers() {
        let active = GCController.controllers().first { $0.extendedGamepad != nil }
        controllerName = active.map { $0.vendorName ?? "Game Controller" }
        if active != nil && isEnabled {
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.poll() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
            releaseAll()
        }
    }

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
