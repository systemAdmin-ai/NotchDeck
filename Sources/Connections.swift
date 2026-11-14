import AppKit
import SystemConfiguration

struct ConnectionSnapshot {
    var happ="—"
    var checkpoint="—"
}

final class ConnectionMonitor {
    static let shared=ConnectionMonitor()
    private var timer:Timer?
    private var busy=false
    private(set) var current=ConnectionSnapshot()
    func start() {
        guard timer == nil else{return}
        refresh()
        let timer=Timer(timeInterval:5,repeats:true) { [weak self] _ in self?.refresh() }
        timer.tolerance=1;RunLoop.main.add(timer,forMode:.common);self.timer=timer
    }
    private func refresh() {
        guard !busy else{return};busy=true
        DispatchQueue.global(qos:.utility).async {
            let status=ConnectionSnapshot(happ:Self.happStatus(),checkpoint:Self.checkpointStatus())
            DispatchQueue.main.async {self.current=status;self.busy=false}
        }
    }
    static func happStatus()->String {
        guard let prefs=SCPreferencesCreate(nil,"NotchDeck" as CFString,nil),
              let services=SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else{return "Нет данных"}
        for service in services {
            let name=SCNetworkServiceGetName(service) as String? ?? ""
            guard name.localizedCaseInsensitiveContains("Happ") else{continue}
            guard let identifier=SCNetworkServiceGetServiceID(service),let connection=SCNetworkConnectionCreateWithServiceID(nil,identifier,nil,nil) else{return "Нет данных"}
            switch SCNetworkConnectionGetStatus(connection) {
            case .connected:return "Подключён"
            case .connecting:return "Подключение"
            case .disconnecting:return "Отключение"
            case .disconnected:return "Выключен"
            default:return "Нет данных"
            }
        }
        return FileManager.default.fileExists(atPath:"/Applications/Happ.app") ? "Не настроен":"Не установлен"
    }
    static func parseCheckpoint(_ output:String)->String {
        // Parse only the product's status field. Never infer connection from a running
        // process or a random utun interface, and never retain VPN sites/credentials.
        for line in output.components(separatedBy:.newlines) {
            let trimmed=line.trimmingCharacters(in:.whitespaces).lowercased()
            guard trimmed.hasPrefix("status:") else{continue}
            let value=trimmed.dropFirst(7).trimmingCharacters(in:.whitespaces)
            switch value {
            case "connected":return "Подключён"
            case "idle","disconnected","not connected":return "Выключен"
            case "connecting":return "Подключение"
            case "disconnecting":return "Отключение"
            default:return "Нет данных"
            }
        }
        return "Нет данных"
    }
    static func checkpointStatus()->String {
        let path="/Library/Application Support/Checkpoint/Endpoint Connect/trac"
        guard FileManager.default.isExecutableFile(atPath:path) else{return "Нет данных"}
        let process=Process(),pipe=Pipe()
        process.executableURL=URL(fileURLWithPath:path);process.arguments=["info"]
        process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        let result=NSLock();var timedOut=false
        let watchdog=DispatchWorkItem {
            result.lock();timedOut=true;result.unlock()
            if process.isRunning {process.terminate()}
        }
        do {
            try process.run();DispatchQueue.global().asyncAfter(deadline:.now()+3,execute:watchdog)
            // Drain output while the process runs to avoid a full pipe deadlock.
            let data=pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit();watchdog.cancel()
            result.lock();let timeout=timedOut;result.unlock()
            guard !timeout,process.terminationStatus==0 else{return "Нет данных"}
            return parseCheckpoint(String(data:data,encoding:.utf8) ?? "")
        } catch {watchdog.cancel();return "Нет данных"}
    }
    static func open(_ item:Item) {
        let path=item == .happStatus ? "/Applications/Happ.app":"/Applications/Endpoint Security VPN.app"
        NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:path),configuration:NSWorkspace.OpenConfiguration()) { _,error in
            if let error {Dbg.log("connection app: \(error.localizedDescription)")}
        }
    }
}

struct NetworkCounter:Equatable {var rx:UInt64;var tx:UInt64}
struct NetworkRateSampler {
    private var baseline:[String:NetworkCounter]?
    private var stamp:TimeInterval=0
    private(set) var ready=false
    private(set) var down:Double=0
    private(set) var up:Double=0
    mutating func sample(_ counters:[String:NetworkCounter],at time:TimeInterval)->(down:Double,up:Double) {
        guard let previous=baseline else {baseline=counters;stamp=time;return(0,0)}
        let delta=time-stamp
        guard delta>=0.2 else{return(down,up)}
        var rx:UInt64=0,tx:UInt64=0
        for (name,current) in counters {
            guard let old=previous[name],current.rx>=old.rx,current.tx>=old.tx else{continue}
            rx += current.rx-old.rx;tx += current.tx-old.tx
        }
        baseline=counters;stamp=time;ready = !counters.isEmpty
        down=Double(rx)/1024/delta;up=Double(tx)/1024/delta
        return(down,up)
    }
}
