import Foundation

/// File naming for recorded segments and exported clips.
///
/// Names are built with a fixed POSIX locale and Gregorian calendar so that they
/// are stable regardless of the user's region or calendar settings.
public enum SegmentNaming {
    public static let segmentPrefix = "seg_"
    public static let fileExtension = "mp4"

    private static func makeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.isLenient = false
        return formatter
    }

    /// `seg_20260319_142355_AB12CD34.mp4`
    public static func segmentFilename(
        startTime: Date,
        id: UUID,
        timeZone: TimeZone = .current
    ) -> String {
        let stamp = makeFormatter(timeZone: timeZone).string(from: startTime)
        return "\(segmentPrefix)\(stamp)_\(shortID(id)).\(fileExtension)"
    }

    /// Extracts the start time and short id from a name produced by `segmentFilename`.
    public static func parseSegmentFilename(
        _ filename: String,
        timeZone: TimeZone = .current
    ) -> (startTime: Date, shortID: String)? {
        guard filename.hasPrefix(segmentPrefix), filename.hasSuffix(".\(fileExtension)") else { return nil }
        let stem = filename
            .dropFirst(segmentPrefix.count)
            .dropLast(fileExtension.count + 1)
        let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].count == 8,
              parts[2].allSatisfy({ $0.isHexDigit }) else { return nil }
        guard let date = makeFormatter(timeZone: timeZone).date(from: "\(parts[0])_\(parts[1])") else {
            return nil
        }
        return (date, String(parts[2]))
    }

    public static func isSegmentFilename(_ filename: String, timeZone: TimeZone = .current) -> Bool {
        parseSegmentFilename(filename, timeZone: timeZone) != nil
    }

    /// `dashcam_collision_20260319_142355_AB12CD34.mp4`
    ///
    /// `label` is reduced to ASCII letters and digits so it is always safe in a file name.
    public static func exportFilename(
        label: String,
        date: Date,
        id: UUID,
        timeZone: TimeZone = .current
    ) -> String {
        let safeLabel = label.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let stamp = makeFormatter(timeZone: timeZone).string(from: date)
        let name = safeLabel.isEmpty ? "clip" : safeLabel.lowercased()
        return "dashcam_\(name)_\(stamp)_\(shortID(id)).\(fileExtension)"
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
