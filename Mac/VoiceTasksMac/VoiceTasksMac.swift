import SwiftUI
import AVFoundation
import Security
import AppKit
import Carbon

struct TaskItem: Codable, Identifiable {
    var id = UUID()
    var content: String
    var due_string: String?
    var description: String?
    var project_id: String?
    enum CodingKeys: String, CodingKey { case content, due_string, description, project_id }
}
struct TodoistProject: Decodable, Identifiable { let id: String; let name: String; let inbox_project: Bool? }
struct TickProject: Decodable { let id: String; let name: String; let closed: Bool?; let kind: String? }
enum TaskService: String, CaseIterable, Identifiable { case todoist = "Todoist", ticktick = "TickTick"; var id: String { rawValue } }
struct ProjectPage: Decodable { let results: [TodoistProject]; let next_cursor: String? }

enum Vault {
    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true]
        var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return "" }; return String(data: d, encoding: .utf8) ?? ""
    }
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        if !value.isEmpty { var a = q; a[kSecValueData as String] = Data(value.utf8); SecItemAdd(a as CFDictionary, nil) }
    }
}
@MainActor final class Model: ObservableObject {
    @Published var groq = Vault.get("groq")
    @Published var todoist = Vault.get("todoist")
    @Published var ticktick = Vault.get("ticktick")
    @Published var service: TaskService = TaskService(rawValue: UserDefaults.standard.string(forKey: "service") ?? "") ?? .todoist
    private var currentToken: String { (service == .todoist ? todoist : ticktick).trimmingCharacters(in: .whitespacesAndNewlines) }
    @Published var vocabulary = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
    @Published var recording = false
    @Published var busy = false
    @Published var status = "Ready to capture"
    @Published var transcript = ""
    @Published var tasks: [TaskItem] = []
    @Published var projects: [TodoistProject] = []
    @Published var projectsStatus = ""
    var recorder: AVAudioRecorder?
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-tasks.m4a")
    func saveSettings() { Vault.set("groq", groq.trimmingCharacters(in: .whitespacesAndNewlines)); Vault.set("todoist", todoist.trimmingCharacters(in: .whitespacesAndNewlines)); Vault.set("ticktick", ticktick.trimmingCharacters(in: .whitespacesAndNewlines)); UserDefaults.standard.set(service.rawValue, forKey: "service"); UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    func switchService(_ newService: TaskService) {
        guard newService != service, !busy else { return }
        service = newService
        UserDefaults.standard.set(service.rawValue, forKey: "service")
        for index in tasks.indices { tasks[index].project_id = nil }
        projects = []; projectsStatus = ""
        Task { await loadProjects() }
    }
    func loadProjects() async {
        let token = currentToken, selected = service
        guard !token.isEmpty else { projects = []; projectsStatus = "Add a \(selected.rawValue) token in Settings to load lists."; return }
        projectsStatus = "Loading lists…"
        do {
            var all: [TodoistProject] = []
            if selected == .todoist {
                var cursor: String? = nil
                repeat {
                    var url = URLComponents(string: "https://api.todoist.com/api/v1/projects")!
                    var items = [URLQueryItem(name: "limit", value: "200")]
                    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }; url.queryItems = items
                    var req = URLRequest(url: url.url!); req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    let page = try JSONDecoder().decode(ProjectPage.self, from: try await request(req))
                    all.append(contentsOf: page.results); cursor = page.next_cursor
                } while cursor != nil
                all = all.filter { $0.inbox_project != true }
            } else {
                var req = URLRequest(url: URL(string: "https://api.ticktick.com/open/v1/project")!)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let result = try JSONDecoder().decode([TickProject].self, from: try await request(req))
                all = result.filter { $0.closed != true && ($0.kind == nil || $0.kind?.uppercased() == "TASK") }.map { TodoistProject(id: $0.id, name: $0.name, inbox_project: nil) }
            }
            guard selected == service && token == currentToken else { return }
            projects = all; projectsStatus = ""
        } catch {
            guard selected == service && token == currentToken else { return }
            projects = []; projectsStatus = "Couldn't load \(selected.rawValue) lists. Check your token and connection."
        }
    }
    func start() async {
        guard !groq.isEmpty else { status = "Add your Groq API key in Settings first."; return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { status = "Microphone access is needed. Enable it in iPhone Settings."; return }
        do {
            recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
            guard recorder?.record() == true else { throw NSError(domain: "Recording could not start", code: 1) }
            recording = true; status = "Listening…"
        } catch { status = error.localizedDescription }
    }
    func cancelRecording() {
        guard recording else { return }
        recorder?.stop(); recorder = nil; recording = false
        try? FileManager.default.removeItem(at: file)
        status = "Recording cancelled."
    }
    func stop() async {
        recorder?.stop(); recording = false; busy = true; status = "Transcribing…"
        defer { busy = false; try? FileManager.default.removeItem(at: file) }
        do {
            let boundary = UUID().uuidString
            var body = Data()
            func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
            field("model", "whisper-large-v3"); field("language", "en"); field("prompt", vocabulary)
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)); body.append(try Data(contentsOf: file)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!); req.httpMethod = "POST"; req.setValue("Bearer \(groq)", forHTTPHeaderField: "Authorization"); req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); req.httpBody = body
            let data = try await request(req); let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]; let currentTranscript = obj?["text"] as? String ?? ""
            guard !currentTranscript.isEmpty else { throw NSError(domain: "No speech was recognized", code: 1) }
            status = "Finding tasks…"
            let now = ISO8601DateFormatter().string(from: Date())
            let prompt = "Extract actionable tasks from the transcript. Preserve Sri Lankan names and local words. Apply spoken corrections. Current date/time: \(now). User timezone: \(TimeZone.current.identifier). Output only JSON object with tasks array. Each task has content, optional description, and optional due_string. Use YYYY-MM-DD for date-only and ISO 8601 date-time with timezone offset for an explicitly stated time. Include dates only if explicitly specified. Do not invent tasks or dates. Transcript: \(currentTranscript)"
            var chat = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!); chat.httpMethod = "POST"; chat.setValue("Bearer \(groq)", forHTTPHeaderField: "Authorization"); chat.setValue("application/json", forHTTPHeaderField: "Content-Type"); chat.httpBody = try JSONSerialization.data(withJSONObject: ["model":"openai/gpt-oss-120b", "messages":[["role":"user", "content":prompt]], "response_format":["type":"json_object"], "temperature":0])
            let result = try await request(chat); let parsed = try JSONSerialization.jsonObject(with: result) as? [String: Any]; let choices = parsed?["choices"] as? [[String: Any]]; let message = choices?.first?["message"] as? [String: Any]; guard let content = message?["content"] as? String, let json = content.data(using: .utf8) else { throw NSError(domain: "Could not read AI response", code: 1) }
            struct Result: Decodable { let tasks: [TaskItem] }; let newTasks = try JSONDecoder().decode(Result.self, from: json).tasks; tasks.append(contentsOf: newTasks); transcript = [transcript, currentTranscript].filter { !$0.isEmpty }.joined(separator: "\n\n"); status = newTasks.isEmpty ? "No tasks found in that recording." : "Review your tasks before adding."
        } catch { status = "Error: \(error.localizedDescription)" }
    }
    func request(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { let code = (response as? HTTPURLResponse)?.statusCode ?? 0; throw NSError(domain: "Request failed (HTTP \(code)). Check your key, connection and usage limits.", code: code) }; return data
    }
    func send() async {
        let selected = service, token = currentToken
        guard !token.isEmpty else { status = "Add your \(selected.rawValue) API token in Settings first."; return }
        busy = true; defer { busy = false }
        while !tasks.isEmpty {
            let item = tasks[0]
            do {
                let endpoint = selected == .todoist ? "https://api.todoist.com/api/v1/tasks" : "https://api.ticktick.com/open/v1/task"
                var req = URLRequest(url: URL(string: endpoint)!)
                req.httpMethod = "POST"; req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if selected == .todoist { req.httpBody = try JSONEncoder().encode(item) }
                else {
                    var data: [String: Any] = ["title": item.content]
                    if let project = item.project_id { data["projectId"] = project }
                    if let description = item.description, !description.isEmpty { data["content"] = description }
                    if let due = item.due_string, !due.isEmpty {
                        guard let date = DateHelper.parse(due) else { status = "Choose a valid date before adding this task."; return }
                        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = .current; format.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                        data["dueDate"] = format.string(from: date); data["isAllDay"] = !DateHelper.hasTime(due); data["timeZone"] = TimeZone.current.identifier
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: data)
                }
                _ = try await request(req); tasks.removeFirst()
            } catch { status = "Some tasks may have been added. Check \(selected.rawValue) before retrying. \(error.localizedDescription)"; return }
        }; status = "Added to \(selected.rawValue)."
    }

}

final class FloatingCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CaptureController: NSObject, ObservableObject, NSWindowDelegate {
    let model = Model()
    @Published var listening = false
    @Published var settingsVisible = false
    private var panel: NSPanel?
    private var eventTap: CFMachPort?
    private var keyDown = false
    private var starting = false
    private var holdTask: Task<Void, Never>?
    private var captureID = UUID()

    func setup() {
        Task { await model.loadProjects() }
        setupMonitor(request: true)
    }
    func setupMonitor(request: Bool) {
        if let tap = eventTap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true); return }
        if request && !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<CaptureController>.fromOpaque(info).takeUnretainedValue()
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let rightDown = (event.flags.rawValue & 0x10) != 0
            DispatchQueue.main.async { controller.keyEvent(type: type, code: code, rightDown: rightDown) }
            return Unmanaged.passUnretained(event)
        }, userInfo: pointer) else { return }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func keyEvent(type: CGEventType, code: Int64, rightDown: Bool) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            holdTask?.cancel(); keyDown = false; captureID = UUID(); model.cancelRecording(); listening = false; panel?.orderOut(nil)
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        if type == .keyDown && keyDown {
            holdTask?.cancel(); keyDown = false
            if listening || starting { captureID = UUID(); model.cancelRecording(); listening = false; panel?.orderOut(nil) }
            return
        }
        guard type == .flagsChanged, code == Int64(kVK_RightCommand) else { return }
        if rightDown && !keyDown {
            keyDown = true
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, self.keyDown else { return }
                await self.beginHold()
            }
        } else if !rightDown && keyDown {
            keyDown = false; holdTask?.cancel()
            if listening { listening = false; showReview(); Task { await model.stop() } }
        }
    }
    func beginHold() async {
        guard !model.busy, !model.recording, !starting else { return }
        let id = UUID(); captureID = id; starting = true
        showPanel(compact: true, activate: false)
        await model.start(); starting = false
        guard captureID == id, keyDown else { model.cancelRecording(); panel?.orderOut(nil); return }
        if model.recording { listening = true }
        else { showReview() }
    }
    func showPanel(compact: Bool, activate: Bool) {
        if panel == nil {
            let p = FloatingCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.isFloatingPanel = true; p.level = .floating; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.delegate = self
            p.contentView = NSHostingView(rootView: CapturePanel(controller: self)); panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame; let width: CGFloat = min(440, visible.width - 24); let height: CGFloat = compact ? 92 : min(390, visible.height - 40)
        p.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 24, width: width, height: height), display: true, animate: true)
        if activate { NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil) } else { p.orderFrontRegardless() }
    }
    func showReview() { showPanel(compact: false, activate: true) }
    func dismiss() { captureID = UUID(); keyDown = false; holdTask?.cancel(); model.cancelRecording(); listening = false; panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { dismiss() }
    func windowDidResignKey(_ notification: Notification) {
        guard !listening && !starting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow, !NSApp.isActive, !self.listening, !self.starting, !self.keyDown else { return }
            self.dismiss()
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = CaptureController()
    var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Tasks")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Voice Tasks", action: #selector(openPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Enable Right Command", action: #selector(enableShortcut), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Voice Tasks", action: #selector(quitApp), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }; item.menu = menu; statusItem = item
        controller.setup()
    }
    @objc func openPanel() { controller.showReview() }
    @objc func enableShortcut() { controller.setupMonitor(request: true) }
    @objc func quitApp() { controller.dismiss(); NSApp.terminate(nil) }
}
@main struct VoiceTasksMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
struct CapturePanel: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var model: Model
    private let background = Color(red: 0.11, green: 0.11, blue: 0.13)
    private let card = Color(red: 0.16, green: 0.16, blue: 0.18)
    private let coral = Color(red: 0.96, green: 0.42, blue: 0.35)
    init(controller: CaptureController) { self.controller = controller; self.model = controller.model }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.listening {
                HStack(spacing: 14) {
                    Image(systemName: "waveform").font(.system(size: 23, weight: .semibold)).foregroundStyle(coral)
                        .frame(width: 46, height: 46).background(coral.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Listening").font(.system(size: 15, weight: .semibold))
                        Text("Release ⌘ to review").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(coral).frame(width: 7, height: 7)
                }.padding(.horizontal, 20).frame(maxHeight: .infinity)
            } else {
                header
                if controller.settingsVisible { settings }
                else { review }
            }
        }
        .foregroundStyle(Color.white.opacity(0.93))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .preferredColorScheme(.dark)
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform").foregroundStyle(coral).font(.system(size: 15, weight: .bold))
            Text(controller.settingsVisible ? "Settings" : "Voice Tasks").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { controller.settingsVisible.toggle() } label: { Image(systemName: controller.settingsVisible ? "chevron.left" : "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(controller.settingsVisible ? "Back" : "Settings")
            Button { controller.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Hide")
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 13)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Task app", selection: Binding(get: { model.service }, set: { model.switchService($0) })) { ForEach(TaskService.allCases) { Text($0.rawValue).tag($0) } }
            SecureField("Groq API key", text: $model.groq)
            SecureField("Todoist API token", text: $model.todoist)
            SecureField("TickTick API token", text: $model.ticktick)
            TextField("Names and local words", text: $model.vocabulary)
            HStack { Spacer(); Button("Save settings") { model.saveSettings(); controller.settingsVisible = false; Task { await model.loadProjects() } }.buttonStyle(.borderedProminent).tint(coral) }
        }.padding(.horizontal, 18).padding(.bottom, 18)
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.busy { HStack(spacing: 9) { ProgressView().controlSize(.small); Text(model.status).foregroundStyle(.secondary) }.padding(.vertical, 10) }
                    if model.tasks.isEmpty && !model.busy && model.status == "Ready to capture" {
                        Text("Hold Right Command to speak").foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach($model.tasks) { $item in
                        MacTaskRow(item: $item, projects: model.projects) { model.tasks.removeAll { $0.id == item.id } }
                    }
                    if !model.transcript.isEmpty { DisclosureGroup("What you said") { Text(model.transcript).textSelection(.enabled).font(.caption).foregroundStyle(.secondary).padding(.top, 5) }.font(.caption).foregroundStyle(.secondary).padding(.top, 4) }
                    if !model.projectsStatus.isEmpty { HStack { Text(model.projectsStatus); Button("Retry") { Task { await model.loadProjects() } } }.font(.caption).foregroundStyle(.secondary) }
                    if !model.busy && model.status != "Ready to capture" && model.status != "Review your tasks before adding." { Text(model.status).foregroundStyle(.secondary).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if !model.tasks.isEmpty {
                HStack {
                    Label(model.service.rawValue, systemImage: "tray").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add tasks") { Task { await model.send(); if model.tasks.isEmpty && model.status.hasPrefix("Added") { controller.dismiss() } } }
                        .buttonStyle(.borderedProminent).tint(coral).disabled(model.busy || model.tasks.contains { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }.padding(.horizontal, 18).padding(.vertical, 14).background(.white.opacity(0.025))
            }
        }
    }
}
struct MacTaskRow: View {
    @Binding var item: TaskItem
    let projects: [TodoistProject]
    let remove: () -> Void
    @State private var editingDate = false
    @State private var showDescription = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "circle").foregroundStyle(.secondary).padding(.top, 2)
                TextField("Task", text: $item.content, axis: .vertical).textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove task")
            }
            if showDescription || !(item.description ?? "").isEmpty {
                TextField("Add description", text: Binding(get: { item.description ?? "" }, set: { item.description = $0.isEmpty ? nil : $0 }), axis: .vertical).textFieldStyle(.plain).font(.caption).padding(.leading, 23)
            }
            HStack(spacing: 7) {
                Button { editingDate = true } label: { Label(DateHelper.label(item.due_string), systemImage: "calendar") }
                    .popover(isPresented: $editingDate) { MacDateEditor(value: $item.due_string) }
                Menu {
                    Button("Inbox") { item.project_id = nil }
                    ForEach(projects) { project in Button(project.name) { item.project_id = project.id } }
                } label: { Label(projects.first(where: { $0.id == item.project_id })?.name ?? "Inbox", systemImage: "tray") }
                Spacer()
                if !showDescription && (item.description ?? "").isEmpty { Button { showDescription = true } label: { Image(systemName: "text.alignleft") }.help("Add description") }
            }.font(.caption).buttonStyle(.borderless).foregroundStyle(Color.white.opacity(0.65)).padding(.leading, 23)
        }.padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }
}
struct MacDateEditor: View {
    @Binding var value: String?
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var hasTime = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Due date").font(.headline)
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Toggle("Add time", isOn: $hasTime)
            if hasTime { DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute) }
            HStack {
                if value != nil { Button("Remove") { value = nil; dismiss() } }
                Spacer(); Button("Cancel") { dismiss() }
                Button("Done") { value = DateHelper.encode(date, timed: hasTime); dismiss() }.buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(width: 290)
            .onAppear { if let existing = DateHelper.parse(value) { date = existing; hasTime = DateHelper.hasTime(value) } }
    }
}

enum DateHelper {
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false; return f }()
    static let localDateTime: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if value.count == 10 { return day.date(from: value) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: value) { return d }
        iso.formatOptions = [.withInternetDateTime]; return iso.date(from: value) ?? localDateTime.date(from: value)
    }
    static func hasTime(_ value: String?) -> Bool { value?.contains("T") == true }
    static func label(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Add date" }
        guard let date = parse(value) else { return value }
        let f = DateFormatter(); f.doesRelativeDateFormatting = true; f.dateStyle = .medium; f.timeStyle = hasTime(value) ? .short : .none
        return f.string(from: date)
    }
    static func encode(_ date: Date, timed: Bool) -> String {
        if !timed { return day.string(from: date) }
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]; return f.string(from: date)
    }
}
