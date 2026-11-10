import SwiftUI
import SwiftData

/// Entrée unifiée de l'agenda (évaluations + calendrier + sessions + tâches).
struct AgendaEntry: Identifiable {
    let id: String
    let date: Date
    let endDate: Date?
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let kind: AgendaItemKind
    var courseID: UUID? = nil
    /// L'objet d'origine, pour les actions de ligne (supprimer, présence…).
    var plannedSession: PlannedSession? = nil
    var task: LinkedTask? = nil
    var event: LinkedCalendarEvent? = nil
    var exam: Exam? = nil

    /// Une tâche a une échéance, pas une heure : elle se range en tête de journée.
    /// Une évaluation datée à minuit pile n'a pas d'heure connue non plus.
    var isAllDay: Bool {
        if kind == .task || kind == .milestone { return true }
        if kind == .exam {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return parts.hour == 0 && parts.minute == 0
        }
        return false
    }
}

/// Ce que l'agenda montre : une famille d'entrées, ou un cours.
///
/// Les filtres étaient cachés dans un menu de la barre du haut, à côté de la
/// synchronisation : personne ne les trouvait. Ce sont maintenant des pastilles
/// sous la semaine, visibles, et on filtre aussi par cours — c'est là que
/// vivent les séances d'un cours depuis que sa page n'a plus d'onglet Agenda.
struct AgendaFilter: Equatable {
    enum Family: String, CaseIterable, Identifiable {
        case lectures, exams, sessions, tasks, epfl
        var id: String { rawValue }
        var label: String {
            switch self {
            case .epfl: return "EPFL"
            case .lectures: return String(localized: "Cours (les séances)")
            case .exams: return String(localized: "Évaluations")
            case .sessions: return String(localized: "Sessions")
            case .tasks: return String(localized: "Tâches")
            }
        }
        var icon: String {
            switch self {
            case .epfl: return "building.2"
            case .lectures: return "building.columns"
            case .exams: return "graduationcap"
            case .sessions: return "timer"
            case .tasks: return "checklist"
            }
        }
    }

    /// `nil` = toutes les familles.
    var family: Family?
    var courseID: UUID?

    var isEverything: Bool { family == nil && courseID == nil }

    func allows(_ entry: AgendaEntry) -> Bool {
        if let courseID, entry.courseID != courseID { return false }
        guard let family else { return true }
        switch entry.kind {
        case .calendar: return family == .lectures
        case .exam: return family == .exams
        case .planned: return family == .sessions
        case .task: return family == .tasks
        case .milestone: return family == .epfl
        }
    }
}

/// Onglet Agenda : une semaine à balayer, la journée choisie en détail, et ce
/// qui vient ensuite.
///
/// La version précédente était une liste plate « des 30 prochains jours » : ni
/// hier, ni la semaine d'un coup d'œil, ni le moyen de sauter à mardi. La bande de
/// semaine règle les trois — et une pastille sous chaque jour dit s'il y a quelque
/// chose avant même de le toucher.
struct AgendaView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \Exam.date) private var exams: [Exam]
    @Query(sort: \PlannedSession.startsAt) private var plannedSessions: [PlannedSession]
    @Query(sort: \LinkedTask.dueDate) private var tasks: [LinkedTask]
    @Query(sort: \LinkedCalendarEvent.startsAt) private var events: [LinkedCalendarEvent]
    /// Le calendrier académique (« Vie de l'EPFL ») : vacances, sessions
    /// d'examens, délais d'inscription.
    @Query(sort: \AcademicMilestone.date) private var milestones: [AcademicMilestone]
    @State private var showingEPFL = false

    @State private var selectedDay = DateUtils.startOfDay(Date())
    @State private var weekStart = DateUtils.startOfWeek(Date())
    @State private var filter = AgendaFilter()
    @State private var showingPlan = false
    /// Début choisi en touchant un créneau libre ; sinon, le défaut du jour.
    @State private var planStart: Date?
    @State private var syncMessage: String?
    @State private var isSyncing = false
    @State private var sessionToDelete: PlannedSession?
    @State private var editingExam: Exam?

    private let calendar = Calendar.current

    // MARK: Données

    /// Toutes les entrées de la fenêtre utile : de la semaine affichée à 120 jours.
    private var allEntries: [AgendaEntry] {
        let start = min(weekStart, DateUtils.startOfDay(Date()))
        let end = DateUtils.addDays(120, to: max(weekStart, Date()))
        var result: [AgendaEntry] = []

        for exam in exams where exam.date >= start && exam.date <= end {
            result.append(AgendaEntry(
                id: "exam-\(exam.id)",
                date: exam.date,
                endDate: nil,
                title: exam.title,
                subtitle: [exam.course?.displayCode, exam.location.isEmpty ? nil : exam.location, exam.weightLabel]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: exam.kind.icon,
                color: exam.kind.color,
                kind: .exam,
                courseID: exam.course?.id,
                exam: exam))
        }

        for session in plannedSessions where session.startsAt >= start && session.startsAt <= end {
            result.append(AgendaEntry(
                id: "planned-\(session.id)",
                date: session.startsAt,
                endDate: session.endsAt,
                title: session.title,
                subtitle: [session.course?.displayCode,
                           session.location.isEmpty ? nil : session.location,
                           session.isGroupSession ? session.groupName : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: "timer",
                color: .indigo,
                kind: .planned,
                courseID: session.course?.id,
                plannedSession: session))
        }

        for milestone in milestones where milestone.date >= start && milestone.date <= end {
            result.append(AgendaEntry(
                id: "milestone-\(milestone.id)",
                date: milestone.date,
                endDate: nil,
                title: milestone.title,
                subtitle: milestone.kind.label,
                icon: milestone.kind.icon,
                color: Carnet.inkSecondary,
                kind: .milestone))
        }

        // L'agenda n'est pas le calendrier personnel : cours, séances
        // d'exercices, évaluations et révisions seulement ; jamais de journée
        // entière (anniversaires, congés).
        for event in events where event.startsAt >= start && event.startsAt <= end
            && event.isAcademic && event.durationSeconds < 20 * 3600 {
            result.append(AgendaEntry(
                id: "event-\(event.id)",
                date: event.startsAt,
                endDate: event.endsAt,
                title: event.title,
                subtitle: eventSubtitle(event),
                icon: event.kind.icon,
                color: event.course.map { Carnet.tint($0.colorHex) } ?? event.kind.color,
                kind: .calendar,
                courseID: event.course?.id,
                event: event))
        }

        for task in tasks {
            guard let due = task.dueDate, !task.isDone, due >= start, due <= end else { continue }
            result.append(AgendaEntry(
                id: "task-\(task.id)",
                date: due,
                endDate: nil,
                title: task.title,
                subtitle: [task.course?.displayCode ?? task.provider.label, task.isOverdue ? String(localized: "en retard") : nil]
                    .compactMap { $0 }.joined(separator: " · "),
                icon: "checklist",
                color: task.isOverdue ? .red : .teal,
                kind: .task,
                courseID: task.course?.id,
                task: task))
        }

        return result
            .filter { filter.allows($0) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.date < rhs.date
            }
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func entries(on day: Date) -> [AgendaEntry] {
        allEntries.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Les sept jours qui suivent la journée choisie, groupés par jour — au plus
    /// douze entrées. Une liste plate de « 8 prochains » mélangeait demain et
    /// dans trois semaines sans que rien ne les sépare.
    private var upcomingDays: [(day: Date, entries: [AgendaEntry])] {
        let from = DateUtils.addDays(1, to: selectedDay)
        let to = DateUtils.addDays(8, to: selectedDay)
        let items = Array(allEntries.filter { $0.date >= from && $0.date < to }.prefix(12))
        let grouped = Dictionary(grouping: items) { DateUtils.startOfDay($0.date) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private func eventSubtitle(_ event: LinkedCalendarEvent) -> String {
        var parts: [String] = []
        if let course = event.course { parts.append(course.displayCode) }
        if !event.location.isEmpty { parts.append(event.location) }
        if event.isLecture, event.isSkipped { parts.append(String(localized: "manqué")) }
        return parts.isEmpty ? event.kind.label : parts.joined(separator: " · ")
    }

    // MARK: Corps

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionGap) {
                    VStack(alignment: .leading, spacing: Layout.block) {
                        weekStrip
                        filterBar
                    }
                    daySection
                    upcomingSection
                    if let syncMessage {
                        Label(syncMessage, systemImage: "calendar.badge.checkmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(Layout.screenPadding)
                .adaptiveColumn()
            }
            .background(Carnet.ground.ignoresSafeArea())
            .carnetBackground()
            .navigationTitle("Agenda")
            .toolbar { toolbar }
            // Tirer vers le bas relit le calendrier système — le geste de toute
            // app d'agenda, au lieu d'un bouton caché dans un menu de filtres.
            .refreshable { await syncCalendar() }
            .onAppear { applyRoute(app.router.agendaRoute) }
            .onChange(of: app.router.agendaRoute) { _, route in applyRoute(route) }
            .sheet(isPresented: $showingPlan, onDismiss: { planStart = nil }) {
                PlanSessionView(group: nil, defaultStart: planStart ?? defaultPlanStart)
            }
            .navigationDestination(isPresented: $showingEPFL) { EPFLLifeView() }
            .sheet(item: $editingExam) { exam in
                if let course = exam.course {
                    ExamFormSheet(course: course, exam: exam)
                }
            }
            .confirmationDialog("Supprimer cette session ?",
                                isPresented: Binding(get: { sessionToDelete != nil },
                                                     set: { if !$0 { sessionToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let session = sessionToDelete {
                        PlannedSessionActions.delete(session, context: context, app: app)
                    }
                    sessionToDelete = nil
                }
                Button("Annuler", role: .cancel) { sessionToDelete = nil }
            } message: {
                Text("La session est aussi retirée du calendrier système et son rappel annulé.")
            }
        }
    }

    /// « Ta journée » sur l'accueil, ou « Séances et sessions » d'un cours,
    /// ouvrent l'agenda sur un jour et, au besoin, un cours.
    private func applyRoute(_ route: AppRouter.AgendaRoute?) {
        guard let route else { return }
        selectedDay = DateUtils.startOfDay(route.day)
        weekStart = DateUtils.startOfWeek(route.day)
        filter = AgendaFilter(family: nil, courseID: route.courseID)
        app.router.agendaRoute = nil
    }

    /// Planifier depuis un jour choisi : la feuille s'ouvre sur ce jour, à 18 h.
    private var defaultPlanStart: Date {
        if calendar.isDateInToday(selectedDay) { return Date().addingTimeInterval(3600) }
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: selectedDay) ?? selectedDay
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingEPFL = true
            } label: {
                Image(systemName: "building.2")
            }
            .accessibilityLabel("Calendrier de l'EPFL")
            Button {
                showingPlan = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Planifier une session d'étude")
        }
        // L'agenda s'ouvre en feuille, depuis n'importe quel onglet.
        ToolbarItem(placement: .cancellationAction) {
            Button("Fermer") { app.router.showingAgenda = false }
        }
    }

    // MARK: Bande de semaine

    private var weekStrip: some View {
        VStack(spacing: Layout.block) {
            HStack(spacing: Layout.inline) {
                VStack(alignment: .leading, spacing: Layout.micro) {
                    Text(weekTitle)
                        .font(.headline)
                    Text(weekSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !calendar.isDate(selectedDay, inSameDayAs: Date()) {
                    Button("Aujourd'hui") {
                        withAnimation(Motion.snappy) {
                            selectedDay = DateUtils.startOfDay(Date())
                            weekStart = DateUtils.startOfWeek(Date())
                        }
                        Haptics.soft()
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                Button {
                    shiftWeek(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentInk)
                .accessibilityLabel("Semaine précédente")
                Button {
                    shiftWeek(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: Layout.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentInk)
                .accessibilityLabel("Semaine suivante")
            }

            HStack(spacing: Layout.tight) {
                ForEach(weekDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .padding(Layout.gutter)
        .background(Theme.softBackground, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            // Balayer la bande change de semaine, comme dans Calendrier.
            if value.translation.width < -40 { shiftWeek(1) }
            if value.translation.width > 40 { shiftWeek(-1) }
        })
    }

    private var weekTitle: String {
        let tracked = courses.filter(\.isTracked)
        if let term = AcademicTerm.resolve(from: tracked.compactMap(\.term)),
           weekStart >= DateUtils.startOfWeek(term.startDate), weekStart < term.endDate {
            return String(localized: "Semaine \(DateUtils.clampedWeek(for: weekStart.addingTimeInterval(3600 * 12), term: term))")
        }
        return String(localized: "Semaine du \(DateUtils.shortDay.string(from: weekStart))")
    }

    private var weekSubtitle: String {
        guard let last = weekDays.last else { return "" }
        return "\(DateUtils.shortDay.string(from: weekStart)) – \(DateUtils.shortDay.string(from: last))"
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let dayEntries = entries(on: day)
        // Jusqu'à trois pastilles, de couleurs distinctes : c'est la nature de la
        // journée qu'on lit, pas son volume.
        var seen: [Color] = []
        for entry in dayEntries where seen.count < 3 && !seen.contains(entry.color) {
            seen.append(entry.color)
        }
        return Button {
            withAnimation(Motion.snappy) { selectedDay = day }
            Haptics.soft()
        } label: {
            VStack(spacing: Layout.tight) {
                Text(DateUtils.weekdayInitial(day))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isToday ? Theme.accentInk : .secondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday || isSelected ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.knockedOutInk : (isToday ? Theme.accentInk : .primary))
                    .frame(width: 34, height: 34)
                    .background {
                        if isSelected {
                            Circle().fill(Theme.accent.accessibleMark)
                        } else if isToday {
                            Circle().strokeBorder(Theme.accent.accessibleMark, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 3) {
                    if seen.isEmpty {
                        Circle().fill(Color.clear).frame(width: 5, height: 5)
                    } else {
                        ForEach(Array(seen.enumerated()), id: \.offset) { _, color in
                            Circle().fill(color.accessibleMark).frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(DateUtils.fullDayLabel(day))\(isToday ? ", aujourd'hui" : ""), \(Plural.count(dayEntries.count, "\(dayEntries.count) élément", "\(dayEntries.count) éléments"))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func shiftWeek(_ delta: Int) {
        withAnimation(Motion.snappy) {
            weekStart = DateUtils.addWeeks(delta, to: weekStart)
            // Le jour choisi suit la semaine : même jour de la semaine.
            selectedDay = DateUtils.addWeeks(delta, to: selectedDay)
        }
        Haptics.soft()
    }

    // MARK: Filtres

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Layout.inline) {
                chip(String(localized: "Tout"), icon: nil, color: nil, isOn: filter.isEverything) {
                    filter = AgendaFilter()
                }
                ForEach(AgendaFilter.Family.allCases) { family in
                    chip(family.label, icon: family.icon, color: nil, isOn: filter.family == family) {
                        filter.family = filter.family == family ? nil : family
                    }
                }
                Divider().frame(height: 20)
                ForEach(courses.filter(\.isTracked)) { course in
                    chip(course.displayCode, icon: nil, color: Carnet.tint(course.colorHex),
                         isOn: filter.courseID == course.id) {
                        filter.courseID = filter.courseID == course.id ? nil : course.id
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
        }
        // Les pastilles défilent jusqu'au bord de l'écran, pas jusqu'à la marge.
        .padding(.horizontal, -Layout.gutter)
    }

    private func chip(_ title: String, icon: String?, color: Color?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.snappy) { action() }
            Haptics.soft()
        } label: {
            HStack(spacing: Layout.snug) {
                if let color {
                    Circle().fill(color.accessibleMark).frame(width: 8, height: 8)
                } else if let icon {
                    Image(systemName: icon).font(.caption)
                }
                Text(title).font(.subheadline.weight(isOn ? .semibold : .regular))
            }
            .padding(.horizontal, Layout.block)
            .padding(.vertical, Layout.snug)
            .foregroundStyle(isOn ? Theme.knockedOutInk : .primary)
            .background(isOn ? AnyShapeStyle(Theme.accent.accessibleMark) : AnyShapeStyle(Theme.softBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: Journée

    private var daySection: some View {
        let items = entries(on: selectedDay)
        let allDay = items.filter(\.isAllDay)
        let timed = items.filter { !$0.isAllDay }
        let total = timed.compactMap { entry -> Int? in
            guard let end = entry.endDate else { return nil }
            return Int(end.timeIntervalSince(entry.date))
        }.reduce(0, +)
        let isToday = calendar.isDateInToday(selectedDay)
        return VStack(alignment: .leading, spacing: Layout.control) {
            SectionHeader(title: dayTitle,
                          trailing: total > 0 ? String(localized: "\(DateUtils.durationLabel(seconds: total)) prévues") : nil)
            if items.isEmpty {
                EmptyCard(icon: "calendar",
                          title: isToday ? String(localized: "Rien aujourd'hui") : String(localized: "Rien ce jour-là"),
                          message: filter.isEverything ? "" : String(localized: "Rien avec ce filtre."),
                          actionTitle: String(localized: "Planifier une session")) {
                    showingPlan = true
                }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(allDay) { entry in
                            timelineRow(entry)
                            Divider().padding(.leading, 64)
                        }
                        ForEach(Array(timed.enumerated()), id: \.element.id) { index, entry in
                            if isToday, isNowBefore(entry, previous: index > 0 ? timed[index - 1] : nil) {
                                nowLine
                            }
                            timelineRow(entry)
                            if let gap = freeGap(after: entry, in: items) {
                                Divider().padding(.leading, 64)
                                freeSlotRow(gap)
                            }
                            if index < timed.count - 1 {
                                Divider().padding(.leading, 64)
                            }
                        }
                        if isToday, let last = timed.last, (last.endDate ?? last.date) < Date() {
                            nowLine
                        }
                    }
                }
            }
        }
    }

    /// La ligne « maintenant » tombe avant la première entrée pas encore finie.
    private func isNowBefore(_ entry: AgendaEntry, previous: AgendaEntry?) -> Bool {
        let now = Date()
        guard (entry.endDate ?? entry.date) >= now else { return false }
        guard let previous else { return entry.date > now }
        return (previous.endDate ?? previous.date) < now && entry.date > now
    }

    private var nowLine: some View {
        HStack(spacing: Layout.snug) {
            Text(DateUtils.time.string(from: Date()))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.red.accessibleInk)
                .frame(width: 44, alignment: .trailing)
            Circle().fill(Color.red.accessibleMark).frame(width: 7, height: 7)
            Rectangle().fill(Color.red.accessibleMark).frame(height: 1.5)
        }
        .padding(.vertical, Layout.tight)
        .accessibilityLabel("Maintenant, \(DateUtils.time.string(from: Date()))")
    }

    /// Un créneau libre d'au moins une heure après cette entrée, entre 8 h et
    /// 20 h — là où une session d'étude tient réellement. Le passé est ignoré.
    private func freeGap(after entry: AgendaEntry, in items: [AgendaEntry]) -> DateInterval? {
        guard !entry.isAllDay else { return nil }
        let timed = items.filter { !$0.isAllDay }
        guard let index = timed.firstIndex(where: { $0.id == entry.id }), index + 1 < timed.count else { return nil }
        let start = max(entry.endDate ?? entry.date.addingTimeInterval(3600), Date())
        let next = timed[index + 1].date
        guard let dayStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: selectedDay),
              let dayEnd = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: selectedDay) else { return nil }
        let from = max(start, dayStart), to = min(next, dayEnd)
        guard to.timeIntervalSince(from) >= 3600 else { return nil }
        // Arrondi au quart d'heure suivant : « 14 h 07 » n'est pas une heure qu'on planifie.
        let minutes = calendar.component(.minute, from: from)
        let rounded = calendar.date(byAdding: .minute, value: (15 - minutes % 15) % 15, to: from) ?? from
        return DateInterval(start: rounded, end: to)
    }

    private func freeSlotRow(_ gap: DateInterval) -> some View {
        Button {
            planStart = gap.start
            showingPlan = true
        } label: {
            HStack(spacing: Layout.block) {
                Text(DateUtils.time.string(from: gap.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary)
                    .frame(width: 4, height: 24)
                Text("Libre · \(DateUtils.durationLabel(seconds: Int(gap.duration)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Layout.inline)
                Label("Planifier", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentInk)
            }
            .padding(.vertical, Layout.inline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Créneau libre de \(DateUtils.durationLabel(seconds: Int(gap.duration))) à \(DateUtils.time.string(from: gap.start)). Planifier une session")
    }

    private var dayTitle: String {
        if calendar.isDateInToday(selectedDay) { return String(localized: "Aujourd'hui") }
        if calendar.isDateInTomorrow(selectedDay) { return String(localized: "Demain") }
        if calendar.isDateInYesterday(selectedDay) { return String(localized: "Hier") }
        return DateUtils.fullDayLabel(selectedDay).capitalizedFirst
    }

    /// Une ligne de journée : l'heure à gauche, dans sa colonne, puis l'entrée.
    private func timelineRow(_ entry: AgendaEntry) -> some View {
        let isPast = calendar.isDateInToday(selectedDay) && !entry.isAllDay && (entry.endDate ?? entry.date) < Date()
        return HStack(alignment: .top, spacing: Layout.block) {
            VStack(alignment: .trailing, spacing: Layout.micro) {
                Text(entry.isAllDay ? String(localized: "Jour") : DateUtils.time.string(from: entry.date))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if let end = entry.endDate {
                    Text(DateUtils.time.string(from: end))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 44, alignment: .trailing)
            .padding(.top, Layout.micro)

            RoundedRectangle(cornerRadius: 2)
                .fill(entry.color.accessibleMark)
                .frame(width: 4)

            actions(for: entry) {
                HStack(spacing: Layout.control) {
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Layout.inline)
                    if let event = entry.event, event.isCheckable() {
                        // Coché = compté dans les heures (Réglages › Chrono › Ce qui compte) :
                        // « J'y étais » ou « manqué », d'un geste.
                        let on = event.isChecked()
                        CheckCircleButton(isOn: on,
                                          tint: TaskType.lecture.tint,
                                          label: on ? String(localized: "Marquer \(event.title) manqué") : String(localized: "J'étais à \(event.title)")) {
                            event.toggleChecked()
                            try? context.save()
                        }
                    } else {
                        Image(systemName: entry.icon)
                            .font(.caption)
                            .foregroundStyle(entry.color.accessibleMark)
                    }
                }
            }
        }
        .padding(.vertical, Layout.inline)
        .frame(minHeight: Layout.minTouch)
        .opacity(isPast ? 0.55 : 1)
    }

    // MARK: À venir

    @ViewBuilder
    private var upcomingSection: some View {
        let days = upcomingDays
        if !days.isEmpty {
            VStack(alignment: .leading, spacing: Layout.control) {
                SectionHeader(title: String(localized: "Les jours suivants"), trailing: nil)
                Card {
                    VStack(alignment: .leading, spacing: Layout.block) {
                        ForEach(Array(days.enumerated()), id: \.element.day) { index, group in
                            Button {
                                withAnimation(Motion.snappy) {
                                    selectedDay = group.day
                                    weekStart = DateUtils.startOfWeek(group.day)
                                }
                                Haptics.soft()
                            } label: {
                                Text(upcomingDayLabel(group.day))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accentInk)
                                    .textCase(.uppercase)
                            }
                            .buttonStyle(.plain)
                            ForEach(group.entries) { entry in
                                actions(for: entry) {
                                    HStack(spacing: Layout.block) {
                                        Text(entry.isAllDay ? String(localized: "Jour") : DateUtils.time.string(from: entry.date))
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                            .frame(width: 44, alignment: .leading)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(entry.color.accessibleMark)
                                            .frame(width: 4, height: 28)
                                        VStack(alignment: .leading, spacing: Layout.micro) {
                                            Text(entry.title).font(.subheadline).lineLimit(1)
                                            if !entry.subtitle.isEmpty {
                                                Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: Layout.inline)
                                        if entry.kind == .exam {
                                            Text(DateUtils.countdownLabel(to: entry.date))
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(entry.color.accessibleInk)
                                        }
                                    }
                                }
                            }
                            if index < days.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func upcomingDayLabel(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Aujourd'hui") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Demain") }
        return DateUtils.fullDayLabel(day)
    }

    // MARK: Actions de ligne

    /// Habille une entrée des gestes qui lui correspondent : tap pour modifier une
    /// évaluation, menu contextuel pour supprimer une session, terminer une tâche
    /// ou lancer le chrono.
    @ViewBuilder
    private func actions<Content: View>(for entry: AgendaEntry, @ViewBuilder content: () -> Content) -> some View {
        let base = content().contentShape(Rectangle())
        if let exam = entry.exam {
            Button { editingExam = exam } label: { base }
                .buttonStyle(.plain)
                .accessibilityHint("Modifier l'évaluation")
        } else if let session = entry.plannedSession {
            base.contextMenu {
                Button {
                    app.router.startFocus(courseID: session.course?.id,
                                          courseCode: session.course?.code ?? "",
                                          taskType: .exercise,
                                          label: session.title)
                } label: {
                    Label("Démarrer le chrono", systemImage: "timer")
                }
                Button(role: .destructive) {
                    sessionToDelete = session
                } label: {
                    Label("Supprimer la session", systemImage: "trash")
                }
            }
        } else if let task = entry.task {
            base.contextMenu {
                Button {
                    complete(task)
                } label: {
                    Label("Terminer la tâche", systemImage: "checkmark")
                }
            }
        } else if let event = entry.event, event.course != nil || [.lecture, .exerciseSession].contains(event.kind) {
            // Le type d'une séance se corrige ici, pour **tout son créneau** :
            // une séance d'exercices comptée en amphi gonflait le bilan.
            base.contextMenu {
                if let course = event.course {
                    Button {
                        app.router.startFocus(courseID: course.id,
                                              courseCode: course.code,
                                              taskType: event.kind == .lecture ? .lecture : .exercise,
                                              label: "")
                    } label: {
                        Label("Démarrer le chrono", systemImage: "timer")
                    }
                }
                Section("Ce créneau, chaque semaine") {
                    Button {
                        retype(event, as: .lecture)
                    } label: {
                        Label(event.kind == .lecture ? "Cours en amphi ✓" : "C'est un cours en amphi",
                              systemImage: CalendarEventKind.lecture.icon)
                    }
                    Button {
                        retype(event, as: .exerciseSession)
                    } label: {
                        Label(event.kind == .exerciseSession ? "Séance d'exercices ✓" : "C'est une séance d'exercices",
                              systemImage: CalendarEventKind.exerciseSession.icon)
                    }
                    Button {
                        retype(event, as: .other)
                    } label: {
                        Label("Ni l'un ni l'autre", systemImage: CalendarEventKind.other.icon)
                    }
                }
            }
        } else {
            base
        }
    }

    /// Change le type de toutes les séances du créneau, et le dit.
    private func retype(_ event: LinkedCalendarEvent, as kind: CalendarEventKind) {
        let count = CalendarSync.setKind(kind, forSlotOf: event, context: context)
        syncMessage = String(localized: "\(Plural.count(count, "\(count) séance", "\(count) séances")) du même créneau : \(kind.label.lowercased()).")
        Haptics.success()
    }

    private func complete(_ task: LinkedTask) {
        task.isDone = true
        task.updatedAt = Date()
        try? context.save()
        Haptics.success()
        if let externalID = task.externalID,
           let service = TaskServiceFactory.shared.service(for: task.provider, settings: app.settings) {
            Task { _ = await service.setCompleted(identifier: externalID, completed: true) }
        }
    }

    @MainActor
    private func syncCalendar() async {
        isSyncing = true
        defer { isSyncing = false }

        if !app.calendar.hasAccess {
            let granted = await app.calendar.requestAccess()
            guard granted else {
                syncMessage = String(localized: "Accès au calendrier refusé. Autorise-le dans Réglages › Polymestre.")
                return
            }
        }

        let result = CalendarSync.sync(context: context,
                                       courses: courses,
                                       service: app.calendar)
        syncMessage = result.total == 0
            ? String(localized: "Calendrier relu · aucun nouvel événement.")
            : String(localized: "Calendrier relu · \(Plural.count(result.imported, "\(result.imported) ajouté", "\(result.imported) ajoutés")), \(result.updated) mis à jour.")
    }
}
