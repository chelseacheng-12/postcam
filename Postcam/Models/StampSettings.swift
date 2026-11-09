import Combine
import Foundation

struct StampCopy: Equatable {
    var date: String
    var label: String
    var caption: String
    var denomination: String
    var place: String
}

enum StampDate {
    /// Capture date printed as `2026.09`. Gregorian, zero-padded, no locale month names.
    static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d.%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// Stamp lines other than the date. The date is filled from the capture moment.
/// `copyForCurrentFrame()` is safe to call from the camera queue.
final class StampSettings: ObservableObject {
    @Published var label: String {
        didSet { store(label, key: Key.label, limit: 24) { label = $0 } }
    }
    @Published var caption: String {
        didSet { store(caption, key: Key.caption, limit: 42) { caption = $0 } }
    }
    @Published var denomination: String {
        didSet { store(denomination, key: Key.denomination, limit: 8) { denomination = $0 } }
    }
    @Published var place: String {
        didSet { store(place, key: Key.place, limit: 18) { place = $0 } }
    }
    @Published private(set) var revision = 0

    private struct Fields {
        var label: String
        var caption: String
        var denomination: String
        var place: String
    }

    private let lock = NSLock()
    private var fields: Fields
    private var cachedDateString: String
    private var isStoring = false

    init() {
        let defaults = UserDefaults.standard
        let label = String((defaults.string(forKey: Key.label) ?? Default.label).prefix(24))
        let caption = String((defaults.string(forKey: Key.caption) ?? Default.caption).prefix(42))
        let denomination = String((defaults.string(forKey: Key.denomination) ?? Default.denomination).prefix(8))
        let place = String((defaults.string(forKey: Key.place) ?? Default.place).prefix(18))
        self.label = label
        self.caption = caption
        self.denomination = denomination
        self.place = place
        fields = Fields(label: label, caption: caption, denomination: denomination, place: place)
        cachedDateString = StampDate.string(from: Date())
    }

    func copyForCurrentFrame() -> StampCopy {
        lock.lock()
        let snapshot = fields
        let date = cachedDateString
        lock.unlock()
        return StampCopy(
            date: date,
            label: snapshot.label.trimmingCharacters(in: .whitespacesAndNewlines),
            caption: snapshot.caption.trimmingCharacters(in: .whitespacesAndNewlines),
            denomination: snapshot.denomination.trimmingCharacters(in: .whitespacesAndNewlines),
            place: snapshot.place.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func refreshDate(to date: Date = Date()) {
        let string = StampDate.string(from: date)
        lock.lock()
        let changed = cachedDateString != string
        cachedDateString = string
        lock.unlock()
        if changed {
            revision += 1
        }
    }

    func reset() {
        label = Default.label
        caption = Default.caption
        denomination = Default.denomination
        place = Default.place
    }

    var datePreview: String {
        lock.lock()
        defer { lock.unlock() }
        return cachedDateString
    }

    private func store(_ value: String, key: String, limit: Int, write: (String) -> Void) {
        if isStoring { return }
        var text = value
        if text.count > limit {
            text = String(text.prefix(limit))
            isStoring = true
            write(text)
            isStoring = false
        }
        lock.lock()
        fields = Fields(label: label, caption: caption, denomination: denomination, place: place)
        lock.unlock()
        UserDefaults.standard.set(text, forKey: key)
        revision += 1
    }

    enum Default {
        static let label = "TRAVEL VLOG"
        static let caption = "SPECIAL ADMINISTRATIVE REGION"
        static let denomination = "520"
        static let place = "HONGKONG"
    }

    private enum Key {
        static let label = "postcam.stamp.label"
        static let caption = "postcam.stamp.caption"
        static let denomination = "postcam.stamp.denomination"
        static let place = "postcam.stamp.place"
    }
}
