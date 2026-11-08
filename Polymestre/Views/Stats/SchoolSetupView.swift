import SwiftUI
import SwiftData

/// Section, cours et dates du semestre — modifiables **après** l'onboarding.
///
/// L'onboarding décidait de tout une fois pour toutes : changer de section, suivre
/// un cours de plus ou corriger la date de début obligeait à effacer l'app. Or ces
/// trois choses changent en cours de semestre, et la date de début commande le
/// numéro de semaine affiché partout.
struct SchoolSetupView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context

    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \AcademicTerm.startDate, order: .reverse) private var terms: [AcademicTerm]

    @State private var showingCourseForm = false
    @State private var showingImport = false
    @State private var resultMessage: String?

    private var trackedCourses: [Course] { courses.filter(\.isTracked) }
    private var lectureCourses: [Course] { courses.filter { $0.hasLectures } }

    /// Le semestre en cours, celui dont les dates pilotent les numéros de semaine.
    private var runningTerm: AcademicTerm? {
        terms.first { $0.isRunning } ?? terms.first
    }

    var body: some View {
        Form {
            sectionSection
            termSection
            coursesSection
            summarySection
        }
        .carnetForm()
        .navigationTitle("Section et semestre")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCourseForm) {
            CourseFormView(course: nil, defaultSectionCode: app.settings.sectionCode)
        }
        .sheet(isPresented: $showingImport) {
            ImportSheet(defaultSectionCode: app.settings.sectionCode)
        }
    }

    // MARK: Section

    private var sectionSection: some View {
        Section {
            Picker("Section EPFL", selection: Binding(
                get: { app.settings.sectionCode },
                set: { newValue in
                    app.settings.sectionCode = newValue
                    // Les cours déjà saisis suivent la section : c'est ce que
                    // l'onboarding faisait, et ne pas le refaire ici donnerait deux
                    // vérités différentes selon l'écran.
                    for course in courses where course.sectionCode.isEmpty {
                        course.sectionCode = newValue
                    }
                    try? context.save()
                }
            )) {
                Text("Non renseignée").tag("")
                ForEach(EPFLCatalog.sections) { section in
                    Text("\(section.name) (\(section.code))").tag(section.code)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Section")
        }
    }

    // MARK: Semestre

    @ViewBuilder
    private var termSection: some View {
        Section {
            if let term = runningTerm {
                DatePicker("Début (semaine 1)", selection: Binding(
                    get: { term.startDate },
                    set: { newValue in
                        term.startDate = DateUtils.startOfWeek(newValue)
                        term.endDate = DateUtils.addTeachingWeeks(term.totalWeeks, to: term.startDate)
                        try? context.save()
                    }
                ), displayedComponents: .date)

                Stepper("Durée : \(term.totalWeeks) semaines",
                        value: Binding(
                            get: { term.totalWeeks },
                            set: { newValue in
                                term.totalWeeks = newValue
                                term.endDate = DateUtils.addTeachingWeeks(newValue, to: term.startDate)
                                try? context.save()
                            }
                        ),
                        in: 8...24)

                Picker("Semestre", selection: Binding(
                    get: { term.seasonRaw },
                    set: { term.seasonRaw = $0; try? context.save() }
                )) {
                    ForEach(TermSeason.allCases) { season in
                        Text(season.label).tag(season.rawValue)
                    }
                }

                HStack {
                    Label("Fin estimée", systemImage: "flag.checkered")
                        .font(.subheadline)
                    Spacer()
                    Text(DateUtils.shortDay.string(from: term.endDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Semaine courante", systemImage: "calendar.badge.clock")
                        .font(.subheadline)
                    Spacer()
                    Text("\(DateUtils.clampedWeek(for: Date(), term: term)) / \(term.totalWeeks)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentInk)
                }
            } else {
                Text("Aucun semestre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Dates du semestre")
        } footer: {
            Text("Dates du calendrier académique de l'EPFL.")
        }
    }

    // MARK: Cours

    private var coursesSection: some View {
        Section {
            ForEach(courses) { course in
                courseRow(course)
            }
            Button {
                showingImport = true
            } label: {
                Label("Importer mon horaire (.ics)", systemImage: "calendar.badge.plus")
            }
            Button {
                showingCourseForm = true
            } label: {
                Label("Ajouter un cours", systemImage: "plus")
            }
        } header: {
            Text("Cours (\(trackedCourses.count) suivis)")
        }
    }

    private func courseRow(_ course: Course) -> some View {
        HStack(spacing: Layout.block) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Carnet.tint(course.colorHex))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(course.displayCode).font(.subheadline.weight(.semibold))
                Text(course.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Layout.inline)
            VStack(alignment: .trailing, spacing: Layout.tight) {
                Toggle("Suivi", isOn: Binding(
                    get: { course.isTracked },
                    set: { course.isTracked = $0; try? context.save() }
                ))
                .labelsHidden()
                .accessibilityLabel("Suivre \(course.code)")

                Toggle("A un cours", isOn: Binding(
                    get: { course.hasLectures },
                    set: { course.hasLectures = $0; try? context.save() }
                ))
                .labelsHidden()
                // Bleu, pour se distinguer de « suivre » juste à côté : le
                // style d'interrupteur de l'app (vert) est remplacé ici.
                .toggleStyle(.switch)
                .tint(.blue)
                .accessibilityLabel("\(course.code) a des heures de cours")
            }
        }
    }

    // MARK: Récapitulatif

    private var summarySection: some View {
        Section {
            HStack(spacing: Layout.block) {
                StatCard(icon: "books.vertical.fill",
                         value: "\(trackedCourses.count)",
                         title: String(localized: "cours suivis"))
                StatCard(icon: "building.columns.fill",
                         value: "\(lectureCourses.count)",
                         title: String(localized: "avec amphi"))
                StatCard(icon: "clock.fill",
                         value: DateUtils.hoursLabel(hours: app.settings.hoursPerCredit),
                         title: String(localized: "par crédit"))
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Récapitulatif")
        }
    }
}
