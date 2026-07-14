import Foundation

/// Pure, `@MainActor`-free builder for the exportable diagnostics log (Brief §7/§8:
/// "human-readable"). It takes plain snapshot values — not the live model — so it is
/// exhaustively unit-testable without any UI or hardware.
///
/// The output is honest by construction: it renders the capability matrix straight
/// from `DeviceCapabilities` (where no row is `.observed`) and prints the protocol
/// trace as `(none — Phase 0B)` when empty rather than inventing a frame.
enum DiagnosticsReport {

    /// A compact filesystem-safe timestamp, e.g. `20260714-153000`, for filenames.
    static func iso8601Compact(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Build the plaintext report.
    /// - Parameters:
    ///   - live: ordered status blocks — `(sectionTitle, [(label, value)])`.
    ///   - catalogue: the capability rows (pass `DeviceCapabilities.catalogue`).
    ///   - frames: the protocol trace (empty today).
    static func text(generatedAt: Date,
                     palette: String,
                     mode: String,
                     live: [(String, [(String, String)])],
                     catalogue: [Capability],
                     frames: [ProtocolTrace.Frame]) -> String {
        var out = ""
        out += "halo diagnostics\n"
        out += "generated  \(iso8601(generatedAt))\n"
        out += "palette    \(palette)\n"
        out += "mode       \(mode)\n"
        out += "scope      read-only · local · no device write\n"

        for (title, rows) in live {
            out += "\n" + section(title)
            let labelWidth = rows.map { $0.0.count }.max() ?? 0
            for (label, value) in rows {
                out += "  \(label.padding(toLength: labelWidth, withPad: " ", startingAt: 0))  \(value)\n"
            }
        }

        out += "\n" + section("CAPABILITY MATRIX")
        out += matrixTable(catalogue)

        out += "\n" + section("PROTOCOL TRACE")
        if frames.isEmpty {
            out += "  (none — Phase 0B; the EP-40 protocol is device-gated,\n"
            out += "   this trace stays empty until a verified transport is wired)\n"
        } else {
            for f in frames {
                let hex = f.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                out += "  \(iso8601(f.timestamp))  \(f.direction.rawValue)  \(f.summary)\n"
                out += "    \(hex)\n"
            }
        }
        return out
    }

    // MARK: - Rendering helpers

    private static func section(_ title: String) -> String {
        "── \(title) " + String(repeating: "─", count: max(0, 46 - title.count)) + "\n"
    }

    /// An aligned monospace table: DOMAIN | CAPABILITY | STATUS | READINESS | EVIDENCE | NOTE.
    private static func matrixTable(_ rows: [Capability]) -> String {
        let header = ["DOMAIN", "CAPABILITY", "STATUS", "READINESS", "EVIDENCE", "NOTE"]
        var table: [[String]] = [header]
        for r in rows {
            table.append([
                r.domain.rawValue,
                r.title,
                r.status.rawValue,
                r.readiness.rawValue,
                r.evidence,
                r.note ?? "—",
            ])
        }
        // Column widths (NOTE is left unpadded — it is last and can be long).
        let padColumns = 5
        var widths = [Int](repeating: 0, count: padColumns)
        for row in table {
            for c in 0..<padColumns { widths[c] = max(widths[c], row[c].count) }
        }
        var out = ""
        for row in table {
            var cells: [String] = []
            for c in 0..<padColumns {
                cells.append(row[c].padding(toLength: widths[c], withPad: " ", startingAt: 0))
            }
            cells.append(row[padColumns])   // NOTE, unpadded
            out += "  " + cells.joined(separator: " | ") + "\n"
        }
        return out
    }
}
