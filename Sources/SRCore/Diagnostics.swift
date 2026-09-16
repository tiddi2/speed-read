import Foundation

/// The logs, and the one command that explains an offline failure.
///
/// sr's logs are content-free by construction (P-5): counts, latencies, HTTP
/// statuses, exception classes and the file:line they came from — never the
/// text being read. That is what makes them safe to hand to someone else, and
/// it is also why a failure can be hard to place from the app alone. This is
/// the one place that collects them, so "what went wrong" is a tab rather than
/// a Terminal session.
public enum Diagnostics {

    // MARK: - Log files

    public struct LogFile: Identifiable, Hashable, Sendable {
        public let id: String
        /// Tab label.
        public let title: String
        /// What writes it, in one line.
        public let summary: String
        public let url: URL
    }

    public static var logDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/sr", isDirectory: true)
    }

    /// The daemon writes its own file rather than going through `SRLog`: it is
    /// a separate Python process, and keeping the two apart means a crashed
    /// daemon cannot take sr's log with it.
    public static let logFiles: [LogFile] = [
        LogFile(id: "app", title: "sr",
                summary: "The app: reads, routing, cache, cost.",
                url: SRLog.logFileURL),
        LogFile(id: "daemon", title: "Offline voice",
                summary: "The local TTS daemon: model loads and synthesis.",
                url: logDirectory.appendingPathComponent("kokoro.log")),
    ]

    /// The tail of a log, or a line saying why there isn't one.
    ///
    /// Reads from the end rather than loading the file: these rotate at 5 MB,
    /// and a settings tab has no business holding that in memory — or asking
    /// anyone to scroll past it to reach the part that matters.
    public static func tail(_ url: URL, maxBytes: Int = 128 << 10) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileManager.default.fileExists(atPath: url.path)
                ? "(cannot read \(url.lastPathComponent))"
                : "(nothing logged yet)"
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        if size > maxBytes {
            try? handle.seek(toOffset: UInt64(size - maxBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if size > maxBytes {
            // Dropping the first (partial) line keeps the view from opening
            // on half a timestamp.
            if let firstBreak = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstBreak)...])
            }
            text = "… earlier lines omitted (showing the last \(maxBytes / 1024) KB) …\n" + text
        }
        return text.isEmpty ? "(nothing logged yet)" : text
    }

    // MARK: - Report

    /// Everything worth pasting into a bug report, in one string.
    ///
    /// Deliberately one blob rather than an attachment: the answer is usually
    /// three lines in one of these files, and a reader who has to open a zip
    /// to find them will not.
    public static func report(
        selfTestOutput: String?,
        settings: SettingsStore = SettingsStore()
    ) -> String {
        var out = ["# sr diagnostics", ""]
        out.append(contentsOf: environmentLines(settings: settings))

        if let selfTestOutput, !selfTestOutput.isEmpty {
            out += ["", "## Offline voice self-test", "", "```", selfTestOutput, "```"]
        }
        for file in logFiles {
            out += ["", "## \(file.title) log — \(file.url.path)", "",
                    "```", tail(file.url, maxBytes: 64 << 10), "```"]
        }
        return out.joined(separator: "\n")
    }

    /// The facts that decide which failures are even possible.
    public static func environmentLines(
        settings: SettingsStore = SettingsStore()
    ) -> [String] {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        let f5 = F5Runtime.shared
        let kokoro = KokoroRuntime.shared
        let voices = f5.voices.voices()

        var lines = [
            "- sr: \(version ?? "?") (\(build ?? "?"))",
            "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- Backend mode: \(settings.backendMode.rawValue)",
            "- English offline voice: \(kokoro.isInstalled ? "installed" : "not installed")",
            "- Norwegian offline voice: \(f5.isInstalled ? "installed" : "not installed")",
        ]
        if f5.isInstalled {
            lines.append("- F5 architecture: \(f5.variant(settings: settings).rawValue)")
            // Names only. A transcript is something the user read aloud, so it
            // stays out of anything meant to be pasted somewhere else.
            lines.append("- Reference voices: "
                + (voices.isEmpty ? "none" : voices.map(\.id).joined(separator: ", ")))
            if let manifest = try? f5.installer.loadValidatedManifest() {
                let bytes = Int64(manifest.weightsBytes)
                    .formatted(.byteCount(style: .file))
                lines.append("- Model: \(manifest.modelRepo)@\(manifest.modelRevision.prefix(12))"
                    + " (\(bytes), from \(manifest.weightsSource))")
            } else {
                lines.append("- Model: manifest missing or no longer matches the bundled pins")
            }
        }
        return lines
    }

    // MARK: - Self-test

    public enum SelfTestEvent: Sendable {
        case output(String)
        /// Process exit status; -1 when it could not be started at all.
        case finished(Int32)
    }

    /// Run the daemon's `--self-test` and stream its output as it arrives.
    ///
    /// The daemon never relays an exception's message, because it could quote
    /// the text being read. `--self-test` reads a sentence of its own instead,
    /// so there is nothing to protect and it can print the failure whole —
    /// which is the difference between "RuntimeError" and knowing which file
    /// is damaged. Running it from here rather than from a terminal also means
    /// it runs against the paths and architecture sr itself would use.
    ///
    /// A stream rather than a callback because order is the whole point: a
    /// traceback delivered out of sequence is not a traceback.
    public static func offlineSelfTest(
        paths: KokoroPaths = .standard,
        f5: F5Runtime = .shared,
        settings: SettingsStore = SettingsStore(),
        timeout: TimeInterval = 600
    ) -> AsyncStream<SelfTestEvent> {
        // Resolved on the caller's side, before anything is spawned: the child
        // gets exactly what the daemon supervisor would hand it, so this tests
        // the install that is failing rather than whatever the script's own
        // fallbacks resolve to.
        var environment: [String: String] = [:]
        if f5.isInstalled, let arch = f5.arch(settings: settings) {
            environment["SR_F5_MODEL_PATH"] = f5.paths.modelDir.path
            environment["SR_F5_VOCODER_PATH"] = f5.paths.vocoderDir.path
            environment["SR_F5_VOICES_PATH"] = f5.paths.voicesDir.path
            environment["SR_F5_ARCH"] = arch.environmentJSON
        }
        let python = paths.venvPython
        let script = paths.daemonScript
        let resolved = environment

        return AsyncStream { continuation in
            let work = Task {
                let status = await run(
                    python: python, script: script, environment: resolved,
                    timeout: timeout,
                    yield: { continuation.yield(.output($0)) })
                continuation.yield(.finished(status))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func run(
        python: URL,
        script: URL,
        environment: [String: String],
        timeout: TimeInterval,
        yield: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: python.path) else {
            yield("No offline voice is installed — install one in Settings → General.\n")
            return -1
        }
        guard fm.fileExists(atPath: script.path) else {
            yield("The daemon script is missing — reinstall the offline voice in Settings → General.\n")
            return -1
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--self-test"]
        process.environment = LocalRuntimeInstaller.scrubbed(
            ProcessInfo.processInfo.environment, adding: environment)
        process.standardInput = FileHandle.nullDevice

        // One pipe for both streams: a traceback on stderr interleaved with
        // the progress lines on stdout is the story in the order it happened.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Armed before run(): a handler assigned after an instant exec failure
        // never fires, and this would wait forever.
        let terminated = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            yield(String(decoding: data, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            yield("Could not start the self-test: \(error.localizedDescription)\n")
            return -1
        }

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            guard process.isRunning else { return }
            yield("\nStopped after \(Int(timeout))s without finishing.\n")
            process.terminate()
            try await Task.sleep(for: .seconds(5))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }

        await withTaskCancellationHandler {
            for await _ in terminated { break }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        // Whatever landed between the last readability callback and exit.
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            yield(String(decoding: rest, as: UTF8.self))
        }
        return process.terminationStatus
    }
}
