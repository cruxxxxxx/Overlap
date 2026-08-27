import Foundation
import CoreGraphics

// Headless Venn selection validator. Reads the dump the app writes when run
// with OVERLAP_VENN_DUMP=1, replays the exact (deterministic) layout via the
// shared VennLayout, and reports — per selected region — whether it can be
// painted and where its badge lands. No screenshots, no eyeballing.
//
// Build & run:
//   swiftc Sources/VennLayout.swift scripts/validate-venn.swift -o /tmp/vv
//   /tmp/vv                       # default dump path
//   /tmp/vv path/to/venn-dump.json 1400 900

@main enum Validator {
static func main() {
let args = CommandLine.arguments
let dumpPath: String = {
    if args.count > 1 { return args[1] }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("Overlap/venn-dump.json").path
}()
let canvas = CGSize(
    width: args.count > 2 ? Double(args[2]) ?? 1400 : 1400,
    height: args.count > 3 ? Double(args[3]) ?? 900 : 900)

guard let data = FileManager.default.contents(atPath: dumpPath),
      let dump = try? JSONDecoder().decode(VennDump.self, from: data) else {
    FileHandle.standardError.write(Data("no dump at \(dumpPath) (run the app with OVERLAP_VENN_DUMP=1)\n".utf8))
    exit(1)
}

print("venn-dump: \(dumpPath)  canvas \(Int(canvas.width))×\(Int(canvas.height))")
let maps = dump.regionMaps
var totalBad = 0
for (di, diagram) in dump.diagrams.enumerated() {
    let report = VennLayout.validate(
        tags: diagram.tags, totals: diagram.totals,
        regions: maps[di], selected: Set(diagram.selected), canvas: canvas)
    print("\nDiagram \(di + 1): \(diagram.tags.count) sets — \(report.selected) selected, "
        + "\(report.unpaintable) unpaintable, \(report.badgesInVoid) badge(s) in void")
    for c in report.checks {
        let mark = c.paintable ? "OK  " : (c.badgeInCircle ? "warn" : "VOID")
        let why = c.reason.isEmpty ? "pole" : c.reason
        print(String(format: "  [%@] %-26@ %3d  %@",
                     mark, c.label as NSString, c.count, why as NSString))
    }
    totalBad += report.badgesInVoid
}
print(totalBad == 0
      ? "\n✓ every selected region has a sensible marker"
      : "\n⚠ \(totalBad) selected region(s) render in dead space — the layout can't place them near their sets")
exit(totalBad == 0 ? 0 : 2)
}
}
