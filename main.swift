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

// MARK: chat with a persistent headless session

final class Chat {
    var sessionID: String? {
        get { UserDefaults.standard.string(forKey: "chatSession") }
        set { UserDefaults.standard.set(newValue, forKey: "chatSession") }
    }
    var busy = false

    func send(_ text: String, done: @escaping (String) -> Void) {
        busy = true
        let resume = sessionID != nil
        let id = sessionID ?? UUID().uuidString.lowercased()
        var args = ["-p", text, "--output-format", "json", "--tools", "", "--disable-slash-commands",
                    "--append-system-prompt", persona]
        args += resume ? ["--resume", id] : ["--session-id", id]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec claude \"$@\"", "claude"] + args     // login shell: PATH from the user's profile
        var env = ProcessInfo.processInfo.environment
        if let dir = accounts.first?.1 { env["CLAUDE_CONFIG_DIR"] = dir.path }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.currentDirectoryURL = home
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        p.terminationHandler = { [weak self] _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            var reply = "…I lost my train of thought. Try again?"
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let r = j["result"] as? String, !r.isEmpty { reply = r }
                if let sid = j["session_id"] as? String { DispatchQueue.main.async { self?.sessionID = sid } }
            }
            DispatchQueue.main.async { self?.busy = false; done(reply.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        do { try p.run(); if !resume { sessionID = id } } catch { busy = false; done("I can't find the claude command.") }
    }
}

// MARK: app

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let sprite = Sprite(), monitor = Monitor(), chat = Chat()
    var window: PetWindow!, view: PetView!, status: NSStatusItem!
    let bubble = pill(12, .medium, alpha: 0.96), statusPill = pill(10, .regular, alpha: 0.75)
    let input = NSTextField()
    let pollQueue = DispatchQueue(label: "pet.monitor"); var polling = false
    var talkTimer: Timer?, bubbleUntil = Date.distantPast, t: Double = 0
    var wasWorking = false, thinkingDots = 0
    let headroom: CGFloat = 170
    let sizes: [(String, CGFloat)] = [("Small", 160), ("Medium", 240), ("Large", 340)]
    var height: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "height") as? Double ?? 240) }

    func applicationDidFinishLaunching(_ n: Notification) {
        window = PetWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true ? .floating : .normal
        view = PetView(sprite: sprite); view.onClick = { [weak self] in self?.toggleInput() }
        window.contentView = view
        input.placeholderString = "Say something…"; input.isHidden = true; input.delegate = self
        input.focusRingType = .none; input.bezelStyle = .roundedBezel; input.font = .systemFont(ofSize: 12)
        [statusPill, bubble, input].forEach { view.addSubview($0) }
        monitor.ignoreSession = { [weak self] in self?.chat.sessionID }
        resize(height, keepBottom: false)
        window.orderFrontRegardless()
        setupMenu()
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollActivity() }
        pollActivity()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.say("Hello. Click me to chat.") }
    }

    func resize(_ h: CGFloat, keepBottom: Bool = true) {
        let w = max(h * sprite.aspect, 260), total = h + headroom
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

    func layoutBubble() {   // bubble sits on the input (or the head) and grows upward with the text
        let w = window.frame.width, base = view.spriteHeight + (input.isHidden ? 6 : 32)
        for (f, maxH) in [(bubble, headroom - 40), (statusPill, CGFloat(32))] {
            let fit = f.sizeThatFits(NSSize(width: w - 24, height: .greatestFiniteMagnitude))
            f.frame = NSRect(x: 4, y: base, width: w - 8, height: min(fit.height + 8, maxH))
        }
    }

    func tick() {   // slow breathing bob
        t += 1 / 30
        view.bob = CGFloat(sin(t * 2 * .pi / 3.2) + 1) * view.spriteHeight * 0.006
        if !bubble.isHidden && Date() > bubbleUntil && !chat.busy && input.isHidden {   // stays up while chatting bubble.isHidden = true; layoutBubble() }
        statusPill.isHidden = statusPill.stringValue.isEmpty || !bubble.isHidden
    }

    func say(_ text: String, hold: TimeInterval? = nil) {
        bubble.stringValue = text; bubble.isHidden = false; layoutBubble()
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

    // chat
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
        guard !text.isEmpty, !chat.busy else { return true }
        input.stringValue = ""
        thinkingDots = 0; say("…", hold: 600)
        chat.send(text) { [weak self] reply in self?.say(reply, hold: 15 + Double(reply.count) / 4)   // ~4 CJK chars/s reading speed, plus slack }
        return true
    }

    // Claude Code activity
    func pollActivity() {
        if !polling {   // the first scan of big transcripts can take longer than the 2s tick
            polling = true
            pollQueue.async { [weak self] in
                guard let self else { return }
                let (act, rows) = self.monitor.poll()
                DispatchQueue.main.async { self.polling = false; self.show(act, rows) }
            }
        }
        if chat.busy { thinkingDots = (thinkingDots + 1) % 3; bubble.stringValue = String(repeating: "·", count: thinkingDots + 1) }
    }

    func show(_ act: Activity?, _ rows: [(String, Int, Int, Int)]) {
        let fresh = act.map { Date().timeIntervalSince($0.last) < 600 } ?? false
        if let a = act, fresh, a.working {
            statusPill.stringValue = "\(a.project): \(a.detail)"
        } else { statusPill.stringValue = "" }
        let working = fresh && (act?.working ?? false)
        if wasWorking && !working, let a = act, fresh, a.last.timeIntervalSince(a.since) > 20 {
            say("Done in \(a.project). Your turn.")
        }
        wasWorking = working
        layoutBubble()
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
    func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "✦"
        let m = NSMenu()
        m.addItem(withTitle: "Today's usage (output tokens in the icon)", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Chat…", action: #selector(openChat), keyEquivalent: "")
        m.addItem(withTitle: "New chat", action: #selector(newChat), keyEquivalent: "")
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
        status.menu = m
    }
    @objc func openChat() { if input.isHidden { toggleInput() } }
    @objc func newChat() { chat.sessionID = nil; say("Fresh start.") }
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
        a.informativeText = "Character: ZipZipPipe (胖次狐) original design; 3-heads-tall pixel version is a derivative work. CC BY-NC-SA 4.0. Non-commercial. Not affiliated with Anthropic."
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
