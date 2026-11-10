import SwiftUI
import SwiftData

/// Une ligne d'horaire : l'heure, le cours, la salle.
struct EventLine: View {
    let event: LinkedCalendarEvent
    @Environment(\.modelContext) private var context

    var body: some View {
        let tint = Carnet.tint(event.course)
        let now = Date()
        let live = event.startsAt <= now && now < event.endsAt
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(DateUtils.time.string(from: event.startsAt)).font(.callout.monospacedDigit()).foregroundStyle(Carnet.ink)
                Text(DateUtils.time.string(from: event.endsAt)).font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
            }
            .frame(width: 38, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.course?.displayCode ?? event.title).font(.callout.weight(.semibold)).foregroundStyle(Carnet.ink).lineLimit(1)
                Text([event.kind.label, event.location.isEmpty ? nil : event.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            if live { Kicker("En cours", color: tint) }
            // Coché = compté dans les heures (« J'y étais » / « manqué »), d'un clic.
            if event.isCheckable() {
                let on = event.isChecked()
                Button {
                    event.toggleChecked()
                    try? context.save()
                } label: {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(on ? tint : Carnet.inkTertiary)
                }
                .buttonStyle(.plain)
                .help(on ? "Compté — cliquer pour marquer manqué" : "J'y étais")
                .accessibilityLabel(on ? "Marquer manqué" : "J'y étais")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(event.endsAt < now ? 0.55 : 1)
    }
}

/// Une échéance : l'icône, quoi, quand.
struct DeadlineLine: View {
    let item: Deadline

    var body: some View {
        let tint = Carnet.tint(item.colorHex)
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.callout)
                .foregroundStyle(item.kind == .exam ? Carnet.wrong : tint)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium)).foregroundStyle(Carnet.ink).lineLimit(1)
                Text("\(item.courseCode) · \(item.detail)").font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            Text(DateUtils.countdownLabel(to: item.date))
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.kind == .exam ? Carnet.wrong : Carnet.inkSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverRow()
    }
}

/// L'agenda : la semaine en colonnes (horaire EPFL, évaluations, rendus), et la
/// liste de ce qui vient.
struct MacAgendaView: View {
    var open: (UUID, UUID?) -> Void

    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \LinkedCalendarEvent.startsAt) private var allEvents: [LinkedCalendarEvent]
    @State private var weekOffset = 0

    private var tracked: [Course] { courses.filter(\.isTracked) }
    /// Le week-end, la semaine qui vient : celle qui finit n'a plus rien à faire.
    private var baseOffset: Int { Calendar.current.isDateInWeekend(Date()) ? 1 : 0 }
    private var weekStart: Date { DateUtils.addDays(7 * (weekOffset + baseOffset), to: DateUtils.startOfWeek(Date())) }

    /// Les heures montrées : 8 h à 19 h, élargies si un cours déborde.
    private static let firstHour = 8
    private static let lastHour = 19
    private static let hourHeight: CGFloat = 52

    var body: some View {
        let start = weekStart
        let end = DateUtils.addDays(7, to: start)
        // Les séances manquées restent visibles, estompées : on peut se raviser.
        let events = allEvents.filter { $0.startsAt >= start && $0.startsAt < end && $0.isAcademic }
        let deadlines = Deadline.between(tracked, start, end)
        let days = (0..<7).map { DateUtils.addDays($0, to: start) }
            .filter { day in
                // Le week-end seulement s'il s'y passe quelque chose.
                let weekday = Calendar.current.component(.weekday, from: day)
                guard weekday == 1 || weekday == 7 else { return true }
                return events.contains { Calendar.current.isDate($0.startsAt, inSameDayAs: day) }
                    || deadlines.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
            }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(start)
                grid(days: days, events: events, deadlines: deadlines)
                    .paperSheet(padding: 0)
                let coming = Deadline.upcoming(in: tracked, days: 30)
                if !coming.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: String(localized: "À venir"), trailing: String(localized: "30 jours"))
                        VStack(spacing: 0) {
                            ForEach(coming) { item in
                                Button { open(item.courseID, item.targetID) } label: {
                                    HStack(spacing: 0) {
                                        Text(DateUtils.shortDay.string(from: item.date))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(Carnet.inkSecondary)
                                            .frame(width: 90, alignment: .leading)
                                            .padding(.leading, 12)
                                        DeadlineLine(item: item)
                                    }
                                }
                                .buttonStyle(.plain)
                                if item.id != coming.last?.id { PaperRule(inset: 12) }
                            }
                        }
                        .paperSheet(padding: 4)
                    }
                }
            }
            .padding(Carnet.pagePadding)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Agenda")
    }

    private func header(_ start: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                let week = tracked.first.map { $0.currentWeek + weekOffset + baseOffset }
                Kicker(week.map { $0 > 0 ? String(localized: "Semaine \($0)") : String(localized: "Hors semestre") } ?? String(localized: "Semaine"))
                Text(weekLabel(start)).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
            }
            Spacer()
            HStack(spacing: 6) {
                Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Aujourd'hui") { weekOffset = 0 }.disabled(weekOffset == 0)
                Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            .buttonStyle(.paper)
        }
    }

    private func weekLabel(_ start: Date) -> String {
        let end = DateUtils.addDays(6, to: start)
        let formatter = DateFormatter()
        formatter.locale = DateUtils.appLocale
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return String(localized: "Du \(formatter.string(from: start)) au \(formatter.string(from: end))")
    }

    // MARK: Grille

    private func grid(days: [Date], events: [LinkedCalendarEvent], deadlines: [Deadline]) -> some View {
        let hours = Array(Self.firstHour...Self.lastHour)
        return VStack(spacing: 0) {
            // En-têtes de jours, et les échéances du jour sous le nom.
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: 48)
                ForEach(days, id: \.self) { day in
                    let today = Calendar.current.isDateInToday(day)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)).capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(today ? Carnet.ink : Carnet.inkSecondary)
                            Text(day.formatted(.dateTime.day()))
                                .font(Carnet.serif(18, weight: today ? .semibold : .regular))
                                .foregroundStyle(Carnet.ink)
                            if today { Circle().fill(Carnet.wrong).frame(width: 5, height: 5) }
                        }
                        ForEach(deadlines.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { item in
                            Button { open(item.courseID, item.targetID) } label: {
                                Label(item.title, systemImage: item.icon)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(item.kind == .exam ? Carnet.ground : Carnet.ink)
                                    .background(item.kind == .exam ? Carnet.wrong : Carnet.tint(item.colorHex).opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("\(item.courseCode) · \(item.detail)")
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(today ? Carnet.marker.opacity(0.5) : .clear)
                }
            }
            PaperRule()
            // Les heures et les cours.
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { hour in
                        Text("\(hour) h")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Carnet.inkTertiary)
                            .frame(width: 48, height: Self.hourHeight, alignment: .topTrailing)
                            .padding(.trailing, 6)
                            .offset(y: -6)
                    }
                }
                ForEach(days, id: \.self) { day in
                    DayColumn(day: day, events: events.filter { Calendar.current.isDate($0.startsAt, inSameDayAs: day) },
                              firstHour: Self.firstHour, hours: hours.count, hourHeight: Self.hourHeight) { event in
                        if let course = event.course { open(course.id, nil) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }
}

/// Une colonne de jour : les traits des heures, les cours posés à leur heure.
private struct DayColumn: View {
    let day: Date
    let events: [LinkedCalendarEvent]
    let firstHour: Int
    let hours: Int
    let hourHeight: CGFloat
    var tap: (LinkedCalendarEvent) -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<hours, id: \.self) { _ in
                    Rectangle().fill(Carnet.rule.opacity(0.6)).frame(height: 1)
                        .frame(height: hourHeight, alignment: .top)
                }
            }
            GeometryReader { geometry in
            let slots = AgendaLanes.assign(events.map { (start: $0.startsAt, end: $0.endsAt) })
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                let top = offset(event.startsAt)
                // Coupé au bas de la grille (un événement qui finit après la dernière heure, ou le lendemain).
                let bottom = Calendar.current.isDate(event.endsAt, inSameDayAs: day) ? offset(event.endsAt) : CGFloat(hours) * hourHeight
                let height = max(18, min(bottom, CGFloat(hours) * hourHeight) - top - 2)
                let slot = slots[index]
                let width = geometry.size.width / CGFloat(slot.lanes)
                let tint = Carnet.tint(event.course)
                Button { tap(event) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(event.course?.displayCode ?? event.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Carnet.ink)
                                .strikethrough(event.isSkipped)
                                .lineLimit(1)
                            if event.isCheckable(), event.isChecked() {
                                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(tint)
                                    .accessibilityLabel("Compté")
                            }
                        }
                        if height > 34 {
                            Text([event.kind == .lecture ? String(localized: "Cours (une séance)") : event.kind.label, event.location.isEmpty ? nil : event.location]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(Carnet.inkSecondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(tint.opacity(event.kind == .lecture ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3).padding(.vertical, 3)
                    }
                }
                .buttonStyle(.plain)
                .opacity(event.isSkipped ? 0.45 : 1)
                .contextMenu {
                    if event.isCheckable() {
                        let on = event.isChecked()
                        Button(on ? "Marquer manqué" : "J'y étais") { event.toggleChecked(); try? context.save() }
                    }
                }
                .padding(.horizontal, slot.lanes > 1 ? 1.5 : 3)
                .frame(width: width, height: height)
                .offset(x: width * CGFloat(slot.lane), y: top)
                .help("\(event.title)\n\(DateUtils.time.string(from: event.startsAt)) – \(DateUtils.time.string(from: event.endsAt))" + (event.isCheckable() ? "\n" + String(localized: "Clic droit : j'y étais / manqué") : ""))
            }
            }
            if Calendar.current.isDateInToday(day) {
                let now = offset(Date())
                if now > 0, now < CGFloat(hours) * hourHeight {
                    Rectangle().fill(Carnet.wrong).frame(height: 1.5).offset(y: now)
                }
            }
        }
        .frame(height: CGFloat(hours) * hourHeight, alignment: .top)
    }

    private func offset(_ date: Date) -> CGFloat {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hours = Double((parts.hour ?? 0) - firstHour) + Double(parts.minute ?? 0) / 60
        return CGFloat(max(0, hours)) * hourHeight
    }
}
