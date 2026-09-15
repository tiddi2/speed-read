import CryptoKit
import Foundation

/// One custom pronunciation, in the shape ElevenLabs' pronunciation
/// dictionaries use (F-13).
///
/// Two kinds, because they reach the voice by different routes:
///
/// - `.alias` respells the word ("Nguyen" → "Nwin"). sr applies these itself,
///   right after normalization, so they work on **every** model and on the
///   offline voice, they cost nothing extra, and they never leave the Mac.
/// - `.phoneme` gives an exact IPA / CMU Arpabet transcription. Only
///   ElevenLabs can act on that, and only on the models listed in
///   `ElevenLabsProvider.phonemeCapableModelIDs`; sr uploads those rules as a
///   pronunciation dictionary and references it on the request.
///
/// Both spellings are kept on the same value so switching kind in the editor
/// does not throw away what was typed for the other one.
public struct PronunciationRule: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case alias, phoneme
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .alias: return "Respell"
            case .phoneme: return "Phonemes"
            }
        }
    }

    /// Phonetic alphabets ElevenLabs accepts for `.phoneme` rules.
    public enum Alphabet: String, Codable, Sendable, CaseIterable, Identifiable {
        case ipa, cmu
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .ipa: return "IPA"
            case .cmu: return "CMU Arpabet"
            }
        }
    }

    public var id: UUID
    /// The word or phrase as it appears in the text being read.
    public var stringToReplace: String
    public var kind: Kind
    /// Replacement spelling for `.alias`.
    public var alias: String
    /// Transcription for `.phoneme`, in `alphabet`.
    public var phoneme: String
    public var alphabet: Alphabet
    /// Off keeps a rule around without applying it — the way you check
    /// whether a pronunciation is the thing that sounds wrong.
    public var isEnabled: Bool
    /// Match the capitalization exactly. Off (the default) makes "nato" and
    /// "NATO" the same rule; on keeps "US" from catching every "us".
    public var matchCase: Bool

    public init(id: UUID = UUID(),
                stringToReplace: String = "",
                kind: Kind = .alias,
                alias: String = "",
                phoneme: String = "",
                alphabet: Alphabet = .ipa,
                isEnabled: Bool = true,
                matchCase: Bool = false) {
        self.id = id
        self.stringToReplace = stringToReplace
        self.kind = kind
        self.alias = alias
        self.phoneme = phoneme
        self.alphabet = alphabet
        self.isEnabled = isEnabled
        self.matchCase = matchCase
    }

    /// Older files predate `matchCase`; decode them as case-insensitive.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        stringToReplace = try container.decodeIfPresent(String.self, forKey: .stringToReplace) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .alias
        alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        phoneme = try container.decodeIfPresent(String.self, forKey: .phoneme) ?? ""
        alphabet = try container.decodeIfPresent(Alphabet.self, forKey: .alphabet) ?? .ipa
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        matchCase = try container.decodeIfPresent(Bool.self, forKey: .matchCase) ?? false
    }

    /// What the rule actually does, as one line, for the list row.
    public var replacementSummary: String {
        switch kind {
        case .alias: return alias
        case .phoneme: return phoneme
        }
    }

    /// A rule with nothing to match, or nothing to say, is not applied and
    /// is never uploaded.
    public var isComplete: Bool {
        !stringToReplace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replacementSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isActive: Bool { isEnabled && isComplete }
}

/// A locator for one uploaded ElevenLabs pronunciation dictionary.
public struct PronunciationDictionaryLocator: Hashable, Sendable {
    public let dictionaryID: String
    public let versionID: String

    public init(dictionaryID: String, versionID: String) {
        self.dictionaryID = dictionaryID
        self.versionID = versionID
    }
}

/// Per-language custom pronunciations, and the alias rewriting sr applies
/// itself.
///
/// Stored as JSON in `~/Library/Application Support/sr/pronunciations.json`
/// (plain user data — a list of words and how to say them, so no Keychain
/// and no defaults database). Read from the main actor while Settings is
/// open and from detached preparation tasks mid-read, so the in-memory copy
/// is lock-guarded and disk writes are write-through.
public final class PronunciationStore: @unchecked Sendable {
    public static let shared = PronunciationStore()

    private let lock = NSLock()
    private let fileURL: URL
    private let defaults: UserDefaults
    private var rulesByLanguage: [String: [PronunciationRule]]

    public init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/pronunciations.json")
        self.defaults = defaults
        self.rulesByLanguage = Self.load(from: self.fileURL)
    }

    private static func load(from url: URL) -> [String: [PronunciationRule]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [PronunciationRule]].self, from: data)) ?? [:]
    }

    // MARK: - Rules

    public func rules(for language: SpeechLanguage) -> [PronunciationRule] {
        lock.withLock { rulesByLanguage[language.rawValue] ?? [] }
    }

    public func setRules(_ rules: [PronunciationRule], for language: SpeechLanguage) {
        let snapshot: [String: [PronunciationRule]] = lock.withLock {
            rulesByLanguage[language.rawValue] = rules
            return rulesByLanguage
        }
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: [PronunciationRule]]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: fileURL, options: .atomic)
        // Owner-only, like the audio cache: the file is a list of words you
        // read often, which is not something other accounts on this Mac need.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Alias rewriting (applied locally, every backend)

    public func aliasRules(for language: SpeechLanguage) -> [PronunciationRule] {
        rules(for: language).filter { $0.isActive && $0.kind == .alias }
    }

    public func phonemeRules(for language: SpeechLanguage) -> [PronunciationRule] {
        rules(for: language).filter { $0.isActive && $0.kind == .phoneme }
    }

    /// Rewrite every enabled alias rule in `text`.
    ///
    /// Runs after normalization and before chunking, so the respelled text is
    /// what gets hashed into the audio cache key: changing a pronunciation
    /// invalidates exactly the sentences that contained the word, and nothing
    /// else. Longer matches win, so "New York City" beats "New York", and the
    /// text is walked once — no rule ever rewrites another's output.
    public func applyAliases(to text: String, language: SpeechLanguage) -> String {
        Self.applyAliases(to: text, rules: aliasRules(for: language))
    }

    public static func applyAliases(to text: String, rules: [PronunciationRule]) -> String {
        let ordered = rules
            .filter(\.isActive)
            .sorted { $0.stringToReplace.count > $1.stringToReplace.count }
        guard !ordered.isEmpty else { return text }

        // One alternation over every needle, walked once — not rule after
        // rule over the whole text. Applying rules in sequence would let a
        // later one rewrite an earlier one's output ("a" → "b" followed by
        // "b" → "c" would end up saying "c"), which is never what a
        // dictionary means. Alternation is leftmost-first, so the
        // longest-first ordering above doubles as the precedence rule.
        var alternatives: [String] = []
        for rule in ordered {
            guard let pattern = pattern(for: rule.stringToReplace,
                                        matchCase: rule.matchCase) else { return text }
            alternatives.append("(" + pattern + ")")
        }
        guard let regex = try? NSRegularExpression(
            pattern: alternatives.joined(separator: "|")) else { return text }

        let source = text as NSString
        var result = ""
        var consumed = 0
        regex.enumerateMatches(
            in: text, range: NSRange(location: 0, length: source.length)
        ) { match, _, _ in
            guard let match else { return }
            var matched: PronunciationRule?
            for index in 1...ordered.count
            where match.range(at: index).location != NSNotFound {
                matched = ordered[index - 1]
                break
            }
            guard let matched else { return }
            result += source.substring(
                with: NSRange(location: consumed,
                              length: match.range.location - consumed))
            result += matched.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            consumed = match.range.location + match.range.length
        }
        result += source.substring(from: consumed)
        return result
    }

    /// Word-bounded where the needle's own edges are word characters, so
    /// "ion" does not fire inside "station", but "C++" still matches. Case
    /// sensitivity rides on an inline flag rather than a regex option, so
    /// needles that disagree about it can still share one alternation.
    private static func pattern(for needle: String, matchCase: Bool) -> String? {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var body = NSRegularExpression.escapedPattern(for: trimmed)
        if trimmed.first.map(isWordCharacter) == true { body = #"\b"# + body }
        if trimmed.last.map(isWordCharacter) == true { body += #"\b"# }
        return matchCase ? "(?-i:\(body))" : "(?i:\(body))"
    }

    private static func regex(for needle: String, matchCase: Bool) -> NSRegularExpression? {
        guard let pattern = pattern(for: needle, matchCase: matchCase) else { return nil }
        return try? NSRegularExpression(pattern: pattern)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: - Inline markup (auditioning a rule before it is saved)

    /// Apply one rule to a short phrase using ElevenLabs' inline markup.
    ///
    /// This is how the pronunciation editor auditions a rule you are still
    /// typing. A respelling is just the substitution it always is; a phoneme
    /// rule becomes a `<phoneme>` tag, which the same models honour as a
    /// dictionary entry — so the rule can be heard before it is saved, and
    /// without uploading anything.
    ///
    /// Reads themselves do *not* go through this: inline tags are billed as
    /// text and a chunk boundary could cut one in half. They use the
    /// uploaded dictionary instead.
    public static func applyInline(_ rule: PronunciationRule, to text: String) -> String {
        switch rule.kind {
        case .alias:
            return applyAliases(to: text, rules: [rule])
        case .phoneme:
            let needle = rule.stringToReplace.trimmingCharacters(in: .whitespacesAndNewlines)
            let phoneme = rule.phoneme.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, !phoneme.isEmpty else { return text }
            guard let regex = regex(for: needle, matchCase: rule.matchCase) else { return text }
            let tag = "<phoneme alphabet=\"\(rule.alphabet.rawValue)\" ph=\"\(escapeXML(phoneme))\">"
                + escapeXML(needle) + "</phoneme>"
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: tag))
        }
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - ElevenLabs dictionary locators (phoneme rules only)

    /// Identity of the phoneme rules currently configured for a language.
    /// Empty when there are none. A stored locator is only usable while its
    /// fingerprint still matches — that is what keeps an edited rule from
    /// being read with the previous dictionary (or from a cache entry made
    /// under it).
    public func phonemeFingerprint(for language: SpeechLanguage) -> String {
        let rules = phonemeRules(for: language)
        guard !rules.isEmpty else { return "" }
        var hasher = SHA256()
        for rule in rules {
            let material = [rule.stringToReplace, rule.phoneme, rule.alphabet.rawValue]
                .joined(separator: "\u{1F}")
            hasher.update(data: Data(material.utf8))
            hasher.update(data: Data([0x1E]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func locatorKey(_ language: SpeechLanguage) -> String {
        "pronunciationLocator.\(language.rawValue)"
    }

    /// The locator to send for `language`, or nil when there is nothing to
    /// send or the upload has not caught up with the current rules yet.
    public func locator(for language: SpeechLanguage) -> PronunciationDictionaryLocator? {
        let fingerprint = phonemeFingerprint(for: language)
        guard !fingerprint.isEmpty else { return nil }
        guard let stored = defaults.stringArray(forKey: locatorKey(language)),
              stored.count == 3, stored[2] == fingerprint else { return nil }
        return PronunciationDictionaryLocator(dictionaryID: stored[0], versionID: stored[1])
    }

    public func storeLocator(_ locator: PronunciationDictionaryLocator,
                             fingerprint: String,
                             for language: SpeechLanguage) {
        defaults.set([locator.dictionaryID, locator.versionID, fingerprint],
                     forKey: locatorKey(language))
    }

    public func clearLocator(for language: SpeechLanguage) {
        defaults.removeObject(forKey: locatorKey(language))
    }

    /// True when `language` has phoneme rules that have not been uploaded
    /// (or were edited since the last upload).
    public func needsPhonemeSync(for language: SpeechLanguage) -> Bool {
        !phonemeFingerprint(for: language).isEmpty && locator(for: language) == nil
    }
}

/// Uploads phoneme rules to ElevenLabs and records the locator they came
/// back with.
///
/// Phoneme transcriptions are the one part of a pronunciation dictionary sr
/// cannot honour on its own, so this is the only thing here that touches the
/// network — and it sends the words being corrected, which is why callers
/// skip it in Local-Only mode.
public enum PronunciationSyncer {
    public enum Outcome: Sendable, Equatable {
        /// Nothing to upload, or the current rules are already uploaded.
        case upToDate
        case uploaded
        case failed(String)
    }

    @discardableResult
    public static func sync(language: SpeechLanguage,
                            store: PronunciationStore = .shared) async -> Outcome {
        let fingerprint = store.phonemeFingerprint(for: language)
        guard !fingerprint.isEmpty else {
            store.clearLocator(for: language)
            return .upToDate
        }
        guard store.locator(for: language) == nil else { return .upToDate }

        let rules = store.phonemeRules(for: language)
        do {
            let locator = try await ElevenLabsProvider().createPronunciationDictionary(
                name: "sr — \(language.displayName)", rules: rules)
            store.storeLocator(locator, fingerprint: fingerprint, for: language)
            SRLog.event("pronunciation.uploaded", [
                "lang": language.rawValue,
                "rules": String(rules.count),
            ])
            return .uploaded
        } catch let error as TTSError {
            SRLog.error("pronunciation.upload", [
                "lang": language.rawValue,
                "error": error.logCategory,
            ])
            return .failed(message(for: error))
        } catch {
            // A decode failure lands here: the request succeeded but the
            // response was not the shape this build expects.
            SRLog.error("pronunciation.upload", ["lang": language.rawValue])
            return .failed("ElevenLabs returned an unexpected response.")
        }
    }

    private static func message(for error: TTSError) -> String {
        switch error {
        case .missingAPIKey:
            return "No ElevenLabs API key — add one in Settings → Cost."
        case .http(401, _), .http(403, _):
            return "ElevenLabs auth failed — check your API key."
        case .http(let status, _):
            return "ElevenLabs rejected the dictionary (HTTP \(status))."
        case .network:
            return "Could not reach ElevenLabs."
        default:
            return "Upload failed."
        }
    }
}
