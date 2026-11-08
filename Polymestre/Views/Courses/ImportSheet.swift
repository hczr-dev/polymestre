import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Import unifié : horaire iCalendar, JSON ou CSV.
///
/// L'EPFL ne délivre pas d'accès API aux étudiant·e·s : le flux `.ics`
/// « Mon horaire » est donc le chemin principal, et il crée les cours,
/// détecte ceux qui ont des heures de cours et lie les séances.
struct ImportSheet: View {
    var defaultSectionCode: String = ""

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    enum Mode: String, CaseIterable, Identifiable {
        case timetable, json, csv
        var id: String { rawValue }
        var title: String {
            switch self {
            case .timetable: return String(localized: "Horaire .ics")
            case .json: return "JSON"
            case .csv: return "CSV"
            }
        }
    }

    @State private var mode: Mode = .timetable
    @State private var text = ""
    @State private var urlString = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false
    @State private var showingFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $mode) {
                        ForEach(Mode.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .timetable {
                    Section {
                        TextField("https://… ou webcal://…", text: $urlString)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        Button {
                            Task { await importFromURL() }
                        } label: {
                            Label("Importer depuis l'URL", systemImage: "arrow.down.circle")
                        }
                        .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    } header: {
                        Text("Flux de ton horaire")
                    } footer: {
                        Text("IS-Academia › Exporter mon horaire › copie le lien iCalendar.")
                    }
                }

                Section {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Ou colle le contenu")
                } footer: {
                    Text(mode == .timetable
                         ? "Colle le contenu du fichier .ics (il commence par BEGIN:VCALENDAR)."
                         : mode == .json
                         ? "Structure : { \"courses\": [ { \"code\": …, \"videos\": […], \"series\": […] } ] }. Une sauvegarde Polymestre (Réglages › Données et sauvegarde) se restaure ici, avancement et sessions compris, sans doublon."
                         : "Une ligne par élément, avec les colonnes : course_code, course_name, kind, number, title, duration_seconds, week, is_bonus, date, weight.")
                }

                Section {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Choisir un fichier", systemImage: "folder")
                    }

                    Button {
                        runImport()
                    } label: {
                        if isWorking {
                            HStack { ProgressView(); Text("Import en cours…") }
                        } else {
                            Label("Importer", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                    if mode == .json {
                        Button("Charger un exemple JSON") { text = Self.sampleJSON }
                    }
                    if mode == .csv {
                        Button("Charger un exemple CSV") { text = Self.sampleCSV }
                    }
                }

                if let message {
                    Section("Résultat") {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(isError ? Color.red.accessibleInk : Color.green.accessibleInk)
                    }
                }
            }
            .carnetBackground()
            .navigationTitle("Importer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingFilePicker,
                          allowedContentTypes: [.json, .commaSeparatedText, .plainText, .calendarEvent]) { result in
                handleFile(result)
            }
            .onAppear {
                if urlString.isEmpty { urlString = app.settings.timetableURLString }
            }
        }
    }

    // MARK: Actions

    private func importFromURL() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            let content = try await TimetableImport.fetch(urlString: urlString)
            text = content
            let result = TimetableImport.import(content,
                                                into: context,
                                                sectionCode: defaultSectionCode)
            isError = false
            message = result.message
            app.settings.timetableURLString = urlString
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func runImport() {
        message = nil
        do {
            switch mode {
            case .timetable:
                let result = TimetableImport.import(text,
                                                    into: context,
                                                    sectionCode: defaultSectionCode)
                isError = result.eventsCreated == 0 && result.coursesCreated == 0
                message = result.message
            case .json:
                let summary = try CourseImporter.importJSON(text,
                                                            into: context,
                                                            sectionCode: defaultSectionCode)
                isError = false
                message = summary.message
            case .csv:
                let summary = try CourseImporter.importCSV(text,
                                                           into: context,
                                                           sectionCode: defaultSectionCode)
                isError = false
                message = summary.message
            }
            if !isError { Haptics.success() }
        } catch {
            isError = true
            message = error.localizedDescription
            Haptics.error()
        }
    }

    private func handleFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                text = content
                if url.pathExtension.lowercased() == "ics" { mode = .timetable }
                else if url.pathExtension.lowercased() == "csv" { mode = .csv }
                else if url.pathExtension.lowercased() == "json" { mode = .json }
                runImport()
            } catch {
                isError = true
                message = "Lecture impossible : \(error.localizedDescription)"
            }
        case .failure(let error):
            isError = true
            message = error.localizedDescription
        }
    }

    // MARK: Exemples

    static let sampleJSON = """
    {
      "term": { "year": 2025, "season": "spring", "startDate": "2025-02-17", "endDate": "2025-06-06", "totalWeeks": 14 },
      "courses": [
        {
          "code": "CS-250",
          "name": "Algorithms I",
          "credits": 6,
          "weeklyLectureHours": 3,
          "weeklyExerciseHours": 2,
          "hasLectures": true,
          "videos": [
            { "section": 1, "number": "1.1", "title": "Introduction", "durationSeconds": 2700, "week": 1 },
            { "section": 1, "number": "1.2", "title": "Analyse asymptotique", "durationSeconds": 3120, "week": 1 }
          ],
          "series": [
            { "number": 1, "week": 1, "exercises": [
              { "number": "1.1", "isBonus": false },
              { "number": "1.2", "isBonus": true }
            ] }
          ],
          "exams": [
            { "kind": "midterm", "title": "Midterm", "date": "2025-03-28T08:00:00Z", "weightPercent": 30 }
          ]
        }
      ]
    }
    """

    static let sampleCSV = """
    course_code,course_name,credits,kind,number,title,duration_seconds,week,is_bonus,date,weight,location
    CS-250,Algorithms I,6,video,1.1,Introduction,2700,1,,,,,
    CS-250,Algorithms I,6,video,1.2,Analyse asymptotique,3120,1,,,,,
    CS-250,Algorithms I,6,exercise,1.1,,,1,false,,,
    CS-250,Algorithms I,6,exercise,1.2,,,1,true,,,
    CS-250,Algorithms I,6,exam,midterm,Midterm,,,,2025-03-28T08:00:00Z,30,SG1
    """
}
