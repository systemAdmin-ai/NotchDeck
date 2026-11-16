import AppKit
import Darwin

// MARK: - Очистка кэша памяти
//
// Штатного способа «освободить кэш» без прав администратора в macOS нет: `purge` требует root,
// поэтому сначала пробуем без него (на некоторых сборках проходит), а если система отказала —
// показываем системный запрос прав через osascript. Пароль вводится в системном диалоге,
// приложение его не видит и не хранит.

enum MemoryPurge {
    static let purgePath = "/usr/sbin/purge"

    static func available() -> Bool {
        FileManager.default.isExecutableFile(atPath: purgePath)
    }

    /// Свободная память по host_statistics64 (free_count), в байтах.
    static func freeBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(stats.free_count) * UInt64(vm_kernel_page_size)
    }

    static func human(_ bytes: UInt64) -> String {
        String(format: L("%.2f ГБ"), Double(bytes) / 1_073_741_824)
    }

    /// - Parameter allowPrompt: если true и без прав не вышло — показать системный запрос прав.
    static func run(allowPrompt: Bool,
                    completion: @escaping (Bool, String, UInt64, UInt64) -> Void) {
        guard available() else {
            completion(false, L("утилита purge не найдена"), 0, 0)
            return
        }
        let before = freeBytes()
        DispatchQueue.global(qos: .userInitiated).async {
            let direct = runProcess("/usr/sbin/purge", ["-l"], javaScriptAllowed: false)
            var ok = direct.status == 0 && !direct.err.lowercased().contains("not permitted")
            var message = ok ? L("Кэш очищен") : ""

            if !ok && allowPrompt {
                let script = "do shell script \"/usr/sbin/purge\" with administrator privileges"
                let admin = runProcess("/usr/bin/osascript", ["-e", script], javaScriptAllowed: true)
                if admin.status == 0 {
                    ok = true
                    message = L("Кэш очищен")
                } else if admin.err.contains("-128") || admin.err.lowercased().contains("cancel") {
                    message = L("Отменено")
                } else {
                    message = L("Не удалось: нужны права администратора")
                }
            } else if !ok {
                message = L("Нужны права администратора")
            }

            let after = freeBytes()
            DispatchQueue.main.async {
                completion(ok, message, before, after)
            }
        }
    }

    private struct Result {
        var status: Int32
        var out: String
        var err: String
    }

    private static func runProcess(_ path: String, _ args: [String], javaScriptAllowed: Bool) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(status: -1, out: "", err: "\(error)")
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(status: p.terminationStatus, out: out, err: err)
    }
}
