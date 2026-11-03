import Foundation
import CleanerCore

/// Renders scan results as a plain-text table: one row per category (count and
/// bytes), a total line, then the largest findings with a risk badge.
enum TableFormatter {
    struct CategoryRow: Hashable, Sendable {
        let category: FindingCategory
        let count: Int
        let bytes: Int64
    }

    static func categoryRows(_ findings: [Finding]) -> [CategoryRow] {
        var counts: [FindingCategory: (count: Int, bytes: Int64)] = [:]
        for finding in findings {
            let entry = counts[finding.category, default: (0, 0)]
            counts[finding.category] = (entry.count + 1, entry.bytes + finding.sizeBytes)
        }
        return counts
            .map { CategoryRow(category: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                if lhs.category.displayName != rhs.category.displayName {
                    return lhs.category.displayName < rhs.category.displayName
                }
                return lhs.category.id < rhs.category.id
            }
    }

    static func render(_ document: ScanDocument, topCount: Int = 20) -> String {
        let findings = document.findings
        var lines: [String] = []

        if findings.isEmpty {
            lines.append("No findings.")
            lines.append(String(format: "Scan took %.1f s.", document.summary.duration))
            return lines.joined(separator: "\n")
        }

        let rows = categoryRows(findings)
        let nameWidth = max(8, rows.map { $0.category.displayName.count }.max() ?? 0)
        let countWidth = max(5, rows.map { String($0.count).count }.max() ?? 0,
                             String(findings.count).count)
        let sizeWidth = max(9, rows.map { ByteFormatter.string($0.bytes).count }.max() ?? 0,
                            ByteFormatter.string(document.summary.totalBytes).count)
        let rule = String(repeating: "-", count: nameWidth + 2 + countWidth + 2 + sizeWidth)

        lines.append(row("Category", "Count", "Size", nameWidth, countWidth, sizeWidth))
        lines.append(rule)
        for entry in rows {
            lines.append(row(entry.category.displayName, String(entry.count),
                             ByteFormatter.string(entry.bytes), nameWidth, countWidth, sizeWidth))
        }
        lines.append(rule)
        lines.append(row("Total", String(findings.count),
                         ByteFormatter.string(document.summary.totalBytes),
                         nameWidth, countWidth, sizeWidth))
        lines.append(String(format: "Scan took %.1f s.", document.summary.duration))

        let top = Array(findings.sortedBySize().prefix(topCount))
        lines.append("")
        lines.append("Largest findings (top \(top.count) of \(findings.count)):")
        let indexWidth = String(top.count).count
        let topSizeWidth = top.map { ByteFormatter.string($0.sizeBytes).count }.max() ?? 0
        for (index, finding) in top.enumerated() {
            let number = padLeft(String(index + 1), to: indexWidth)
            let size = padLeft(ByteFormatter.string(finding.sizeBytes), to: topSizeWidth)
            let suffix = finding.isDirectory ? "/" : ""
            lines.append("\(number). \(finding.risk.badge) \(size)  \(finding.path.path)\(suffix)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func row(_ name: String, _ count: String, _ size: String,
                            _ nameWidth: Int, _ countWidth: Int, _ sizeWidth: Int) -> String {
        padRight(name, to: nameWidth) + "  " + padLeft(count, to: countWidth) + "  " + padLeft(size, to: sizeWidth)
    }

    static func padLeft(_ text: String, to width: Int) -> String {
        let padding = max(0, width - text.count)
        return String(repeating: " ", count: padding) + text
    }

    static func padRight(_ text: String, to width: Int) -> String {
        let padding = max(0, width - text.count)
        return text + String(repeating: " ", count: padding)
    }
}
