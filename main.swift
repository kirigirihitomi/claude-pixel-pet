// Claude desktop pet: the pixel character floating on the macOS desktop.
// Click to chat or drive a Claude Code session, drag to move. Shows what Claude Code sessions are doing
// (read from the local transcripts) and today's token usage in the menu-bar icon. Transparent pixels are click-through.
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
// Claude Code config dirs whose transcripts are watched; the first one is also used for chat.
// Default ~/.claude; override for several accounts:
//   defaults write io.github.kirigirihitomi.claude-pixel-pet configDirs -array ~/.claude-work ~/.claude
let accounts: [(label: String, dir: URL)] = ((UserDefaults.standard.array(forKey: "configDirs") as? [String]) ?? ["~/.claude"])
    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    .map { ($0.lastPathComponent, $0) }

let persona = """
You are Claude, living on the user's Mac desktop as a small pixel-art desktop pet (orange hair, white dress, holding a book). \
The user clicked you to chat. Reply like a calm, dry-humoured friend: short, usually one to three sentences, plain text, \
no markdown, no lists. Match the user's language.
"""

/// CLAUDE_CONFIG_DIR value for a config dir. The default ~/.claude must stay unset: setting it explicitly makes
/// Claude Code look up a different stored login, and it asks you to log in again.
func configEnv(_ dir: URL) -> String? {
    dir.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path ? nil : dir.path
}

/// "Bash · Run tests"; `full` keeps the whole command / path (for permission cards).
func describeTool(_ tool: String, _ input: [String: Any], full: Bool = false) -> String {
    let path = input["file_path"] as? String
    let detail: String?
    if full { detail = (input["command"] as? String) ?? path ?? (input["description"] as? String) }
    else { detail = (input["description"] as? String) ?? (input["command"] as? String) ?? path.map { ($0 as NSString).lastPathComponent } }
    let d = detail ?? (input["pattern"] as? String) ?? (input["url"] as? String) ?? ""
    return String((d.isEmpty ? tool : "\(tool) · \(d)").prefix(full ? 300 : 70))
}

/// Splits complete lines off `buffer` (keeping a trailing partial line) and parses each as a JSON object.
/// `keep` can reject a raw line before the (expensive) JSON parse.
func takeJSONLines(_ buffer: inout Data, keep: (Data) -> Bool = { _ in true }) -> [[String: Any]] {
    guard let last = buffer.lastIndex(of: 0x0A) else { return [] }
    let lines = buffer[buffer.startIndex..<last].split(separator: 0x0A)
    buffer.removeSubrange(buffer.startIndex...last)
    return lines.compactMap { keep($0) ? (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] : nil }
}

/// Every transcript (*.jsonl) under the watched accounts modified after `since`.
func transcripts(since: Date, subagents: Bool) -> [(label: String, dir: URL, url: URL, size: UInt64)] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    var out: [(String, URL, URL, UInt64)] = []
    for (label, dir) in accounts {
        guard let e = FileManager.default.enumerator(at: dir.appendingPathComponent("projects"), includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in e where url.pathExtension == "jsonl" && (subagents || !url.path.contains("/subagents/")) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), (v.contentModificationDate ?? .distantPast) > since else { continue }
            out.append((label, dir, url, UInt64(v.fileSize ?? 0)))
        }
    }
    return out
}

func shortCount(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }

// MARK: sprite

/// Sprite frames, one PNG each in Resources/. closed/half/open are the mouth while talking; the rest are face poses.
enum Pose: String, CaseIterable { case closed, half, open, blink_half, blink_closed, read, yawn, smile, surprised }

final class Sprite {
    let frames: [Pose: NSImage]
    let aspect: CGFloat
    private let w: Int, h: Int, mask: [Bool]   // opaque pixels of the neutral frame, for click-through
    init() {
        let res = Bundle.main.resourceURL!
        frames = Dictionary(uniqueKeysWithValues: Pose.allCases.map { ($0, NSImage(contentsOf: res.appendingPathComponent("\($0.rawValue).png"))!) })
        let cg = frames[.closed]!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        w = cg.width; h = cg.height; aspect = CGFloat(w) / CGFloat(h)
        var alpha = [UInt8](repeating: 0, count: w * h)   // draw into an alpha-only buffer: one pass, no per-pixel objects
        let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        mask = alpha.map { $0 > 25 }
    }
    func opaque(atUnit p: CGPoint) -> Bool {   // p in 0...1, origin bottom-left
        let x = Int(p.x * CGFloat(w)), y = Int((1 - p.y) * CGFloat(h))
        return x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x]
    }
}

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }   // borderless windows can't take typing otherwise
}

final class PetView: NSView {
    let sprite: Sprite
    var spriteHeight: CGFloat = 240
    var pose = Pose.closed { didSet { if pose != oldValue { needsDisplay = true } } }
    var bob: CGFloat = 0 { didSet { if bob != oldValue { needsDisplay = true } } }   // whole pixels only
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    private var dragStart: NSPoint?, moved = false

    init(sprite: Sprite) { self.sprite = sprite; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var spriteRect: NSRect {
        let w = spriteHeight * sprite.aspect
        return NSRect(x: (bounds.width - w) / 2, y: bob, width: w, height: spriteHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        sprite.frames[pose]!.draw(in: spriteRect)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for v in subviews.reversed() where !v.isHidden && v.frame.contains(p) { return v.hitTest(point) }
        let r = spriteRect
        guard r.contains(p) else { return nil }
        return sprite.opaque(atUnit: CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { dragStart = e.locationInWindow; moved = false }
    override func mouseDragged(with e: NSEvent) {
        guard let start = dragStart, let w = window else { return }
        let p = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: p.x - start.x, y: p.y - start.y)); moved = true
    }
    override func mouseUp(with e: NSEvent) {
        if moved { onMoved?() } else { onClick?() }
        dragStart = nil
    }
}

// MARK: Claude Code activity + usage, read from ~/.claude*/projects/**/*.jsonl

struct Activity { var working = false; var detail = ""; var project = ""; var last = Date.distantPast; var since = Date.distantPast; var context = 0 }
struct Usage: Equatable { var input = 0, output = 0, sessions = 0 }

final class Monitor {
    private struct FileState { var offset: UInt64 = 0; var rest = Data(); var act = Activity() }
    private var files: [String: FileState] = [:]
    private var seen = Set<String>()                    // message ids already counted (one message spans several lines)
    private var dayStart = Date.distantPast
    private var usage: [String: (input: Int, output: Int, sessions: Set<String>)] = [:]
    var ignoreSession: () -> String? = { nil }          // the session the pet itself is attached to
    private let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    // only user/assistant lines matter; skip everything else (huge tool results, snapshots…) before parsing
    private let wanted = [Data(#""type":"user""#.utf8), Data(#""type":"assistant""#.utf8)]

    func poll() -> (Activity?, [(label: String, usage: Usage)]) {
        let start = Calendar.current.startOfDay(for: Date())
        if start != dayStart {   // new day: restart the counts, keep read offsets (yesterday's lines don't count anyway)
            dayStart = start; usage = [:]; seen = []
            files = files.filter { $0.value.act.last >= start.addingTimeInterval(-3600) }
        }
        for t in transcripts(since: start, subagents: true) where files[t.url.path]?.offset != t.size {
            read(t.url, label: t.label, size: t.size)
        }
        let mine = ignoreSession()
        let latest = files.filter { mine == nil || !$0.key.contains(mine!) }.values.map(\.act).max { $0.last < $1.last }
        let rows = usage.sorted { $0.key < $1.key }.map { ($0.key, Usage(input: $0.value.input, output: $0.value.output, sessions: $0.value.sessions.count)) }
        return (latest, rows)
    }

    private func read(_ url: URL, label: String, size: UInt64) {
        var st = files[url.path] ?? FileState()
        if size < st.offset { st = FileState() }
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: st.offset)
        st.rest += (try? h.read(upToCount: Int(size - st.offset))) ?? Data()
        st.offset = size
        let session = url.deletingPathExtension().lastPathComponent
        for j in takeJSONLines(&st.rest, keep: { line in self.wanted.contains { line.range(of: $0) != nil } }) {
            guard let type = j["type"] as? String, type == "user" || type == "assistant",
                  let ts = (j["timestamp"] as? String).flatMap(iso.date) else { continue }
            let msg = j["message"] as? [String: Any] ?? [:]
            let content = msg["content"] as? [[String: Any]] ?? []
            if let cwd = j["cwd"] as? String { st.act.project = (cwd as NSString).lastPathComponent }
            if type == "user" {
                let isPrompt = msg["content"] is String || content.contains { $0["type"] as? String == "text" }
                if isPrompt && !st.act.working { st.act.since = ts }
                st.act.working = true
                if isPrompt { st.act.detail = "thinking" }
            } else {
                if let u = msg["usage"] as? [String: Any], let id = msg["id"] as? String {
                    let inp = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                    st.act.context = inp
                    if ts >= dayStart, seen.insert(id).inserted {
                        var row = usage[label] ?? (0, 0, [])
                        row.input += inp; row.output += u["output_tokens"] as? Int ?? 0; row.sessions.insert(session)
                        usage[label] = row
                    }
                }
                if let tool = content.first(where: { $0["type"] as? String == "tool_use" }) {
                    st.act.detail = describeTool(tool["name"] as? String ?? "tool", tool["input"] as? [String: Any] ?? [:])
                    st.act.working = true
                } else if msg["stop_reason"] as? String == "end_turn" {
                    st.act.working = false; st.act.detail = "done"
                }
            }
            st.act.last = ts
        }
        files[url.path] = st
    }
}

// MARK: recent sessions (reads only the tail of each transcript)

struct Session {
    let id: String, dir: URL, cwd: String, title: String, modified: Date
    var label: String { "\((cwd as NSString).lastPathComponent) — \(title)" }
}

func recentSessions(days: Double = 7, limit: Int = 12) -> [Session] {
    var found: [Session] = []
    let fields = [Data(#""cwd""#.utf8), Data(#"Title""#.utf8), Data(#""lastPrompt""#.utf8)]
    for t in transcripts(since: Date().addingTimeInterval(-days * 86400), subagents: false) {
        guard let h = try? FileHandle(forReadingFrom: t.url) else { continue }
        try? h.seek(toOffset: t.size > 262_144 ? t.size - 262_144 : 0)
        var tail = ((try? h.readToEnd()) ?? Data()) + Data([0x0A]); try? h.close()
        var cwd = "", title = "", prompt = ""
        for j in takeJSONLines(&tail, keep: { line in fields.contains { line.range(of: $0) != nil } }) {
            if let c = j["cwd"] as? String { cwd = c }
            if let s = (j["customTitle"] ?? j["aiTitle"]) as? String { title = s }
            if let s = j["lastPrompt"] as? String { prompt = s }
        }
        guard !cwd.isEmpty else { continue }
        let id = t.url.deletingPathExtension().lastPathComponent
        let shown = String((title.isEmpty ? (prompt.isEmpty ? String(id.prefix(8)) : prompt) : title).prefix(40))
        let mod = (try? t.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        found.append(Session(id: id, dir: t.dir, cwd: cwd, title: shown, modified: mod))
    }
    return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
}

/// Opens Terminal in the session's directory and runs `claude --resume` there (a .command file needs no extra permissions).
func resumeInTerminal(_ s: Session) {
    let q = { (x: String) in "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let env = configEnv(s.dir).map { "CLAUDE_CONFIG_DIR=\(q($0)) " } ?? "unset CLAUDE_CONFIG_DIR; "
    let script = "#!/bin/zsh -l\ncd \(q(s.cwd)) && \(env)exec claude --resume \(s.id)\n"
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("claude-pixel-pet")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("resume-\(s.id.prefix(8)).command")
    try? script.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    NSWorkspace.shared.open(file)
}

// MARK: talking to Claude Code: one long-lived `claude -p` process per attached session, stream-json both ways
// (the same protocol the IDE extensions use; tool permission requests arrive as control_request can_use_tool)

/// `claude`'s path and the PATH it needs, as the user's interactive shell sees them (resolved once; GUI apps get a bare PATH).
let claudeLaunch: (exe: String, path: String)? = {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-ilc", "print -r -- \"$PATH\"; command -v claude"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    guard lines.count >= 2, let exe = lines.last, exe.hasPrefix("/") else { return nil }
    return (exe, lines[lines.count - 2])
}()

struct Target {
    var id: String?            // session id; nil = start a new one
    var cwd: String
    var dir: URL?              // Claude Code config dir
    var tools: Bool            // false = plain chat with the pet (no tools, pet persona)
    var name: String
}

final class Agent {
    enum Event { case text(String), step(String), permission(id: String, title: String, input: [String: Any]), done(String), failed(String) }
    var target: Target
    var onEvent: (Event) -> Void = { _ in }
    var onSession: (String) -> Void = { _ in }
    private(set) var busy = false
    private var proc: Process?, stdin: FileHandle?, buffer = Data()

    init(target: Target) { self.target = target }

    func attach(_ t: Target) { stop(); target = t }

    func send(_ text: String) {
        if proc?.isRunning != true { start() }
        busy = true
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    func answer(permission id: String, allow: Bool, input: [String: Any]) {
        let r: [String: Any] = allow ? ["behavior": "allow", "updatedInput": input] : ["behavior": "deny", "message": "The user declined this from the desktop pet."]
        write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": r]])
    }

    func interrupt() {
        guard busy else { return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func stop() { try? stdin?.close(); proc?.terminate(); proc = nil; stdin = nil; busy = false; buffer = Data() }

    private func write(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? stdin?.write(contentsOf: d + Data([0x0A]))
    }

    private func start() {
        guard let launch = claudeLaunch else { onEvent(.failed("I can't find the claude command.")); return }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompt-tool", "stdio"]
        if let id = target.id { args += ["--resume", id] }
        else { let id = UUID().uuidString.lowercased(); target.id = id; args += ["--session-id", id]; onSession(id) }
        if !target.tools { args += ["--tools", "", "--disable-slash-commands", "--append-system-prompt", persona] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = target.dir.flatMap(configEnv)
        env["PATH"] = launch.path
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: target.cwd)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.proc === p else { return }
                if self.busy { self.onEvent(.failed("The claude process stopped.")) }
                self.proc = nil; self.stdin = nil; self.busy = false
            }
        }
        do { try p.run(); proc = p; stdin = inPipe.fileHandleForWriting }
        catch { onEvent(.failed("I can't start claude.")) }
    }

    private func consume(_ d: Data) {
        buffer += d
        takeJSONLines(&buffer).forEach(handle)
    }

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "system":
            if let sid = m["session_id"] as? String, sid != target.id { target.id = sid; onSession(sid) }
        case "assistant":
            let content = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty { onEvent(.text(t)) }
                if c["type"] as? String == "tool_use" {
                    onEvent(.step(describeTool(c["name"] as? String ?? "tool", c["input"] as? [String: Any] ?? [:])))
                }
            }
        case "control_request":
            guard let id = m["request_id"] as? String, let r = m["request"] as? [String: Any] else { return }
            if r["subtype"] as? String == "can_use_tool" {
                let input = r["input"] as? [String: Any] ?? [:]
                onEvent(.permission(id: id, title: describeTool(r["tool_name"] as? String ?? "tool", input, full: true), input: input))
            } else {
                write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "not supported by the pet"]])
            }
        case "result":
            busy = false
            onEvent(.done((m["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        default: break
        }
    }
}

// MARK: overlays

/// Scrollable, selectable speech bubble (long replies scroll instead of being cut off).
final class BubbleView: NSScrollView {
    let text = NSTextView()
    init() {
        super.init(frame: .zero)
        drawsBackground = true; backgroundColor = NSColor(white: 1, alpha: 0.96); hasVerticalScroller = true
        autohidesScrollers = true; borderType = .noBorder; wantsLayer = true; layer?.cornerRadius = 8; isHidden = true
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = .systemFont(ofSize: 12, weight: .medium); text.textColor = NSColor(white: 0.15, alpha: 1)
        text.textContainerInset = NSSize(width: 6, height: 5); text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        documentView = text
    }
    required init?(coder: NSCoder) { fatalError() }
    var string: String { get { text.string } set { text.string = newValue; text.scrollToBeginningOfDocument(nil) } }
    func fittingHeight(width: CGFloat) -> CGFloat {
        text.frame.size.width = width
        guard let lm = text.layoutManager, let tc = text.textContainer else { return 30 }
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height + 12
    }
}

/// "Claude wants to run …  [Deny] [Allow]"
final class PermissionCard: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let allow = NSButton(title: "Allow", target: nil, action: nil), deny = NSButton(title: "Deny", target: nil, action: nil)
    var onAnswer: (Bool) -> Void = { _ in }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 0.97).cgColor
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular); label.maximumNumberOfLines = 5
        allow.bezelStyle = .rounded; deny.bezelStyle = .rounded; allow.keyEquivalent = "\r"
        allow.target = self; allow.action = #selector(yes); deny.target = self; deny.action = #selector(no)
        [label, allow, deny].forEach(addSubview); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func yes() { onAnswer(true) }
    @objc func no() { onAnswer(false) }
    override func layout() {
        super.layout()
        allow.frame = NSRect(x: bounds.width - 76, y: 4, width: 70, height: 26)
        deny.frame = NSRect(x: bounds.width - 150, y: 4, width: 70, height: 26)
        label.frame = NSRect(x: 8, y: 32, width: bounds.width - 16, height: bounds.height - 36)
    }
}

// MARK: app

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let sprite = Sprite(), monitor = Monitor()
    var window: PetWindow!, view: PetView!, status: NSStatusItem!
    let bubble = BubbleView(), card = PermissionCard(), input = NSTextField()
    let statusPill: NSTextField = {
        let f = NSTextField(wrappingLabelWithString: "")
        f.isEditable = false; f.isSelectable = false; f.drawsBackground = true; f.isHidden = true
        f.backgroundColor = NSColor(white: 1, alpha: 0.8); f.textColor = NSColor(white: 0.15, alpha: 1)
        f.font = .systemFont(ofSize: 10); f.alignment = .center
        f.wantsLayer = true; f.layer?.cornerRadius = 8
        return f
    }()
    let pollQueue = DispatchQueue(label: "pet.monitor"); var polling = false
    var bubbleTimer: Timer?, t: Double = 0
    var waiting = false              // sent a message, no text back yet: the bubble shows animated dots
    var wasWorking = false, agentStep = "", otherActivity = ""
    var pending: [(id: String, title: String, input: [String: Any])] = []
    var lastUsage: [String] = []
    let headroom: CGFloat = 230
    let sizes: [(String, CGFloat)] = [("Small", 160), ("Medium", 240), ("Large", 340)]
    var height: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "height") as? Double ?? 240) }
    let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()
    var sigterm: DispatchSourceSignal?

    var petChatID: String? {
        get { UserDefaults.standard.string(forKey: "chatSession") }
        set { UserDefaults.standard.set(newValue, forKey: "chatSession") }
    }
    func petChat() -> Target { Target(id: petChatID, cwd: home.path, dir: accounts.first?.dir, tools: false, name: "Pet chat") }
    lazy var agent = Agent(target: petChat())

    func applicationDidFinishLaunching(_ n: Notification) {
        window = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true ? .floating : .normal
        view = PetView(sprite: sprite)
        view.onClick = { [weak self] in self?.toggleInput() }
        view.onMoved = { [weak self] in self?.window.saveFrame(usingName: "pet") }
        window.contentView = view
        input.isHidden = true; input.delegate = self
        input.focusRingType = .none; input.bezelStyle = .roundedBezel; input.font = .systemFont(ofSize: 12)
        [statusPill, bubble, card, input].forEach { view.addSubview($0) }
        card.onAnswer = { [weak self] ok in self?.answerPermission(ok) }
        agent.onEvent = { [weak self] e in self?.agentEvent(e) }
        agent.onSession = { [weak self] id in if self?.agent.target.tools == false { self?.petChatID = id } }
        monitor.ignoreSession = { [weak self] in self?.agent.target.id }
        var restored = window.setFrameUsingName("pet")
        if !restored, let s = UserDefaults.standard.string(forKey: "origin") {   // position saved by v0.1
            window.setFrameOrigin(NSPointFromString(s)); restored = true
        }
        resize(height, keepBottom: restored)
        updatePlaceholder()
        window.orderFrontRegardless()
        setupMenu()
        // `pkill` / logout send SIGTERM: quit through AppKit so the claude child process is stopped too
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }; sigterm?.resume()
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollActivity() }
        pollActivity(); refreshSessions()
        pollQueue.async { _ = claudeLaunch }   // resolve the claude path early, off the main thread
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.say("Hello. Click me to chat.") }
    }

    func resize(_ h: CGFloat, keepBottom: Bool = true) {
        let w = max(h * sprite.aspect, 300), total = h + headroom
        let origin: NSPoint
        if keepBottom { origin = NSPoint(x: window.frame.midX - w / 2, y: window.frame.minY) }
        else { let v = NSScreen.main!.visibleFrame; origin = NSPoint(x: v.maxX - w - 40, y: v.minY + 10) }
        window.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: total)), display: true)
        window.saveFrame(usingName: "pet")
        view.spriteHeight = h
        input.frame = NSRect(x: 8, y: h + 4, width: w - 16, height: 24)
        layoutOverlays()
        UserDefaults.standard.set(Double(h), forKey: "height")
    }

    /// Visibility and frames of everything above the head, from state:
    /// [input] [status pill] [permission card, or else the bubble]. Call after any state change.
    func layoutOverlays() {
        statusPill.isHidden = statusPill.stringValue.isEmpty
        card.isHidden = pending.isEmpty
        if !card.isHidden { bubble.isHidden = true }
        let w = window.frame.width
        var y = view.spriteHeight + (input.isHidden ? 6 : 32)
        let fit = statusPill.sizeThatFits(NSSize(width: w - 24, height: .greatestFiniteMagnitude))
        statusPill.frame = NSRect(x: 4, y: y, width: w - 8, height: min(fit.height + 6, 30))
        if !statusPill.isHidden { y += statusPill.frame.height + 4 }
        let room = view.spriteHeight + headroom - y - 4
        card.frame = NSRect(x: 4, y: y, width: w - 8, height: min(130, room))
        bubble.frame = NSRect(x: 4, y: y, width: w - 8, height: min(bubble.fittingHeight(width: w - 8), room))
    }

    func tick() {   // 30fps: slow breathing bob, waiting dots, pixel animation
        t += 1 / 30
        view.bob = (CGFloat(sin(t * 2 * .pi / 3.2) + 1) * view.spriteHeight * 0.006).rounded()
        if waiting && Int(t * 30) % 12 == 0 { bubble.string = String(repeating: "·", count: Int(t * 2.5) % 3 + 1) }
        if !anim.isEmpty && t >= animStepEnd {
            anim.removeFirst()
            animStepEnd = t + (anim.first?.1 ?? 0)
        }
        view.pose = anim.first?.0 ?? .closed
        if anim.isEmpty && t >= nextIdle { idleAnimation(); nextIdle = t + .random(in: 2.5...6) }
    }

    // pixel animation: one sequence of (pose, seconds) at a time, stepped by tick(); then back to the neutral face.
    // A sequence of equal or higher priority replaces the current one; a lower one is dropped.
    enum Priority: Int { case idle, expression, talk }
    var anim: [(Pose, Double)] = [], animPriority = Priority.idle, animStepEnd = 0.0, nextIdle = 2.0
    func play(_ seq: [(Pose, Double)], _ priority: Priority) {
        guard !seq.isEmpty, anim.isEmpty || priority.rawValue >= animPriority.rawValue else { return }
        anim = seq; animPriority = priority; animStepEnd = t + seq[0].1
    }
    func talking(_ steps: Int) -> [(Pose, Double)] {   // mouth flap, 90ms per frame
        (0..<steps).map { ([Pose.closed, .half, .open, .half][$0 % 4], 0.09) }
    }
    let blink: [(Pose, Double)] = [(.blink_half, 0.05), (.blink_closed, 0.08), (.blink_half, 0.05)]
    lazy var idleActions: [(chance: Double, seq: [(Pose, Double)])] = [
        (0.06, [(.blink_half, 0.08), (.yawn, 1.4), (.blink_half, 0.1)]),                    // rare yawn
        (0.14, [(.read, 2.2)] + blink + [(.read, 2.4), (.blink_half, 0.06)]),               // read the book a moment
        (0.10, blink + [(.closed, 0.15)] + blink),                                          // double blink
        (0.70, blink),
    ]
    func idleAnimation() {   // pick one idle action by its chance
        var r = Double.random(in: 0..<1)
        for a in idleActions { r -= a.chance; if r < 0 { play(a.seq, .idle); return } }
    }

    /// Show `text` in the bubble for `hold` seconds (it also stays while the input is open or Claude is working),
    /// moving the mouth; `then` plays right after the talking.
    func say(_ text: String, hold: TimeInterval? = nil, then: [(Pose, Double)] = []) {
        bubble.string = text; bubble.isHidden = false; layoutOverlays()
        play(talking(min(8 + text.count / 2, 60)) + then, .talk)
        bubbleTimer?.invalidate()
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: hold ?? max(4, Double(text.count) / 12), repeats: true) { [weak self] tm in
            guard let self else { return }
            if self.agent.busy || !self.input.isHidden { return }   // check again next period
            self.bubble.isHidden = true; tm.invalidate()
        }
    }
    func readTime(_ s: String) -> TimeInterval { 15 + Double(s.count) / 4 }   // ~4 CJK chars/s, plus slack

    // input
    func updatePlaceholder() { input.placeholderString = "Message \(agent.target.name)…" }
    func toggleInput() {
        if !input.isHidden { closeInput(); return }
        input.isHidden = false; layoutOverlays()
        NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(input)
    }
    func closeInput() { input.isHidden = true; input.stringValue = ""; layoutOverlays(); window.resignKey() }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { closeInput(); return true }
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agent.busy else { return true }
        input.stringValue = ""
        agentStep = ""; say("·", hold: 3600); waiting = true
        agent.send(text)
        refreshPill()
        return true
    }

    // agent events
    func agentEvent(_ e: Agent.Event) {
        switch e {
        case .text(let s): waiting = false; say(s, hold: 3600)
        case .step(let s): agentStep = s
        case .permission(let id, let title, let input):
            pending.append((id, title, input)); showCard()
        case .done(let s):
            waiting = false; agentStep = ""
            say(s.isEmpty ? bubble.string : s, hold: readTime(s.isEmpty ? bubble.string : s))
        case .failed(let s): waiting = false; agentStep = ""; say(s)
        }
        refreshPill()
    }
    func showCard() {
        if let p = pending.first {
            card.label.stringValue = "\(agent.target.name) wants to run:\n\(p.title)"
            window.orderFrontRegardless(); play([(.surprised, 1.2)], .talk)
        }
        layoutOverlays()
    }
    func answerPermission(_ ok: Bool) {
        guard !pending.isEmpty else { return }
        let p = pending.removeFirst()
        agent.answer(permission: p.id, allow: ok, input: p.input)
        if pending.isEmpty && !bubble.string.isEmpty { bubble.isHidden = false }
        showCard()
    }

    // status pill: the attached session's step, otherwise whatever other Claude Code session is busy
    func refreshPill() {
        let s = agent.busy ? "\(agent.target.name): \(agentStep.isEmpty ? "thinking" : agentStep)" : otherActivity
        guard s != statusPill.stringValue else { return }
        statusPill.stringValue = s; layoutOverlays()
    }

    // Claude Code activity in other sessions
    func pollActivity() {
        guard !polling else { return }   // the first scan of big transcripts can take longer than the 2s tick
        polling = true
        pollQueue.async { [weak self] in
            guard let self else { return }
            let (act, rows) = self.monitor.poll()
            DispatchQueue.main.async { self.polling = false; self.show(act, rows) }
        }
    }

    func show(_ act: Activity?, _ rows: [(label: String, usage: Usage)]) {
        let fresh = act.map { Date().timeIntervalSince($0.last) < 600 } ?? false
        let working = fresh && (act?.working ?? false)
        otherActivity = working ? "\(act!.project): \(act!.detail)" : ""
        if wasWorking && !working, let a = act, fresh, a.last.timeIntervalSince(a.since) > 20, !agent.busy {
            say("Done in \(a.project). Your turn.", then: [(.smile, 2.5)])
        }
        wasWorking = working
        refreshPill()
        var lines = rows.map { "\($0.label): \(shortCount($0.usage.output)) out · \(shortCount($0.usage.input)) in · \($0.usage.sessions) sessions" }
        if let a = act, a.context > 0 { lines.append("Context (\(a.project)): \(shortCount(a.context))") }
        guard lines != lastUsage else { return }
        lastUsage = lines
        let total = rows.reduce(0) { $0 + $1.usage.output }
        status.button?.title = total > 0 ? "✦ \(shortCount(total))" : "✦"
        usageItems.forEach { status.menu?.removeItem($0) }
        usageItems = lines.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
        for (i, it) in usageItems.enumerated() { status.menu?.insertItem(it, at: 1 + i) }
    }

    // menu
    var usageItems: [NSMenuItem] = []
    var sessionLabel: NSMenuItem!, switchMenu = NSMenu(), terminalMenu = NSMenu()
    var sessions: [Session] = []
    func refreshSessions() {   // off the main thread; the submenus show the last result
        pollQueue.async { let s = recentSessions(); DispatchQueue.main.async { self.sessions = s } }
    }
    func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "✦"
        let m = NSMenu()
        m.addItem(withTitle: "Today's usage (output tokens in the icon)", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        sessionLabel = m.addItem(withTitle: "", action: nil, keyEquivalent: "")
        m.addItem(withTitle: "Chat…", action: #selector(openChat), keyEquivalent: "")
        m.addItem(withTitle: "Switch session", action: nil, keyEquivalent: "").submenu = switchMenu
        m.addItem(withTitle: "Stop", action: #selector(stopAgent), keyEquivalent: "")
        m.addItem(withTitle: "Open in Terminal", action: nil, keyEquivalent: "").submenu = terminalMenu
        switchMenu.delegate = self; terminalMenu.delegate = self
        m.addItem(.separator())
        for (i, (name, _)) in sizes.enumerated() {
            let it = m.addItem(withTitle: name, action: #selector(pickSize(_:)), keyEquivalent: ""); it.tag = i
        }
        let top = m.addItem(withTitle: "Always on top", action: #selector(toggleTop(_:)), keyEquivalent: "")
        top.state = window.level == .floating ? .on : .off
        m.addItem(withTitle: "Hide / Show", action: #selector(toggleShow), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "About", action: #selector(about), keyEquivalent: "")
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != nil && $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        m.delegate = self
        status.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === status.menu {
            sessionLabel.title = "Talking to: \(agent.target.name)\(agent.target.tools ? "" : " (no tools)")"
            refreshSessions(); return
        }
        menu.removeAllItems()
        let toTerminal = menu === terminalMenu
        if !toTerminal {
            let it = menu.addItem(withTitle: "Pet chat (no tools)", action: #selector(switchToPetChat), keyEquivalent: "")
            it.target = self; it.state = agent.target.tools ? .off : .on
            menu.addItem(.separator())
        }
        for (i, s) in sessions.enumerated() where s.id != petChatID {
            let it = menu.addItem(withTitle: "\(s.label)  ·  \(relative.localizedString(for: s.modified, relativeTo: Date()))",
                                  action: toTerminal ? #selector(openInTerminal(_:)) : #selector(switchSession(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = s.id == agent.target.id ? .on : .off
        }
        if !toTerminal {
            menu.addItem(.separator())
            menu.addItem(withTitle: "New session in folder…", action: #selector(newSessionInFolder), keyEquivalent: "").target = self
        }
    }
    func switchTo(_ t: Target) {
        agent.attach(t); pending = []; agentStep = ""; waiting = false
        updatePlaceholder(); refreshPill()
        say(t.tools ? "Attached to \(t.name). I can use tools here; I'll ask before anything risky." : "Back to our chat.")
    }
    @objc func switchToPetChat() { switchTo(petChat()) }
    @objc func switchSession(_ item: NSMenuItem) {
        let s = sessions[item.tag]
        switchTo(Target(id: s.id, cwd: s.cwd, dir: s.dir, tools: true, name: s.label))
    }
    @objc func newSessionInFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switchTo(Target(id: nil, cwd: url.path, dir: accounts.first?.dir, tools: true, name: url.lastPathComponent))
    }
    @objc func openInTerminal(_ item: NSMenuItem) { resumeInTerminal(sessions[item.tag]) }
    @objc func stopAgent() { agent.interrupt() }
    @objc func openChat() { if input.isHidden { toggleInput() } }
    @objc func pickSize(_ s: NSMenuItem) { resize(sizes[s.tag].1) }
    @objc func toggleTop(_ s: NSMenuItem) {
        window.level = window.level == .floating ? .normal : .floating
        s.state = window.level == .floating ? .on : .off
        UserDefaults.standard.set(window.level == .floating, forKey: "onTop")
    }
    @objc func toggleShow() { window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless() }
    @objc func about() {
        let a = NSAlert()
        a.messageText = "Claude desktop pet"
        a.informativeText = "Character: ZipZipPipe original design; 3-heads-tall pixel version is a derivative work. CC BY-NC-SA 4.0. Non-commercial. Not affiliated with Anthropic."
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
    func applicationWillTerminate(_ n: Notification) { agent.stop() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
