import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - SMC (температура без root)
// Структура повторяет рабочий прототип: 80 байт, key@0, keyInfo@28, result@40, data8@42, bytes@48.
private struct SMCLayout {
    static let size = 80
    static let key = 0
    static let keyInfo = 28
    static let result = 40
    static let data8 = 42
    static let bytes = 48
}

private func fourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
    return r
}

final class SMCReader {
    private var conn: io_connect_t = 0
    private var opened = false

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(svc, mach_task_self_, 0, &c)
        IOObjectRelease(svc)
        if kr == KERN_SUCCESS { conn = c; opened = true }
    }

    deinit { if opened { IOServiceClose(conn) } }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        let n = SMCLayout.size
        let ip = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        let op = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        defer { ip.deallocate(); op.deallocate() }
        ip.initialize(repeating: 0, count: n)
        op.initialize(repeating: 0, count: n)
        for i in 0..<min(n, input.count) { ip[i] = input[i] }
        var outSize = n
        let kr = IOConnectCallStructMethod(conn, 2, ip, n, op, &outSize)
        guard kr == KERN_SUCCESS else { return nil }
        return Array(UnsafeBufferPointer(start: op, count: n))
    }

    /// Возвращает °C для температурного ключа или nil.
    func temperature(_ key: String) -> Double? {
        guard opened else { return nil }
        let k = fourCC(key)

        // 1) запрос keyInfo; если SMC не отдал — читаем как 'flt ' 4 байта (как в рабочем C-прототипе)
        var in1 = [UInt8](repeating: 0, count: SMCLayout.size)
        in1[0] = UInt8(k & 0xff); in1[1] = UInt8((k >> 8) & 0xff)
        in1[2] = UInt8((k >> 16) & 0xff); in1[3] = UInt8((k >> 24) & 0xff)
        in1[SMCLayout.data8] = 5
        var size: UInt32 = 4
        let dbgKi = call(in1)
        if let ki = dbgKi, ki[SMCLayout.result] == 0 {
            let s = read32(ki, SMCLayout.keyInfo)
            if s > 0 && s <= 32 { size = s }
        }

        // 2) чтение значения: dataType НЕ пишем — SMC отвергает такой запрос (err 132)
        var in2 = [UInt8](repeating: 0, count: SMCLayout.size)
        in2[0] = in1[0]; in2[1] = in1[1]; in2[2] = in1[2]; in2[3] = in1[3]
        in2[SMCLayout.keyInfo] = UInt8(size & 0xff)
        in2[SMCLayout.keyInfo + 1] = UInt8((size >> 8) & 0xff)
        in2[SMCLayout.keyInfo + 2] = UInt8((size >> 16) & 0xff)
        in2[SMCLayout.keyInfo + 3] = UInt8((size >> 24) & 0xff)
        in2[SMCLayout.data8] = 5

        let dbgRd = call(in2)
        guard let rd = dbgRd, rd[SMCLayout.result] == 0 else { return nil }
        let raw = Array(rd[SMCLayout.bytes..<(SMCLayout.bytes + Int(size))])

        if size == 4 {
            let bits = UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
            return Double(Float(bitPattern: bits))
        }
        if size == 2 {
            let v = UInt16(raw[0]) << 8 | UInt16(raw[1])
            return Double(v) / 256.0
        }
        if size == 1 { return Double(raw[0]) }
        return nil
    }

    private func read32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
}

// MARK: - Метрики
struct MetricSnapshot {
    var cpu: Double = 0            // %
    var ramUsed: Double = 0        // GB
    var ramTotal: Double = 0       // GB
    var temp: Double? = nil        // °C
    var battery: Int? = nil        // %
    var charging: Bool = false
    var down: Double = 0           // KB/s
    var up: Double = 0             // KB/s
    var diskFree: Double = 0       // GB
    var uptime: String = ""
    var ip: String = "—"
    var vpn: Bool = false
    var networkReady=false
    var happStatus="—"
    var checkpointStatus="—"
}

final class Metrics {
    static let shared = Metrics()

    private let smc = SMCReader()
    private var prevCPU: (busy: Double, total: Double)?
    private var alertPrevCPU: (busy:Double,total:Double)?
    private var networkSampler=NetworkRateSampler()
    private var cachedTemp: Double?
    private var tempFetchedAt: TimeInterval = 0

    private init() {}

    func snapshot() -> MetricSnapshot {
        var s = MetricSnapshot()
        s.cpu = cpuPercent() ?? 0
        let mem = memory()
        s.ramUsed = mem.used
        s.ramTotal = mem.total
        s.temp = cpuTemperature()
        if let b = battery() { s.battery = b.percent; s.charging = b.charging }
        let rate = netRate()
        s.down = rate.down
        s.up = rate.up
        s.networkReady=networkSampler.ready
        s.happStatus=ConnectionMonitor.shared.current.happ
        s.checkpointStatus=ConnectionMonitor.shared.current.checkpoint
        s.diskFree = diskFreeGB()
        s.uptime = uptimeString()
        let n = networkIdentity()
        s.ip = n.ip
        s.vpn = n.vpn
        return s
    }

    func alertSnapshot() -> MetricSnapshot {
        var s = MetricSnapshot()
        let panelBaseline=prevCPU
        prevCPU=alertPrevCPU
        s.cpu=cpuPercent() ?? 0
        alertPrevCPU=prevCPU
        prevCPU=panelBaseline
        let mem = memory()
        s.ramUsed = mem.used
        s.ramTotal = mem.total
        s.temp = cpuTemperature()
        if let b = battery() { s.battery = b.percent; s.charging = b.charging }
        return s
    }

    // CPU
    func cpuPercent() -> Double? {
        var numCpu: natural_t = 0
        var numInfo: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpu, &info, &numInfo)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(numInfo) * MemoryLayout<integer_t>.stride))
        }
        var busy = 0.0, total = 0.0
        for i in 0..<Int(numCpu) {
            let base = i * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { prevCPU = (busy, total) }
        guard let prev = prevCPU, total > prev.total else { return prevCPU == nil ? 0 : nil }
        let dBusy = busy - prev.busy
        let dTotal = total - prev.total
        guard dTotal > 0 else { return 0 }
        return max(0, min(100, dBusy / dTotal * 100))
    }

    // RAM
    func memory() -> (used: Double, total: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard kr == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)
        // «Используемая память» так же, как в Мониторинге системы: всего − свободно − кэшированные файлы
        // (external/file-backed страницы). Прежняя формула active+wired+compressor давала на 0.5–2 ГБ меньше:
        // она не учитывает file-backed страницы, которые Activity Monitor считает занятыми.
        let free = Double(stats.free_count) * page
        let fileBacked = Double(stats.external_page_count) * page
        let usedBytes = max(0, Double(ProcessInfo.processInfo.physicalMemory) - free - fileBacked)
        let used = usedBytes / 1_073_741_824
        return (used, total)
    }

    // Температура: кэш 3 с, чтобы не дёргать SMC зря
    func cpuTemperature() -> Double? {
        let now = Date().timeIntervalSince1970
        if now - tempFetchedAt < 3 { return cachedTemp }
        tempFetchedAt = now
        let keys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te09"]
        var best: Double = 0
        for k in keys {
            if let v = smc.temperature(k), v > 0, v < 130, v > best { best = v }
        }
        cachedTemp = best > 0 ? best : nil
        return cachedTemp
    }

    // Батарея
    func battery() -> (percent: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0,
                  let transport = desc[kIOPSTransportTypeKey] as? String, transport == kIOPSInternalType else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return (Int(Double(cur) / Double(maxCap) * 100.0), charging)
        }
        return nil
    }

    // Сеть
    func networkCounters()->[String:NetworkCounter] {
        var mib:[Int32]=[CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0]
        var length=0
        guard sysctl(&mib,6,nil,&length,nil,0)==0,length>0 else{return [:]}
        var bytes=[UInt8](repeating:0,count:length)
        guard sysctl(&mib,6,&bytes,&length,nil,0)==0 else{return [:]}
        var counters:[String:NetworkCounter]=[:]
        bytes.withUnsafeBytes { raw in
            var offset=0
            while offset+MemoryLayout<if_msghdr2>.size<=length {
                let header=raw.loadUnaligned(fromByteOffset:offset,as:if_msghdr2.self)
                let size=Int(header.ifm_msglen)
                guard size>0,offset+size<=length else{break}
                if Int32(header.ifm_type)==RTM_IFINFO2,header.ifm_flags & IFF_UP != 0 {
                    var name=[CChar](repeating:0,count:Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(header.ifm_index),&name) != nil {
                        let interface=String(cString:name)
                        // Count physical traffic once; adding utun would double VPN traffic.
                        if interface.hasPrefix("en") {
                            counters[interface]=NetworkCounter(rx:header.ifm_data.ifi_ibytes,tx:header.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += size
            }
        }
        return counters
    }

    func netRate()->(down:Double,up:Double) {
        networkSampler.sample(networkCounters(),at:ProcessInfo.processInfo.systemUptime)
    }

    // Диск
    func diskFreeGB() -> Double {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = v.volumeAvailableCapacityForImportantUsage else { return 0 }
        return Double(bytes) / 1_073_741_824
    }

    // Uptime
    func uptimeString() -> String {
        let up = Int(ProcessInfo.processInfo.systemUptime)
        let d = up / 86400, h = (up % 86400) / 3600, m = (up % 3600) / 60
        if d > 0 { return "\(d)д \(h)ч" }
        if h > 0 { return "\(h)ч \(String(format: "%02d", m))м" }
        return "\(m)м"
    }

    // IP / VPN
    func networkIdentity() -> (ip: String, vpn: Bool) {
        var ip = "—", vpn = false
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (ip, vpn) }
        defer { freeifaddrs(addrs) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let a = cur {
            let name = String(cString: a.pointee.ifa_name)
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let addr = String(cString: host)
                    if name.hasPrefix("en") && ip == "—" { ip = addr }
                    if name.hasPrefix("utun") && addr != "0.0.0.0" { vpn = true }
                }
            }
            cur = a.pointee.ifa_next
        }
        return (ip, vpn)
    }

    // Для self-test из консоли
    func dump() -> String {
        let s = snapshot()
        let t = s.temp.map { String(format: "%.1f", $0) } ?? "n/a"
        return """
        cpu=\(String(format: "%.1f", s.cpu))% ram=\(String(format: "%.1f", s.ramUsed))/\(String(format: "%.1f", s.ramTotal))GB \
        temp=\(t)°C bat=\(s.battery.map { "\($0)%" } ?? "n/a")\(s.charging ? "+" : "") \
        net=\(String(format: "%.0f", s.down))/\(String(format: "%.0f", s.up))KB/s disk=\(String(format: "%.1f", s.diskFree))GB \
        up=\(s.uptime) ip=\(s.ip) vpn=\(s.vpn)
        """
    }
}
