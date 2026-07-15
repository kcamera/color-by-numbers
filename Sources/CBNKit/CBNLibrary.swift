import Foundation

/// A template plus its library metadata, as returned by `CBNLibrary.items()`
/// — what the Studio grid actually renders.
public struct CBNLibraryItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var template: CBNTemplate
    public var addedAt: Date

    public init(id: String, template: CBNTemplate, addedAt: Date) {
        self.id = id
        self.template = template
        self.addedAt = addedAt
    }
}

/// The on-disk store of every template a family has imported, plus the
/// child's attempts at each — a plain folder of document-package-shaped
/// directories, ready for M3+ additions (source images live alongside
/// template.json without touching this layout again). Pure Foundation, no
/// UIKit/AppKit, so it builds and tests identically on macOS (cbnc, CI) and
/// iOS (the app).
///
/// Layout:
/// ```
/// <root>/<itemID>/template.json
/// <root>/<itemID>/meta.json        // { "addedAt": <date> }
/// <root>/<itemID>/attempts/<attemptID>.json
/// ```
public struct CBNLibrary: Sendable {
    public var rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private struct Meta: Codable {
        var addedAt: Date
    }

    /// Sorted-keys + ISO-8601 dates, consistently, everywhere this type
    /// touches JSON — same rationale as TemplateIO in Sources/cbnc/Cbnc.swift:
    /// readable, debuggable output. Note `.iso8601` is whole-second (no
    /// fractional component), so two writes within the same wall-clock
    /// second round-trip to the identical timestamp; `add`/`seedIfEmpty`
    /// account for that explicitly rather than assuming sub-second
    /// ordering ever survives a disk round-trip.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Paths

    private func itemDirectory(_ itemID: String) -> URL {
        rootURL.appendingPathComponent(itemID, isDirectory: true)
    }

    private func templateURL(_ itemID: String) -> URL {
        itemDirectory(itemID).appendingPathComponent("template.json")
    }

    private func metaURL(_ itemID: String) -> URL {
        itemDirectory(itemID).appendingPathComponent("meta.json")
    }

    private func attemptsDirectory(_ itemID: String) -> URL {
        itemDirectory(itemID).appendingPathComponent("attempts", isDirectory: true)
    }

    private func attemptURL(_ attemptID: String, in itemID: String) -> URL {
        attemptsDirectory(itemID).appendingPathComponent("\(attemptID).json")
    }

    // MARK: - Root

    /// Creates the root directory if it doesn't already exist. Safe to call
    /// on every launch.
    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: - Items

    /// Adds a new library item for `template`: a fresh UUID id, template.json
    /// + meta.json on disk, and one empty attempts/ entry ready to color into
    /// — the "new project appears at the front of the Studio" moment
    /// (DESIGN.md's import ritual) starts here.
    @discardableResult
    public func add(_ template: CBNTemplate) throws -> CBNLibraryItem {
        try addItem(template, addedAt: Date())
    }

    /// Shared by `add` and `seedIfEmpty`: the latter needs to control
    /// `addedAt` directly so a whole seeded batch orders correctly by
    /// construction, rather than depending on real clock resolution between
    /// back-to-back calls. Internal (not `private`) rather than public: it's
    /// not part of the documented API, but tests need it too, to construct
    /// deliberately-ordered fixtures without sleeping past `.iso8601`'s
    /// whole-second rounding.
    func addItem(_ template: CBNTemplate, addedAt: Date) throws -> CBNLibraryItem {
        try ensureRoot()
        let itemID = UUID().uuidString
        try FileManager.default.createDirectory(
            at: attemptsDirectory(itemID), withIntermediateDirectories: true
        )

        let encoder = Self.makeEncoder()
        try encoder.encode(template).write(to: templateURL(itemID))
        try encoder.encode(Meta(addedAt: addedAt)).write(to: metaURL(itemID))
        try saveAttempt(CBNAttempt(), in: itemID)

        return CBNLibraryItem(id: itemID, template: template, addedAt: addedAt)
    }

    /// Every library item, sorted NEWEST FIRST by `addedAt` — the Studio
    /// grid contract (DESIGN.md). A single malformed folder (partial write,
    /// hand-edited junk) is skipped rather than thrown: a corrupt entry must
    /// never take down a child's whole library. Root-level I/O errors (the
    /// root itself unreadable) still throw — that's a real device problem,
    /// not a per-item quirk.
    public func items() throws -> [CBNLibraryItem] {
        try ensureRoot()
        let decoder = Self.makeDecoder()
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        )

        var results: [CBNLibraryItem] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let itemID = entry.lastPathComponent
            guard
                let templateData = try? Data(contentsOf: templateURL(itemID)),
                let template = try? decoder.decode(CBNTemplate.self, from: templateData),
                let metaData = try? Data(contentsOf: metaURL(itemID)),
                let meta = try? decoder.decode(Meta.self, from: metaData)
            else { continue }
            results.append(CBNLibraryItem(id: itemID, template: template, addedAt: meta.addedAt))
        }
        return results.sorted { $0.addedAt > $1.addedAt }
    }

    // MARK: - Attempts

    /// Writes `attempt` atomically — this is the continuous-autosave path
    /// (DESIGN.md: "state survives anything, including mid-stroke power
    /// loss"), so a torn write must never leave a half-written file behind.
    public func saveAttempt(_ attempt: CBNAttempt, in itemID: String) throws {
        try FileManager.default.createDirectory(
            at: attemptsDirectory(itemID), withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(attempt)
        try data.write(to: attemptURL(attempt.id, in: itemID), options: .atomic)
    }

    /// The most recently updated attempt for an item, or nil if it has none
    /// (or the item itself doesn't exist). Malformed attempt files are
    /// skipped for the same reason malformed items are in `items()`.
    public func latestAttempt(in itemID: String) throws -> CBNAttempt? {
        let directory = attemptsDirectory(itemID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        let decoder = Self.makeDecoder()
        let attempts: [CBNAttempt] = entries.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(CBNAttempt.self, from: data)
        }
        return attempts.max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - Seeding

    /// First-launch starter installation: if the library has no items yet,
    /// adds every template in `templates`. A no-op on every later launch
    /// (once the root has any item at all), so it's safe to call unconditionally
    /// at app startup.
    ///
    /// Templates are added in REVERSE order, one synthetic second apart,
    /// so that `addedAt` comes out strictly increasing with array position
    /// — the FIRST template in `templates` ends up with the latest
    /// `addedAt` and therefore sorts NEWEST FIRST in `items()`, matching
    /// the order the starter set was authored in. The explicit spacing
    /// (rather than one `Date()` per call) is what keeps this correct by
    /// construction: a first-launch seeding batch runs as fast as disk I/O
    /// allows, well under the wall clock's practical resolution.
    @discardableResult
    public func seedIfEmpty(with templates: [CBNTemplate]) throws -> Bool {
        guard try items().isEmpty else { return false }
        let batchStart = Date()
        for (offset, template) in templates.reversed().enumerated() {
            try addItem(template, addedAt: batchStart.addingTimeInterval(Double(offset)))
        }
        return true
    }
}
