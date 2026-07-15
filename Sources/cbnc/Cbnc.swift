import ArgumentParser
import CBNKit
import CoreGraphics
import Foundation

@main
struct Cbnc: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cbnc",
        abstract: "Color By Numbers pipeline CLI — import, render, validate, tune.",
        discussion: """
        Typical desk workflow:
          make-testart   Generate the synthetic TestArt/ corpus (one-time, or
                         after pulling changes to it).
          tune           Sweep parameters over a corpus, produce an HTML
                         contact sheet, eyeball it, bless winners into
                         Sources/CBNKit/Resources/presets.json.
          import         Convert one image into a .cbn template using a
                         preset (or explicit parameter overrides).
          render         Preview a template as filled / outline / composite
                         PNG.
          validate       Sanity-check a template's structure (used on
                         hand-authored or hand-edited templates).

        See 'cbnc help <subcommand>' or 'cbnc <subcommand> --help' for full
        detail on any one of these — 'tune --help' in particular documents
        the c/d/m filename convention used in its output.
        """,
        subcommands: [
            ImportCommand.self,
            RenderCommand.self,
            ValidateCommand.self,
            TuneCommand.self,
            SuggestCommand.self,
            MakeTestArtCommand.self,
        ]
    )
}

// MARK: - Shared helpers

/// Resolves CLI inputs (files and/or directories) into image URLs. A
/// directory contributes its *direct* contents only — non-recursion is
/// what keeps `TestArt/local/` out of default sweeps (see README).
enum ImageCollection {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    static func collect(from inputs: [String]) throws -> [URL] {
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

enum TemplateIO {
    static func read(_ path: String) throws -> CBNTemplate {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(CBNTemplate.self, from: data)
    }

    static func write(_ template: CBNTemplate, to path: String) throws {
        let encoder = JSONEncoder()
        // Sorted keys keep git diffs of regenerated templates readable.
        encoder.outputFormatting = [.sortedKeys]
        try (try encoder.encode(template))
            .write(to: URL(fileURLWithPath: path))
    }
}

struct ParameterOptions: ParsableArguments {
    @Option(name: .customLong("preset"), help: "Preset id: simple, just-right, detailed.")
    var presetID: String = "just-right"

    @Option(help: "Override the preset's palette size.")
    var colors: Int?

    @Option(
        name: .customLong("min-region-mm"),
        help: "Override the preset's smallest colorable region (dot diameter in mm at display size)."
    )
    var minRegionMM: Double?

    @Option(help: "Override the preset's detail (0...1).")
    var detail: Double?

    func resolve() throws -> ImportParameters {
        guard let preset = PresetStore.preset(id: presetID) else {
            let known = PresetStore.bundled().map(\.id).joined(separator: ", ")
            throw ValidationError("Unknown preset \"\(presetID)\". Known presets: \(known)")
        }
        var parameters = preset.parameters
        if let colors { parameters.colorCount = colors }
        if let minRegionMM { parameters.minRegionMM = minRegionMM }
        if let detail { parameters.detail = detail }
        return parameters
    }
}

// MARK: - import

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Convert a flat-art image into a CBN template."
    )

    @Argument(help: "Path to the source image (PNG, JPEG, …).")
    var image: String

    @OptionGroup var parameters: ParameterOptions

    @Option(name: .shortAndLong, help: "Output template path (default: alongside the image).")
    var output: String?

    @Option(help: "Template title (default: the image's file name).")
    var title: String?

    func run() throws {
        let imageURL = URL(fileURLWithPath: image)
        let raster = try RasterImage.load(from: imageURL)
        let resolved = try parameters.resolve()

        let template = ImportPipeline.importTemplate(
            from: raster,
            title: title ?? imageURL.deletingPathExtension().lastPathComponent,
            parameters: resolved
        )

        let outputPath = output
            ?? imageURL.deletingPathExtension().appendingPathExtension("json").path
        try TemplateIO.write(template, to: outputPath)

        let issues = template.validate()
        print("\(template.title): \(template.regions.count) regions, \(template.palette.count) colors → \(outputPath)")
        if !issues.isEmpty {
            print("WARNING — template has \(issues.count) validation issue(s):")
            for issue in issues { print("  • \(issue)") }
            throw ExitCode(1)
        }
    }
}

// MARK: - render

struct RenderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Render a template to PNG."
    )

    @Argument(help: "Path to a template .json.")
    var template: String

    @Option(help: "filled, outline, or composite.")
    var mode: String = "composite"

    @Option(help: "Render scale multiplier.")
    var scale: Double = 1.0

    @Option(name: .shortAndLong, help: "Output PNG path (default: alongside the template).")
    var output: String?

    func run() throws {
        guard let renderMode = TemplateRenderer.Mode(rawValue: mode) else {
            let known = TemplateRenderer.Mode.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown mode \"\(mode)\". Known modes: \(known)")
        }
        let doc = try TemplateIO.read(template)
        guard let image = TemplateRenderer.render(doc, mode: renderMode, scale: scale) else {
            throw ValidationError("Render failed for \(template)")
        }
        let outputPath = output
            ?? URL(fileURLWithPath: template)
                .deletingPathExtension()
                .appendingPathExtension("\(mode).png").path
        try RasterImage.writePNG(image, to: URL(fileURLWithPath: outputPath))
        print("\(doc.title) → \(outputPath) (\(image.width)×\(image.height))")
    }
}

// MARK: - validate

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Decode a template and report structural issues."
    )

    @Argument(help: "Path to a template .json.")
    var template: String

    func run() throws {
        let doc = try TemplateIO.read(template)
        print("\(doc.title) — \(Int(doc.size.width))×\(Int(doc.size.height)) template units")
        print("Palette (\(doc.palette.count)):")
        for entry in doc.palette {
            print("  \(entry.number). \(entry.name) \(entry.hex)")
        }
        print("Regions: \(doc.regions.count)")

        let issues = doc.validate()
        if issues.isEmpty {
            print("Valid ✓")
        } else {
            print("INVALID — \(issues.count) issue(s):")
            for issue in issues { print("  • \(issue)") }
            throw ExitCode(1)
        }
    }
}
