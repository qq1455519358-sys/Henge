import CoreBluetooth
import Foundation
import SwiftUI

/// Bridges the iPad's physical Bluetooth LE radio to the Mac's Broadcom BCM20702A0 USB Bluetooth HCI controller.
/// When macOS turns on BLE scanning in System Settings › Bluetooth (or any CoreBluetooth Mac app), Henge scans
/// nearby physical BLE peripherals via CBCentralManager and injects real HCI LE Advertising Reports into the guest.
/// When macOS advertises BLE services, Henge mirrors the local name and 16-bit/128-bit UUIDs via CBPeripheralManager.
final class BluetoothBridge: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    static let shared = BluetoothBridge()
    static let enabledKey = "henge.bt.radio"

    @Published private(set) var statusText: String = "Standby"
    @Published private(set) var discoveredCount: Int = 0

    private let btQueue = DispatchQueue(label: "com.henge.bt.radio", qos: .utility)
    private var central: CBCentralManager?
    private var peripheralMgr: CBPeripheralManager?
    private var pollTimer: Timer?
    private var isScanning = false
    private var isAdvertising = false
    private var lastAdvertisedSignature: Data?
    private var seenUUIDs = Set<UUID>()
    private var lastInjectTime: [UUID: TimeInterval] = [:]
    private var activeSession = false

    var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            btQueue.async { [weak self] in self?.syncRadioState() }
        }
    }

    func start() {
        guard pollTimer == nil else { return }
        activeSession = true
        discoveredCount = 0
        btQueue.async { [weak self] in
            self?.seenUUIDs.removeAll()
            self?.lastInjectTime.removeAll()
            self?.syncRadioState()
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.btQueue.async { self.syncRadioState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        activeSession = false
        pollTimer?.invalidate()
        pollTimer = nil
        btQueue.async { [weak self] in
            guard let self else { return }
            if self.isScanning {
                self.central?.stopScan()
                self.isScanning = false
            }
            if self.isAdvertising {
                self.peripheralMgr?.stopAdvertising()
                self.isAdvertising = false
                self.lastAdvertisedSignature = nil
            }
            DispatchQueue.main.async { self.statusText = "Off" }
        }
    }

    private func syncRadioState() {
        guard activeSession, isEnabled else {
            if isScanning { central?.stopScan(); isScanning = false }
            if isAdvertising { peripheralMgr?.stopAdvertising(); isAdvertising = false; lastAdvertisedSignature = nil }
            DispatchQueue.main.async { self.statusText = self.isEnabled ? "Standby" : "Disabled" }
            return
        }

        let wantScan = henge_vm_bt_scan_active() != 0
        if wantScan {
            if central == nil {
                central = CBCentralManager(delegate: self, queue: btQueue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            if let central, central.state == .poweredOn, !isScanning {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                isScanning = true
                HengeLog.log("bt", "physical CoreBluetooth LE scan started for macOS")
            }
        } else if isScanning {
            central?.stopScan()
            isScanning = false
            HengeLog.log("bt", "physical CoreBluetooth LE scan paused (macOS idle)")
        }

        var rawAdv = [UInt8](repeating: 0, count: 256)
        var rawLen: UInt32 = 0
        let wantAdv = henge_vm_bt_adv_active(&rawAdv, UInt32(rawAdv.count), &rawLen) != 0
        if wantAdv {
            if peripheralMgr == nil {
                peripheralMgr = CBPeripheralManager(delegate: self, queue: btQueue, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
            }
            if let pm = peripheralMgr, pm.state == .poweredOn {
                let payload = Data(rawAdv.prefix(Int(rawLen)))
                if !isAdvertising || payload != lastAdvertisedSignature {
                    if isAdvertising { pm.stopAdvertising() }
                    let dict = Self.decodeGuestAdvertisement(payload)
                    pm.startAdvertising(dict)
                    isAdvertising = true
                    lastAdvertisedSignature = payload
                }
            }
        } else if isAdvertising {
            peripheralMgr?.stopAdvertising()
            isAdvertising = false
            lastAdvertisedSignature = nil
        }

        let count = seenUUIDs.count
        let scanningNow = isScanning
        let authState = central?.state
        DispatchQueue.main.async {
            if authState == .unauthorized {
                self.statusText = "Bluetooth permission needed in iPad Settings"
            } else if authState == .poweredOff {
                self.statusText = "iPad Bluetooth is off"
            } else if scanningNow {
                self.statusText = count > 0 ? "Scanning · \(count) BLE devices" : "Scanning nearby BLE…"
            } else {
                self.statusText = count > 0 ? "Ready · \(count) BLE devices cached" : "Ready (macOS Bluetooth attached)"
            }
            self.discoveredCount = count
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { isScanning = false }
        syncRadioState()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn { isAdvertising = false }
        syncRadioState()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard activeSession, isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastInjectTime[peripheral.identifier], now - last < 0.45 { return }
        lastInjectTime[peripheral.identifier] = now

        let rssiInt = RSSI.intValue
        // CoreBluetooth reports 127 when RSSI is unavailable.
        let clampedRSSI = Int8(clamping: (rssiInt == 127 || rssiInt > 20) ? -60 : max(-127, rssiInt))
        let addr = Self.bleStaticRandomAddress(for: peripheral.identifier)
        let adv = Self.encodeAdvertisingPayload(peripheral: peripheral, advertisementData: advertisementData)

        let injected = addr.withUnsafeBufferPointer { addrPtr in
            adv.withUnsafeBufferPointer { advPtr in
                henge_vm_bt_inject_adv(1, addrPtr.baseAddress, clampedRSSI, advPtr.baseAddress, UInt32(adv.count))
            }
        }
        if injected != 0, seenUUIDs.insert(peripheral.identifier).inserted {
            let count = seenUUIDs.count
            DispatchQueue.main.async {
                self.discoveredCount = count
                if self.isScanning { self.statusText = "Scanning · \(count) BLE devices" }
            }
        }
    }

    /// Deterministic 6-byte BLE Static Random address (LSB-first wire order, MSB bits [47:46] = 11).
    private static func bleStaticRandomAddress(for id: UUID) -> [UInt8] {
        let u = id.uuid
        var b: [UInt8] = [
            u.15 ^ u.7,
            u.14 ^ u.6,
            u.13 ^ u.5,
            u.12 ^ u.4,
            u.11 ^ u.3,
            (u.10 ^ u.2) | 0xc0
        ]
        if b[0] == 0 && b[1] == 0 && b[2] == 0 { b[0] = 0x01 }
        return b
    }

    /// Packs CoreBluetooth discovery fields into standard Bluetooth LE AD structures (max 31 bytes).
    private static func encodeAdvertisingPayload(peripheral: CBPeripheral, advertisementData: [String: Any]) -> [UInt8] {
        var out: [UInt8] = []
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        // AD 0x01: Flags (LE General Discoverable + BR/EDR Not Supported)
        out.append(contentsOf: [0x02, 0x01, connectable ? 0x06 : 0x04])

        // AD 0x03 / 0x07: Service UUIDs
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            var uuid16Bytes: [UInt8] = []
            var uuid128Bytes: [UInt8] = []
            for uuid in uuids {
                let d = uuid.data
                if d.count == 2 && uuid16Bytes.count + 2 <= 12 {
                    uuid16Bytes.append(d[1]) // BLE wire order is little-endian
                    uuid16Bytes.append(d[0])
                } else if d.count == 16 && uuid128Bytes.isEmpty {
                    uuid128Bytes.append(contentsOf: d.reversed())
                }
            }
            if !uuid16Bytes.isEmpty && out.count + 2 + uuid16Bytes.count <= 31 {
                out.append(UInt8(1 + uuid16Bytes.count))
                out.append(0x03)
                out.append(contentsOf: uuid16Bytes)
            } else if !uuid128Bytes.isEmpty && out.count + 2 + uuid128Bytes.count <= 23 {
                out.append(UInt8(1 + uuid128Bytes.count))
                out.append(0x07)
                out.append(contentsOf: uuid128Bytes)
            }
        }

        // AD 0x09 / 0x08: Complete or Shortened Local Name (prioritized so devices have human-readable names in macOS)
        let rawName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        if let rawName, !rawName.isEmpty, out.count + 3 <= 31 {
            let utf8 = Array(rawName.utf8)
            let room = 31 - out.count - 2
            if room > 0 {
                let slice = Array(utf8.prefix(room))
                let complete = slice.count == utf8.count
                out.append(UInt8(1 + slice.count))
                out.append(complete ? 0x09 : 0x08)
                out.append(contentsOf: slice)
            }
        }

        // AD 0xFF: Manufacturer Specific Data if space remains
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfg.count >= 2, out.count + 2 + mfg.count <= 31 {
            out.append(UInt8(1 + mfg.count))
            out.append(0xff)
            out.append(contentsOf: mfg)
        }
        return out
    }

    private static func decodeGuestAdvertisement(_ data: Data) -> [String: Any] {
        var result: [String: Any] = [:]
        var uuids: [CBUUID] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            if len == 0 || i + 1 + len > bytes.count { break }
            let adType = bytes[i + 1]
            let body = bytes[(i + 2)..<(i + 1 + len)]
            if adType == 0x08 || adType == 0x09 {
                if let name = String(bytes: body, encoding: .utf8), !name.isEmpty {
                    result[CBAdvertisementDataLocalNameKey] = name
                }
            } else if adType == 0x02 || adType == 0x03 {
                var j = body.startIndex
                while j + 1 < body.endIndex {
                    let bigEndian = Data([body[j + 1], body[j]])
                    uuids.append(CBUUID(data: bigEndian))
                    j += 2
                }
            }
            i += 1 + len
        }
        if !uuids.isEmpty { result[CBAdvertisementDataServiceUUIDsKey] = uuids }
        return result
    }
}
