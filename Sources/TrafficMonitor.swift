import AppKit

// R1/R2/R6: опрос 1 Гц только при активном наблюдении, история 60 точек.
final class TrafficMonitor {
    static let shared = TrafficMonitor()

    private(set) var history = TrafficHistory()
    private(set) var processes: [TrafficProcess] = []
    private(set) var ready = false
    private var timer: Timer?
    private var sampler = NetworkRateSampler()
    private var processReader = ProcessTrafficReader()
    /// Последние измеренные значения; nil означает «неизвестно», а не ноль (R7).
    private(set) var current: TrafficPoint?
    private var primed = false

    var isRunning: Bool { timer != nil }

    /// Наблюдение включается только на время показа острова (R6).
    func start() {
        guard timer == nil else { return }
        sampler = NetworkRateSampler()
        primed = false
        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Dbg.log("traffic: наблюдение включено")
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        history.reset()
        processes = []
        current = nil
        ready = false
        primed = false
        sampler = NetworkRateSampler()
        processReader = ProcessTrafficReader()
        Dbg.log("traffic: наблюдение остановлено")
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // R8: только физические интерфейсы, без utun/lo0.
        let counters = debugForceEmpty ? [:] : Metrics.shared.networkCounters().filter { $0.key.hasPrefix("en") }
        guard !counters.isEmpty else {
            ready = false
            current = nil
            return
        }
        let rate = sampler.sample(counters, at: now)
        ready = true
        let point = TrafficPoint(down: rate.down, up: rate.up)
        current = point
        // Первый опрос — базлайн сэмплера, в историю он не идёт.
        if primed { history.append(point) } else { primed = true }
        // R4: топ процессов только когда виден остров или открыта панель — в покое nettop не запускается.
        let wantProcesses = TrafficHUD.shared.isShowing || NotchHUD.shared.panelExpanded
        if wantProcesses {
            processes = processReader.top(limit: 3, at: now, systemDown: rate.down, systemUp: rate.up)
        } else if !processes.isEmpty {
            processes = []
        }
        // R3: пока остров виден, график обновляется вместе с опросом.
        TrafficHUD.shared.refresh()
    }

    /// Переключается панелью: пока панель закрыта, nettop не запускается.
    static var collectProcesses = false
    /// Только для проверки R7: имитирует отсутствие счётчиков.
    var debugForceEmpty = false

    /// Значения для проверки и отрисовки: nil, если счётчики недоступны (R7).
    var display: (down: Double, up: Double)? {
        guard ready, let current else { return nil }
        return (current.down, current.up)
    }

    /// Сброс для CLI-сверки: сэмплер и история очищаются, таймер не запускается.
    func resetForCheck() {
        sampler = NetworkRateSampler()
        primed = false
        history.reset()
    }

    /// Один опрос вне таймера (для сверки с независимым источником).
    func tickForCheck() { tick() }

    /// Синхронный замер для CLI-проверки: два опроса с шагом ~1 с, без таймера.
    /// Возвращает точку и число точек истории, набранных за замер.
    func sampleNow(processes: Bool) -> (point: TrafficPoint?, history: Int) {
        sampler = NetworkRateSampler()
        primed = false
        history.reset()
        tick()
        // R4: базовый снимок nettop до паузы, затем дельта после неё.
        _ = processReader.top(limit: 3, at: ProcessInfo.processInfo.systemUptime)
        Thread.sleep(forTimeInterval: 1.1)
        tick()
        let point = current
        let samples = history.count
        if processes {
            self.processes = processReader.top(limit: 3, at: ProcessInfo.processInfo.systemUptime,
                                               systemDown: point?.down ?? .infinity,
                                               systemUp: point?.up ?? .infinity)
        }
        sampler = NetworkRateSampler()
        primed = false
        return (point, samples)
    }
}
