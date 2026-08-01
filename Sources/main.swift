import AppKit
import Combine
import CoreBluetooth
import SwiftUI

// Menu bar app showing battery % of this Mac, Bluetooth accessories (AirPods,
// keyboards, mice) and Wi-Fi-paired iPhones/iPads. Polls every 60s.

struct Device {
    let name: String
    let symbol: String            // SF Symbol name
    let percent: Int?             // headline percent (lowest part)
    let charging: Bool
    let parts: [(String, Int)]    // e.g. [("L", 83), ("R", 97), ("Case", 86)]
}

func run(_ launchPath: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Sources

func macBattery() -> Device? {
    let out = run("/usr/bin/pmset", ["-g", "batt"])
    guard let m = out.firstMatch(of: #/(\d+)%/#) else { return nil }
    let pct = Int(m.1)!
    return Device(name: Host.current().localizedName ?? "This Mac",
                  symbol: "laptopcomputer", percent: pct,
                  charging: out.contains("AC Power"), parts: [])
}

func bluetoothDevices() -> [Device] {
    let out = run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
    guard let data = out.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let bt = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
          let connected = bt["device_connected"] as? [[String: Any]]
    else { return [] }

    var devices: [Device] = []
    for entry in connected {
        for (name, v) in entry {
            guard let props = v as? [String: String] else { continue }
            let pct = { (key: String) -> Int? in
                props[key].flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
            }
            let symbol: String
            switch props["device_minorType"] {
            case "Headphones", "Headset": symbol = "airpods.gen3"
            case "Keyboard": symbol = "keyboard"
            case "Mouse": symbol = "computermouse"
            default: symbol = "wave.3.right.circle"
            }
            let l = pct("device_batteryLevelLeft")
            let r = pct("device_batteryLevelRight")
            let c = pct("device_batteryLevelCase")
            let single = pct("device_batteryLevel") ?? pct("device_batteryLevelMain")
            if l != nil || r != nil || c != nil {
                var parts: [(String, Int)] = []
                if let l { parts.append(("L", l)) }
                if let r { parts.append(("R", r)) }
                if let c { parts.append(("Case", c)) }
                devices.append(Device(name: name, symbol: symbol,
                                      percent: [l, r].compactMap { $0 }.min(),
                                      charging: false, parts: parts))
            } else if let single {
                devices.append(Device(name: name, symbol: symbol, percent: single,
                                      charging: false, parts: []))
            }
        }
    }
    return devices
}

// iPhone/iPad over Wi-Fi via libimobiledevice (one-time USB pairing + Wi-Fi sync required).
func idevices() -> [Device] {
    let bins = ["/opt/homebrew/bin", "/usr/local/bin"]
    guard let bin = bins.first(where: { FileManager.default.fileExists(atPath: $0 + "/idevice_id") })
    else { return [] }

    // USB devices first, then network; dedupe by UDID (a plugged-in phone can be both).
    let usb = Set(run(bin + "/idevice_id", ["-l"]).split(separator: "\n").map(String.init))
    let net = Set(run(bin + "/idevice_id", ["-n"]).split(separator: "\n").map(String.init))
    var devices: [Device] = []
    for udid in usb.union(net) {
        let netFlag = usb.contains(udid) ? [] : ["-n"]
        let info = run(bin + "/ideviceinfo", ["-u", udid] + netFlag + ["-q", "com.apple.mobile.battery"])
        guard let m = info.firstMatch(of: #/BatteryCurrentCapacity: (\d+)/#) else { continue }
        let name = run(bin + "/idevicename", ["-u", udid] + netFlag)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        devices.append(Device(name: name.isEmpty ? "iPhone" : name, symbol: "iphone",
                              percent: Int(m.1)!,
                              charging: info.contains("BatteryIsCharging: true"), parts: []))
    }
    return devices
}

// AirPods battery while they're connected to the iPhone (not the Mac): Apple's
// BLE proximity-pairing advertisements carry the levels in plaintext.
// Offsets per AirBattery's BLEBattery.swift; format is Apple-private and may change.
final class BLEAirPods: NSObject, CBCentralManagerDelegate {
    static let shared = BLEAirPods()
    private var central: CBCentralManager?
    private(set) var latest: (left: Int?, right: Int?, case_: Int?, at: Date)?
    var onChange: (() -> Void)?   // fired on the main queue when values change

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        // ponytail: continuous scan; duty-cycle it if battery impact ever shows.
        c.scanForPeripherals(withServices: nil,
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard rssi.intValue > -70,  // near me, not a stranger's AirPods across the café
              let d = ad[CBAdvertisementDataManufacturerDataKey] as? Data,
              d.count > 2, d[0] == 0x4C, d[1] == 0x00 else { return }
        func pct(_ b: UInt8) -> Int? { b == 255 ? nil : Int(min(b & 0x7F, 100)) }
        let old = latest
        if d.count == 29, d[2] == 0x07 {          // lid open
            latest = (pct(d[14]), pct(d[15]), pct(d[16]), Date())
        } else if d.count == 25, d[2] == 0x12 {   // lid closed
            latest = (pct(d[13]), pct(d[14]), pct(d[12]), Date())
        } else { return }
        if old?.left != latest?.left || old?.right != latest?.right || old?.case_ != latest?.case_ {
            onChange?()
        }
    }

    // ponytail: L/R may be swapped (flip bit unparsed) and identity is "nearest
    // AirPods", not verified ownership — good enough for a personal menu bar.
    var device: Device? {
        guard let l = latest, Date().timeIntervalSince(l.at) < 300 else { return nil }
        var parts: [(String, Int)] = []
        if let v = l.left { parts.append(("L", v)) }
        if let v = l.right { parts.append(("R", v)) }
        if let v = l.case_ { parts.append(("Case", v)) }
        guard !parts.isEmpty else { return nil }
        return Device(name: "AirPods (nearby)", symbol: "airpods.gen3",
                      percent: [l.left, l.right].compactMap { $0 }.min(),
                      charging: false, parts: parts)
    }
}

// MARK: - UI

func levelColor(_ pct: Int) -> Color {
    pct <= 20 ? .red : pct <= 40 ? .orange : .green
}

let menuWidth: CGFloat = 320

struct Gauge: View {
    let pct: Int
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(levelColor(pct))
                    .frame(width: max(5, geo.size.width * CGFloat(pct) / 100))
            }
        }
        .frame(height: 4)
    }
}

struct DeviceRow: View {
    let d: Device
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 36, height: 36)
                Image(systemName: d.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary.opacity(0.75))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(d.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if d.charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                    Text(d.percent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(d.percent.map { $0 <= 20 ? Color.red : .primary } ?? .secondary)
                }
                if let p = d.percent { Gauge(pct: p) }
                if !d.parts.isEmpty {
                    Text(d.parts.map { "\($0.0) \($0.1)%" }.joined(separator: "   ·   "))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: menuWidth, alignment: .leading)
    }
}

final class Store: ObservableObject {
    @Published var devices: [Device] = []
    @Published var updated = Date()
}

struct MenuContent: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(updated: store.updated)
            if store.devices.isEmpty {
                Text("Looking for devices…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            ForEach(store.devices, id: \.name) { DeviceRow(d: $0) }
        }
        .frame(width: menuWidth)
    }
}

struct HeaderRow: View {
    let updated: Date
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Devices")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("Updated \(updated, style: .time)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(width: menuWidth)
    }
}

// MARK: - App

// ponytail: `--once` prints devices and exits — the self-check for all parsing logic.
if CommandLine.arguments.contains("--once") {
    var devices: [Device] = []
    if let mac = macBattery() { devices.append(mac) }
    devices += bluetoothDevices()
    devices += idevices()
    for d in devices {
        let parts = d.parts.map { "\($0.0) \($0.1)%" }.joined(separator: "  ")
        print("\(d.name): \(d.percent.map { "\($0)%" } ?? "—") \(parts)")
    }
    assert(!devices.isEmpty, "expected at least the Mac's own battery")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    let store = Store()
    var contentHost: NSHostingView<MenuContent>!
    var sizeSub: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Notched Macs hide new status items when the right side is full: default
        // placement lands under the notch. Seed a position away from it BEFORE
        // creating the item (pts from right edge); user can ⌘-drag it afterwards.
        let posKey = "NSStatusItem Preferred Position devbat"
        if UserDefaults.standard.object(forKey: posKey) == nil {
            UserDefaults.standard.set(1000, forKey: posKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "devbat"
        setButton(percent: nil, charging: false)

        // Menu built once; content is a live SwiftUI view bound to the store,
        // so an already-open menu updates in place.
        let menu = NSMenu()
        menu.delegate = self
        let contentItem = NSMenuItem()
        contentHost = NSHostingView(rootView: MenuContent(store: store))
        contentHost.frame.size = contentHost.fittingSize
        contentItem.view = contentHost
        menu.addItem(contentItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        // Row count changes menu height; track the content's fitting size.
        sizeSub = store.$devices.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let host = self?.contentHost else { return }
                host.frame.size = host.fittingSize
            }
        }

        BLEAirPods.shared.start()
        BLEAirPods.shared.onChange = { [weak self] in self?.mergeBLE() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow),
            name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // Fresh data whenever the user opens the menu — no manual refresh needed.
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // Live-update the BLE AirPods row between polls.
    func mergeBLE() {
        var devices = store.devices.filter { $0.name != "AirPods (nearby)" }
        if !devices.contains(where: { !$0.parts.isEmpty }),
           let ble = BLEAirPods.shared.device {
            devices.append(ble)
        }
        guard devices.map(\.name) != store.devices.map(\.name)
            || devices.map(\.percent) != store.devices.map(\.percent) else { return }
        store.devices = devices
        store.updated = Date()
    }

    // Template SF Symbol battery icon: tints white/black with the menu bar like
    // native icons (emoji don't).
    func setButton(percent: Int?, charging: Bool) {
        guard let button = item.button else { return }
        let name: String
        if charging {
            name = "battery.100percent.bolt"
        } else if let p = percent {
            name = "battery.\(p <= 12 ? 0 : p <= 37 ? 25 : p <= 62 ? 50 : p <= 87 ? 75 : 100)percent"
        } else {
            name = "battery.50percent"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Battery")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeading
        button.title = percent.map { " \($0)%" } ?? " –"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    func refresh() {
        DispatchQueue.global().async {
            var devices: [Device] = []
            if let mac = macBattery() { devices.append(mac) }
            devices += bluetoothDevices()
            devices += idevices()
            DispatchQueue.main.async {
                // BLE fallback only when no AirPods are connected to the Mac itself.
                if !devices.contains(where: { !$0.parts.isEmpty }),
                   let ble = BLEAirPods.shared.device {
                    devices.append(ble)
                }
                self.render(devices)
            }
        }
    }

    func render(_ devices: [Device]) {
        let lowest = devices.compactMap(\.percent).min()
        let lowestDevice = devices.first { $0.percent == lowest }
        setButton(percent: lowest, charging: lowestDevice?.charging ?? false)
        store.devices = devices
        store.updated = Date()
    }

    @objc func refreshNow() { refresh() }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
