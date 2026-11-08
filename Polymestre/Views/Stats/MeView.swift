import SwiftUI
import SwiftData

/// « Moi » : qui, la semaine en trois chiffres, le bilan et les réglages.
/// Une feuille ouverte par l'avatar d'« Aujourd'hui ».
///
/// C'était une feuille « Profil & réglages » ouverte par l'avatar : un sommaire
/// de réglages d'abord, le bilan à un toucher de plus. On ouvre surtout cet
/// onglet pour **voir où on en est** — le bilan vient donc en premier ; les
/// liens (Moodle, calendrier, assistant) disent ensuite s'ils marchent ; les
/// réglages, inchangés, sont au bout d'une ligne.
struct MeView: View {
    var onClose: (() -> Void)? = nil
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    /// Les sessions de la semaine (et un peu avant, au passage du lundi).
    @Query private var sessions: [StudySession]
    /// `-settings` (captures) : ouvre les réglages à l'arrivée.
    @State private var debugSettings = false

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        let since = DateUtils.addDays(-7, to: DateUtils.startOfWeek(Date()))
        _sessions = Query(filter: #Predicate<StudySession> { $0.startedAt >= since },
                          sort: \StudySession.startedAt, order: .reverse)
    }

    var body: some View {
        NavigationStack {
            CarnetScroll {
                identity
                weekStats
                settingsLinks
            }
            .navigationTitle("Moi")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .accessibilityLabel("Fermer")
                    }
                }
            }
            .navigationDestination(isPresented: $debugSettings) { ProfileView(isEmbedded: true) }
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("-settings") { debugSettings = true }
                #endif
            }
        }
    }

    // MARK: Qui

    private var identity: some View {
        let name = app.settings.displayName.trimmingCharacters(in: .whitespaces)
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        // Qui : une carte, pas un lien — les réglages (nom, section compris)
        // ont leur ligne juste en dessous ; deux entrées menaient à la même page.
        return HStack(spacing: 14) {
            Group {
                if initials.isEmpty {
                    Image(systemName: "person.fill").font(.title3)
                } else {
                    Text(initials).font(Carnet.serif(.title3, weight: .semibold))
                }
            }
            .foregroundStyle(Carnet.ground)
            .frame(width: 52, height: 52)
            .background(Carnet.ink, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Profil" : name)
                    .font(Carnet.serif(.title3))
                    .foregroundStyle(Carnet.ink)
                if let section = app.settings.section?.name {
                    Text(section)
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Bilan

    private var tracked: [Course] { courses.filter(\.isTracked) }

    /// Trois chiffres, **tous de la semaine** : le temps, ce qui était prévu et
    /// est fait, ce qui a été corrigé juste. (Le deuxième était celui du
    /// semestre et le troisième de toujours, sous le titre « Cette semaine ».)
    private var weekStats: some View {
        let start = DateUtils.startOfWeek(Date())
        let end = DateUtils.addDays(7, to: start)
        let _ = sessions.count
        let seconds = StudyTime.seconds(in: context, from: start, to: end)
        let weekSessions = sessions.prefix { $0.startedAt >= start }.filter { $0.startedAt < end }
        let weeks = tracked.map { ProgressEngine.weekProgress(for: $0, week: $0.currentWeek) }
        let done = weeks.reduce(0) { $0 + $1.watchedCount + $1.doneCount }
        let total = weeks.reduce(0) { $0 + $1.videoCount + $1.exerciseCount }
        let corrected = tracked.flatMap(\.allExercises).filter {
            guard let at = $0.correctedAt, $0.correctness != nil else { return false }
            return at >= start && at < end
        }
        let right = corrected.filter { $0.correctness == .correct }.count
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(String(localized: "Cette semaine"))
            HStack(spacing: 8) {
                CarnetStat(label: "Travail", value: DateUtils.hoursLabel(seconds: seconds),
                           detail: Plural.count(weekSessions.count, "\(weekSessions.count) session", "\(weekSessions.count) sessions"))
                CarnetStat(label: String(localized: "Fait"), value: total == 0 ? "—" : "\(done)/\(total)",
                           detail: String(localized: "du programme"))
                CarnetStat(label: String(localized: "Juste"), value: corrected.isEmpty ? "—" : "\(Int((Double(right) / Double(corrected.count) * 100).rounded())) %",
                           detail: corrected.isEmpty ? String(localized: "rien de corrigé") : Plural.count(corrected.count, "\(corrected.count) corrigé", "\(corrected.count) corrigés"))
            }
        }
    }

    // MARK: Réglages

    private var settingsLinks: some View {
        CarnetSheet {
            NavigationLink {
                StatsView()
            } label: {
                CarnetRow(icon: "chart.bar.xaxis", tint: Carnet.inkSecondary, title: String(localized: "Bilan")) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                }
            }
            .buttonStyle(.plain)
            CarnetRule()
            NavigationLink {
                ProfileView(isEmbedded: true)
            } label: {
                CarnetRow(icon: "gearshape", tint: Carnet.inkSecondary, title: String(localized: "Réglages")) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
