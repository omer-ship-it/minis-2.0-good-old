import Foundation

enum RongtaMini13Printer {

    // ✅ Hard gate: cannot enable for any other mini
    private static var enabled: Bool {
        UserDefaults.standard.integer(forKey: "miniAppId") == 13
    }

    // ✅ Hardcoded endpoints (your 2 Rongta devices)
    private static let port: UInt16 = 9100
    private static let primaryHost  = "10.0.0.221"
    private static let secondaryHost = "10.0.0.222"

    // ✅ Your known-good Rongta settings
    private static let codepage: UInt8 = 33
    private static let rotated: Bool = false
    private static let lineWidth: Int = 42

    // Namespace so dedupe never collides with Tabit jobs
    private static func dk(_ base: String, _ suffix: String) -> String {
        "ron13|\(base)|\(suffix)"
    }

    static func tryPrint(order: KDSAdminOrder,
                         lines: [KDSOrderLine],
                         dedupe: String) {
        guard enabled else { return }
        guard !lines.isEmpty else { return }

        let job = makeJob(order: order, lines: lines)

        // Primary then fallback to secondary
        OneShotPrinter.send(
            host: primaryHost,
            port: port,
            data: job,
            tag: dk(dedupe, "p"),
            dedupeKey: dk(dedupe, "p")
        ) { ok in
            guard !ok else { return }
            OneShotPrinter.send(
                host: secondaryHost,
                port: port,
                data: job,
                tag: dk(dedupe, "s"),
                dedupeKey: dk(dedupe, "s")
            ) { _ in }
        }
    }

    // MARK: - Build ticket

    private static func makeJob(order o: KDSAdminOrder, lines: [KDSOrderLine]) -> Data {
        var job = Data()
        job += EscPos.initPrinter

        // ✅ Force Rongta Hebrew codepage
        job.append(contentsOf: [0x1B, 0x74, codepage])

        if rotated { job += EscPos.rotate180On }

        let sep = String(repeating: "-", count: max(8, lineWidth))

        job += EscPos.align(1)
        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += asciiLine("\(o.id)")
        job += EscPos.feed(1)

        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += hebrewLineData(o.customerName.isEmpty ? "ללא שם" : o.customerName)
        job += EscPos.feed(1)

        job += EscPos.align(0)
        job += asciiLine(sep)
        job += EscPos.feed(1)

        for ln in lines {
            job += EscPos.align(2)
            job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
            job += hebrewLineData("\(ln.qty) \(ln.name)")

            if let mods = ln.modifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
               !mods.isEmpty {
                job += EscPos.feed(1)
                job += EscPos.style(doubleHeight: false, doubleWidth: true, bold: false)
                job += hebrewLineData("  \(mods)")
            }

            job += EscPos.feed(1)
            job += EscPos.align(0)
            job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
            job += asciiLine(sep)
            job += EscPos.feed(1)
        }

        job += EscPos.feed(4)
        if rotated { job += EscPos.rotate180Off }
        job += EscPos.cut
        return job
    }
}
