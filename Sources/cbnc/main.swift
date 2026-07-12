import CBNKit
import Foundation

// M0 stub: decode + validate a template from Terminal. The real pipeline,
// argument parsing (swift-argument-parser), and the `tune` contact-sheet
// workflow arrive in M1.

let arguments = CommandLine.arguments.dropFirst()

guard let path = arguments.first, arguments.count == 1 else {
    print(
        """
        cbnc — Color By Numbers pipeline CLI (M0 stub)

        Usage: cbnc <template.json>
          Decodes and validates a CBN template, printing a summary.
        """
    )
    exit(64) // EX_USAGE
}

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let template = try JSONDecoder().decode(CBNTemplate.self, from: data)

    print("\(template.title) — \(Int(template.size.width))×\(Int(template.size.height)) template units")
    print("Palette (\(template.palette.count)):")
    for entry in template.palette {
        print("  \(entry.number). \(entry.name) \(entry.hex)")
    }
    print("Regions: \(template.regions.count)")

    let issues = template.validate()
    if issues.isEmpty {
        print("Valid ✓")
    } else {
        print("INVALID — \(issues.count) issue(s):")
        for issue in issues {
            print("  • \(issue)")
        }
        exit(1)
    }
} catch {
    print("Failed to read template: \(error.localizedDescription)")
    exit(1)
}
