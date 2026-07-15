import Foundation

/// The pipeline's tunable knobs. Presets are named bundles of these values;
/// the raw values remain reachable through cbnc flags and (later) the
/// Workshop's "Adjust…" escape hatch.
public struct ImportParameters: Codable, Equatable, Sendable {
    /// Maximum palette size.
    public var colorCount: Int
    /// The smallest colorable region, as the diameter in millimeters of an
    /// equivalent circle *at standard display size* (the template's long
    /// edge shown at `ImportPipeline.referenceLongEdgeMM` — roughly an iPad
    /// landscape screen or a printed page). Anything smaller merges into a
    /// neighbor. Physical units because that's how the floor is actually
    /// reasoned about — a fingertip is ~10mm, a cartoon pupil ~3mm — and
    /// they hold steady across source resolutions *and* aspect ratios,
    /// which the old fraction-of-image-area unit did not.
    public var minRegionMM: Double
    /// DORMANT — scheduled for removal in a future refactor; 1.0 is the
    /// only sensible value and the default everywhere.
    ///
    /// 0...1, mapping to the path-simplification tolerance. The original
    /// intent was "lower = calmer, chunkier shapes", but RDP simplification
    /// can only facet curves, never round them, so every value below 1.0
    /// just degrades boundaries without changing structure (region count is
    /// unaffected — merging owns that). If a real "calm" dial ever returns,
    /// it will be a smoothing parameter on a curve-fitting pass, not this.
    /// When removing: also collapse `simplifyTolerance` in ImportPipeline
    /// to its detail-1.0 constant (ideally mm-based), drop the `--detail`
    /// flags in cbnc, the field here and in ImportPreset/presets.json, and
    /// the d-component of tune's filename convention.
    public var detail: Double

    public init(colorCount: Int, minRegionMM: Double, detail: Double = 1.0) {
        self.colorCount = colorCount
        self.minRegionMM = minRegionMM
        self.detail = detail
    }
}

/// A named, kid-selectable parameter bundle ("Simple", "Just Right",
/// "Detailed"). Stored in Resources/presets.json — data, not code, so
/// retuning never touches the app.
public struct ImportPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var colorCount: Int
    public var minRegionMM: Double
    public var detail: Double

    public var parameters: ImportParameters {
        ImportParameters(
            colorCount: colorCount,
            minRegionMM: minRegionMM,
            detail: detail
        )
    }
}

public enum PresetStore {
    struct PresetsFile: Codable {
        var schemaVersion: Int
        var presets: [ImportPreset]
    }

    /// Loads the bundled presets. Trap on failure is deliberate: a missing
    /// or malformed presets.json is a build defect, not a runtime
    /// condition.
    public static func bundled() -> [ImportPreset] {
        guard
            let url = Bundle.module.url(forResource: "presets", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(PresetsFile.self, from: data)
        else {
            fatalError("CBNKit resource presets.json is missing or malformed")
        }
        return file.presets
    }

    public static func preset(id: String) -> ImportPreset? {
        bundled().first { $0.id == id }
    }
}
