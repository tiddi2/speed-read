import AppKit

/// The app icon, and the Dock presence it is drawn into.
///
/// `sr` ships as an `LSUIElement` (menu-bar) app so launching it never steals
/// focus or flashes a Dock tile before preferences are read. The Dock icon is
/// therefore switched on at runtime by raising the activation policy —
/// permanently when "Show sr in the Dock" is on, and temporarily while the
/// Settings window is open (an accessory app never truly activates, so the
/// shortcut recorders would otherwise receive no key events).
enum AppIcon {
    /// `sr.icns` from the bundle, falling back to the repo copy when running
    /// from `swift run` (no bundle, so no `CFBundleIconFile` either).
    static func image() -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "sr", withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources/sr.icns"),
        ]
        for url in candidates.compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    /// Assign the icon explicitly rather than leaving it to `Info.plist`.
    /// The Dock caches icons per bundle path and happily keeps showing a
    /// stale (or generic) tile after an in-place update; setting
    /// `applicationIconImage` overrides that cache for the running app.
    static func apply() {
        guard let image = image() else { return }
        NSApp.applicationIconImage = image
    }
}
