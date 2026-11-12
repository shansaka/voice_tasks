import SwiftUI
import AVFoundation
import AppIntents
import Security
import UIKit

struct OpenCapture: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Capture"
    static var description = IntentDescription("Open Voice Tasks and start recording.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "startCaptureFromShortcut")
        NotificationCenter.default.post(name: Notification.Name("startCaptureFromShortcut"), object: nil)
        return .result()
    }
}
struct VoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCapture(), phrases: ["Open \(.applicationName)", "Capture tasks with \(.applicationName)"], shortTitle: "Start Voice Capture", systemImageName: "mic")
    }
}
@main struct VoiceTasksApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
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
        guard UIApplication.shared.applicationState == .active else { status = "Recording cancelled."; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
            guard recorder?.record() == true else { throw NSError(domain: "Recording could not start", code: 1) }
            recording = true; status = "Listening…"; tasks = []; transcript = ""
        } catch { status = error.localizedDescription }
    }
    func cancelRecording() {
        guard recording else { return }
        recorder?.stop(); recorder = nil; recording = false
        try? FileManager.default.removeItem(at: file)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = "Recording cancelled."
    }
    func stop() async {
        recorder?.stop(); recording = false; busy = true; status = "Transcribing…"
        defer { busy = false; try? FileManager.default.removeItem(at: file); try? AVAudioSession.sharedInstance().setActive(false) }
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
struct ContentView: View {
    @StateObject private var model = Model()
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var showTranscript = false
    @State private var confirmNewRecording = false
    private let ink = Color(red: 0.93, green: 0.92, blue: 0.90)
    private let accent = Color(red: 0.78, green: 0.29, blue: 0.23)
    private let paper = Color(red: 0.07, green: 0.07, blue: 0.08)
    private let card = Color(red: 0.14, green: 0.14, blue: 0.16)

    var body: some View {
        NavigationStack {
            ZStack {
                paper.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    GeometryReader { geometry in
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Spacer(minLength: 0)
                                    if !model.transcript.isEmpty { transcriptCard }
                                    if model.busy {
                                        HStack(spacing: 12) {
                                            ProgressView().tint(accent)
                                            Text(model.status).font(.subheadline).foregroundStyle(ink.opacity(0.7))
                                        }.padding(.vertical, 10)
                                    } else if !model.tasks.isEmpty {
                                        taskList
                                        if model.status != "Review your tasks before adding." {
                                            Text(model.status).font(.subheadline).foregroundStyle(ink.opacity(0.7))
                                        }
                                    }
                                    if !model.busy && model.status != "Ready to capture" && !model.recording && model.tasks.isEmpty {
                                        Text(model.status).font(.subheadline).foregroundStyle(ink.opacity(0.7))
                                    }
                                    Color.clear.frame(height: 1).id("bottom")
                                }
                                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
                                .frame(maxWidth: 620, minHeight: geometry.size.height, alignment: .bottomLeading)
                                .frame(maxWidth: .infinity)
                            }
                            .scrollDismissesKeyboard(.interactively)
                            .onChange(of: model.tasks.count) { oldCount, newCount in
                                if oldCount == 0 && newCount > 0 {
                                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                                }
                            }
                        }
                    }
                    bottomControls
                }
            }
            .foregroundStyle(ink)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) { settingsSheet }
            .confirmationDialog("Start a new recording?", isPresented: $confirmNewRecording, titleVisibility: .visible) {
                Button("Discard tasks and record", role: .destructive) { Task { await model.start() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Your unadded tasks will be discarded.") }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .task { await model.loadProjects(); startShortcutCaptureIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startShortcutCaptureIfNeeded() }
            else if phase == .background {
                UserDefaults.standard.set(false, forKey: "startCaptureFromShortcut")
                model.cancelRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               value == AVAudioSession.InterruptionType.began.rawValue { model.cancelRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("startCaptureFromShortcut"))) { _ in
            if scenePhase == .active { startShortcutCaptureIfNeeded() }
        }
    }

    private func startShortcutCaptureIfNeeded() {
        guard scenePhase == .active, UserDefaults.standard.bool(forKey: "startCaptureFromShortcut") else { return }
        UserDefaults.standard.set(false, forKey: "startCaptureFromShortcut")
        guard !model.recording, !model.busy else { return }
        if !model.tasks.isEmpty { confirmNewRecording = true }
        else { Task { await model.start() } }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 16, weight: .bold)).foregroundStyle(accent)
                Menu { ForEach(TaskService.allCases) { option in Button { model.switchService(option) } label: { if model.service == option { Label(option.rawValue, systemImage: "checkmark") } else { Text(option.rawValue) } } } } label: { HStack(spacing: 5) { Text(model.service.rawValue); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline.weight(.semibold)) }.disabled(model.busy || model.recording)
            }
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).background(card, in: Circle())
            }.accessibilityLabel("Settings")
        }.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 12)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($model.tasks) { $item in
                TaskCard(item: $item, projects: model.projects, projectsStatus: model.projectsStatus, remove: { model.tasks.removeAll { $0.id == item.id } })
            }
            if !model.projectsStatus.isEmpty {
                HStack {
                    Text(model.projectsStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadProjects() } }.font(.caption)
                }
            }
        }
    }

    private var transcriptCard: some View {
        DisclosureGroup(isExpanded: $showTranscript) {
            Text(model.transcript).font(.subheadline).foregroundStyle(ink.opacity(0.72))
                .lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        } label: {
            Label("What you said", systemImage: "text.quote").font(.subheadline.weight(.semibold)).foregroundStyle(ink.opacity(0.75))
        }.padding(18).background(card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            Button {
                if !model.recording && !model.tasks.isEmpty { confirmNewRecording = true }
                else { Task { if model.recording { await model.stop() } else { await model.start() } } }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.recording ? "stop.fill" : "mic.fill")
                    Text(model.recording ? "Done" : (model.tasks.isEmpty ? "Start speaking" : "Record"))
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(model.recording ? Color.white : ink)
                .background(model.recording ? accent : card, in: RoundedRectangle(cornerRadius: 16))
            }.disabled(model.busy)
            if !model.tasks.isEmpty {
                Button { Task { await model.send() } } label: {
                    HStack(spacing: 8) { Text("Add tasks"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(accent, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
                }.disabled(model.busy || model.tasks.contains { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
            .background(paper)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Task app", selection: Binding(get: { model.service }, set: { model.switchService($0) })) {
                        ForEach(TaskService.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.busy || model.recording)
                } header: { Text("Send tasks to") } footer: { Text("This choice applies to all tasks. Switching apps resets the selected lists on tasks you haven't added yet.") }
                Section {
                    SecureField("Groq API key", text: $model.groq).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Label("Voice and task recognition", systemImage: "waveform") } footer: { Text("Your Groq key is used to transcribe and understand your voice.") }
                Section {
                    SecureField("Todoist API token", text: $model.todoist).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("TickTick API token", text: $model.ticktick).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Label("Task app connections", systemImage: "link") } footer: { Text("Keys are stored on your iPhone. You only need a token for the app you use.") }
                Section {
                    TextField("e.g. Nuwan, kottu, Colombo", text: $model.vocabulary, axis: .vertical)
                } header: { Label("Names and local words", systemImage: "text.bubble") } footer: { Text("Add words that help the app recognize your speech.") }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.saveSettings(); settings = false; Task { await model.loadProjects() } } } }
        }
    }

}

struct TaskCard: View {
    @Binding var item: TaskItem
    let projects: [TodoistProject]
    let projectsStatus: String
    let remove: () -> Void
    @State private var dateSheet = false
    @State private var showDescription = false
    private let card = Color(red: 0.14, green: 0.14, blue: 0.16)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "circle").foregroundStyle(.secondary).padding(.top, 3)
                TextField("Task name", text: $item.content, axis: .vertical).font(.body.weight(.medium))
                Button(role: .destructive, action: remove) { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(5) }.accessibilityLabel("Remove task")
            }
            if showDescription || !(item.description ?? "").isEmpty {
                TextField("Add a description", text: Binding(get: { item.description ?? "" }, set: { item.description = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .font(.subheadline).foregroundStyle(.secondary).padding(.leading, 29)
            }
            HStack(spacing: 8) {
                Button { dateSheet = true } label: { Label(DateHelper.label(item.due_string), systemImage: "calendar") }.buttonStyle(ChipStyle())
                Menu {
                    Button { item.project_id = nil } label: { if item.project_id == nil { Label("Inbox", systemImage: "checkmark") } else { Text("Inbox") } }
                    ForEach(projects) { project in
                        Button { item.project_id = project.id } label: { if item.project_id == project.id { Label(project.name, systemImage: "checkmark") } else { Text(project.name) } }
                    }
                } label: { Label(projects.first(where: { $0.id == item.project_id })?.name ?? "Inbox", systemImage: "tray") }.buttonStyle(ChipStyle())
                Spacer(minLength: 0)
                if !showDescription && (item.description ?? "").isEmpty {
                    Button { showDescription = true } label: { Image(systemName: "text.alignleft").padding(6) }.accessibilityLabel("Add description")
                }
            }.font(.caption.weight(.medium)).lineLimit(1)
        }.padding(16).background(card, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $dateSheet) { DateEditor(value: $item.due_string) }
    }
}
struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.15 : 0.08), in: Capsule())
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
struct DateEditor: View {
    @Binding var value: String?
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()
    @State private var hasTime = false
    @State private var unrecognized: String?
    var body: some View {
        NavigationStack {
            Form {
                if let unrecognized { Text("Could not read “\(unrecognized)”. Choose a date to replace it.").font(.caption).foregroundStyle(.secondary) }
                DatePicker("Date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                Toggle("Add time", isOn: $hasTime)
                if hasTime { DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute) }
                if value != nil { Button("Remove date", role: .destructive) { value = nil; dismiss() } }
            }.navigationTitle("Due date").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { value = DateHelper.encode(date, timed: hasTime); dismiss() } }
                }
                .onAppear { if let value { if let existing = DateHelper.parse(value) { date = existing; hasTime = DateHelper.hasTime(value) } else { unrecognized = value } } }
        }.presentationDetents([.large])
    }
}
