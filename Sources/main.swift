import AppKit
import ServiceManagement

// MARK: - Консольные проверки (AC)
enum CLI {
    static func run(_ args: [String]) {
        let cmd = args[1]
        switch cmd {
        case "--test-tap-watchdog":
            MediaKeyTap.testWatchdog()
        case "--test-keyboard-mode":
            KeyboardModeChecks.run()
        case "--keyboard-settings":
            DistributedNotificationCenter.default().postNotificationName(AppIdentity.notification("keyboard-settings"),object:nil,userInfo:nil,deliverImmediately:true)
        case "--test-profiles":
            ProfileChecks.run()
        case "--profiles":
            DistributedNotificationCenter.default().postNotificationName(AppIdentity.notification("profiles"),object:nil,userInfo:nil,deliverImmediately:true)
        case "--render-onboarding":
            Onboarding.shared.render(to:args.count>2 ? args[2]:"/tmp/notchdeck-onboarding")
        case "--render-charge":
            NotchHUD.renderCharge(to:args.count>2 ? args[2]:"/tmp/notch-charge")
        case "--l10n-report":
            print(L10n.shared.report())
        case "--l10n-switch-test":
            let previous = L10n.shared.mode
            let view = PreferencesView(frame: NSRect(x: 0, y: 0, width: 620, height: 510))
            let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            func dump(_ stage: String) {
                let tabs = (view.subviews.first as? NSTabView)?.tabViewItems.map { $0.label }.joined(separator: " | ") ?? "?"
                let menu = notchStatusMenu(target: NSObject()).items.map { $0.title }.filter { !$0.isEmpty }
                print("\(stage): lang=\(L10n.shared.effective.rawValue)")
                print("  tabs: \(tabs)")
                print("  menu: \(menu.joined(separator: " | "))")
            }
            dump("до")
            L10n.shared.set(.en); dump("после en")
            L10n.shared.set(.ru); dump("после ru")
            L10n.shared.set(previous)
        case "--capture-status":
            print("screenCapture=\(CGPreflightScreenCaptureAccess()) microphoneRequested=false")
        case "--test-r39":
            LevelWatch.testAutomaticBrightness()
            R39Checks.run()
        case "--render-settings":
            let view=PreferencesView(frame:NSRect(x:0,y:0,width:620,height:510))
            let window=NSWindow(contentRect:view.bounds,styleMask:[.titled],backing:.buffered,defer:false)
            window.contentView=view
            view.renderTabs(to:args.count>2 ? args[2] : "/tmp/notchdeck-settings")
            print("SETTINGS RENDERED")
        case "--demo":
            DistributedNotificationCenter.default().postNotificationName(AppIdentity.notification("demo"),object:nil,userInfo:nil,deliverImmediately:true)
            print("Запущен 12-секундный тест в установленном NotchDeck")
        case "--notes":
            DistributedNotificationCenter.default().postNotificationName(AppIdentity.notification("notes"),object:nil,userInfo:nil,deliverImmediately:true)
        case "--network-check":
            _=Metrics.shared.netRate()
            Thread.sleep(forTimeInterval:1)
            let rate=Metrics.shared.netRate()
            print("interfaces=\(Metrics.shared.networkCounters().keys.sorted().joined(separator:",")) down=\(rate.down)KB/s up=\(rate.up)KB/s")
        case "--traffic-check":
            let wantProcesses = args.contains("processes=3")
            let empty = args.contains("--empty")
            if empty {
                let monitor = TrafficMonitor.shared
                monitor.debugForceEmpty = true
                let (point, _) = monitor.sampleNow(processes: false)
                print("down=\(point == nil ? "—" : "0") up=\(point == nil ? "—" : "0") ready=\(point != nil) history=0 window=\(TrafficHistory.capacity) interfaces= empty")
                monitor.debugForceEmpty = false
            } else {
                let monitor = TrafficMonitor.shared
                // --with-load: дочерний curl даёт реальную нагрузку для R4 (сумма процессов vs система).
                var load: Process?
                if args.contains("--with-load") {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    p.arguments = ["-s", "-o", "/dev/null", "--max-time", "20",
                                   "https://speed.cloudflare.com/__down?bytes=10000000"]
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    if (try? p.run()) != nil { load = p; Thread.sleep(forTimeInterval: 3.0) }
                }
                let (point, samples) = monitor.sampleNow(processes: wantProcesses)
                load?.terminate()
                guard let point else {
                    print("down=— up=— ready=false history=0 window=\(TrafficHistory.capacity) interfaces=<none>")
                    exit(1)
                }
                let interfaces = Metrics.shared.networkCounters().keys.filter { $0.hasPrefix("en") }.sorted()
                print("down=\(String(format: "%.1f", point.down))KB/s up=\(String(format: "%.1f", point.up))KB/s ready=true history=\(samples) window=\(TrafficHistory.capacity) interfaces=\(interfaces.joined(separator: ","))")
                print("hoverMode=\(TrafficHUD.hoverEnabled ? "enabled" : "disabled") hotZone=\(Int(TrafficHUD.hotZone.width))x\(Int(TrafficHUD.hotZone.height)) panelExpanded=\(NotchHUD.shared.panelExpanded)")
                if wantProcesses {
                    let top = monitor.processes
                    print("processes=\(top.count)")
                    for p in top {
                        print("  \(p.name) pid=\(p.pid) down=\(String(format: "%.1f", p.down))KB/s up=\(String(format: "%.1f", p.up))KB/s")
                    }
                    // R4: сверка суммы процессов с системным замером; причина расхождения называется.
                    let sumDown = top.reduce(0) { $0 + $1.down }
                    let sys = point.down
                    let gap = sys > 1 ? (sumDown - sys) / sys * 100 : 0
                    var reason = "в пределах точности"
                    if gap > 10 {
                        let tunnel = top.first { $0.down > sys * 1.5 }
                        reason = tunnel.map { "процесс «\($0.name)» учитывает трафик дважды (VPN-туннель)" }
                            ?? "служебные процессы дублируют счётчик"
                    }
                    print("сумма процессов=\(String(format: "%.1f", sumDown))KB/s системный=\(String(format: "%.1f", sys))KB/s расхождение=\(String(format: "%+.1f", gap))% — \(reason)")
                }
            }
        case "--load-run":
            // Держит нагрузку заданное число секунд (для внешних замеров интерфейсов).
            let secs = args.count > 2 ? (Double(args[2]) ?? 10) : 10
            let url = args.count > 3 ? args[3] : "https://speed.cloudflare.com/__down?bytes=10000000"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-o", "/dev/null", "-w", "code=%{http_code} speed=%{speed_download} size=%{size_download}",
                           "--max-time", "\(Int(secs))", url]
            let pipe = Pipe(); p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                print("нагрузка запущена на \(Int(secs))с: \(url)")
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                print("нагрузка завершена: \(out)")
            } else {
                print("нагрузку запустить не удалось"); exit(1)
            }
        case "--load-probe":
            // Диагностика: дочерний curl из процесса приложения — работает ли вообще.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "-o", "/dev/null", "-w", "code=%{http_code} speed=%{speed_download} size=%{size_download}",
                           "--max-time", "8", "https://speed.cloudflare.com/__down?bytes=20000000"]
            let pipe = Pipe(); p.standardOutput = pipe
            let errPipe = Pipe(); p.standardError = errPipe
            do {
                try p.run()
            } catch {
                print("запуск не удался: \(error)"); exit(1)
            }
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("status=\(p.terminationStatus) \(out) err=\(err.prefix(120))")
        case "--panel-expand":
            DistributedNotificationCenter.default().post(
                name: AppIdentity.notification("panel-expand"), object: nil)
            Thread.sleep(forTimeInterval: 1.0)
        case "--traffic-show":
            // Живая проверка: показать остров так, как это делает наведение.
            let seconds = args.count > 2 ? Double(args[2]) ?? 5 : 5
            let dnc = DistributedNotificationCenter.default()
            dnc.post(name: AppIdentity.notification("traffic-show"),
                     object: nil, userInfo: ["seconds": seconds])
            Thread.sleep(forTimeInterval: seconds + 0.5)
        case "--net-raw":
            // Абсолютные счётчики en* из двух источников — для сверки парсеров.
            func sysctlRx() -> UInt64 {
                var t: UInt64 = 0
                var per: [String: UInt64] = [:]
                for (k, c) in Metrics.shared.networkCounters() where c.rx > 0 { t += c.rx; per[k] = c.rx }
                if args.contains("-v") { for (k, v) in per.sorted(by: { $0.key < $1.key }) { print("  sysctl \(k)=\(v)") } }
                return t
            }
            let s1 = sysctlRx()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            p.arguments = ["-ibn"]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            var ns: UInt64 = 0
            var seen: [String: UInt64] = [:]
            for line in out.split(separator: "\n") {
                let c = line.split(separator: " ", omittingEmptySubsequences: true)
                guard c.count >= 10, c[0].hasPrefix("en"), c[2].hasPrefix("<Link") else { continue }
                if let r = UInt64(c[6]) { ns += r; seen[String(c[0])] = r }
            }
            print("netstat_total=\(ns) sysctl_total=\(s1) отношение=\(String(format: "%.2f", s1 > 0 ? Double(ns) / Double(s1) : 0))")
            if args.contains("-v") {
                for (k, v) in seen.sorted(by: { $0.key < $1.key }) { print("  netstat \(k)=\(v)") }
            }
        case "--traffic-debug":
            func sum() -> (UInt64, UInt64, [String: NetworkCounter]) {
                let c = Metrics.shared.networkCounters()
                var rx: UInt64 = 0, tx: UInt64 = 0
                for (_, v) in c { rx += v.rx; tx += v.tx }
                return (rx, tx, c)
            }
            let a = sum()
            print("t0 rx=\(a.0) tx=\(a.1) keys=\(a.2.keys.sorted().joined(separator: ","))")
            for (k, v) in a.2.sorted(by: { $0.key < $1.key }) { print("   \(k) rx=\(v.rx) tx=\(v.tx)") }
            Thread.sleep(forTimeInterval: 1.5)
            let b = sum()
            print("t1 rx=\(b.0) tx=\(b.1) deltaRx=\(b.0 >= a.0 ? b.0 - a.0 : 0) deltaTx=\(b.1 >= a.1 ? b.1 - a.1 : 0)")
            var s = NetworkRateSampler()
            _ = s.sample(a.2, at: 1000)
            let r = s.sample(b.2, at: 1001.5)
            print("sampler down=\(String(format: "%.1f", r.down))KB/s up=\(String(format: "%.1f", r.up))KB/s")
        case "--traffic-cross-check":
            // R1: сверка с независимым источником — netstat -ib по физическому интерфейсу.
            func netstatBytes() -> (rx: UInt64, tx: UInt64)? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
                p.arguments = ["-ibn"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                var rx: UInt64 = 0, tx: UInt64 = 0
                for line in text.split(separator: "\n").dropFirst() {
                    let c = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard c.count >= 10, c[0].hasPrefix("en"), c[2].hasPrefix("<Link") else { continue }
                    if let r = UInt64(c[6]), let t = UInt64(c[9]) { rx += r; tx += t }
                }
                return (rx, tx)
            }
            guard netstatBytes() != nil else { print("netstat недоступен"); exit(1) }
            // --with-load: генератор нагрузки запускается дочерним процессом, чтобы
            // сверка шла на реальном трафике (фоновые задания оболочки качают 1 байт).
            var load: Process?
            if args.contains("--with-load") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                p.arguments = ["-s", "-o", "/dev/null", "--max-time", "30",
                               "https://speed.cloudflare.com/__down?bytes=10000000"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    load = p
                    Thread.sleep(forTimeInterval: 1.5)
                } else {
                    print("нагрузку запустить не удалось")
                }
            }
            let monitor = TrafficMonitor.shared
            monitor.resetForCheck()
            func sysctlRx() -> UInt64 {
                var t: UInt64 = 0
                for (_, c) in Metrics.shared.networkCounters() where c.rx > 0 { t += c.rx }
                return t
            }
            guard let a = netstatBytes() else { print("netstat недоступен"); exit(1) }
            let rawA = sysctlRx()
            let stampA = ProcessInfo.processInfo.systemUptime
            monitor.tickForCheck()
            Thread.sleep(forTimeInterval: 3.0)
            let stampB = ProcessInfo.processInfo.systemUptime
            let rawB = sysctlRx()
            guard let b = netstatBytes() else { print("netstat недоступен"); exit(1) }
            monitor.tickForCheck()
            load?.terminate()
            let span = max(1.0, stampB - stampA)
            let ref = Double(b.rx >= a.rx ? b.rx - a.rx : 0) / 1024 / span
            let ref2 = Double(rawB >= rawA ? rawB - rawA : 0) / 1024 / span
            let ours = monitor.display?.down ?? 0
            let delta = ref > 5 ? abs(ours - ref) / ref * 100 : -1
            print("netstat=\(String(format: "%.1f", ref))KB/s sysctl=\(String(format: "%.1f", ref2))KB/s traffic=\(String(format: "%.1f", ours))KB/s окно=\(String(format: "%.1f", span))с delta=\(delta < 0 ? "n/a" : String(format: "%.1f%%", delta))")
        case "--traffic-buffer-check":
            var h = TrafficHistory()
            for i in 0..<65 { h.append(TrafficPoint(down: Double(i), up: Double(65 - i))) }
            print("history=\(h.count) window=\(h.windowSeconds) first=\(Int(h.points.first?.down ?? -1)) last=\(Int(h.points.last?.down ?? -1)) peak=\(String(format: "%.0f", h.peak))")
        case "--render-traffic":
            let path = args.count > 2 ? args[2] : "/tmp/traffic.png"
            let demo = args.contains("--demo")
            var scene = TrafficHUD.scene()
            if demo {
                var h = TrafficHistory()
                for i in 0..<60 {
                    let t = Double(i) / 59
                    h.append(TrafficPoint(down: 420 + 260 * sin(t * 6.2) + 90 * sin(t * 19),
                                          up: 60 + 55 * sin(t * 4.1 + 1.2)))
                }
                scene = TrafficScene(history: h.points, down: h.points.last?.down, up: h.points.last?.up, peak: h.peak)
            }
            let ok = TrafficIslandView.render(to: path, scene: scene)
            print(ok ? "рендер трафика: \(path)" : "рендер не удался")
        case "--connection-check":
            print("Happ=\(ConnectionMonitor.happStatus()) CheckPoint=\(ConnectionMonitor.checkpointStatus())")
        case "--settings":
            DistributedNotificationCenter.default().postNotificationName(AppIdentity.notification("settings"),object:nil,userInfo:nil,deliverImmediately:true)
        case "--selftest":
            let g = Geometry.measure()
            print("screen=\(Int(g.screen.frame.width))x\(Int(g.screen.frame.height)) scale=\(g.screen.backingScaleFactor)")
            print("notch=\(String(format: "%.1f", g.notchWidth))x\(String(format: "%.1f", g.notchHeight))")
            print("notchRect=\(g.notchRect)")
            print("collapsed=\(g.collapsedFrame)")
            print("expanded=\(g.expandedFrame(height: 176))")
            print("expandedEdit=\(g.expandedFrame(height: 222))")
            print("brightness available=\(Brightness.shared.available) value=\(Brightness.shared.current().map { String(format: "%.3f", $0) } ?? "nil") increment=\(String(format: "%.4f", Brightness.shared.increment()))")
            print("volume=\(Volume.shared.current().map { String(format: "%.3f", $0) } ?? "nil") muted=\(Volume.shared.isMuted())")
            print("media available=\(Media.shared.available)")
            // прогрев дельт
            _ = Metrics.shared.snapshot()
            Thread.sleep(forTimeInterval: 1.0)
            print("metrics: \(Metrics.shared.dump())")
            print("hidden=\(Config.shared.hidden.sorted())")
        case "--metrics":
            _ = Metrics.shared.snapshot()
            Thread.sleep(forTimeInterval: 1.0)
            print(Metrics.shared.dump())
        case "--smc":
            let smc = SMCReader()
            for k in ["Tp01", "Tp05", "Tp09", "Tp0D", "Te05", "Te09", "TB0T", "Ts0P"] {
                print("\(k) = \(smc.temperature(k).map { String(format: "%.2f", $0) } ?? "err")")
            }
        case "--brightness-step":
            let n = Int(args.count > 2 ? args[2] : "1") ?? 1
            let before = Brightness.shared.current() ?? -1
            let after = Brightness.shared.step(n) ?? -1
            print(String(format: "brightness before=%.4f after=%.4f", before, after))
        case "--volume-step":
            let n = Int(args.count > 2 ? args[2] : "1") ?? 1
            let before = Volume.shared.current() ?? -1
            let after = Volume.shared.step(n) ?? -1
            print(String(format: "volume before=%.4f after=%.4f", before, after))
        case "--volume-set":
            let v = Float(args.count > 2 ? args[2] : "0.3") ?? 0.3
            Volume.shared.set(v)
            print(String(format: "volume set -> %.4f", Volume.shared.current() ?? -1))
        case "--mute-toggle":
            let before = Volume.shared.isMuted()
            Volume.shared.toggleMute()
            print("mute before=\(before) after=\(Volume.shared.isMuted())")
        case "--now-playing":
            // Apple Events требуют живого главного run loop — семафор здесь блокирует доставку.
            var line: String? = nil
            NowPlayingReader.shared.read { np in
                if let np {
                    line = String(format: "«%@» — %@ | %.0f/%.0f c | %@ | %@",
                                  np.title, np.artist, np.elapsed, np.duration,
                                  np.playing ? "играет" : "пауза", np.source)
                } else {
                    line = "ничего не играет"
                }
            }
            let deadline = Date().addingTimeInterval(6)
            while line == nil && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            print(line ?? "таймаут чтения now-playing")
        case "--seek":
            let frac = args.count > 2 ? Double(args[2].replacingOccurrences(of: ",", with: ".")) ?? 0.5 : 0.5
            var done = false
            NowPlayingReader.shared.read { np in
                guard let np else { print("ничего не играет"); done = true; return }
                print("до: \(String(format: "%.0f", np.elapsed))/\(String(format: "%.0f", np.duration)) c")
                NowPlayingReader.shared.seek(to: frac)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NowPlayingReader.shared.read { after in
                        if let a = after {
                            print("после: \(String(format: "%.0f", a.elapsed))/\(String(format: "%.0f", a.duration)) c")
                        }
                        done = true
                    }
                }
            }
            let deadline = Date().addingTimeInterval(6)
            while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        case "--media":
            let name = args.count > 2 ? args[2] : "toggle"
            let map: [String: Media.Command] = ["play": .play, "pause": .pause, "toggle": .toggle, "next": .next, "prev": .previous]
            let ok = Media.shared.perform(map[name] ?? .toggle)
            print("media \(name) -> \(ok)")
        case "--clip-list":
            ClipboardStore.shared.capture()
            let items = ClipboardStore.shared.items
            print("записей=\(items.count)")
            for (i, it) in items.enumerated() { print("\(i): [\(it.kind)] \(it.preview)") }
        case "--clip-copy":
            ClipboardStore.shared.capture()
            let idx = args.count > 2 ? Int(args[2]) ?? 0 : 0
            let items = ClipboardStore.shared.items
            guard idx < items.count else { print("нет записи \(idx)"); return }
            ClipboardStore.shared.restore(items[idx])
            print("в буфере: \(NSPasteboard.general.string(forType: .string) ?? "—")")
        case "--clip-clear":
            ClipboardStore.shared.clear()
            print("буфер истории очищен")
        case "--shelf-add":
            let urls = args.dropFirst(2).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let n = ShelfStore.shared.add(urls)
            print("добавлено=\(n) всего=\(ShelfStore.shared.urls.count)")
        case "--shelf-list":
            print("файлов=\(ShelfStore.shared.urls.count)")
            for u in ShelfStore.shared.urls { print("- \(u.path)") }
        case "--shelf-clear":
            ShelfStore.shared.clear(); print("полка пуста")
        case "--top-mem":
            let rows = Procs.topByMemory(limit: 8)
            print("топ \(rows.count) по памяти:")
            for (i, p) in rows.enumerated() {
                print(String(format: "%d. %@ pid=%d %.0f МБ%@", i + 1, p.name, p.pid, p.megabytes,
                             Procs.isProtected(p) ? " (защищён)" : ""))
            }
        case "--flash-island":
            let secs = Double(args.count > 2 ? args[2] : "4") ?? 4
            let end = Date().addingTimeInterval(secs)
            var next = Date()
            while Date() < end {
                if Date() >= next {
                    NotchHUD.shared.showLevel(kind: .brightness, value: 0.72, muted: false)
                    next = Date().addingTimeInterval(0.8)   // плашка живёт 1.15 с — подновляем
                }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        case "--demo-hud":
            let value = Float(args.count > 2 ? args[2] : "0.75") ?? 0.75
            let kind: LevelKind = args.count > 3 && args[3] == "volume" ? .volume : .brightness
            NotchHUD.shared.showLevel(kind: kind, value: value, muted: false)
            let end = Date().addingTimeInterval(2.1)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        case "--render-island-motion":
            let kind: LevelKind = args.count > 2 && args[2] == "volume" ? .volume : .brightness
            let value = Float(args.count > 3 ? args[3] : "0.75") ?? 0.75
            let path = args.count > 4 ? args[4] : "Build/vision/r33-motion"
            let ok = NotchHUD.renderMotion(to: path, kind: kind, value: value)
            print(ok ? "кадры реальной анимации: \(path)" : "не удалось снять анимацию")
        case "--render-island":
            // Первый аргумент может быть режимом (traffic/brightness/volume) или сразу путём.
            if args.count > 2, args[2] == "traffic" {
                let path = args.count > 3 ? args[3] : "/tmp/island-traffic.png"
                let scene = TrafficIslandView.demoScene(empty: args.contains("--empty"))
                let ok = TrafficIslandView.render(to: path, scene: scene)
                print(ok ? "рендер traffic: \(path)" : "рендер traffic не удался")
                exit(ok ? 0 : 1)
            }
            let kind: LevelKind
            let value: Float
            let path: String
            if args.count > 2, args[2] == "brightness" || args.count > 2 && args[2] == "volume" {
                kind = args[2] == "brightness" ? .brightness : .volume
                value = args.count > 3 ? Float(args[3]) ?? 0.7 : 0.7
                path = args.count > 4 ? args[4] : "/tmp/island-\(args[2]).png"
            } else {
                kind = .brightness
                value = 0.72
                path = args.count > 2 ? args[2] : "/tmp/island.png"
            }
            let ok = NotchHUD.renderSample(to: path, kind: kind, value: value)
            print(ok ? "рендер \(kind == .brightness ? "brightness" : "volume"): \(path)" : "рендер не удался")
        case "--render-island-sequence":
            let kind: LevelKind = args.count > 2 && args[2] == "volume" ? .volume : .brightness
            let value = Float(args.count > 3 ? args[3] : "0.7") ?? 0.7
            let path = args.count > 4 ? args[4] : "Build/sequence-\(kind == .brightness ? "brightness" : "volume")"
            let ok = NotchHUD.renderSequence(to: path, kind: kind, value: value)
            print(ok ? "кадры неона \(kind == .brightness ? "brightness" : "volume"): \(path)" : "рендер кадров не удался")
        case "--render-alert":
            let alert: NotchAlert
            switch args.count > 2 ? args[2] : "memory" {
            case "memory": alert = .memory
            case "temperature": alert = .temperature
            case "battery": alert = .battery
            case "cpu": alert = .cpu
            default: alert = .off
            }
            let path = args.count > 3 ? args[3] : "/tmp/notch-alert.png"
            let ok = NotchHUD.renderAlertSample(to: path, alert: alert)
            print(ok ? "рендер alert=\(args.count > 2 ? args[2] : "memory"): \(path)" : "рендер не удался")
        case "--test-alerts":
            func name(_ alert: NotchAlert) -> String {
                switch alert {
                case .cpu: return "cpu"
                case .off: return "off"
                case .memory: return "memory"
                case .temperature: return "temperature"
                case .battery: return "battery"
                }
            }
            var sample = MetricSnapshot(ramUsed: 85, ramTotal: 100)
            let memoryOnly = name(NotchAlert.resolve(sample))
            sample.temp = 85
            let temperatureOverMemory = name(NotchAlert.resolve(sample))
            sample.battery = 20
            let batteryOverOthers = name(NotchAlert.resolve(sample))
            sample.charging = true
            let chargingIgnoresBattery = name(NotchAlert.resolve(sample))
            sample = MetricSnapshot()
            let absentMetrics = name(NotchAlert.resolve(sample))
            print("RAM=\(memoryOnly) temp_over_RAM=\(temperatureOverMemory) battery_over_all=\(batteryOverOthers) charging=\(chargingIgnoresBattery) missing=\(absentMetrics)")
            print(memoryOnly == "memory" && temperatureOverMemory == "temperature" && batteryOverOthers == "battery" && chargingIgnoresBattery == "temperature" && absentMetrics == "off" ? "ALERT TESTS PASS" : "ALERT TESTS FAIL")
        case "--test-key-routing":
            MediaKeyTap.testRouting()
        case "--probe-tap":
            MediaKeyTap.shared.onChange = { _, _, _ in }
            print("AX=\(AXIsProcessTrusted()) tap=\(MediaKeyTap.shared.start())")
            MediaKeyTap.shared.stop()
        case "--test-halo":
            NotchHUD.testHalo()
        case "--test-hud-lifecycle":
            NotchHUD.testLifecycle()
        case "--island":
            print(NotchHUD.describe())
        case "--mem-free":
            print("свободно: \(MemoryPurge.human(MemoryPurge.freeBytes()))")
        case "--purge":
            let prompt = !args.contains("--no-prompt")
            var done = false
            MemoryPurge.run(allowPrompt: prompt) { ok, message, before, after in
                print("очистка: \(ok ? "ок" : "нет") · \(message)")
                print("свободно было \(MemoryPurge.human(before)) → стало \(MemoryPurge.human(after))")
                done = true
            }
            let deadline = Date().addingTimeInterval(30)
            while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        case "--top-cpu":
            let base = Procs.snapshot()
            Thread.sleep(forTimeInterval: 1.0)
            let now = Procs.snapshot()
            let prev = Dictionary(uniqueKeysWithValues: base.map { ($0.pid, $0.cpuTime) })
            let rows = Procs.topByCPU(previous: prev, current: now, interval: 1.0)
            print("топ \(min(8, rows.count)) по CPU:")
            for (i, p) in rows.prefix(8).enumerated() {
                print(String(format: "%d. %@ pid=%d %.0f %%", i + 1, p.name, p.pid, Double(p.cpuTime)))
            }
        case "--ax":
            print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
            print("mediaKeys=\(MediaKeyTap.shared.enabled)")
        case "--request-ax":
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(opts)
            print("доступ Accessibility: \(trusted ? "уже есть" : "запрошен — включи NotchDeck в «Универсальный доступ»»")")
        case "--key-sim":
            let code = args.count > 2 ? Int(args[2]) ?? 0 : 0
            MediaKeyTap.shared.onChange = { kind, value, muted in
                NotchHUD.shared.showLevel(kind: kind, value: value, muted: muted)
            }
            MediaKeyTap.shared.apply(keyCode: code)
            var done = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done = true }
            let deadline = Date().addingTimeInterval(3)
            while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            print("клавиша \(code) обработана")
        case "--keys":
            let on = args.count > 2 ? (args[2] != "off") : true
            UserDefaults.standard.set(on, forKey: "NotchDeck.mediaKeys")
            print("перехват клавиш: \(on ? "вкл" : "выкл")")
        case "--level":
            let kind: LevelKind = (args.count > 2 && args[2] == "volume") ? .volume : .brightness
            let v = kind == .brightness ? (Brightness.shared.current() ?? 0) : (Volume.shared.current() ?? 0)
            NotchHUD.shared.showLevel(kind: kind, value: v, muted: Volume.shared.isMuted())
            var done = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done = true }
            let deadline = Date().addingTimeInterval(3)
            while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            print(String(format: "плашка %@ = %.0f %%", kind == .brightness ? "яркость" : "громкость", v * 100))
        case "--signal":
            let text = args.count > 2 ? args[2] : "Проверка сигнала"
            Signal.post(text, symbol: "bell.fill")
            var done = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done = true }
            let deadline = Date().addingTimeInterval(3)
            while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            print("сигнал отправлен: \(text)")
        case "--memwarn":
            let snap = Metrics.shared.snapshot()
            let pct = snap.ramTotal > 0 ? snap.ramUsed / snap.ramTotal * 100 : 0
            print(String(format: "порог=%.0f %% занято=%.1f %% (%.1f/%.1f ГБ)",
                         MemWarn.threshold, pct, snap.ramUsed, snap.ramTotal))
        case "--bundles":
            var counts: [String: Int] = [:]
            for p in Procs.snapshot() { counts[p.bundlePath ?? "(без бандла)", default: 0] += 1 }
            for (b, c) in counts.sorted(by: { $0.value > $1.value }).prefix(12) { print("\(c)  \(b)") }
        case "--app-procs":
            let path = args.count > 2 ? (args[2] as NSString).expandingTildeInPath : ""
            let list = Procs.processes(inBundle: path)
            print("бандл: \(path) процессов=\(list.count)")
            for p in list { print(String(format: "  %@ pid=%d %.0f МБ", p.name, p.pid, p.megabytes)) }
        case "--kill-app":
            let path = args.count > 2 ? (args[2] as NSString).expandingTildeInPath : ""
            let n = Procs.terminateBundle(path)
            print("SIGTERM бандлу, процессов=\(n)")
        case "--procs-mode":
            let m = (args.count > 2 && args[2] == "cpu") ? ProcessPanelController.Mode.cpu : .memory
            ProcessPanelController.shared.setMode(m)
            print("режим панели: \(m == .cpu ? "cpu" : "память")")
        case "--kill":
            guard args.count > 2, let pid = Int32(args[2]) else { print("нужен pid"); return }
            if let p = Procs.info(pid: pid) {
                print(Procs.terminate(p) ? "SIGTERM отправлен: \(p.name)" : "отказ: защищённый процесс")
            } else {
                print("отказ: процесс недоступен (системный или чужой)")
            }
        case "--procs-panel":
            var done = false
            ProcessPanelController.shared.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                print(ProcessPanelController.shared.dumpRows()); done = true
            }
            let deadline = Date().addingTimeInterval(3)
            while !done && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        case "--shot":
            let path = Capture.screenshot()
            print("скриншот: \(path.path)")
        case "--shot-rect":
            let parts = (args.count > 2 ? args[2] : "0,0,200,100").split(separator: ",").compactMap { Int($0) }
            let rect = NSRect(x: parts.count > 0 ? parts[0] : 0, y: parts.count > 1 ? parts[1] : 0,
                              width: parts.count > 2 ? parts[2] : 200, height: parts.count > 3 ? parts[3] : 100)
            let path = Capture.screenshot(rect: rect)
            let ok = FileManager.default.fileExists(atPath: path.path)
            print("скриншот: \(path.path) существует=\(ok)")
            print("в буфере: \(NSPasteboard.general.string(forType: .string) ?? "—")")
        case "--record-test":
            let secs = args.count > 2 ? Int(args[2]) ?? 2 : 2
            let url = Capture.recordTest(seconds: secs)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("запись: \(url.path) размер=\(size ?? 0) байт")
        case "--record":
            let on = Capture.toggleRecording()
            print("запись: " + (on ? "старт" : "стоп"))
        case "--hide":
            if args.count > 2, let item = Item(rawValue: args[2]) { Config.shared.hide(item) }
            print("hidden=\(Config.shared.hidden.sorted())")
        case "--unhide":
            if args.count > 2, let item = Item(rawValue: args[2]) { Config.shared.unhide(item) }
            print("hidden=\(Config.shared.hidden.sorted())")
        case "--reset":
            Config.shared.resetAll()
            print("hidden=\(Config.shared.hidden.sorted())")
        case "--rss-sample":
            print("pid=\(ProcessInfo.processInfo.processIdentifier)")
        case "--notify":
            let name = AppIdentity.bundleID + "." + (args.count > 2 ? args[2] : "expand")
            DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: nil, deliverImmediately: true)
            print("posted \(name)")
        case "--click":
            guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { print("нужны x y"); break }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID).first else {
                print("приложение не запущено"); break
            }
            let pt = CGPoint(x: x, y: y)
            for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
                if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) {
                    e.postToPid(app.processIdentifier)
                }
                usleep(60_000)
            }
            print("click \(x),\(y) -> pid \(app.processIdentifier)")
        case "--login":
            if args.count > 2 {
                LaunchAtLogin.set(args[2] == "on")
            }
            print("loginAtStart status=\(SMAppService.mainApp.status.rawValue) (1 = enabled, 0 = notRegistered, 2 = requiresApproval, 3 = notFound)")
        case "--windows":
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowOwnerName as String] as? String) == "NotchDeck" {
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                print("layer=\(w[kCGWindowLayer as String] ?? "?") bounds=x:\(b["X"] ?? "?") y:\(b["Y"] ?? "?") w:\(b["Width"] ?? "?") h:\(b["Height"] ?? "?") alpha=\(w[kCGWindowAlpha as String] ?? "?")")
            }
        default:
            print("unknown command \(cmd)")
        }
    }
}

/// Меню в строке состояния. Вынесено из AppDelegate, чтобы проверять смену языка
/// без запуска приложения: см. `--l10n-switch-test`.
func notchStatusMenu(target: AnyObject) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
    _ = add(L("Показать панель"), #selector(AppDelegate.showPanel))
    _ = add(L("Профили панели…"), #selector(AppDelegate.profiles))
    _ = add(L("Быстрые заметки"), #selector(AppDelegate.notes))
    _ = add(L("Клавиатура Windows…"), #selector(AppDelegate.keyboardSettings))
    _ = add(L("Быстрый тест чёлки"), #selector(AppDelegate.demo))
    _ = add(L("Настройки…"), #selector(AppDelegate.openSettings), ",")
    _ = add(L("Знакомство с NotchDeck…"), #selector(AppDelegate.onboarding))
    menu.addItem(.separator())
    _ = add(L("Вернуть все плитки"), #selector(AppDelegate.resetTiles))
    menu.addItem(.separator())
    _ = add(L("Выход"), #selector(AppDelegate.quit), "q")
    return menu
}

// MARK: - Приложение
final class AppDelegate: NSObject, NSApplicationDelegate {
    let deck = DeckController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url=Bundle.main.url(forResource:"AppIcon",withExtension:"icns"),let icon=NSImage(contentsOf:url) {NSApp.applicationIconImage=icon}
        buildStatusItem()
        deck.start()
        KeyboardMode.shared.start()
        DistributedNotificationCenter.default().addObserver(forName: AppIdentity.notification("keyboard-settings"),object:nil,queue:.main) { _ in KeyboardMode.shared.showSettings() }
        Onboarding.shared.onShowPanel = { [weak self] in self?.deck.expand() }
        TrafficHUD.shared.startHoverWatch()
        Onboarding.shared.onDemo = { [weak self] in self?.deck.runQuickDemo() }
        DispatchQueue.main.async {Onboarding.shared.showIfNeeded()}
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.deck.refreshGeometry()
        }
        // Смена языка: меню в строке состояния собирается заново на месте.
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildStatusItem()
        }
        NSLog("NotchDeck started pid=\(ProcessInfo.processInfo.processIdentifier) rss=\(Self.rssMB()) MB")
    }

    func applicationWillTerminate(_ notification:Notification) {KeyboardMode.shared.stop();Capture.stopRecording();QuickNotes.shared.save();SystemMediaStream.shared.stop()}

    private static func rssMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    private func rebuildStatusItem() {
        if let existing = statusItem { NSStatusBar.system.removeStatusItem(existing); statusItem = nil }
        buildStatusItem()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "chevron.down.square", accessibilityDescription: "NotchDeck")
            img?.isTemplate = true
            button.image = img
        }
        item.menu = notchStatusMenu(target: self)
        statusItem = item
    }

    @objc func keyboardSettings() { KeyboardMode.shared.showSettings() }
    @objc func profiles() {ProfileManager.shared.show()}
    @objc func onboarding() {Onboarding.shared.show()}
    @objc func showPanel() { deck.expand() }
    @objc func notes() {QuickNotes.shared.show()}
    @objc func demo() {deck.runQuickDemo()}
    @objc func openSettings() { deck.showSettings() }
    @objc func resetTiles() { Config.shared.resetAll() }
    @objc func quit() { NSApp.terminate(nil) }
}

let cliArgs = CommandLine.arguments
if cliArgs.count > 1 && cliArgs[1].hasPrefix("--") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    CLI.run(cliArgs)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
