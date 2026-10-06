// Nexus voice control — a Jarvis-style "wake word + command" ear plus a mouth for confirmations.
//
// Nexus is the head of the fleet, so its voice job is simple and local: it listens for its wake
// word ("Nexus" by default, plus any names you add), then runs a fleet command — open an agent,
// activate everyone, stop one, rebuild, or read the status. Because Nexus can start the other
// agents on command, those apps don't each need to launch at login; Nexus wakes them when asked.
//
// Ears / Mouth / Sound here mirror Jarvis's Voice.swift so the two feel the same, but this file is
// self-contained (no Brain / custom language model) and routes straight to Fleet + Actions.

import AppKit
import AVFoundation
import Speech

// MARK: - "Sounds like" helpers (trimmed from Jarvis's People)

enum Sound {
    /// A rough phonetic key so "Nexus" still matches "Nexas"/"Nexis", "Jarvis" still matches "Jervis".
    static func key(_ s: String) -> String {
        var k = s.lowercased().filter(\.isLetter)
        for (from, to) in [("ph","f"),("bh","b"),("dh","d"),("th","t"),("kh","k"),("gh","g"),
                           ("sh","s"),("ch","c"),("ck","k"),("q","k"),("x","ks"),("w","v"),("z","j"),("y","i")] {
            k = k.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for c in k { let ch = "aeiou".contains(c) ? Character("a") : c; if out.last != ch { out.append(ch) } }
        return out
    }

    /// 0…1 similarity from the edit distance between two sound keys.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    private static var englishCache: [String: Bool] = [:]
    static func isEnglish(_ word: String) -> Bool {
        if let known = englishCache[word] { return known }
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                                       inSpellDocumentWithTag: 0, wordCount: nil)
        let eng = miss.location == NSNotFound
        englishCache[word] = eng
        return eng
    }

    /// Is `heard` the wake word `name`? Exact sound key, or (for longer names) a close non-word.
    static func isWakeWord(_ heard: String, _ name: String, exact: Bool = false) -> Bool {
        let k = key(heard), target = key(name)
        if k == target { return true }
        return !exact && target.count >= 4 && k.first == target.first
            && similarity(k, target) >= 0.8 && !isEnglish(heard)
    }
}

// MARK: - Ears (wake word + command capture)

final class Ears {
    var onWake: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onCommand: ((String) -> Void)?
    var onGiveUp: (() -> Void)?
    var onLevel: ((Float) -> Void)?   // mic loudness 0…~0.3, for the orb

    private enum Capture { case none, afterWake, direct }

    static let accents = [("en-US","English (US)"),("en-IN","English (India)"),("en-GB","English (UK)"),
                          ("en-AU","English (Australia)"),("en-CA","English (Canada)")]
        .filter { SFSpeechRecognizer(locale: Locale(identifier: $0.0))?.supportsOnDeviceRecognition == true }

    static var locale: Locale {
        if let id = Settings.speechLocale { return Locale(identifier: id) }
        let india = Locale.current.region?.identifier == "IN" && accents.contains { $0.0 == "en-IN" }
        return Locale(identifier: india ? "en-IN" : "en-US")
    }

    private var recognizer = SFSpeechRecognizer(locale: Ears.locale)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var capture = Capture.none
    private var command = ""
    private var silenceTimer: Timer?
    private var recycleTimer: Timer?
    private var listenUntil = Date()
    private var finalizing = false
    private(set) var running = false

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            let mode = self.capture, remaining = self.listenUntil.timeIntervalSinceNow
            self.stop(); self.start()
            if self.running && mode != .none { self.beginTask(mode); self.armSilence(max(remaining, 3)) }
            else if mode != .none { self.onGiveUp?() }
        }
    }

    func reload() { let was = running; stop(); recognizer = SFSpeechRecognizer(locale: Ears.locale); if was { start() } }

    var available: Bool { recognizer?.isAvailable ?? false }

    /// Contextual vocabulary: the wake words, the agent names, and the command verbs.
    private var vocabulary: [String] {
        var v = Settings.wakeNames + Settings.wakeNames.map { "Hey " + $0 }
        v += Fleet.shared.apps.map(\.name)
        v += ["open","start","launch","activate","wake up","boot","run","stop","quit","close",
              "shut down","restart","relaunch","rebuild","build","status","report","dashboard",
              "all","everything","everyone","agents"]
        return Array(v.prefix(100))
    }

    /// Text after the last wake word (any of Settings.wakeNames), or nil if none is present.
    static func afterWakeWord(_ text: String) -> String? {
        var words: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { _, r, _, _ in words.append(r) }
        let names = Settings.wakeNames.map { ($0, $0.split(separator: " ").count) }
        for end in words.indices.reversed() {
            for (name, n) in names {
                for len in [n, n + 1] where end - len + 1 >= 0 {
                    let heard = String(text[words[end - len + 1].lowerBound..<words[end].upperBound])
                    guard Sound.isWakeWord(heard, name, exact: len > n) else { continue }
                    return String(text[words[end].upperBound...])
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                }
            }
        }
        return nil
    }

    func start() {
        guard !running, available else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            if self?.finalizing == false { self?.request?.append(buf) }
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(buf.frameLength))
            DispatchQueue.main.async { self?.onLevel?(rms) }
        }
        engine.prepare()
        do { try engine.start() } catch { NSLog("Nexus: audio engine failed: \(error)"); return }
        running = true
        beginTask(.none)
    }

    func stop() {
        running = false; finalizing = false
        silenceTimer?.invalidate(); recycleTimer?.invalidate()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
    }

    func listenNow(timeout: TimeInterval = 6) {
        if !running { start() }; guard running else { return }
        beginTask(.direct); armSilence(timeout)
    }

    func reset() { if running { beginTask(.none) } }

    private func beginTask(_ mode: Capture) {
        silenceTimer?.invalidate(); task?.cancel(); request?.endAudio()
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req; capture = mode; command = ""; finalizing = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handle(req, result, error) }
        }
        recycleTimer?.invalidate()
        recycleTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self, self.running, self.capture == .none else { return }
            self.beginTask(.none)
        }
    }

    private func handle(_ req: SFSpeechAudioBufferRecognitionRequest,
                        _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard req === request, running else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            switch capture {
            case .none:
                if let rest = Ears.afterWakeWord(text) { capture = .afterWake; onWake?(); update(rest) }
            case .afterWake: update(Ears.afterWakeWord(text) ?? command)
            case .direct: update(Ears.afterWakeWord(text) ?? text)
            }
        }
        if error != nil || result?.isFinal == true {
            if capture != .none && !command.isEmpty { finish() }
            else if capture != .none && Date() < listenUntil {
                let mode = capture; beginTask(mode); armSilence(listenUntil.timeIntervalSinceNow)
            } else if capture != .none { beginTask(.none); onGiveUp?() }
            else { beginTask(.none) }
        }
    }

    private func update(_ cmd: String) {
        if finalizing && cmd.isEmpty { return }
        command = cmd; onPartial?(cmd)
        if !finalizing { armSilence(cmd.isEmpty ? 6 : 1.4) }
    }

    private func armSilence(_ seconds: TimeInterval) {
        silenceTimer?.invalidate(); listenUntil = Date() + seconds
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.command.isEmpty { self.beginTask(.none); self.onGiveUp?() } else { self.finalize() }
        }
    }

    private func finalize() {
        guard !finalizing else { return }
        finalizing = true; request?.endAudio()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in self?.finish() }
    }

    private func finish() { let cmd = command; stop(); onCommand?(cmd) }
}

// MARK: - Mouth (spoken confirmations)

final class Mouth: NSObject, AVSpeechSynthesizerDelegate {
    var onDone: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var pending = false

    override init() { super.init(); synth.delegate = self }

    private var voice: AVSpeechSynthesisVoice? {
        if let id = Settings.voice, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        return en.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func say(_ text: String) {
        guard !text.isEmpty else { onDone?(); return }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice; u.rate = 0.52; u.pitchMultiplier = 0.98
        pending = true
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate); finished() }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { if !self.synth.isSpeaking { self.finished() } }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished() }
    }
    private func finished() { guard pending else { return }; pending = false; onDone?() }
}

// MARK: - Commands → fleet actions

enum Commands {
    /// Runs a spoken command and returns a short line for Nexus to say back.
    static func run(_ text: String, showDashboard: (() -> Void)?) -> String {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }

        Fleet.shared.discover(); Fleet.shared.refresh()

        if has(t, ["status","report","how are things","how's the fleet","hows the fleet","what's running","whats running","how is everyone"]) {
            return statusReport()
        }
        if has(t, ["dashboard","mission control","show me the office","open the office"]) {
            DispatchQueue.main.async { showDashboard?() }
            return "Opening the dashboard."
        }

        let wantsAll = has(t, ["all","everything","everyone","every agent","every app","the fleet","all agents","all apps"])
        let stopV    = has(t, ["stop","quit","close","shut down","shutdown","kill","turn off","power down","sleep"])
        let restartV = has(t, ["restart","relaunch","reboot","reload"])
        let rebuildV = has(t, ["rebuild","build"])
        let openV    = has(t, ["open","start","launch","activate","wake","boot","run","bring up","fire up","turn on","power up"])

        // Whole-fleet operations.
        if wantsAll && stopV {
            let running = Fleet.shared.apps.filter { $0.status.severity == 1 || $0.status == .stale }
            running.forEach { Actions.stop($0) }
            return running.isEmpty ? "No agents are running." : "Standing down all \(running.count) agents."
        }
        if wantsAll && rebuildV {
            let build = Fleet.shared.apps.filter { $0.installed && !$0.building }
            build.forEach { a in Actions.build(a) { Fleet.shared.onChange?() } }
            return "Rebuilding \(build.count) agents."
        }
        if wantsAll && (openV || restartV) {
            let idle = Fleet.shared.apps.filter { $0.installed && !($0.status.severity == 1 || $0.status == .stale) }
            idle.forEach { Actions.open($0) }
            return idle.isEmpty ? "All agents are already on duty." : "Activating all agents. Bringing \(idle.count) online."
        }

        // Single-agent operations.
        guard let app = bestApp(for: t) else {
            return "I didn't catch which agent you meant. Try, Nexus, open Jarvis."
        }
        if restartV { Actions.stop(app); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Actions.open(app) }; return "Restarting \(app.name)." }
        if stopV    { Actions.stop(app); return "Stopping \(app.name)." }
        if rebuildV { Actions.build(app) { Fleet.shared.onChange?() }; return "Rebuilding \(app.name)." }
        Actions.open(app)
        return "Opening \(app.name)."
    }

    private static func statusReport() -> String {
        let apps = Fleet.shared.apps
        guard !apps.isEmpty else { return "I'm not watching any agents yet." }
        let run = Fleet.shared.runningCount
        var line = "\(run) of \(apps.count) agents on duty."
        let trouble = apps.filter { $0.status.severity >= 2 }
        if !trouble.isEmpty {
            line += " " + trouble.map { "\($0.name) is \($0.status.word.lowercased())" }.joined(separator: ", ") + "."
        } else if run < apps.count {
            let off = apps.filter { !($0.status.severity == 1 || $0.status == .stale) }
            if !off.isEmpty { line += " " + off.map(\.name).joined(separator: ", ") + " \(off.count == 1 ? "is" : "are") idle." }
        } else {
            line += " All systems nominal."
        }
        return line
    }

    /// The agent whose name best matches the spoken text, by phonetic key.
    private static func bestApp(for text: String) -> AppInfo? {
        let apps = Fleet.shared.apps
        guard !apps.isEmpty else { return nil }
        let heardWords = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        var best: (AppInfo, Double)?
        for app in apps {
            // Match the full name and each significant word of it against windows of the heard text.
            let forms = [app.name] + app.name.split(separator: " ").map(String.init).filter { $0.count > 2 }
            for form in forms {
                let fk = Sound.key(form)
                let n = form.split(separator: " ").count
                for i in 0...(max(0, heardWords.count - n)) where i + n <= heardWords.count {
                    let heard = heardWords[i..<i+n].joined(separator: " ")
                    let s = Sound.similarity(Sound.key(heard), fk)
                    if s > (best?.1 ?? 0.6) { best = (app, s) }
                }
            }
        }
        return best?.0
    }

    private static func has(_ text: String, _ phrases: [String]) -> Bool {
        for p in phrases {
            if p.contains(" ") { if text.contains(p) { return true } }
            else {
                // whole-word match for single words so "run" doesn't fire on "running"
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: p) + "\\b"
                if text.range(of: pattern, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }
}

// MARK: - Voice controller (ties Ears + Mouth to the fleet)

final class Voice: NSObject {
    let ears = Ears()
    let mouth = Mouth()
    var showDashboard: (() -> Void)?
    var onState: ((String) -> Void)?     // "idle" | "listening" | "working" | "speaking" | "off"
    var onLevel: ((Float) -> Void)?      // mic loudness, for the orb
    var onCaption: ((String) -> Void)?   // text to show under the orb

    private var wired = false

    override init() {
        super.init()
        wire()
    }

    private func wire() {
        guard !wired else { return }; wired = true
        ears.onWake = { [weak self] in
            NSSound(named: "Tink")?.play()
            self?.onState?("listening")
            self?.onCaption?("Listening…")
        }
        ears.onPartial = { [weak self] text in if !text.isEmpty { self?.onCaption?(text) } }
        ears.onLevel = { [weak self] level in self?.onLevel?(level) }
        ears.onGiveUp = { [weak self] in self?.onState?("idle"); self?.onCaption?("") }
        ears.onCommand = { [weak self] cmd in self?.handle(cmd) }
        mouth.onDone = { [weak self] in
            guard let self else { return }
            self.onState?("idle")
            self.onCaption?("")
            if Settings.voiceEnabled { self.ears.start() }   // Ears stopped itself while we spoke
        }
    }

    func start() {
        guard Settings.voiceEnabled else { return }
        requestAuth { [weak self] ok in
            guard ok, let self else { return }
            self.ears.start()
            self.onState?("idle")
        }
    }

    func stop() { ears.stop(); mouth.stop(); onState?("off"); onCaption?("") }

    func reload() { if Settings.voiceEnabled { ears.reload() } }

    var status: String {
        if !Settings.voiceEnabled { return "Voice control is off" }
        if !ears.available { return "Voice: no speech model" }
        return "Listening for " + Settings.wakeNames.map { "“\($0)”" }.joined(separator: " or ")
    }

    private func handle(_ cmd: String) {
        onState?("working")
        let reply = Commands.run(cmd, showDashboard: showDashboard)
        if reply.isEmpty {
            onState?("idle"); onCaption?("")
            if Settings.voiceEnabled { ears.start() }
            return
        }
        onState?("speaking")
        onCaption?(reply)
        mouth.say(reply)
    }

    private func requestAuth(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized else { DispatchQueue.main.async { done(false) }; return }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { done(mic) }
            }
        }
    }
}
