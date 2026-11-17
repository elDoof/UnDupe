import Foundation

/// Counts as people read them: grouped digits and a noun that agrees with the
/// number — "1 file", "1,234 files" — instead of "1 files" or "item(s)".
/// The companion to `ByteFormat`, shared by the engine's messages and the UI.
public enum CountFormat {

    /// A count with locale-appropriate digit grouping, e.g. "1,234,567".
    public static func number(_ count: Int) -> String {
        formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    /// A count followed by its noun, e.g. `string(1, "file")` → "1 file" and
    /// `string(3, "file")` → "3 files".
    ///
    /// - Parameter plural: the plural form, for nouns that don't just take an
    ///   "s" (`"copy"`/`"copies"`). Defaults to `singular + "s"`.
    public static func string(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number(count)) \(noun(count, singular, plural: plural))"
    }

    /// Just the noun in the form that agrees with `count`, for sentences where
    /// the number is written separately.
    public static func noun(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? singular + "s")
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
