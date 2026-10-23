// Claude desktop pet: the pixel character floating on the macOS desktop.
// Click to chat (a persistent headless Claude Code session), drag to move. Shows what Claude Code sessions are doing
// (read from the local transcripts) and today's token usage in the menu-bar icon. Transparent pixels are click-through.
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
// Claude Code config dirs whose transcripts are watched; the first one is also used for chat.
// Default ~/.claude; override for several accounts:
//   defaults write io.github.kirigirihitomi.claude-pixel-pet configDirs -array ~/.claude-work ~/.claude
let accounts: [(String, URL)] = ((UserDefaults.standard.array(forKey: "configDirs") as? [String]) ?? ["~/.claude"])
    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("projects").path) }
    .map { ($0.lastPathComponent, $0) }

let persona = """
You are Claude, living on the user's Mac desktop as a small pixel-art desktop pet (orange hair, white dress, holding a book). \
The user clicked you to chat. Reply like a calm, dry-humoured friend: short, usually one to three sentences, plain text, \
no markdown, no lists. Match the user's language.
"""

// MARK: sprite

final class Sprite {
    let frames: [NSImage]          // closed, half, open
    let aspect: CGFloat
    private let alpha: NSBitmapImageRep
    init() {
        let res = Bundle.main.resourceURL!
        frames = ["closed", "half", "open"].map { NSImage(contentsOf: res.appendingPathComponent("\($0).png"))! }
        alpha = NSBitmapImageRep(data: frames[0].tiffRepresentation!)!
        aspect = CGFloat(alpha.pixelsWide) / CGFloat(alpha.pixelsHigh)
    }
    func opaque(atUnit p: CGPoint) -> Bool {   // p in 0...1, origin bottom-left
        let x = Int(p.x * CGFloat(alpha.pixelsWide)), y = Int((1 - p.y) * CGFloat(alpha.pixelsHigh))
        guard x >= 0, y >= 0, x < alpha.pixelsWide, y < alpha.pixelsHigh else { return false }
        return (alpha.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
    }
}

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }   // borderless windows can't take typing otherwise
}

final class PetView: NSView {
    let sprite: Sprite
    var spriteHeight: CGFloat = 240
    var frameIndex = 0 { didSet { needsDisplay = true } }
    var bob: CGFloat = 0 { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var dragStart: NSPoint?, moved = false

    init(sprite: Sprite) { self.sprite = sprite; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var spriteRect: NSRect {
        let w = spriteHeight * sprite.aspect
        return NSRect(x: (bounds.width - w) / 2, y: bob, width: w, height: spriteHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        sprite.frames[frameIndex].draw(in: spriteRect)
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
        if moved { UserDefaults.standard.set(NSStringFromPoint(window!.frame.origin), forKey: "origin") } else { onClick?() }
        dragStart = nil
    }
}

func pill(_ size: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: "")
    f.isEditable = false; f.isSelectable = false; f.drawsBackground = true; f.isHidden = true
    f.backgroundColor = NSColor(white: 1, alpha: alpha); f.textColor = NSColor(white: 0.15, alpha: 1)
    f.font = .systemFont(ofSize: size, weight: weight); f.alignment = .center
    f.wantsLayer = true; f.layer?.cornerRadius = 8
    return f
}

// MARK: Claude Code activity + usage, read from ~/.claude*/projects/**/*.jsonl

struct Activity { var working = false; var detail = ""; var project = ""; var last = Date.distantPast; var since = Date.distantPast; var context = 0 }

final class Monitor {
    struct FileState { var offset: UInt64 = 0; var rest = Data(); var act = Activity() }
    var files: [String: FileState] = [:]
    var seen = Set<String>()                    // message ids already counted (one message spans several lines)
    var day = ""
    var usage: [String: (input: Int, output: Int, sessions: Set<String>)] = [:]
    var ignoreSession: () -> String? = { nil }  // the pet's own chat session
    let iso = ISO8601DateFormatter()
    init() { iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }

    func today() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    func poll() -> (Activity?, [(String, Int, Int, Int)]) {
        if day != today() { day = today(); usage = [:]; seen = [] ; for k in files.keys { files[k]!.offset = 0 } }
        let cutoff = Calendar.current.startOfDay(for: Date())
        for (label, dir) in accounts {
            guard let e = FileManager.default.enumerator(at: dir.appendingPathComponent("projects"),
                                                        includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if mod < cutoff { continue }
                read(url, label: label)
            }
        }
        let mine = ignoreSession()
        let latest = files.filter { mine == nil || !$0.key.contains(mine!) }.values.map(\.act).max { $0.last < $1.last }
        let rows = usage.sorted { $0.key < $1.key }.map { ($0.key, $0.value.input, $0.value.output, $0.value.sessions.count) }
        return (latest, rows)
    }

    private func read(_ url: URL, label: String) {
        var st = files[url.path] ?? FileState()
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st = FileState() }
        if size == st.offset { files[url.path] = st; return }
        try? h.seek(toOffset: st.offset)
        var data = st.rest + ((try? h.readToEnd()) ?? Data())
        st.offset = size
        if let nl = data.lastIndex(of: 0x0A) { st.rest = data[(nl + 1)...]; data = data[..<nl] } else { st.rest = data; files[url.path] = st; return }
        let session = url.deletingPathExtension().lastPathComponent
        for line in data.split(separator: 0x0A) {
            guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = j["type"] as? String, type == "user" || type == "assistant",
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
                    if ts >= Calendar.current.startOfDay(for: Date()), seen.insert(id).inserted {
                        var row = usage[label] ?? (0, 0, [])
                        row.input += inp; row.output += u["output_tokens"] as? Int ?? 0; row.sessions.insert(session)
                        usage[label] = row
                    }
                }
                if let tool = content.first(where: { $0["type"] as? String == "tool_use" }) {
                    let input = tool["input"] as? [String: Any] ?? [:]
                    let what = (input["description"] as? String) ?? (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
                    st.act.detail = [tool["name"] as? String ?? "tool", what].filter { !$0.isEmpty }.joined(separator: " · ")
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

// MARK: recent sessions, for "Resume" (reads only the tail of each transcript)

struct Session { let id: String; let dir: URL; let cwd: String; let title: String; let modified: Date }

func recentSessions(days: Double = 7, limit: Int = 12) -> [Session] {
    let cutoff = Date().addingTimeInterval(-days * 86400)
    var found: [Session] = []
    for (_, dir) in accounts {
        guard let e = FileManager.default.enumerator(at: dir.appendingPathComponent("projects"),
                                                    includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
        for case let url as URL in e where url.pathExtension == "jsonl" && !url.path.contains("/subagents/") {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard mod > cutoff, let h = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let tail = (try? h.readToEnd()) ?? Data(); try? h.close()
            var cwd = "", title = "", prompt = ""
            for line in tail.split(separator: 0x0A) {
                guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let c = j["cwd"] as? String { cwd = c }
                if let t = (j["customTitle"] ?? j["aiTitle"]) as? String { title = t }
                if let t = j["lastPrompt"] as? String { prompt = t }
            }
            guard !cwd.isEmpty else { continue }
            found.append(Session(id: url.deletingPathExtension().lastPathComponent, dir: dir, cwd: cwd,
                                 title: title.isEmpty ? String(prompt.prefix(40)) : title, modified: mod))
        }
    }
    return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
}

/// CLAUDE_CONFIG_DIR value for a config dir. The default ~/.claude must stay unset: setting it explicitly makes
/// Claude Code look up a different stored login, and it asks you to log in again.
func configEnv(_ dir: URL) -> String? {
    dir.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path ? nil : dir.path
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
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompt-tool", "stdio"]
        if let id = target.id { args += ["--resume", id] }
        else { let id = UUID().uuidString.lowercased(); target.id = id; args += ["--session-id", id]; onSession(id) }
        if !target.tools { args += ["--tools", "", "--disable-slash-commands", "--append-system-prompt", persona] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec claude \"$@\"", "claude"] + args     // login shell: PATH from the user's profile
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = (target.dir ?? accounts.first?.1).flatMap(configEnv)
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
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
        catch { onEvent(.failed("I can't find the claude command.")) }
    }

    private func consume(_ d: Data) {
        buffer += d
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]; buffer = Data(buffer[(nl + 1)...])
            guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(m)
        }
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
                    onEvent(.step(describe(c["name"] as? String ?? "tool", c["input"] as? [String: Any] ?? [:])))
                }
            }
        case "control_request":
            guard let id = m["request_id"] as? String, let r = m["request"] as? [String: Any] else { return }
            if r["subtype"] as? String == "can_use_tool" {
                let input = r["input"] as? [String: Any] ?? [:]
                onEvent(.permission(id: id, title: describe(r["tool_name"] as? String ?? "tool", input, full: true), input: input))
            } else {
                write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "not supported by the pet"]])
            }
        case "result":
            busy = false
            onEvent(.done((m["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        default: break
        }
    }

    func describe(_ tool: String, _ input: [String: Any], full: Bool = false) -> String {
        let detail = (full ? input["command"] as? String : nil) ?? (input["description"] as? String) ?? (input["command"] as? String)
            ?? (input["file_path"] as? String).map { full ? $0 : ($0 as NSString).lastPathComponent }
            ?? (input["pattern"] as? String) ?? (input["url"] as? String) ?? ""
        let s = detail.isEmpty ? tool : "\(tool) · \(detail)"
        return String(s.prefix(full ? 300 : 70))
    }
}

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
    let bubble = BubbleView(), statusPill = pill(10, .regular, alpha: 0.8), card = PermissionCard()
    let input = NSTextField()
    let pollQueue = DispatchQueue(label: "pet.monitor"); var polling = false
    var talkTimer: Timer?, bubbleUntil = Date.distantPast, t: Double = 0
    var wasWorking = false, thinkingDots = 0, agentStep = ""
    var pending: [(id: String, title: String, input: [String: Any])] = []
    let headroom: CGFloat = 230
    let sizes: [(String, CGFloat)] = [("Small", 160), ("Medium", 240), ("Large", 340)]
    var height: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "height") as? Double ?? 240) }

    var petChatID: String? {
        get { UserDefaults.standard.string(forKey: "chatSession") }
        set { UserDefaults.standard.set(newValue, forKey: "chatSession") }
    }
    func petChat() -> Target { Target(id: petChatID, cwd: home.path, dir: accounts.first?.1, tools: false, name: "Pet chat") }
    lazy var agent = Agent(target: petChat())

    func applicationDidFinishLaunching(_ n: Notification) {
        window = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true ? .floating : .normal
        view = PetView(sprite: sprite); view.onClick = { [weak self] in self?.toggleInput() }
        window.contentView = view
        input.isHidden = true; input.delegate = self
        input.focusRingType = .none; input.bezelStyle = .roundedBezel; input.font = .systemFont(ofSize: 12)
        [statusPill, bubble, card, input].forEach { view.addSubview($0) }
        card.onAnswer = { [weak self] ok in self?.answerPermission(ok) }
        agent.onEvent = { [weak self] e in self?.agentEvent(e) }
        agent.onSession = { [weak self] id in if self?.agent.target.tools == false { self?.petChatID = id } }
        monitor.ignoreSession = { [weak self] in self?.agent.target.id }
        resize(height, keepBottom: false)
        updatePlaceholder()
        window.orderFrontRegardless()
        setupMenu()
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollActivity() }
        pollActivity()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.say("Hello. Click me to chat.") }
    }

    func resize(_ h: CGFloat, keepBottom: Bool = true) {
        let w = max(h * sprite.aspect, 300), total = h + headroom
        var origin: NSPoint
        if keepBottom { origin = NSPoint(x: window.frame.midX - w / 2, y: window.frame.minY) }
        else if let s = UserDefaults.standard.string(forKey: "origin") { origin = NSPointFromString(s) }
        else { let v = NSScreen.main!.visibleFrame; origin = NSPoint(x: v.maxX - w - 40, y: v.minY + 10) }
        window.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: total)), display: true)
        view.spriteHeight = h
        input.frame = NSRect(x: 8, y: h + 4, width: w - 16, height: 24)
        layoutBubble()
        UserDefaults.standard.set(Double(h), forKey: "height")
    }

    func layoutBubble() {   // stacked upward from the head: [input] [status] [card or bubble]
        let w = window.frame.width
        var y = view.spriteHeight + (input.isHidden ? 6 : 32)
        let fit = statusPill.sizeThatFits(NSSize(width: w - 24, height: .greatestFiniteMagnitude))
        statusPill.frame = NSRect(x: 4, y: y, width: w - 8, height: min(fit.height + 6, 30))
        if !statusPill.isHidden { y += statusPill.frame.height + 4 }
        let room = view.spriteHeight + headroom - y - 4
        card.frame = NSRect(x: 4, y: y, width: w - 8, height: min(130, room))
        bubble.frame = NSRect(x: 4, y: y, width: w - 8, height: min(bubble.fittingHeight(width: w - 8), room))
    }

    func tick() {   // slow breathing bob; the bubble stays up while the input box is open or Claude is working
        t += 1 / 30
        view.bob = CGFloat(sin(t * 2 * .pi / 3.2) + 1) * view.spriteHeight * 0.006
        if !bubble.isHidden && Date() > bubbleUntil && !agent.busy && input.isHidden { bubble.isHidden = true }
        if !card.isHidden { bubble.isHidden = true }
        let pillHidden = statusPill.stringValue.isEmpty
        if statusPill.isHidden != pillHidden { statusPill.isHidden = pillHidden; layoutBubble() }
    }

    func say(_ text: String, hold: TimeInterval? = nil) {
        bubble.string = text; bubble.isHidden = !card.isHidden; layoutBubble()
        bubbleUntil = Date().addingTimeInterval(hold ?? max(4, Double(text.count) / 12))
        talkTimer?.invalidate()
        var n = 0
        let steps = min(8 + text.count / 2, 60)   // mouth flaps ~ text length
        talkTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] tm in
            guard let self else { return }
            n += 1
            self.view.frameIndex = n >= steps ? 0 : [0, 1, 2, 1][n % 4]
            if n >= steps { tm.invalidate() }
        }
    }
    func readTime(_ s: String) -> TimeInterval { 15 + Double(s.count) / 4 }   // ~4 CJK chars/s, plus slack

    // input
    func updatePlaceholder() { input.placeholderString = "Message \(agent.target.name)…" }
    func toggleInput() {
        if !input.isHidden { closeInput(); return }
        input.isHidden = false; layoutBubble()
        NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(input)
    }
    func closeInput() { input.isHidden = true; input.stringValue = ""; layoutBubble(); window.resignKey() }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { closeInput(); return true }
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agent.busy else { return true }
        input.stringValue = ""
        thinkingDots = 0; agentStep = ""; say("·", hold: 3600)
        agent.send(text)
        return true
    }

    // agent events
    func agentEvent(_ e: Agent.Event) {
        switch e {
        case .text(let s): say(s, hold: 3600)
        case .step(let s): agentStep = s
        case .permission(let id, let title, let input):
            pending.append((id, title, input)); showCard()
        case .done(let s):
            agentStep = ""
            if !s.isEmpty { say(s, hold: readTime(s)) } else { bubbleUntil = Date().addingTimeInterval(readTime(bubble.string)) }
        case .failed(let s): agentStep = ""; say(s)
        }
        refreshPill()
    }
    func showCard() {
        guard let p = pending.first else { card.isHidden = true; layoutBubble(); return }
        card.label.stringValue = "\(agent.target.name) wants to run:\n\(p.title)"
        card.isHidden = false; bubble.isHidden = true; layoutBubble()
        window.orderFrontRegardless()
        say("May I?", hold: 2); bubble.isHidden = true
    }
    func answerPermission(_ ok: Bool) {
        guard !pending.isEmpty else { return }
        let p = pending.removeFirst()
        agent.answer(permission: p.id, allow: ok, input: p.input)
        showCard()
    }

    // status pill: the attached session's step, otherwise whatever other Claude Code session is busy
    var otherActivity = ""
    func refreshPill() {
        if agent.busy { statusPill.stringValue = agentStep.isEmpty ? "\(agent.target.name): thinking" : "\(agent.target.name): \(agentStep)" }
        else { statusPill.stringValue = otherActivity }
        layoutBubble()
    }

    // Claude Code activity in other sessions
    func pollActivity() {
        if !polling {   // the first scan of big transcripts can take longer than the 2s tick
            polling = true
            pollQueue.async { [weak self] in
                guard let self else { return }
                let (act, rows) = self.monitor.poll()
                DispatchQueue.main.async { self.polling = false; self.show(act, rows) }
            }
        }
        if agent.busy && card.isHidden && bubble.string.allSatisfy({ $0 == "·" }) {
            thinkingDots = (thinkingDots + 1) % 3; bubble.string = String(repeating: "·", count: thinkingDots + 1)
        }
    }

    func show(_ act: Activity?, _ rows: [(String, Int, Int, Int)]) {
        let fresh = act.map { Date().timeIntervalSince($0.last) < 600 } ?? false
        let working = fresh && (act?.working ?? false)
        otherActivity = working ? "\(act!.project): \(act!.detail)" : ""
        if wasWorking && !working, let a = act, fresh, a.last.timeIntervalSince(a.since) > 20, !agent.busy {
            say("Done in \(a.project). Your turn.")
        }
        wasWorking = working
        refreshPill()
        let total = rows.reduce(0) { $0 + $1.2 }
        status.button?.title = total > 0 ? "✦ \(short(total))" : "✦"
        usageItems.forEach { status.menu?.removeItem($0) }
        usageItems = rows.map { r in NSMenuItem(title: "\(r.0): \(short(r.2)) out · \(short(r.1)) in · \(r.3) sessions", action: nil, keyEquivalent: "") }
        if let a = act, a.context > 0 { usageItems.append(NSMenuItem(title: "Context (\(a.project)): \(short(a.context))", action: nil, keyEquivalent: "")) }
        for (i, it) in usageItems.enumerated() { status.menu?.insertItem(it, at: 1 + i) }
    }
    func short(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)" }

    // menu
    var usageItems: [NSMenuItem] = []
    var sessionLabel: NSMenuItem!, switchMenu = NSMenu(), terminalMenu = NSMenu()
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

    var sessions: [Session] = []
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === status.menu { sessionLabel.title = "Talking to: \(agent.target.name)\(agent.target.tools ? "" : " (no tools)")"; return }
        menu.removeAllItems()
        sessions = recentSessions()
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        let toTerminal = menu === terminalMenu
        if !toTerminal {
            let it = menu.addItem(withTitle: "Pet chat (no tools)", action: #selector(switchToPetChat), keyEquivalent: "")
            it.target = self; it.state = agent.target.tools ? .off : .on
            menu.addItem(.separator())
        }
        for (i, s) in sessions.enumerated() where s.id != petChatID {
            let it = menu.addItem(withTitle: "\(label(s))  ·  \(rel.localizedString(for: s.modified, relativeTo: Date()))",
                                  action: toTerminal ? #selector(openInTerminal(_:)) : #selector(switchSession(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = s.id == agent.target.id ? .on : .off
        }
        if !toTerminal {
            menu.addItem(.separator())
            menu.addItem(withTitle: "New session in folder…", action: #selector(newSessionInFolder), keyEquivalent: "").target = self
        }
    }
    func label(_ s: Session) -> String {
        "\((s.cwd as NSString).lastPathComponent) — \(s.title.isEmpty ? String(s.id.prefix(8)) : String(s.title.prefix(40)))"
    }
    func switchTo(_ t: Target) {
        agent.attach(t); pending = []; card.isHidden = true; agentStep = ""
        updatePlaceholder(); refreshPill()
        say(t.tools ? "Attached to \(t.name). I can use tools here; I'll ask before anything risky." : "Back to our chat.")
    }
    @objc func switchToPetChat() { switchTo(petChat()) }
    @objc func switchSession(_ item: NSMenuItem) {
        let s = sessions[item.tag]
        switchTo(Target(id: s.id, cwd: s.cwd, dir: s.dir, tools: true, name: label(s)))
    }
    @objc func newSessionInFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switchTo(Target(id: nil, cwd: url.path, dir: accounts.first?.1, tools: true, name: url.lastPathComponent))
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
