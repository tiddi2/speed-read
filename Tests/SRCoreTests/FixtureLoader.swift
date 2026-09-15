import Foundation

// Foundation-only helper (no `import Testing` here: the CLT toolchain lacks
// the _Testing_Foundation cross-import overlay, so test files that import
// Testing must not also import Foundation).
enum FixtureLoader {
    struct Pair {
        let name: String
        let input: String
        let expected: String
    }

    /// English parity fixtures (T-4).
    static let englishDirectory = "fixtures"
    /// Norwegian fixtures for the language-aware normalizer.
    static let norwegianDirectory = "fixtures-nb"

    static func pairs(in subdirectory: String = englishDirectory) throws -> [Pair] {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "txt",
                                            subdirectory: subdirectory) else {
            return []
        }
        let inputs = urls
            .filter { $0.lastPathComponent.hasSuffix(".in.txt") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try inputs.map { url in
            let name = String(url.lastPathComponent.dropLast(".in.txt".count))
            let outURL = url.deletingLastPathComponent()
                .appendingPathComponent(name + ".out.txt")
            return Pair(
                name: name,
                input: try String(contentsOf: url, encoding: .utf8),
                expected: try String(contentsOf: outURL, encoding: .utf8)
            )
        }
    }

    static func names(in subdirectory: String = englishDirectory) -> [String] {
        (try? pairs(in: subdirectory).map(\.name)) ?? []
    }

    static func pair(named name: String,
                     in subdirectory: String = englishDirectory) -> Pair? {
        (try? pairs(in: subdirectory))?.first { $0.name == name }
    }
}
