import Foundation

/// The pipeline's tunable knobs. Presets are named bundles of these values;
/// the raw values remain reachable through cbnc flags and (later) the
/// Workshop's "Adjust…" escape hatch.
public struct ImportParameters: Codable, Equatable, Sendable {
    /// Maximum palette size.
    public var colorCount: Int
    /// Minimum region size as a fraction of total image area —
    /// resolution-independent, so a preset means the same thing for a
    /// 800px sketch and a 4000px scan.
    public var minRegionAreaFraction: Double
    /// 0...1. Higher keeps boundaries more faithful; lower simplifies them
    /// into calmer, chunkier shapes. Maps to the path-simplification
    /// tolerance in ImportPipeline.
    public var detail: Double

    public init(colorCount: Int, minRegionAreaFraction: Double, detail: Double) {
        self.colorCount = colorCount
        self.minRegionAreaFraction = minRegionAreaFraction
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
    public var minRegionAreaFraction: Double
    public var detail: Double

    public var parameters: ImportParameters {
        ImportParameters(
            colorCount: colorCount,
            minRegionAreaFraction: minRegionAreaFraction,
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
