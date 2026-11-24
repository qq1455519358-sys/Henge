import Darwin
import Foundation
import Network
import UIKit

/// Publishes the physical iPad's battery percentage, charging state, thermal state, Wi-Fi / Ethernet IPv4
/// address, and mounted external USB drive label to host/share.c (/.henge/status) for the macOS menu bar.
final class HostStatusBridge: ObservableObject {
    static let shared = HostStatusBridge()

    @Published private(set) var batteryPercent: Int = -1
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var networkKind: String = "Wi-Fi"
    @Published private(set) var ipAddress: String = ""

    private let monitorQueue = DispatchQueue(label: "com.henge.hoststatus", qos: .utility)
    private var pathMonitor: NWPathMonitor?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: String
            if path.status != .satisfied {
                kind = "Offline"
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = "Ethernet"
            } else if path.usesInterfaceType(.wifi) {
                kind = "Wi-Fi"
            } else if path.usesInterfaceType(.cellular) {
                kind = "Cellular"
            } else {
                kind = "Online"
            }
            DispatchQueue.main.async {
                self?.networkKind = kind
                self?.pushNow()
            }
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.pushNow() },
            nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.pushNow() },
            nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.pushNow() }
        ]

        pushNow()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.pushNow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
        observers.removeAll()
    }

    func pushNow() {
        let level = UIDevice.current.batteryLevel
        let pct = level >= 0 ? Int((level * 100).rounded()) : -1
        let state = UIDevice.current.batteryState
        let charging = (state == .charging || state == .full)
        let ip = Self.primaryIPv4Address() ?? ""
        let thermal = Self.thermalLabel(ProcessInfo.processInfo.thermalState)

        batteryPercent = pct
        isCharging = charging
        ipAddress = ip

        let dict: [String: Any] = [
            "device": Device.marketingName,
            "battery": pct,
            "charging": charging,
            "network": networkKind,
            "ip": ip,
            "thermal": thermal,
            "external": Sharing.externalLabel ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let json = String(data: data, encoding: .utf8) {
            henge_share_set_host_status(json)
        }
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Normal"
        }
    }

    private static func primaryIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let interface = cur.pointee
            ptr = interface.ifa_next
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            if name == "lo0" { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if ip.hasPrefix("169.254.") { continue }
                if name == "en0" || name == "en1" { return ip }
                if fallback == nil { fallback = ip }
            }
        }
        return fallback
    }
}
