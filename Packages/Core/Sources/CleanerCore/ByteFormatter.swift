import Foundation

public enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]

    /// Decimal (1000-based) formatting with at most one decimal place:
    /// "0 B", "350 KB", "12.4 GB". No trailing ".0".
    public static func string(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        let negative = bytes < 0
        let magnitude = negative ? (bytes == Int64.min ? Double(Int64.max) : Double(-bytes)) : Double(bytes)
        var value = magnitude
        var unit = 0
        while value >= 999.95 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let text: String
        if unit == 0 {
            text = String(Int64(value))
        } else {
            let rounded = (value * 10).rounded() / 10
            if rounded == rounded.rounded(.towardZero) {
                text = String(Int64(rounded))
            } else {
                text = String(rounded)
            }
        }
        return (negative ? "-" : "") + text + " " + units[unit]
    }
}
