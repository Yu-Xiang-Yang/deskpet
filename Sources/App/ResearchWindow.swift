import AppKit
import WebKit

/// The message list: the daily chat log and the research conversations, with Markdown/LaTeX rendering.
/// Research turns run in the shared ResearchEngine (also used by the pet in research mode).
/// Main-actor isolated (inferred from the WebKit delegate protocols); network work suspends, it does not block.
@MainActor
final class ResearchWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let store = ConversationStore.shared
    private var window: NSWindow?
    private var webView: WKWebView!
    private var ready = false
    private var selectedID: String?
    private let engine: ResearchEngine
    /// The conversation whose answer is streaming into this window (not refreshed from the store meanwhile).
    private var streamingID: String?

    /// Sends a daily-chat message through the pet persona.
    var onDailyMessage: ((String) -> Void)?

    init(engine: ResearchEngine) {
        self.engine = engine
        super.init()
        NotificationCenter.default.addObserver(forName: ConversationStore.didChange, object: nil, queue: .main) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated { self?.storeChanged(id) }
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(conversationID: String? = nil) {
        if window == nil { build() }
        if let conversationID { select(conversationID) }
        // A click on the pet (a non-activating panel) leaves another app active; since macOS 14 activation
        // is cooperative, so the window is also ordered front explicitly.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        if ready { webView.evaluateJavaScript("research.focus()") }
    }

    private func build() {
        webView = WKWebView.make(handlerName: "research", handler: self)
        webView.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = tr("消息列表", "Messages")
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DeskPetResearch")
        self.window = window
        webView.load(URLRequest(url: AppSchemeHandler.url("web/research.html")))
    }

    // MARK: Page

    private func js(_ fn: String, _ args: JSON...) {
        guard ready else { return }
        let list = args.map { $0.compactString }.joined(separator: ",")
        webView.evaluateJavaScript("\(fn)(\(list))")
    }

    private func pageInit() {
        let strings: [String: JSON] = L10n.current == .zh ? [:] : [
            "daily": "Daily chat", "research": "Research", "empty": "Ask a research question: literature search, derivations, method comparisons, writing…",
            "emptyDaily": "The daily conversation with your pet is kept here.", "send": "Send", "stop": "Stop", "copy": "Copy",
            "copied": "Copied", "sources": "Sources", "rename": "Rename", "del": "Delete", "newTitle": "New research chat",
            "web": "Search literature online", "placeholder": "Ask a research question, ⌘↩ to send",
            "placeholderDaily": "Chat with your pet, ⌘↩ to send", "search": "Search titles",
        ]
        js("research.init", ["strings": .object(strings), "web": .bool(engine.webSearch)])
        refreshList()
        select(selectedID ?? store.list().first(where: { $0.kind == .research })?.id ?? ConversationStore.dailyID)
    }

    private func refreshList() {
        let items: [JSON] = store.list().map {
            ["id": .string($0.id), "title": .string($0.title), "kind": .string($0.kind.rawValue),
             "updated": .number($0.updated.timeIntervalSince1970 * 1000), "count": .number(Double($0.count))]
        }
        js("research.setList", .array(items), selectedID.map(JSON.string) ?? .null)
    }

    private func select(_ id: String) {
        selectedID = id
        let conversation = id == ConversationStore.dailyID ? store.daily() : (store.load(id) ?? store.daily())
        selectedID = conversation.id
        js("research.show", [
            "id": .string(conversation.id), "title": .string(conversation.title), "kind": .string(conversation.kind.rawValue),
            "meta": .string(metaText), "messages": .array(conversation.messages.map(Self.display)),
        ])
        js("research.setBusy", .bool(streamingID == conversation.id))
    }

    private var metaText: String {
        settings.provider == .anthropic ? settings.anthropicModel : settings.openaiModel
    }

    static func display(_ m: StoredMessage) -> JSON {
        var o: [String: JSON] = ["id": .string(m.id.uuidString), "role": .string(m.role.rawValue), "text": .string(m.text),
                                 "date": .number(m.date.timeIntervalSince1970 * 1000)]
        if let c = m.citations { o["citations"] = .array(c.map { ["title": .string($0.title), "url": .string($0.url)] }) }
        return .object(o)
    }

    private func storeChanged(_ id: String?) {
        guard ready else { return }
        refreshList()
        // Conversations written elsewhere (the pet's chat, research mode, title updates) are re-rendered
        // when on screen, unless an answer is streaming into this view.
        if let id, id == selectedID, streamingID != id { select(id) }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            pageInit()
        case "select":
            if let id = body["id"] as? String { select(id); refreshList() }
        case "new":
            let c = store.newResearch()
            store.save(c)
            select(c.id)
            refreshList()
        case "send":
            guard let id = body["id"] as? String, let text = body["text"] as? String else { return }
            engine.webSearch = body["web"] as? Bool ?? engine.webSearch
            send(conversationID: id, text: text)
        case "stop":
            engine.cancel()
        case "web":
            engine.webSearch = body["on"] as? Bool ?? true
        case "rename":
            if let id = body["id"] as? String { rename(id, current: body["title"] as? String ?? "") }
        case "delete":
            if let id = body["id"] as? String { delete(id, title: body["title"] as? String ?? "") }
        case "openURL":
            if let s = body["url"] as? String, let url = URL(string: s), ["http", "https"].contains(url.scheme) {
                NSWorkspace.shared.open(url)
            }
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
        case "log":
            NSLog("[research.js] %@", body["text"] as? String ?? "")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page never navigates away; external links open in the default browser.
        if action.request.url?.scheme == AppSchemeHandler.scheme { decisionHandler(.allow); return }
        if let url = action.request.url, ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    // MARK: Rename / delete

    private func rename(_ id: String, current: String) {
        let alert = NSAlert()
        alert.messageText = tr("重命名对话", "Rename conversation")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: tr("确定", "OK"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !title.isEmpty else { return }
            self?.store.rename(id, to: title)
            self?.select(id)
        }
    }

    private func delete(_ id: String, title: String) {
        guard id != ConversationStore.dailyID, let window else { return }
        let alert = NSAlert()
        alert.messageText = tr("删除“\(title)”？", "Delete “\(title)”?")
        alert.informativeText = tr("该对话的全部记录将被删除，且无法恢复。", "All messages of this conversation will be deleted permanently.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("删除", "Delete"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if self.engine.runningID == id { self.engine.cancel() }
            self.store.delete(id)
            self.select(self.store.list().first(where: { $0.kind == .research })?.id ?? ConversationStore.dailyID)
        }
    }

    // MARK: Research turn

    private func send(conversationID: String, text: String) {
        if conversationID == ConversationStore.dailyID {
            // The daily chat is the pet's conversation: the pet answers with a bubble, and the store
            // notification refreshes this view.
            onDailyMessage?(text)
            return
        }
        guard !engine.isBusy else { return }
        var events = ResearchEngine.Events()
        events.onStart = { [weak self] id, user, assistantID in
            guard let self else { return }
            if let c = self.store.load(id), c.messages.count == 1 { self.js("research.setTitle", .string(id), .string(c.title)) }
            self.js("research.append", Self.display(user))
            self.js("research.begin", .string(assistantID.uuidString))
            self.js("research.setBusy", .bool(true))
        }
        events.onDelta = { [weak self] aid, piece in self?.js("research.delta", .string(aid.uuidString), .string(piece)) }
        events.onStatus = { [weak self] aid, status in self?.js("research.status", .string(aid.uuidString), .string(status)) }
        events.onFinish = { [weak self] aid, text, citations in
            self?.js("research.finish", .string(aid.uuidString), .string(text),
                     .array(citations.map { ["title": .string($0.title), "url": .string($0.url)] }))
        }
        events.onFail = { [weak self] aid, message in self?.js("research.fail", .string(aid.uuidString), .string(message)) }
        events.onEnd = { [weak self] in
            self?.streamingID = nil
            self?.js("research.setBusy", .bool(false))
        }
        // Mark the view as streaming before the engine stores the question, so the store notification
        // does not re-render the conversation underneath the live answer.
        streamingID = conversationID
        if engine.ask(text, in: conversationID, events: events) == nil { streamingID = nil }
    }
}
