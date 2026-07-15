import ArgumentParser
import CBNKit
import CoreGraphics
import Dispatch
import Foundation

/// The durable tuning workflow: sweep parameter combinations over test
/// images, emit a browsable contact sheet, eyeball, bless winners into
/// Sources/CBNKit/Resources/presets.json. Documented in README.md.
struct TuneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tune",
        abstract: "Sweep pipeline parameters over images and build an HTML contact sheet.",
        discussion: """
        Every combination of --colors × --detail × --min-region-mm is run \
        once per image, producing two PNGs each:
          <name>-c<colors>-d<detail>-m<mm>-composite.png  fills + outlines,
                                                            for judging
                                                            boundary quality
          <name>-c<colors>-d<detail>-m<mm>-outline.png    blank numbered
                                                            template — what
                                                            the child sees

        Filename letters: c = --colors, d = --detail, m = --min-region-mm.

        Parameter effects:
          --colors          Palette size cap — max distinct fill colors
                             after quantization.
          --detail           0...1. Higher keeps region boundaries more
                             faithful to the source; lower simplifies
                             them into calmer, chunkier shapes.
          --min-region-mm    Smallest colorable region, as a dot diameter
                             in millimeters at standard display size (the
                             image's long edge shown at 240mm — an iPad
                             landscape screen / printed page). Smaller
                             regions merge into a neighbor. Rules of
                             thumb: fingertip ≈ 10mm, comfortable tap
                             target ≈ 7mm, a cartoon pupil ≈ 3mm.
        """
    )

    @Argument(help: "Image files and/or directories of images.")
    var inputs: [String]

    @Option(help: "Comma-separated palette sizes to sweep, e.g. 6,10,16. (filename: c)")
    var colors: String = "6,10,16"

    @Option(help: "Comma-separated detail values to sweep, 0...1. DORMANT: 1.0 is the only sensible value (lower only facets boundaries — see ImportParameters.detail); the flag survives until the parameter's planned removal. (filename: d)")
    var detail: String = "1.0"

    @Option(
        name: .customLong("min-region-mm"),
        help: "Comma-separated min region sizes to sweep, as dot diameters in mm at display size. (filename: m)"
    )
    var minRegionMM: String = "10"

    @Option(name: .shortAndLong, help: "Output directory for the contact sheet.")
    var output: String = "tune-output"

    @Option(help: "Thumbnail width in pixels for sheet cells.")
    var cellWidth: Int = 420

    /// One (image, parameter combo) unit of work — independent and
    /// side-effect-isolated (each writes its own PNGs), so the whole batch
    /// is safe to run across cores with no fine-grained coordination.
    private struct Job {
        var imageIndex: Int
        var colorCount: Int
        var detailValue: Double
        var millimeters: Double
    }

    private struct JobResult {
        var baseName: String
        var caption: String
        var detailLine: String
        var fileNames: [String]
        var regionCount: Int
        /// Wall-clock elapsed, not clock()-based CPU time: clock() measures
        /// the whole *process's* CPU time on Darwin, not the calling
        /// thread's, so reading it from several jobs running at once would
        /// double-count concurrently-running siblings into each job's
        /// number. Wall time per job is valid under concurrency because
        /// each thread just timestamps its own start/end.
        var elapsedSeconds: Double
    }

    private enum JobOutcome {
        case success(JobResult)
        case failure(Error)
    }

    func run() throws {
        let colorValues = try parseList(colors, Int.init, flag: "--colors")
        let detailValues = try parseList(detail, Double.init, flag: "--detail")
        let millimeterValues = try parseList(minRegionMM, Double.init, flag: "--min-region-mm")

        let imageURLs = try ImageCollection.collect(from: inputs)
        guard !imageURLs.isEmpty else {
            throw ValidationError("No images found in: \(inputs.joined(separator: ", "))")
        }

        let comboCount = colorValues.count * detailValues.count * millimeterValues.count
        if comboCount * imageURLs.count > 96 {
            print("Note: \(comboCount) combinations × \(imageURLs.count) images = \(comboCount * imageURLs.count) cells — this may take a while.")
        }

        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        // Decode every image once, up front, sequentially — decode is
        // cheap next to the pipeline itself, so there's nothing to gain
        // parallelizing it, and it keeps the parallel section below simple.
        let rasters = try imageURLs.map { try RasterImage.load(from: $0) }
        let stems = imageURLs.map { $0.deletingPathExtension().lastPathComponent }

        // A `let`, not a `var` built via append: captured by value in the
        // concurrent closure below, so Swift 6 can see it never mutates
        // during the parallel section.
        let jobs: [Job] = imageURLs.indices.flatMap { imageIndex in
            colorValues.flatMap { colorCount in
                detailValues.flatMap { detailValue in
                    millimeterValues.map { millimeters in
                        Job(
                            imageIndex: imageIndex,
                            colorCount: colorCount,
                            detailValue: detailValue,
                            millimeters: millimeters
                        )
                    }
                }
            }
        }

        // Every job writes to a distinct index — safe to fan out across
        // cores via concurrentPerform without locks, but JobOutcome carries
        // a non-Sendable `Error`, so the buffer pointer itself can't be
        // proven Sendable mechanically. `nonisolated(unsafe)` is the
        // sanctioned escape hatch for exactly this: we've manually verified
        // the real invariant (indices never collide) that the compiler
        // can't see through raw pointer arithmetic.
        nonisolated(unsafe) let outcomes = UnsafeMutableBufferPointer<JobOutcome?>.allocate(capacity: jobs.count)
        outcomes.initialize(repeating: nil)
        defer { outcomes.deallocate() }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        #if DEBUG
        print("""
        note: this is a DEBUG build — the pipeline runs ~30× slower than release.
              For sweeps, use:  swift run -c release cbnc tune …
        """)
        #endif
        print("Running \(jobs.count) job(s) across up to \(cores) cores…")

        // A single clock() bracket around the whole parallel section is
        // valid (no overlap to double-count here, unlike per-job deltas
        // taken from inside concurrently-running jobs) and gives the true
        // total CPU-seconds consumed by the batch across all threads.
        let cpuStart = clock()
        let wallClockStart = Date()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            do {
                let result = try runJob(
                    job, raster: rasters[job.imageIndex], stem: stems[job.imageIndex], outputURL: outputURL
                )
                outcomes[index] = .success(result)
            } catch {
                outcomes[index] = .failure(error)
            }
        }
        let wallSeconds = Date().timeIntervalSince(wallClockStart)
        let totalCPUSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)

        var results = [JobResult?](repeating: nil, count: jobs.count)
        for index in jobs.indices {
            switch outcomes[index] {
            case .success(let result): results[index] = result
            case .failure(let error): throw error
            case .none: break // unreachable: every index is written exactly once above
            }
        }

        // Rebuild sections in the original image × combo order so output
        // is identical to a sequential run — only the timing differs, not
        // the report.
        var sections: [ContactSheetSection] = []
        var jobIndex = 0
        for imageIndex in imageURLs.indices {
            var cells: [ContactSheetCell] = []
            for _ in 0..<comboCount {
                guard let result = results[jobIndex] else { jobIndex += 1; continue }
                cells.append(
                    ContactSheetCell(
                        caption: result.caption,
                        detailLine: result.detailLine,
                        imageFiles: result.fileNames
                    )
                )
                print("  \(result.baseName): \(result.regionCount) regions (\(formatCPUTime(result.elapsedSeconds)) elapsed)")
                jobIndex += 1
            }
            sections.append(ContactSheetSection(title: stems[imageIndex], cells: cells))
        }

        print("Total CPU time \(formatCPUTime(totalCPUSeconds)) across \(jobs.count) cells, wall time \(formatCPUTime(wallSeconds)) (\(cores) cores available)")

        let sheetURL = outputURL.appendingPathComponent("index.html")
        try ContactSheet.html(sections: sections)
            .write(to: sheetURL, atomically: true, encoding: .utf8)
        print("Contact sheet: \(sheetURL.path)")
        print("Open it, pick winners, bless them into Sources/CBNKit/Resources/presets.json.")
    }

    private func runJob(_ job: Job, raster: RasterImage, stem: String, outputURL: URL) throws -> JobResult {
        let parameters = ImportParameters(
            colorCount: job.colorCount,
            minRegionMM: job.millimeters,
            detail: job.detailValue
        )
        // Date(), not clock(): clock() is process-wide on Darwin, so
        // reading it from several concurrently-running jobs would have
        // each job's "own" number include CPU time spent by its siblings.
        // A wall-clock timestamp is per-call and immune to that.
        let start = Date()
        let template = ImportPipeline.importTemplate(from: raster, title: stem, parameters: parameters)
        let scale = Double(cellWidth) / template.size.width

        let baseName = "\(stem)-c\(job.colorCount)-d\(job.detailValue)-m\(job.millimeters)"
        var fileNames: [String] = []
        for mode in [TemplateRenderer.Mode.composite, .outline] {
            guard let image = TemplateRenderer.render(template, mode: mode, scale: scale) else { continue }
            let fileName = "\(baseName)-\(mode.rawValue).png"
            try RasterImage.writePNG(image, to: outputURL.appendingPathComponent(fileName))
            fileNames.append(fileName)
        }
        let elapsedSeconds = Date().timeIntervalSince(start)

        return JobResult(
            baseName: baseName,
            caption: "colors \(job.colorCount) · detail \(job.detailValue) · min \(job.millimeters)mm",
            detailLine: "\(template.regions.count) regions, \(template.palette.count) colors",
            fileNames: fileNames,
            regionCount: template.regions.count,
            elapsedSeconds: elapsedSeconds
        )
    }

    private func parseList<T>(_ raw: String, _ transform: (String) -> T?, flag: String) throws -> [T] {
        let values = raw.split(separator: ",").compactMap {
            transform($0.trimmingCharacters(in: .whitespaces))
        }
        guard !values.isEmpty else { throw ValidationError("Could not parse \(flag) \"\(raw)\"") }
        return values
    }

}

/// Formats seconds as "mm:ss.ss" — fractional seconds because fast
/// flat-art combos would otherwise all print as an undifferentiated
/// "00:00".
private func formatCPUTime(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let remainder = seconds - Double(minutes * 60)
    return String(format: "%02d:%05.2f", minutes, remainder)
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
