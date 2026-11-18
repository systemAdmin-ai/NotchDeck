import AppKit

// MARK: - Анализатор трафика (спека specs/2026-11-18-анализатор-трафика.md)
//
// R2: кольцевой буфер на 60 секунд, только в памяти.
// R7: недоступные счётчики дают «—», а не 0.
// R8: физический трафик en*, без двойного счёта через utun.

struct TrafficPoint: Equatable {
    var down: Double = 0   // КБ/с
    var up: Double = 0     // КБ/с
}

struct TrafficProcess: Equatable {
    var name: String
    var pid: Int
    var down: Double       // КБ/с
    var up: Double         // КБ/с
    var total: Double { down + up }
}

/// Кольцевая история на 60 значений (R2).
struct TrafficHistory {
    static let capacity = 60
    private(set) var points: [TrafficPoint] = []

    mutating func append(_ p: TrafficPoint) {
        points.append(p)
        if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }
    }

    var isEmpty: Bool { points.isEmpty }
    var count: Int { points.count }
    var windowSeconds: Int { Self.capacity }

    /// Нормировка графика: максимум по обеим сериям, не меньше 1 КБ/с.
    var peak: Double {
        max(1, points.reduce(0) { max($0, max($1.down, $1.up)) })
    }

    mutating func reset() { points.removeAll() }
}

/// Снимок кумулятивных байт по процессам через `nettop` (без root).
struct ProcessTrafficReader {
    private var baseline: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var stamp: TimeInterval = 0

    /// Один быстрый снимок nettop (~15 мс). Возвращает nil, если утилита недоступна.
    static func snapshot() -> [String: (rx: UInt64, tx: UInt64)]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-x", "-n", "-s", "1", "-L", "1", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var rows: [String: (rx: UInt64, tx: UInt64)] = [:]
        // Формат: имя.pid,bytes_in,bytes_out, первая строка — заголовок.
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3,
                  let rx = UInt64(cols[1]), let tx = UInt64(cols[2]) else { continue }
            let key = String(cols[0])
            guard !key.isEmpty else { continue }
            rows[key] = (rx, tx)
        }
        return rows.isEmpty ? nil : rows
    }

    /// Разница двух снимков → КБ/с по процессам, топ-3 (R4).
    mutating func top(limit: Int = 3, at time: TimeInterval,
                      systemDown: Double = .infinity, systemUp: Double = .infinity) -> [TrafficProcess] {
        guard let current = Self.snapshot() else { return [] }
        defer { baseline = current; stamp = time }
        guard !baseline.isEmpty, time > stamp else { return [] }
        let delta = time - stamp
        guard delta >= 0.5 else { return [] }
        var result: [TrafficProcess] = []
        for (key, now) in current {
            guard let old = baseline[key], now.rx >= old.rx, now.tx >= old.tx else { continue }
            let down = Double(now.rx - old.rx) / 1024 / delta
            let up = Double(now.tx - old.tx) / 1024 / delta
            guard down + up > 0.01 else { continue }
            // R4: процесс, который «прокачал» больше системного итога, — агрегатор туннеля
            // (VPN считает трафик дважды). Не показываем его как отдельного потребителя.
            if down > systemDown * 1.5 || up > systemUp * 1.5 + 1 { continue }
            let parts = key.split(separator: ".")
            let pid = Int(parts.last ?? "") ?? 0
            var name = parts.dropLast().joined(separator: ".")
            if name.isEmpty { name = key }
            if name.count > 18 { name = String(name.prefix(17)) + "…" }
            result.append(TrafficProcess(name: name, pid: pid, down: down, up: up))
        }
        return Array(result.sorted { $0.total > $1.total }.prefix(limit))
    }
}
