import Foundation
import EventKit
import SwiftData
import UIKit

// MARK: - Tâche externe

struct ExternalTask {
    var identifier: String
    var title: String
    var notes: String
    var dueDate: Date?
    var isDone: Bool
    var priority: Int
    var listName: String
}

/// Abstraction d'un fournisseur de tâches.
protocol TaskService: AnyObject {
    var provider: TaskProvider { get }
    var isConfigured: Bool { get }
    func requestAccess() async -> Bool
    func fetchTasks() async -> [ExternalTask]
    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask?
    func setCompleted(identifier: String, completed: Bool) async -> Bool
    func deleteTask(identifier: String) async -> Bool
}

// MARK: - Rappels Apple (EventKit)

final class RemindersTaskService: TaskService {
    let provider: TaskProvider = .reminders
    private let store = EKEventStore()

    var isConfigured: Bool { true }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    func fetchTasks() async -> [ExternalTask] {
        guard hasAccess else { return [] }
        // Les rappels à faire, plus ceux terminés depuis un mois : l'historique
        // complet d'un compte Rappels peut compter des milliers d'entrées, et rien
        // dans l'app n'en fait usage.
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                          ending: nil,
                                                          calendars: nil)
        let recentlyDone = store.predicateForCompletedReminders(
            withCompletionDateStarting: DateUtils.addDays(-30, to: Date()),
            ending: nil,
            calendars: nil)
        async let openList = fetch(open)
        async let doneList = fetch(recentlyDone)
        return await openList + doneList
    }

    private func fetch(_ predicate: NSPredicate) async -> [ExternalTask] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped: [ExternalTask] = (reminders ?? []).map { reminder in
                    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return ExternalTask(identifier: reminder.calendarItemIdentifier,
                                        title: reminder.title ?? String(localized: "Sans titre"),
                                        notes: reminder.notes ?? "",
                                        dueDate: due,
                                        isDone: reminder.isCompleted,
                                        priority: reminder.priority,
                                        listName: reminder.calendar?.title ?? "")
                }
                continuation.resume(returning: mapped)
            }
        }
    }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        guard hasAccess, let calendar = store.defaultCalendarForNewReminders() else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        reminder.priority = priority
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
        }
        do {
            try store.save(reminder, commit: true)
            return ExternalTask(identifier: reminder.calendarItemIdentifier,
                                title: title, notes: notes, dueDate: dueDate,
                                isDone: false, priority: priority, listName: calendar.title)
        } catch {
            return nil
        }
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool {
        guard hasAccess,
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return false }
        reminder.isCompleted = completed
        reminder.completionDate = completed ? Date() : nil
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    func deleteTask(identifier: String) async -> Bool {
        guard hasAccess,
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return false }
        do {
            try store.remove(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Todoist (API unifiée v1)

final class TodoistTaskService: TaskService {
    let provider: TaskProvider = .todoist

    private let token: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.todoist.com/api/v1")!

    init(token: String, session: URLSession = .shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var isConfigured: Bool { !token.isEmpty }

    func requestAccess() async -> Bool { isConfigured }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Data? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func fetchTasks() async -> [ExternalTask] {
        guard isConfigured, let data = await send("tasks") else { return [] }
        let decoder = JSONDecoder()
        var items: [TodoistTask] = []
        if let list = try? decoder.decode([TodoistTask].self, from: data) {
            items = list
        } else if let page = try? decoder.decode(TodoistTaskPage.self, from: data) {
            items = page.results
        }
        return items.map { item in
            ExternalTask(identifier: item.id,
                         title: item.content,
                         notes: item.description ?? "",
                         dueDate: Self.parseDue(item.due),
                         isDone: item.isCompleted ?? false,
                         priority: item.priority ?? 1,
                         listName: item.projectId ?? "")
        }
    }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        guard isConfigured else { return nil }
        var body: [String: Any] = ["content": title]
        if !notes.isEmpty { body["description"] = notes }
        if priority > 1 { body["priority"] = priority }
        if let dueDate { body["due_datetime"] = ISO8601DateFormatter().string(from: dueDate) }
        guard let data = await send("tasks", method: "POST", body: body),
              let task = try? JSONDecoder().decode(TodoistTask.self, from: data) else { return nil }
        return ExternalTask(identifier: task.id, title: task.content,
                            notes: task.description ?? "", dueDate: dueDate,
                            isDone: false, priority: task.priority ?? 1, listName: "")
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool {
        guard isConfigured else { return false }
        return await send("tasks/\(identifier)/\(completed ? "close" : "reopen")", method: "POST") != nil
    }

    func deleteTask(identifier: String) async -> Bool {
        guard isConfigured else { return false }
        return await send("tasks/\(identifier)", method: "DELETE") != nil
    }

    private static func parseDue(_ due: TodoistDue?) -> Date? {
        guard let due else { return nil }
        if let datetime = due.datetime, let date = DateUtils.iso8601.date(from: datetime) { return date }
        if let date = due.date { return DateUtils.parse(date) }
        return nil
    }
}

struct TodoistTask: Decodable {
    let id: String
    let content: String
    let description: String?
    let priority: Int?
    let projectId: String?
    let isCompleted: Bool?
    let due: TodoistDue?

    enum CodingKeys: String, CodingKey {
        case id, content, description, priority, due
        case projectId = "project_id"
        case isCompleted = "is_completed"
    }
}

struct TodoistTaskPage: Decodable { let results: [TodoistTask] }

struct TodoistDue: Decodable {
    let date: String?
    let datetime: String?
}

// MARK: - Things 3 (schéma d'URL, écriture seule)

final class ThingsTaskService: TaskService {
    let provider: TaskProvider = .things

    var isConfigured: Bool { true }
    func requestAccess() async -> Bool { true }

    /// Things n'expose pas d'API de lecture.
    func fetchTasks() async -> [ExternalTask] { [] }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        var components = URLComponents(string: "things:///add")
        var items: [URLQueryItem] = [URLQueryItem(name: "title", value: title)]
        if !notes.isEmpty { items.append(URLQueryItem(name: "notes", value: notes)) }
        if let dueDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            items.append(URLQueryItem(name: "when", value: formatter.string(from: dueDate)))
        }
        components?.queryItems = items

        guard let url = components?.url, await Self.open(url) else { return nil }
        // Things ne renvoie pas d'identifiant : la tâche reste locale, sans relecture.
        return ExternalTask(identifier: "things-local-\(UUID().uuidString)",
                            title: title, notes: notes, dueDate: dueDate,
                            isDone: false, priority: priority, listName: "Things")
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool { false }
    func deleteTask(identifier: String) async -> Bool { false }

    @MainActor
    private static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}

// MARK: - Notion (base de données de tâches)

final class NotionTaskService: TaskService {
    let provider: TaskProvider = .notion
    private let token: String
    private let databaseID: String
    private let session: URLSession

    init(token: String, databaseID: String, session: URLSession = .shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.databaseID = databaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var isConfigured: Bool { !token.isEmpty && !databaseID.isEmpty }

    func requestAccess() async -> Bool { isConfigured }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Data? {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Convention : propriétés `Name` (titre), `Done` (case à cocher), `Due` (date).
    func fetchTasks() async -> [ExternalTask] {
        guard isConfigured,
              let data = await send("databases/\(databaseID)/query",
                                    method: "POST",
                                    body: ["page_size": 50]) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.compactMap { page in
            guard let id = page["id"] as? String else { return nil }
            let properties = page["properties"] as? [String: Any] ?? [:]
            let title = Self.title(from: properties["Name"]) ?? String(localized: "Sans titre")
            let done = (properties["Done"] as? [String: Any])?["checkbox"] as? Bool ?? false
            let due = Self.date(from: properties["Due"])
            let archived = page["archived"] as? Bool ?? false
            guard !archived else { return nil }
            return ExternalTask(identifier: id, title: title, notes: "",
                                dueDate: due, isDone: done, priority: 1, listName: "Notion")
        }
    }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        guard isConfigured else { return nil }
        var properties: [String: Any] = [
            "Name": ["title": [["text": ["content": title]]]],
            "Done": ["checkbox": false]
        ]
        if let dueDate {
            properties["Due"] = ["date": ["start": ISO8601DateFormatter().string(from: dueDate)]]
        }
        let body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": properties
        ]
        guard let data = await send("pages", method: "POST", body: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { return nil }
        return ExternalTask(identifier: id, title: title, notes: notes,
                            dueDate: dueDate, isDone: false, priority: priority, listName: "Notion")
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool {
        guard isConfigured else { return false }
        let body: [String: Any] = ["properties": ["Done": ["checkbox": completed]]]
        return await send("pages/\(identifier)", method: "PATCH", body: body) != nil
    }

    func deleteTask(identifier: String) async -> Bool {
        guard isConfigured else { return false }
        return await send("pages/\(identifier)", method: "PATCH", body: ["archived": true]) != nil
    }

    private static func title(from property: Any?) -> String? {
        guard let property = property as? [String: Any],
              let titles = property["title"] as? [[String: Any]] else { return nil }
        return titles.compactMap { ($0["plain_text"] as? String) }.joined()
    }

    private static func date(from property: Any?) -> Date? {
        guard let property = property as? [String: Any],
              let date = property["date"] as? [String: Any],
              let start = date["start"] as? String else { return nil }
        return DateUtils.parse(start)
    }
}

// MARK: - Webhook générique

/// Envoie un JSON à une URL : compatible Shortcuts, Home Assistant, Zapier, n8n…
final class WebhookTaskService: TaskService {
    let provider: TaskProvider = .webhook
    private let urlString: String
    private let session: URLSession

    init(urlString: String, session: URLSession = .shared) {
        self.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var isConfigured: Bool { URL(string: urlString) != nil }

    func requestAccess() async -> Bool { isConfigured }

    func fetchTasks() async -> [ExternalTask] { [] }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        guard isConfigured else { return nil }
        var payload: [String: Any] = [
            "event": "task.created",
            "source": "StudyTrack",
            "title": title,
            "notes": notes,
            "priority": priority
        ]
        if let dueDate { payload["dueDate"] = ISO8601DateFormatter().string(from: dueDate) }
        guard await post(payload) else { return nil }
        return ExternalTask(identifier: "webhook-\(UUID().uuidString)",
                            title: title, notes: notes, dueDate: dueDate,
                            isDone: false, priority: priority, listName: String(localized: "Webhook"))
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool {
        await post(["event": completed ? "task.completed" : "task.reopened",
                    "source": "StudyTrack",
                    "identifier": identifier])
    }

    func deleteTask(identifier: String) async -> Bool {
        await post(["event": "task.deleted", "source": "StudyTrack", "identifier": identifier])
    }

    private func post(_ payload: [String: Any]) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

// MARK: - Fabrique de services (instances partagées)

/// Conserve **une seule** instance par fournisseur.
///
/// Auparavant, chaque case cochée construisait un `RemindersTaskService` neuf,
/// donc un `EKEventStore` neuf : coûteux et source d'incohérences.
// MARK: - Google Tasks

/// Tâches Google via l'API Tasks.
///
/// Les jetons d'accès Google ne vivent qu'une heure : on garde donc le refresh
/// token et on redemande un jeton à la demande. Le jeton d'accès ne quitte jamais
/// la mémoire de l'app.
final class GoogleTasksTaskService: TaskService {
    let provider: TaskProvider = .googleTasks

    private let clientID: String
    private let clientSecret: String
    private let refreshToken: String
    private let session: URLSession

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var listID: String?

    init(clientID: String,
         clientSecret: String,
         refreshToken: String,
         session: URLSession = .shared) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Un client « iOS » n'a pas de secret : l'identifiant et le jeton de
    /// renouvellement suffisent.
    var isConfigured: Bool {
        !clientID.isEmpty && !refreshToken.isEmpty
    }

    func requestAccess() async -> Bool { await token() != nil }

    private func token() async -> String? {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["client_id": clientID,
                      "refresh_token": refreshToken,
                      "grant_type": "refresh_token"]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        let encoded = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }.joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            return nil
        }
        accessToken = payload.access_token
        // Marge d'une minute : on ne veut pas présenter un jeton qui expire pendant l'appel.
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(max(payload.expires_in - 60, 30)))
        return accessToken
    }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Data? {
        guard let token = await token() else { return nil }
        var request = URLRequest(url: URL(string: "https://tasks.googleapis.com/tasks/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func resolvedListID() async -> String? {
        if let listID { return listID }
        guard let data = await send("users/@me/lists"),
              let page = try? JSONDecoder().decode(GoogleListPage.self, from: data),
              let first = page.items?.first else { return nil }
        listID = first.id
        return listID
    }

    func fetchTasks() async -> [ExternalTask] {
        guard isConfigured, let list = await resolvedListID(),
              let data = await send("lists/\(list)/tasks?showCompleted=true") else { return [] }
        guard let page = try? JSONDecoder().decode(GoogleTaskPage.self, from: data) else { return [] }
        return (page.items ?? []).map { task in
            ExternalTask(identifier: task.id,
                         title: task.title ?? "",
                         notes: task.notes ?? "",
                         dueDate: task.due.flatMap { DateUtils.iso8601.date(from: $0) },
                         isDone: task.status == "completed",
                         priority: 1,
                         listName: "Tasks")
        }
    }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        guard isConfigured, let list = await resolvedListID() else { return nil }
        var body: [String: Any] = ["title": title]
        if !notes.isEmpty { body["notes"] = notes }
        if let dueDate { body["due"] = ISO8601DateFormatter().string(from: dueDate) }
        guard let data = await send("lists/\(list)/tasks", method: "POST", body: body),
              let task = try? JSONDecoder().decode(GoogleTask.self, from: data) else { return nil }
        return ExternalTask(identifier: task.id, title: task.title ?? title, notes: notes,
                            dueDate: dueDate, isDone: false, priority: priority, listName: "Tasks")
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool {
        guard isConfigured, let list = await resolvedListID() else { return false }
        let body: [String: Any] = ["status": completed ? "completed" : "needsAction"]
        return await send("lists/\(list)/tasks/\(identifier)", method: "PATCH", body: body) != nil
    }

    func deleteTask(identifier: String) async -> Bool {
        guard isConfigured, let list = await resolvedListID() else { return false }
        return await send("lists/\(list)/tasks/\(identifier)", method: "DELETE") != nil
    }
}

struct GoogleTokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
}
struct GoogleListPage: Decodable { let items: [GoogleList]? }
struct GoogleList: Decodable { let id: String }
struct GoogleTaskPage: Decodable { let items: [GoogleTask]? }
struct GoogleTask: Decodable {
    let id: String
    let title: String?
    let notes: String?
    let status: String?
    let due: String?
}

// MARK: - TickTick

/// Tâches TickTick via son API ouverte (OAuth2).
final class TickTickTaskService: TaskService {
    let provider: TaskProvider = .tickTick

    private let token: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.ticktick.com/open/v1")!
    private var projectID: String?

    init(token: String, session: URLSession = .shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var isConfigured: Bool { !token.isEmpty }
    func requestAccess() async -> Bool { isConfigured }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> Data? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func resolvedProjectID() async -> String? {
        if let projectID { return projectID }
        guard let data = await send("project"),
              let projects = try? JSONDecoder().decode([TickTickProject].self, from: data),
              let first = projects.first else { return nil }
        projectID = first.id
        return projectID
    }

    func fetchTasks() async -> [ExternalTask] {
        guard isConfigured, let project = await resolvedProjectID(),
              let data = await send("project/\(project)/data"),
              let payload = try? JSONDecoder().decode(TickTickProjectData.self, from: data) else {
            return []
        }
        return (payload.tasks ?? []).map { task in
            ExternalTask(identifier: task.id,
                         title: task.title ?? "",
                         notes: task.content ?? "",
                         dueDate: task.dueDate.flatMap { DateUtils.iso8601.date(from: $0) },
                         isDone: (task.status ?? 0) == 2,
                         priority: task.priority ?? 0,
                         listName: payload.project?.name ?? "TickTick")
        }
    }

    func createTask(title: String, notes: String, dueDate: Date?, priority: Int) async -> ExternalTask? {
        guard isConfigured, let project = await resolvedProjectID() else { return nil }
        var body: [String: Any] = ["title": title, "projectId": project]
        if !notes.isEmpty { body["content"] = notes }
        if let dueDate { body["dueDate"] = ISO8601DateFormatter().string(from: dueDate) }
        if priority > 0 { body["priority"] = priority }
        guard let data = await send("task", method: "POST", body: body),
              let task = try? JSONDecoder().decode(TickTickTask.self, from: data) else { return nil }
        return ExternalTask(identifier: task.id, title: task.title ?? title, notes: notes,
                            dueDate: dueDate, isDone: false, priority: priority, listName: "TickTick")
    }

    func setCompleted(identifier: String, completed: Bool) async -> Bool {
        guard isConfigured, let project = await resolvedProjectID() else { return false }
        let path = "project/\(project)/task/\(identifier)/\(completed ? "complete" : "uncomplete")"
        return await send(path, method: "POST") != nil
    }

    func deleteTask(identifier: String) async -> Bool {
        guard isConfigured, let project = await resolvedProjectID() else { return false }
        return await send("project/\(project)/task/\(identifier)", method: "DELETE") != nil
    }
}

struct TickTickProject: Decodable {
    let id: String
    let name: String?
}
struct TickTickProjectData: Decodable {
    let project: TickTickProject?
    let tasks: [TickTickTask]?
}
struct TickTickTask: Decodable {
    let id: String
    let title: String?
    let content: String?
    let dueDate: String?
    let status: Int?
    let priority: Int?
}

final class TaskServiceFactory {
    static let shared = TaskServiceFactory()

    private let reminders = RemindersTaskService()
    private var todoist: TodoistTaskService?
    private var todoistToken = ""
    private var things: ThingsTaskService?
    private var notion: NotionTaskService?
    private var notionKey = ""
    private var webhook: WebhookTaskService?
    private var webhookURL = ""
    private var google: GoogleTasksTaskService?
    private var googleKey = ""
    private var tickTick: TickTickTaskService?
    private var tickTickToken = ""

    private init() {}

    func service(for provider: TaskProvider, settings: SettingsStore) -> TaskService? {
        switch provider {
        case .reminders:
            return reminders

        case .todoist:
            guard !settings.todoistToken.isEmpty else { return nil }
            if todoist == nil || todoistToken != settings.todoistToken {
                todoist = TodoistTaskService(token: settings.todoistToken)
                todoistToken = settings.todoistToken
            }
            return todoist

        case .things:
            guard settings.thingsEnabled else { return nil }
            if things == nil { things = ThingsTaskService() }
            return things

        case .notion:
            let key = "\(settings.notionToken)|\(settings.notionDatabaseID)"
            guard !settings.notionToken.isEmpty, !settings.notionDatabaseID.isEmpty else { return nil }
            if notion == nil || notionKey != key {
                notion = NotionTaskService(token: settings.notionToken,
                                           databaseID: settings.notionDatabaseID)
                notionKey = key
            }
            return notion

        case .webhook:
            guard !settings.webhookURL.isEmpty else { return nil }
            if webhook == nil || webhookURL != settings.webhookURL {
                webhook = WebhookTaskService(urlString: settings.webhookURL)
                webhookURL = settings.webhookURL
            }
            return webhook


        case .googleTasks:
            let key = "\(settings.googleClientID)|\(settings.googleRefreshToken)"
            guard !settings.googleClientID.isEmpty,
                  !settings.googleRefreshToken.isEmpty else { return nil }
            if google == nil || googleKey != key {
                google = GoogleTasksTaskService(clientID: settings.googleClientID,
                                                clientSecret: settings.googleClientSecret,
                                                refreshToken: settings.googleRefreshToken)
                googleKey = key
            }
            return google

        case .tickTick:
            guard !settings.tickTickToken.isEmpty else { return nil }
            if tickTick == nil || tickTickToken != settings.tickTickToken {
                tickTick = TickTickTaskService(token: settings.tickTickToken)
                tickTickToken = settings.tickTickToken
            }
            return tickTick
        }
    }

    /// Fournisseurs réellement configurés, dans l'ordre d'affichage.
    func configuredServices(settings: SettingsStore) -> [TaskService] {
        TaskProvider.allCases.compactMap { service(for: $0, settings: settings) }
    }

    /// Fournisseurs lisibles (donc synchronisables) uniquement.
    func readableServices(settings: SettingsStore) -> [TaskService] {
        configuredServices(settings: settings).filter { $0.provider.supportsReading }
    }
}

// MARK: - Synchronisation vers le modèle local

@MainActor
enum TaskSync {

    struct SyncResult {
        var fetched = 0
        var created = 0
        var updated = 0
        var removed = 0
        var providers: [String] = []
    }

    @discardableResult
    static func sync(context: ModelContext, settings: SettingsStore) async -> SyncResult {
        var result = SyncResult()
        var existing = (try? context.fetch(FetchDescriptor<LinkedTask>())) ?? []

        for service in TaskServiceFactory.shared.readableServices(settings: settings) {
            let tasks = await service.fetchTasks()
            guard !tasks.isEmpty else { continue }
            result.providers.append(service.provider.label)
            result.fetched += tasks.count

            // Une tâche supprimée chez le fournisseur restait ici pour toujours :
            // la boîte de réception se remplissait de fantômes. Le fournisseur a
            // répondu, donc son absence dans la liste est une vraie absence.
            let remoteIDs = Set(tasks.map(\.identifier))
            let stale = existing.filter {
                $0.providerRaw == service.provider.rawValue
                    && $0.externalID != nil
                    && !remoteIDs.contains($0.externalID ?? "")
            }
            for task in stale {
                context.delete(task)
                result.removed += 1
            }
            existing.removeAll { task in stale.contains { $0.id == task.id } }

            for task in tasks {
                if let match = existing.first(where: {
                    $0.providerRaw == service.provider.rawValue && $0.externalID == task.identifier
                }) {
                    match.title = task.title
                    match.note = task.notes
                    match.dueDate = task.dueDate
                    match.isDone = task.isDone
                    match.priority = task.priority
                    match.updatedAt = Date()
                    match.lastSyncedAt = Date()
                    result.updated += 1
                    continue
                }

                let linked = LinkedTask(provider: service.provider,
                                        externalID: task.identifier,
                                        title: task.title,
                                        note: task.notes,
                                        dueDate: task.dueDate,
                                        isDone: task.isDone,
                                        priority: task.priority)
                linked.lastSyncedAt = Date()
                context.insert(linked)
                existing.append(linked)
                result.created += 1
            }
        }

        try? context.save()
        return result
    }

    /// Coche (ou décoche) une tâche ici **et** chez son fournisseur.
    @MainActor
    static func setDone(_ task: LinkedTask, _ done: Bool, context: ModelContext, settings: SettingsStore) async {
        task.isDone = done
        task.updatedAt = Date()
        try? context.save()
        guard let externalID = task.externalID else { return }
        let service = TaskServiceFactory.shared.service(for: task.provider, settings: settings)
        _ = await service?.setCompleted(identifier: externalID, completed: done)
    }

    /// Rattache automatiquement une tâche à un cours dont le code apparaît dans le titre.
    static func autoLink(tasks: [LinkedTask], courses: [Course]) {
        for task in tasks where task.course == nil {
            if let course = CalendarSync.matchCourse(for: task.title, in: courses) {
                task.course = course
            }
        }
    }
}
