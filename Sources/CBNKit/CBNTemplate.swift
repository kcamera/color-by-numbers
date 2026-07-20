import Foundation

/// A color-by-numbers template: the immutable "coloring page" produced by the
/// import pipeline (or authored by hand, like the M0 sample).
///
/// A template never changes during play — coloring progress lives in
/// per-attempt state (arriving in M2/M3), which is what makes "color it
/// again" additive and the Studio safe by construction. The one sanctioned
/// exception is the Workshop's rename (M4, `CBNLibrary.renameItem`): editing
/// `title` in place, parent-zone only, after import — it never touches
/// anything a child's in-progress attempt depends on (regions, palette,
/// geometry all stay fixed).
public struct CBNTemplate: Codable, Equatable, Sendable {
    /// Bumped only when the on-disk JSON layout changes incompatibly.
    public var schemaVersion: Int
    public var title: String
    /// Canvas size in template units — an abstract coordinate space, not
    /// pixels. Renderers scale to whatever output size they need.
    public var size: CBNSize
    /// The fixed palette. `number` is what the child sees printed in each
    /// region; the importer assigns it and the app never lets it change.
    public var palette: [CBNPaletteEntry]
    /// Regions in painter's order: later entries draw over earlier ones.
    /// This keeps hand-authored templates simple (a sun can sit "on" the
    /// sky, no hole needed). Pipeline-produced regions carry explicit
    /// `holes` and paint exactly their own pixels, so their order is only
    /// a cosmetic tiebreak for hairline overlaps left by simplification.
    public var regions: [CBNRegion]

    public init(
        schemaVersion: Int = 1,
        title: String,
        size: CBNSize,
        palette: [CBNPaletteEntry],
        regions: [CBNRegion]
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.size = size
        self.palette = palette
        self.regions = regions
    }
}

public struct CBNSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct CBNPaletteEntry: Codable, Equatable, Sendable {
    public var number: Int
    public var name: String
    /// "#RRGGBB" (uppercase or lowercase hex both accepted).
    public var hex: String

    public init(number: Int, name: String, hex: String) {
        self.number = number
        self.name = name
        self.hex = hex
    }

    /// Parsed color channels in 0...1, or nil if `hex` is malformed.
    public var rgb: CBNColor? { CBNColor(hex: hex) }
}

/// A parsed RGB color with channels in 0...1. Deliberately not tied to
/// SwiftUI/UIKit color types so CBNKit stays platform-pure.
public struct CBNColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init?(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return nil
        }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }
}

public struct CBNRegion: Codable, Equatable, Sendable {
    public var id: String
    /// Must match a `CBNPaletteEntry.number` in the template's palette.
    public var colorNumber: Int
    /// Closed polygon: the last point connects back to the first implicitly.
    /// (Curved boundaries arrive with the M1 pipeline's path smoothing.)
    public var path: [CBNPoint]
    /// Closed polygons cut out of `path` (even-odd fill). Real line art
    /// demands these: an eye outline with an attached pupil is one connected
    /// region living at two nesting depths at once, which no painter's
    /// ordering of hole-free polygons can draw correctly — it must paint
    /// both before the eye white (it surrounds it) and after it (the pupil
    /// sits inside it). With holes, every region paints exactly its own
    /// pixels and draw order stops mattering for correctness. Empty for
    /// simply-shaped regions; omitted from JSON when empty.
    public var holes: [[CBNPoint]]
    /// Where the region's number label is drawn — must lie inside the region.
    public var labelPoint: CBNPoint

    public init(
        id: String,
        colorNumber: Int,
        path: [CBNPoint],
        holes: [[CBNPoint]] = [],
        labelPoint: CBNPoint
    ) {
        self.id = id
        self.colorNumber = colorNumber
        self.path = path
        self.holes = holes
        self.labelPoint = labelPoint
    }

    private enum CodingKeys: String, CodingKey {
        case id, colorNumber, path, holes, labelPoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        colorNumber = try container.decode(Int.self, forKey: .colorNumber)
        path = try container.decode([CBNPoint].self, forKey: .path)
        holes = try container.decodeIfPresent([[CBNPoint]].self, forKey: .holes) ?? []
        labelPoint = try container.decode(CBNPoint.self, forKey: .labelPoint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(colorNumber, forKey: .colorNumber)
        try container.encode(path, forKey: .path)
        if !holes.isEmpty { try container.encode(holes, forKey: .holes) }
        try container.encode(labelPoint, forKey: .labelPoint)
    }
}

/// A point encoded in JSON as a two-element array `[x, y]` — template files
/// contain thousands of points once the pipeline exists, so compactness in
/// the on-disk format matters more than JSON readability.
public struct CBNPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A point must be exactly [x, y]"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}
