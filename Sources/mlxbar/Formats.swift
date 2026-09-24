import Foundation

enum Formats {
    // Port of the dashboard's fmt(v, d): M/K suffix with one decimal, else toFixed(d).
    static func fmt(_ v: Double, _ d: Int = 1) -> String {
        if v.isNaN { return "—" }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        switch d {
        case 0: return String(format: "%.0f", v)
        case 1: return String(format: "%.1f", v)
        default: return String(format: "%.\(d)f", v)
        }
    }

    // -1 sentinel ⇒ the dashboard renders an em dash.
    static func orDash(_ v: Double, _ d: Int = 1) -> String {
        v < 0 ? "—" : fmt(v, d)
    }

    // Math.round display (cache %, token-reuse %): JS shows "95", not "95.0".
    static func dashInt(_ v: Double) -> String {
        v < 0 ? "—" : String(format: "%.0f", v.rounded())
    }

    static func raw(_ v: Int) -> String { String(v) }
}
