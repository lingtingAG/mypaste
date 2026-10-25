import AppKit
import MyPasteUI

@main
struct SnapshotApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/snapshots"
        let directory = URL(fileURLWithPath: outputPath)
        do {
            let urls = try DebugSnapshots.renderStudio(to: directory)
            print("Wrote \(urls.count) snapshots to \(directory.path)")
        } catch {
            fputs("Snapshot error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
