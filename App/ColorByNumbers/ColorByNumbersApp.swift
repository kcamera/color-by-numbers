import CBNKit
import SwiftUI

@main
struct ColorByNumbersApp: App {
    /// The on-device library root: `<Documents>/Library`. Zero network code,
    /// ever (DESIGN.md) — everything a family imports and everything a
    /// child colors lives only inside the app's own sandbox.
    private static let library: CBNLibrary = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return CBNLibrary(rootURL: documents.appendingPathComponent("Library", isDirectory: true))
    }()

    init() {
        Self.prepareLibraryIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            StudioView(library: Self.library)
        }
    }

    /// First-launch setup: ensure the library root exists, then seed the
    /// bundled starters if this is a fresh install. `seedIfEmpty` is a
    /// no-op once the library has anything in it, so calling this
    /// unconditionally on every launch is safe (CBNLibrary.swift).
    private static func prepareLibraryIfNeeded() {
        do {
            try library.ensureRoot()
        } catch {
            // A library the app can't even create is a real device problem,
            // not a per-item quirk — but it must still never crash a
            // child's app at runtime (CLAUDE.md). Debug builds want to know
            // loudly; release builds fall back to an empty, unseeded Studio.
            assertionFailure("Could not create the library root: \(error)")
            return
        }

        // seedIfEmpty adds templates in REVERSE order so the FIRST array
        // element ends up with the newest addedAt (CBNLibrary.seedIfEmpty's
        // doc comment). Little Sailboat listed first here is what lands as
        // the newest card — first thing the child sees in the grid.
        let starterNames = ["little-sailboat", "rings", "banner"]
        let starters = starterNames.compactMap(starterTemplate(named:))

        // Every named starter failing to decode is a build defect (a
        // bundled resource is malformed or missing) — assert loudly in
        // debug. In release, seed whatever did decode rather than leaving
        // the child with nothing.
        assert(
            starters.count == starterNames.count,
            "One or more bundled starter templates failed to decode"
        )
        guard !starters.isEmpty else { return }

        do {
            try library.seedIfEmpty(with: starters)
        } catch {
            assertionFailure("Could not seed the starter library: \(error)")
        }
    }

    /// Decodes a bundled starter template by name. Tries the "Starters"
    /// subdirectory first (how the resource is authored on disk and how
    /// Xcode preserves it when a folder reference is used), then falls back
    /// to a flat lookup (how a plain resources build phase can flatten a
    /// group instead) — this only needs to be right once, so it's cheap to
    /// be defensive about which bundle layout xcodegen produced.
    private static func starterTemplate(named name: String) -> CBNTemplate? {
        let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Starters")
            ?? Bundle.main.url(forResource: name, withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else {
            assertionFailure("Missing bundled starter template: \(name)")
            return nil
        }
        do {
            return try JSONDecoder().decode(CBNTemplate.self, from: data)
        } catch {
            assertionFailure("Malformed bundled starter template \(name): \(error)")
            return nil
        }
    }
}
