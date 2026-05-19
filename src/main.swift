import Cocoa
import WebKit
import Darwin
import ServiceManagement

// MARK: - System stats

struct CPUSnap { var user: UInt32; var sys: UInt32; var idle: UInt32; var nice: UInt32 }

func cpuTicks() -> [CPUSnap] {
    var count: mach_msg_type_number_t = 0
    var cpuCount: natural_t = 0
    var infoPtr: processor_info_array_t?
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                 &cpuCount, &infoPtr, &count)
    guard kr == KERN_SUCCESS, let info = infoPtr else { return [] }
    var out: [CPUSnap] = []
    let stride = Int(CPU_STATE_MAX)
    for i in 0..<Int(cpuCount) {
        let base = i * stride
        out.append(CPUSnap(
            user: UInt32(info[base + Int(CPU_STATE_USER)]),
            sys:  UInt32(info[base + Int(CPU_STATE_SYSTEM)]),
            idle: UInt32(info[base + Int(CPU_STATE_IDLE)]),
            nice: UInt32(info[base + Int(CPU_STATE_NICE)])
        ))
    }
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
    return out
}

func cpuPercent(prev: [CPUSnap], curr: [CPUSnap]) -> (avg: Double, perCore: [Double]) {
    guard prev.count == curr.count, !curr.isEmpty else { return (0, []) }
    var pc: [Double] = []
    var sumUsed: Double = 0, sumTotal: Double = 0
    for i in 0..<curr.count {
        let dUser = Double(curr[i].user &- prev[i].user)
        let dSys  = Double(curr[i].sys  &- prev[i].sys)
        let dIdle = Double(curr[i].idle &- prev[i].idle)
        let dNice = Double(curr[i].nice &- prev[i].nice)
        let used = dUser + dSys + dNice
        let total = used + dIdle
        let p = total > 0 ? (used / total) * 100.0 : 0
        pc.append(p)
        sumUsed += used; sumTotal += total
    }
    let avg = sumTotal > 0 ? (sumUsed / sumTotal) * 100.0 : 0
    return (avg, pc)
}

func memoryStats() -> (totalBytes: UInt64, usedBytes: UInt64, percent: Double, pressure: Double) {
    var size: UInt64 = 0
    var sz = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &sz, nil, 0)

    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (size, 0, 0, 0) }
    let ps = UInt64(pageSize)
    let active = UInt64(stats.active_count) * ps
    let wired = UInt64(stats.wire_count) * ps
    let compressed = UInt64(stats.compressor_page_count) * ps
    let used = active + wired + compressed
    let percent = size > 0 ? Double(used) / Double(size) * 100.0 : 0
    return (size, used, percent, percent)
}

func diskStats() -> (total: UInt64, used: UInt64, percent: Double) {
    let url = URL(fileURLWithPath: "/")
    if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
        let total = UInt64(v.volumeTotalCapacity ?? 0)
        let avail = UInt64(v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0))
        let used = total > avail ? total - avail : 0
        let pct = total > 0 ? Double(used) / Double(total) * 100.0 : 0
        return (total, used, pct)
    }
    return (0, 0, 0)
}

func netCounters() -> (sent: UInt64, recv: UInt64) {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
    defer { freeifaddrs(ifap) }
    var sent: UInt64 = 0, recv: UInt64 = 0
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = ptr {
        if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
            let name = String(cString: cur.pointee.ifa_name)
            if !name.hasPrefix("lo") && !name.hasPrefix("gif") && !name.hasPrefix("stf") && !name.hasPrefix("utun") {
                if let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    sent += UInt64(data.pointee.ifi_obytes)
                    recv += UInt64(data.pointee.ifi_ibytes)
                }
            }
        }
        ptr = cur.pointee.ifa_next
    }
    return (sent, recv)
}

func loadAverages() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    getloadavg(&l, 3)
    return l
}

// MARK: - Collector

final class Collector {
    private var prevCPU: [CPUSnap] = []
    private var prevNet: (sent: UInt64, recv: UInt64) = (0, 0)
    private var prevT: TimeInterval = Date().timeIntervalSince1970
    private(set) var last: [String: Any] = [:]

    init() {
        prevCPU = cpuTicks()
        prevNet = netCounters()
    }

    func tick() -> [String: Any] {
        let now = Date().timeIntervalSince1970
        let dt = max(now - prevT, 0.001)

        let cur = cpuTicks()
        let cpu = cpuPercent(prev: prevCPU, curr: cur)
        prevCPU = cur

        let nc = netCounters()
        let up = Double(nc.sent &- prevNet.sent) / dt
        let down = Double(nc.recv &- prevNet.recv) / dt
        prevNet = nc
        prevT = now

        let mem = memoryStats()
        let dsk = diskStats()
        let load = loadAverages()

        let d: [String: Any] = [
            "ts": now,
            "cpu": [
                "avg": cpu.avg,
                "perCore": cpu.perCore,
                "cores": cpu.perCore.count,
                "load": load
            ],
            "mem": [
                "total": mem.totalBytes,
                "used": mem.usedBytes,
                "percent": mem.percent
            ],
            "net": [
                "up": up,
                "down": down,
                "sentTotal": nc.sent,
                "recvTotal": nc.recv
            ],
            "disk": [
                "total": dsk.total,
                "used": dsk.used,
                "percent": dsk.percent
            ],
            "host": Host.current().localizedName ?? "Mac",
            "uptime": ProcessInfo.processInfo.systemUptime
        ]
        last = d
        return d
    }
}

func jsonString(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: - Dashboard window

final class DraggableWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class DashboardWindow: NSWindowController, WKScriptMessageHandler {
    let webView: WKWebView

    init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = DraggableWebView(frame: .zero, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "SysMon"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        win.contentView = webView
        webView.autoresizingMask = [.width, .height]
        webView.frame = win.contentView!.bounds

        super.init(window: win)
        ucc.add(self, name: "log")

        let url = Bundle.main.url(forResource: "index", withExtension: "html")!
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    required init?(coder: NSCoder) { fatalError() }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        NSLog("web: \(message.body)")
    }

    func push(_ dict: [String: Any]) {
        let js = "window.pushStats && window.pushStats(\(jsonString(dict)))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Autostart (LaunchAgent)

enum Autostart {
    static let label = "com.sysmon.menubar"
    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable(appPath: String) {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
            _ = shell("/bin/launchctl", ["unload", plistURL.path])
            _ = shell("/bin/launchctl", ["load", plistURL.path])
        }
    }

    static func disable() {
        _ = shell("/bin/launchctl", ["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = path
        p.arguments = args
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}

// MARK: - App

func formatBytes(_ b: Double) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var v = b; var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: v >= 100 ? "%.0f%@" : "%.1f%@", v, units[i])
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var dashboard: DashboardWindow?
    let collector = Collector()
    var timer: Timer?
    var cpuItem: NSMenuItem!
    var memItem: NSMenuItem!
    var netItem: NSMenuItem!
    var diskItem: NSMenuItem!
    var loadItem: NSMenuItem!
    var autoItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            btn.title = " ⏱ … "
        }

        let menu = NSMenu()
        menu.minimumWidth = 240
        cpuItem  = NSMenuItem(title: "CPU —", action: nil, keyEquivalent: "")
        memItem  = NSMenuItem(title: "RAM —", action: nil, keyEquivalent: "")
        netItem  = NSMenuItem(title: "Сеть —", action: nil, keyEquivalent: "")
        diskItem = NSMenuItem(title: "Диск —", action: nil, keyEquivalent: "")
        loadItem = NSMenuItem(title: "Загрузка —", action: nil, keyEquivalent: "")
        for it in [cpuItem, memItem, netItem, diskItem, loadItem] {
            it!.isEnabled = false
            menu.addItem(it!)
        }
        menu.addItem(.separator())
        let dash = NSMenuItem(title: "Открыть дашборд…", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        menu.addItem(dash)

        autoItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleAutostart), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = Autostart.isEnabled() ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        // first tick after a moment so delta is meaningful
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tick() }
    }

    func tick() {
        let d = collector.tick()
        let cpu = d["cpu"] as! [String: Any]
        let mem = d["mem"] as! [String: Any]
        let net = d["net"] as! [String: Any]
        let disk = d["disk"] as! [String: Any]
        let cpuAvg = cpu["avg"] as! Double
        let memPct = mem["percent"] as! Double
        let up = net["up"] as! Double
        let down = net["down"] as! Double
        let memUsed = (mem["used"] as! UInt64)
        let memTotal = (mem["total"] as! UInt64)
        let diskPct = disk["percent"] as! Double
        let load = (cpu["load"] as! [Double])

        statusItem.button?.title = String(format: " ⚙︎ %.0f%%  ◉ %.0f%%  ↑%@/s ", cpuAvg, memPct, formatBytes(up))

        cpuItem.title = String(format: "CPU  %.1f%%  ·  %d ядер", cpuAvg, (cpu["cores"] as! Int))
        memItem.title = String(format: "RAM  %.0f%%  ·  %@ / %@", memPct, formatBytes(Double(memUsed)), formatBytes(Double(memTotal)))
        netItem.title = String(format: "Сеть  ↑ %@/s   ↓ %@/s", formatBytes(up), formatBytes(down))
        diskItem.title = String(format: "Диск  %.0f%%  использовано", diskPct)
        loadItem.title = String(format: "Load avg  %.2f  %.2f  %.2f", load[0], load[1], load[2])

        dashboard?.push(d)
    }

    @objc func openDashboard() {
        if dashboard == nil { dashboard = DashboardWindow() }
        dashboard?.show()
    }

    @objc func toggleAutostart() {
        if Autostart.isEnabled() {
            Autostart.disable()
            autoItem.state = .off
        } else {
            let appPath = Bundle.main.bundlePath
            Autostart.enable(appPath: appPath)
            autoItem.state = .on
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
