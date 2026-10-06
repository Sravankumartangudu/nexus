// Brain — natural-language understanding for Nexus, via the local `claude` CLI.
//
// The fast keyword parser in Voice.swift (Commands.run) handles the obvious cases instantly and
// offline ("open Jarvis", "stop all", "status"). Anything it can't confidently parse — a question
// about how the agents are doing, or a casually phrased request — is handed here. Nexus launches
// Claude once (warm, resumable), hands it a live snapshot of the fleet, and lets it either answer
// the question or act on the fleet by emitting a directive like [[do: open all]], which Nexus runs
// back through Commands.run. Same approach as Jarvis's Brain, trimmed to just fleet control.

import AppKit
import Foundation

final class Brain {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private struct Turn {
        let onText: (String) -> Void
        let done: (Result<Void, Error>) -> Void
    }

    private var proc: Process?
    private var stdin: FileHandle?
    private var turn: Turn?
    private var stderrTail = ""
    private var resumed = false
    private var completedTurns = 0
    private var pendingPrompt: String?

    /// Whether the Claude CLI is on PATH; if not, Nexus stays with its keyword parser only.
    static let available: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", #"export PATH="$HOME/.local/bin:$HOME/.devbar/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; command -v claude >/dev/null"#]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }()

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexus", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // MARK: Persona + live fleet state

    private static let persona = """
    You are the voice of Nexus, the "head" of a small fleet of macOS apps (called agents) that the \
    user builds and runs — Jarvis, OrgCS Pulse, Water Buddy, Animi, Sev1 Siren, and others. Nexus \
    watches them all and can start, stop, restart or rebuild any of them.

    You are spoken aloud, so reply in one or two short, plain sentences. No markdown, no lists, no \
    emoji, no stage directions. Use each agent's real name.

    You can act on the fleet. To do something, put a directive on its own in your reply, for example:
    [[do: open Jarvis]]  [[do: restart OrgCS Pulse]]  [[do: stop all]]  [[do: rebuild all]]  [[do: open all]]
    The directive is executed and never spoken, so also say a short confirmation. Only act when the \
    user actually asks you to; for a plain question just answer from the fleet state you are given. \
    The text after "do:" is a command for the fleet, so phrase it as a verb plus an agent name or "all".
    """

    /// A compact, current description of every agent, refreshed into the system prompt on change.
    static func fleetSnapshot() -> String {
        Fleet.shared.discover(); Fleet.shared.refresh()
        let apps = Fleet.shared.apps
        guard !apps.isEmpty else { return "(no agents discovered yet)" }
        let lines = apps.map { a -> String in
            let state = a.status.word
            let extra = a.detail.isEmpty ? "" : " — \(a.detail)"
            return "• \(a.name): \(state)\(extra)"
        }
        return "\(Fleet.shared.runningCount) of \(apps.count) running.\n" + lines.joined(separator: "\n")
    }

    // MARK: Lifecycle

    func warmUp() { if Brain.available, proc == nil { launch() } }

    func reset() { Settings.brainSessionId = nil; cancel(); if Brain.available { launch() } }

    func cancel() { turn = nil; proc?.terminate(); proc = nil; stdin = nil }

    /// Ask Claude. `onText` streams spoken chunks; `done` fires once. Both on the main queue.
    /// A fresh fleet snapshot is prepended to every question so the brain always sees current state.
    func ask(_ prompt: String, onText: @escaping (String) -> Void, done: @escaping (Result<Void, Error>) -> Void) {
        guard Brain.available else { done(.failure(Failure(message: ""))); return }
        if turn != nil { cancel() }
        if proc == nil { launch() }
        guard proc != nil else { done(.failure(Failure(message: "Couldn't start Claude."))); return }
        turn = Turn(onText: onText, done: done)
        send("Fleet right now:\n\(Brain.fleetSnapshot())\n\nThe user said: \"\(prompt)\"")
    }

    private func send(_ prompt: String) {
        guard let stdin else { finish(.failure(Failure(message: "Couldn't start Claude."))); return }
        pendingPrompt = prompt
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var line = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
        line.append(0x0A)
        do { try stdin.write(contentsOf: line) } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        let t = turn; turn = nil; pendingPrompt = nil
        t?.done(result)
    }

    /// Copy just the auth keys from ~/.claude/settings.json so Nexus signs in like Terminal does,
    /// even though we launch with `--setting-sources project` for speed.
    private static func writeAuthSettings() -> URL {
        let out = dir.appendingPathComponent("auth-settings.json")
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        var auth: [String: Any] = [:]
        if let data = try? Data(contentsOf: user),
           let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["apiKeyHelper", "env", "awsAuthRefresh", "awsCredentialExport", "forceLoginMethod"] {
                auth[key] = all[key]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: auth) {
            try? data.write(to: out, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        }
        return out
    }

    /// A `claude` process run through a login shell so it sees Terminal's PATH/env.
    private static func claude(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc",
                       #"export PATH="$HOME/.local/bin:$HOME/.devbar/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; exec claude "$@""#,
                       "nexus"] + args
        p.currentDirectoryURL = Brain.dir
        var env = ProcessInfo.processInfo.environment.filter {
            !["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"].contains($0.key)
        }
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        p.environment = env
        return p
    }

    private func launch() {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--disable-slash-commands", "--setting-sources", "project",
                    "--settings", Brain.writeAuthSettings().path,
                    "--append-system-prompt", Brain.persona,
                    "--model", Settings.brainModel]
        resumed = Settings.brainSessionId != nil
        if let id = Settings.brainSessionId { args += ["--resume", id] }

        let p = Brain.claude(args)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { self?.stderrTail = String(((self?.stderrTail ?? "") + s).suffix(300)) }
        }
        p.terminationHandler = { [weak self] dead in
            DispatchQueue.main.async {
                guard let self, self.proc === dead else { return }
                self.proc = nil; self.stdin = nil
                if self.resumed && self.completedTurns == 0 {
                    NSLog("Nexus: couldn't resume Claude session, starting fresh")
                    Settings.brainSessionId = nil
                    self.launch()
                    if self.turn != nil, let prompt = self.pendingPrompt { self.send(prompt) }
                    return
                }
                let err = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finish(.failure(Failure(message: err.isEmpty ? "Claude exited (\(dead.terminationStatus))." : err)))
            }
        }

        do { try p.run() } catch { NSLog("Nexus: Claude launch failed: \(error)"); return }
        proc = p
        stdin = inPipe.fileHandleForWriting
        completedTurns = 0
        stderrTail = ""

        let reader = outPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { guard let self, self.proc === p else { return }; self.handle(obj) }
                }
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        if let id = event["session_id"] as? String, !id.isEmpty { Settings.brainSessionId = id }
        switch event["type"] as? String {
        case "assistant":
            guard let msg = event["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { return }
            for b in blocks where b["type"] as? String == "text" {
                if let text = b["text"] as? String, !text.isEmpty { turn?.onText(text) }
            }
        case "result":
            completedTurns += 1
            if event["is_error"] as? Bool == true {
                finish(.failure(Failure(message: (event["result"] as? String) ?? "Claude reported an error.")))
            } else {
                finish(.success(()))
            }
        default: break
        }
    }

    /// Pulls [[do: …]] directives out of a reply, returning the clean spoken text and the commands.
    static func directives(in text: String) -> (spoken: String, commands: [String]) {
        var commands: [String] = []
        var spoken = text
        let pattern = #"\[\[\s*do:\s*(.+?)\s*\]\]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return (text, []) }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches.reversed() {
            if let cmd = Range(m.range(at: 1), in: text) { commands.insert(String(text[cmd]), at: 0) }
            if let whole = Range(m.range, in: spoken) { spoken.replaceSubrange(whole, with: "") }
        }
        spoken = spoken.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (spoken, commands)
    }
}
