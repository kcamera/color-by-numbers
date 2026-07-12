import ArgumentParser
import CBNKit
import CoreGraphics
import Foundation

/// The durable tuning workflow: sweep parameter combinations over test
/// images, emit a browsable contact sheet, eyeball, bless winners into
/// Sources/CBNKit/Resources/presets.json. Documented in README.md.
struct TuneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tune",
        abstract: "Sweep pipeline parameters over images and build an HTML contact sheet."
    )

    @Argument(help: "Image files and/or directories of images.")
    var inputs: [String]

    @Option(help: "Comma-separated palette sizes to sweep, e.g. 6,10,16.")
    var colors: String = "6,10,16"

    @Option(help: "Comma-separated detail values to sweep, e.g. 0.35,0.6,0.85.")
    var detail: String = "0.35,0.6,0.85"

    @Option(help: "Comma-separated min region area fractions to sweep.")
    var minRegionFraction: String = "0.0015"

    @Option(name: .shortAndLong, help: "Output directory for the contact sheet.")
    var output: String = "tune-output"

    @Option(help: "Thumbnail width in pixels for sheet cells.")
    var cellWidth: Int = 420

    func run() throws {
        let colorValues = try parseList(colors, Int.init, flag: "--colors")
        let detailValues = try parseList(detail, Double.init, flag: "--detail")
        let fractionValues = try parseList(minRegionFraction, Double.init, flag: "--min-region-fraction")

        let imageURLs = try collectImages()
        guard !imageURLs.isEmpty else {
            throw ValidationError("No images found in: \(inputs.joined(separator: ", "))")
        }

        let combos = colorValues.count * detailValues.count * fractionValues.count
        if combos * imageURLs.count > 96 {
            print("Note: \(combos) combinations × \(imageURLs.count) images = \(combos * imageURLs.count) cells — this may take a while.")
        }

        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var sections: [ContactSheetSection] = []
        for imageURL in imageURLs {
            let raster = try RasterImage.load(from: imageURL)
            let stem = imageURL.deletingPathExtension().lastPathComponent
            var cells: [ContactSheetCell] = []

            for colorCount in colorValues {
                for detailValue in detailValues {
                    for fraction in fractionValues {
                        let parameters = ImportParameters(
                            colorCount: colorCount,
                            minRegionAreaFraction: fraction,
                            detail: detailValue
                        )
                        let template = ImportPipeline.importTemplate(
                            from: raster, title: stem, parameters: parameters
                        )
                        let scale = Double(cellWidth) / template.size.width

                        let baseName = "\(stem)-c\(colorCount)-d\(detailValue)-f\(fraction)"
                        var fileNames: [String] = []
                        for mode in [TemplateRenderer.Mode.composite, .outline] {
                            guard let image = TemplateRenderer.render(template, mode: mode, scale: scale) else { continue }
                            let fileName = "\(baseName)-\(mode.rawValue).png"
                            try RasterImage.writePNG(
                                image, to: outputURL.appendingPathComponent(fileName)
                            )
                            fileNames.append(fileName)
                        }
                        cells.append(
                            ContactSheetCell(
                                caption: "colors \(colorCount) · detail \(detailValue) · minFrac \(fraction)",
                                detailLine: "\(template.regions.count) regions, \(template.palette.count) colors",
                                imageFiles: fileNames
                            )
                        )
                        print("  \(baseName): \(template.regions.count) regions")
                    }
                }
            }
            sections.append(ContactSheetSection(title: stem, cells: cells))
        }

        let sheetURL = outputURL.appendingPathComponent("index.html")
        try ContactSheet.html(sections: sections)
            .write(to: sheetURL, atomically: true, encoding: .utf8)
        print("Contact sheet: \(sheetURL.path)")
        print("Open it, pick winners, bless them into Sources/CBNKit/Resources/presets.json.")
    }

    private func parseList<T>(_ raw: String, _ transform: (String) -> T?, flag: String) throws -> [T] {
        let values = raw.split(separator: ",").compactMap {
            transform($0.trimmingCharacters(in: .whitespaces))
        }
        guard !values.isEmpty else { throw ValidationError("Could not parse \(flag) \"\(raw)\"") }
        return values
    }

    private func collectImages() throws -> [URL] {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
        var urls: [URL] = []
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory) else {
                throw ValidationError("No such file or directory: \(input)")
            }
            if isDirectory.boolValue {
                let entries = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: input),
                    includingPropertiesForKeys: nil
                )
                urls.append(contentsOf: entries
                    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent })
            } else {
                urls.append(URL(fileURLWithPath: input))
            }
        }
        return urls
    }
}

// MARK: - Contact sheet HTML

struct ContactSheetSection {
    var title: String
    var cells: [ContactSheetCell]
}

struct ContactSheetCell {
    var caption: String
    var detailLine: String
    var imageFiles: [String]
}

enum ContactSheet {
    /// Self-contained static HTML: no scripts, no network, opens from file://.
    static func html(sections: [ContactSheetSection]) -> String {
        var body = ""
        for section in sections {
            body += "<h2>\(section.title)</h2>\n<div class=\"grid\">\n"
            for cell in section.cells {
                let images = cell.imageFiles
                    .map { "<img src=\"\($0)\" loading=\"lazy\">" }
                    .joined()
                body += """
                <figure>
                  \(images)
                  <figcaption><strong>\(cell.caption)</strong><br>\(cell.detailLine)</figcaption>
                </figure>\n
                """
            }
            body += "</div>\n"
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>cbnc tune — contact sheet</title>
        <style>
          body { font-family: -apple-system, sans-serif; margin: 2rem; background: #faf8f4; color: #333; }
          h2 { border-bottom: 1px solid #ddd; padding-bottom: 0.3rem; }
          .grid { display: flex; flex-wrap: wrap; gap: 1rem; }
          figure { margin: 0; padding: 0.5rem; background: white; border: 1px solid #e5e0d8;
                   border-radius: 6px; }
          figure img { display: block; margin-bottom: 0.25rem; max-width: 100%; }
          figcaption { font-size: 0.8rem; color: #555; }
        </style></head><body>
        <h1>cbnc tune — contact sheet</h1>
        <p>Each cell: composite render (boundary quality) + outline render (what the child sees).
           Pick winners, bless their parameters into <code>Sources/CBNKit/Resources/presets.json</code>.</p>
        \(body)
        </body></html>
        """
    }
}
