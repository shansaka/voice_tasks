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
            recording = true; status = "Listening…"; tasks = []; transcript = ""
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
            let data = try await request(req); let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]; transcript = obj?["text"] as? String ?? ""
            guard !transcript.isEmpty else { throw NSError(domain: "No speech was recognized", code: 1) }
            status = "Finding tasks…"
            let now = ISO8601DateFormatter().string(from: Date())
            let prompt = "Extract actionable tasks from the transcript. Preserve Sri Lankan names and local words. Apply spoken corrections. Current date/time: \(now). User timezone: \(TimeZone.current.identifier). Output only JSON object with tasks array. Each task has content, optional description, and optional due_string. Use YYYY-MM-DD for date-only and ISO 8601 date-time with timezone offset for an explicitly stated time. Include dates only if explicitly specified. Do not invent tasks or dates. Transcript: \(transcript)"
            var chat = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!); chat.httpMethod = "POST"; chat.setValue("Bearer \(groq)", forHTTPHeaderField: "Authorization"); chat.setValue("application/json", forHTTPHeaderField: "Content-Type"); chat.httpBody = try JSONSerialization.data(withJSONObject: ["model":"openai/gpt-oss-120b", "messages":[["role":"user", "content":prompt]], "response_format":["type":"json_object"], "temperature":0])
            let result = try await request(chat); let parsed = try JSONSerialization.jsonObject(with: result) as? [String: Any]; let choices = parsed?["choices"] as? [[String: Any]]; let message = choices?.first?["message"] as? [String: Any]; guard let content = message?["content"] as? String, let json = content.data(using: .utf8) else { throw NSError(domain: "Could not read AI response", code: 1) }
            struct Result: Decodable { let tasks: [TaskItem] }; tasks = try JSONDecoder().decode(Result.self, from: json).tasks; status = tasks.isEmpty ? "No tasks found." : "Review your tasks before adding."
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

@MainActor final class AppCoordinator: ObservableObject {
    let model = Model()
    @Published var showSettings = false
    func capture() { NSApp.activate(ignoringOtherApps: true); if !model.recording && !model.busy && model.tasks.isEmpty { Task { await model.start() } } }
}
final class HotKey {
    var ref: EventHotKeyRef?
    var handler: EventHandlerRef?
    init(action: @escaping () -> Void) {
        let ptr = Unmanaged.passRetained(HotKeyAction(action)).toOpaque()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }; let box = Unmanaged<HotKeyAction>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { box.action() }; return noErr
        }, 1, &event, ptr, &handler)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x5654534B, id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
final class HotKeyAction { let action: () -> Void; init(_ action: @escaping () -> Void) { self.action = action } }
@main struct VoiceTasksMacApp: App {
    @StateObject private var app = AppCoordinator()
    @State private var hotKey: HotKey?
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Voice Tasks", id: "main") {
            MacView(model: app.model).frame(minWidth: 430, minHeight: 520)
                .task { await app.model.loadProjects(); if hotKey == nil { hotKey = HotKey { openWindow(id: "main"); app.capture() } } }
        }.defaultSize(width: 480, height: 650)
        MenuBarExtra("Voice Tasks", systemImage: "waveform") {
            Button("Start recording   ⌃⌥Space") { openWindow(id: "main"); app.capture() }
            Button("Open Voice Tasks") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit Voice Tasks") { app.model.cancelRecording(); NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
struct MacView: View {
    @ObservedObject var model: Model
    @State private var settings = false
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("Task app", selection: Binding(get: { model.service }, set: { model.switchService($0) })) { ForEach(TaskService.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 160).disabled(model.busy || model.recording)
                Spacer()
                Button("Settings") { settings = true }
            }
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                if !model.transcript.isEmpty { DisclosureGroup("What you said") { Text(model.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                ForEach($model.tasks) { $item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("Task", text: $item.content); Button { model.tasks.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        TextField("Description", text: Binding(get: { item.description ?? "" }, set: { item.description = $0.isEmpty ? nil : $0 }))
                        HStack {
                            TextField("Due date (YYYY-MM-DD or date and time)", text: Binding(get: { item.due_string ?? "" }, set: { item.due_string = $0.isEmpty ? nil : $0 }))
                            Picker("List", selection: Binding(get: { item.project_id ?? "" }, set: { item.project_id = $0.isEmpty ? nil : $0 })) { Text("Inbox").tag(""); ForEach(model.projects) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 130)
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if !model.projectsStatus.isEmpty { HStack { Text(model.projectsStatus); Button("Retry") { Task { await model.loadProjects() } } }.font(.caption) }
                if model.status != "Ready to capture" { Text(model.status).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button(model.recording ? "Stop and process" : "Start speaking") { Task { if model.recording { await model.stop() } else { await model.start() } } }.disabled(model.busy || (!model.tasks.isEmpty && !model.recording))
                if !model.tasks.isEmpty { Button("Add tasks") { Task { await model.send() } }.disabled(model.busy).buttonStyle(.borderedProminent) }
            }.controlSize(.large)
        }.padding(20).sheet(isPresented: $settings) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.title2.bold())
                SecureField("Groq API key", text: $model.groq)
                SecureField("Todoist API token", text: $model.todoist)
                SecureField("TickTick API token", text: $model.ticktick)
                TextField("Names and local words", text: $model.vocabulary)
                HStack { Spacer(); Button("Done") { model.saveSettings(); settings = false; Task { await model.loadProjects() } }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 440)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in model.cancelRecording() }
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
