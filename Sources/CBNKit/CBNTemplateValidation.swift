import Foundation

extension CBNTemplate {
    /// A structural problem that would make a template misbehave at render
    /// or play time. The import pipeline must never emit any of these; the
    /// validator exists so hand-authored templates and future pipeline
    /// regressions fail loudly in tests instead of quietly on a child's iPad.
    public enum ValidationIssue: Equatable, Sendable, CustomStringConvertible {
        case duplicatePaletteNumber(Int)
        case malformedPaletteHex(number: Int, hex: String)
        case unknownColorNumber(regionID: String, colorNumber: Int)
        case degeneratePath(regionID: String, pointCount: Int)
        case emptyPalette
        case noRegions

        public var description: String {
            switch self {
            case .duplicatePaletteNumber(let n):
                "palette number \(n) appears more than once"
            case .malformedPaletteHex(let number, let hex):
                "palette entry \(number) has malformed hex color \"\(hex)\""
            case .unknownColorNumber(let regionID, let colorNumber):
                "region \"\(regionID)\" references color \(colorNumber), which is not in the palette"
            case .degeneratePath(let regionID, let pointCount):
                "region \"\(regionID)\" has only \(pointCount) point(s); a closed polygon needs at least 3"
            case .emptyPalette:
                "template has no palette entries"
            case .noRegions:
                "template has no regions"
            }
        }
    }

    /// Returns every structural issue found (empty means the template is
    /// sound). Returns all issues rather than throwing on the first so a
    /// tuning session or test run shows the whole picture at once.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if palette.isEmpty { issues.append(.emptyPalette) }
        if regions.isEmpty { issues.append(.noRegions) }

        var seenNumbers = Set<Int>()
        for entry in palette {
            if !seenNumbers.insert(entry.number).inserted {
                issues.append(.duplicatePaletteNumber(entry.number))
            }
            if entry.rgb == nil {
                issues.append(.malformedPaletteHex(number: entry.number, hex: entry.hex))
            }
        }

        for region in regions {
            if !seenNumbers.contains(region.colorNumber) {
                issues.append(.unknownColorNumber(regionID: region.id, colorNumber: region.colorNumber))
            }
            if region.path.count < 3 {
                issues.append(.degeneratePath(regionID: region.id, pointCount: region.path.count))
            }
        }

        return issues
    }
}
