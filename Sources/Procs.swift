import Darwin
import Foundation

// MARK: - Процессы по памяти
struct ProcInfo {
    let pid: pid_t
    let name: String
    let footprint: UInt64   // байт, физический след (как «Память» в Мониторинге)
    let executable: String?
    var cpuTime: UInt64 = 0 // наносекунды user+system

    var megabytes: Double { Double(footprint) / 1_048_576 }

    /// Корень бандла: …/Foo.app — чтобы закрывать приложение целиком.
    var bundlePath: String? {
        guard let exe = executable, let r = exe.range(of: ".app/") else { return nil }
        return String(exe[exe.startIndex..<r.lowerBound]) + ".app"
    }
}

enum Procs {
    /// Эти процессы не предлагаем завершать: система или мы сами.
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "coreaudiod", "tccd", "logd", "opendirectoryd",
        "NotchDeck", "runningboardd", "launchservicesd"
    ]

    static func isProtected(_ p: ProcInfo) -> Bool {
        if p.pid == 1 || p.pid == getpid() { return true }
        return protectedNames.contains(p.name)
    }

    private static func displayName(_ pid: pid_t) -> (String, String?) {
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        if len > 0 {
            let path = String(cString: buf)
            let last = (path as NSString).lastPathComponent
            let name = last.hasSuffix(".app") ? String(last.dropLast(4)) : (last as NSString).deletingPathExtension
            return (name, path)
        }
        var nm = [CChar](repeating: 0, count: 512)
        let n = proc_name(pid, &nm, UInt32(nm.count))
        return (n > 0 ? String(cString: nm) : "pid \(pid)", nil)
    }

    /// ri_user_time/ri_system_time приходят в тиках mach absolute time (24 МГц на Apple Silicon),
    /// а не в наносекундах — без пересчёта busy-loop показывал 2 % вместо 100 %.
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static func rusage(_ pid: pid_t) -> (footprint: UInt64, cpu: UInt64) {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { q in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, q)
            }
        }
        guard r == 0 else { return (0, 0) }
        return (info.ri_phys_footprint, nanoseconds(info.ri_user_time + info.ri_system_time))
    }

    /// Завершает все процессы бандла: SIGTERM сразу всем, через 3 с выжившим SIGKILL.
    @discardableResult
    static func terminateBundle(_ bundle: String, completion: ((Int) -> Void)? = nil) -> Int {
        let victims = processes(inBundle: bundle).filter { !isProtected($0) }
        guard !victims.isEmpty else { completion?(0); return 0 }
        for v in victims { _ = kill(v.pid, SIGTERM) }
        Dbg.log("procs: SIGTERM бандлу \(bundle) процессов=\(victims.count)")
        let pids = victims.map { $0.pid }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            for pid in pids where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
            DispatchQueue.main.async { completion?(pids.count) }
        }
        return pids.count
    }

    /// Данные по конкретному pid (для CLI и проверок).
    static func info(pid: pid_t) -> ProcInfo? {
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        let (name, path) = displayName(pid)
        return ProcInfo(pid: pid, name: name, footprint: rusage(pid).footprint, executable: path)
    }

    /// Снимок всех процессов: память + процессорное время.
    static func snapshot() -> [ProcInfo] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        var rows: [ProcInfo] = []
        rows.reserveCapacity(count)
        for i in 0..<max(0, count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let r = rusage(pid)
            guard r.footprint > 0 else { continue }
            let (name, path) = displayName(pid)
            rows.append(ProcInfo(pid: pid, name: name, footprint: r.footprint,
                                 executable: path, cpuTime: r.cpu))
        }
        return rows
    }

    /// Топ по загрузке CPU за интервал между снимками (100 % = одно ядро).
    static func topByCPU(previous: [pid_t: UInt64], current: [ProcInfo], interval: Double) -> [ProcInfo] {
        let elapsed = max(0.05, interval) * 1_000_000_000
        var scored: [(ProcInfo, Double)] = []
        for var p in current {
            let before = previous[p.pid] ?? p.cpuTime
            let delta = p.cpuTime > before ? p.cpuTime - before : 0
            p.cpuTime = UInt64(Double(delta) / elapsed * 100)
            if p.cpuTime > 0 { scored.append((p, Double(p.cpuTime))) }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.map { $0.0 }
    }

    /// Канонический путь: /tmp — это симлинк на /private/tmp, иначе бандл не находится.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Все процессы одного бандла (для «закрыть приложение целиком»).
    static func processes(inBundle bundle: String) -> [ProcInfo] {
        let want = canonical(bundle)
        return snapshot().filter { $0.bundlePath.map(canonical) == want }
    }

    /// Топ процессов по физическому следу. Защищённые остаются в списке, но помечены.
    static func topByMemory(limit: Int = 8) -> [ProcInfo] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        var rows: [ProcInfo] = []
        rows.reserveCapacity(count)
        for i in 0..<max(0, count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let fp = rusage(pid).footprint
            guard fp > 0 else { continue }
            let (name, path) = displayName(pid)
            rows.append(ProcInfo(pid: pid, name: name, footprint: fp, executable: path))
        }
        rows.sort { $0.footprint > $1.footprint }
        return Array(rows.prefix(limit))
    }

    /// SIGTERM, при живом через `grace` секунд — SIGKILL. Возвращает true, если сигнал ушёл.
    @discardableResult
    static func terminate(_ p: ProcInfo, grace: TimeInterval = 3, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !isProtected(p) else {
            Dbg.log("procs: отказ — защищённый \(p.name)")
            return false
        }
        let ok = kill(p.pid, SIGTERM) == 0
        Dbg.log("procs: SIGTERM \(p.name) pid=\(p.pid) результат=\(ok)")
        guard ok else { completion?(false); return false }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if kill(p.pid, 0) == 0 {
                _ = kill(p.pid, SIGKILL)
                Dbg.log("procs: SIGKILL \(p.name) pid=\(p.pid)")
            }
            DispatchQueue.main.async { completion?(true) }
        }
        return true
    }
}
