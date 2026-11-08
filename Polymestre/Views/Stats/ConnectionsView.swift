import SwiftUI

/// Une connexion à faire : la feuille qui la fait.
enum ConnectionSheet: String, Identifiable {
    case moodle, courseware, explique, mediaspace, groups, ankiweb
    var id: String { rawValue }
}

/// La feuille de connexion d'un compte, qui se ferme seule une fois connecté·e.
struct ConnectionSheetContent: View {
    let sheet: ConnectionSheet
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch sheet {
        case .moodle:
            SiteLoginSheet(source: .moodle) { dismiss() }
        case .courseware:
            SiteLoginSheet(source: .courseware) { dismiss() }
        case .explique:
            SiteLoginSheet(site: .explique) { dismiss() }
        case .mediaspace:
            SiteLoginSheet(site: .mediaspace) { dismiss() }
        case .groups:
            NavigationStack {
                GroupsSignInView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                    }
            }
            .onChange(of: app.social.isSignedIn) { _, signedIn in
                if signedIn { dismiss() }
            }
        case .ankiweb:
            NavigationStack {
                AnkiSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                    }
            }
        }
    }
}

/// Les comptes de l'app, leur état, et le bouton qui connecte.
///
/// La même liste dans l'accueil guidé et dans le profil : tout se relie au même
/// endroit, et chaque ligne dit à quoi sert le compte.
struct ConnectionsList: View {
    @Environment(AppContainer.self) private var app
    @State private var sheet: ConnectionSheet?
    @State private var calendarGranted = false
    /// L'état **vérifié** de chaque site (nil : vérification en cours).
    @State private var sites: [ConnectionSheet: Bool] = [:]
    @State private var checking: Set<ConnectionSheet> = []

    private var center: ConnectionCenter { .shared }
    private static let websites: [ConnectionSheet] = [.moodle, .courseware, .explique, .mediaspace]

    var body: some View {
        CarnetSheet {
            siteRow(.moodle, icon: "graduationcap", title: "Moodle",
                    purpose: String(localized: "Séries, énoncés, théorie et échéances, mis à jour tout seuls"))
            CarnetRule()
            siteRow(.courseware, icon: "play.rectangle", title: "Courseware",
                    purpose: String(localized: "Vidéos des MOOC que les cours demandent de regarder"))
            CarnetRule()
            siteRow(.explique, icon: "sparkles.tv", title: String(localized: "Explique"),
                    purpose: String(localized: "Cours en replay et exercices d'AICC (CS-101)"))
            CarnetRule()
            siteRow(.mediaspace, icon: "video", title: "MediaSpace",
                    purpose: String(localized: "Enregistrements des cours, lus dans l'app"))
            CarnetRule()
            row(icon: "person.2", title: String(localized: "Compte Polymestre"),
                purpose: String(localized: "Groupes, entraide, progression partagée"),
                status: app.social.isSignedIn ? String(localized: "Connecté·e") : (center.state(of: .groups) == .expired ? String(localized: "Session expirée") : String(localized: "Pas de compte")),
                connected: app.social.isSignedIn,
                action: app.social.isSignedIn ? nil : { sheet = .groups })
            CarnetRule()
            row(icon: "rectangle.stack", title: "AnkiWeb",
                purpose: String(localized: "Cartes, révisions et temps de révision"),
                status: ankiStatus,
                connected: AnkiWebSync.shared.isSignedIn && center.state(of: .ankiweb) != .expired,
                action: { sheet = .ankiweb })
            CarnetRule()
            row(icon: "calendar", title: "Calendrier de l'iPhone",
                purpose: String(localized: "Ton horaire et tes sessions dans l'agenda"),
                status: calendarGranted ? String(localized: "Accès accordé") : String(localized: "Accès à autoriser"),
                connected: calendarGranted,
                action: calendarGranted ? nil : {
                    Task { calendarGranted = await app.calendar.requestAccess() }
                })
        }
        .sheet(item: $sheet, onDismiss: {
            // Après une connexion : on revérifie ce site-là.
            for site in Self.websites { Task { await check(site) } }
        }) { ConnectionSheetContent(sheet: $0) }
        .task {
            calendarGranted = app.calendar.hasAccess
            await withTaskGroup(of: Void.self) { group in
                for site in Self.websites { group.addTask { await check(site) } }
            }
        }
    }

    private func siteRow(_ site: ConnectionSheet, icon: String, title: String, purpose: String) -> some View {
        let connected = sites[site] == true
        let status: String
        if checking.contains(site) {
            status = String(localized: "Vérification…")
        } else if connected {
            status = String(localized: "Connecté·e")
        } else if site == .moodle, center.state(of: .moodle) == .expired {
            status = String(localized: "Reconnexion nécessaire")
        } else {
            status = sites[site] == false ? String(localized: "Pas connecté·e") : "—"
        }
        return row(icon: icon, title: title, purpose: purpose, status: status, connected: connected,
                   action: checking.contains(site) ? nil : { sheet = site }, actionTitle: connected ? "Reconnecter" : "Connecter")
    }

    /// Vérifie un site dans le navigateur invisible (sa vraie session).
    @MainActor
    private func check(_ site: ConnectionSheet) async {
        guard !checking.contains(site) else { return }
        checking.insert(site)
        defer { checking.remove(site) }
        let result: Bool
        switch site {
        case .moodle: result = await MoodleClient.background.ensureSignedIn()
        case .courseware: result = await CoursewareClient().isSignedIn()
        case .explique: result = await ExpliqueClient().isSignedIn()
        case .mediaspace: result = await MediaSpaceClient().isSignedIn()
        default: return
        }
        withAnimation(Motion.snappy) { sites[site] = result }
    }

    private var ankiStatus: String {
        guard AnkiWebSync.shared.isSignedIn else { return String(localized: "Facultatif") }
        return center.state(of: .ankiweb) == .expired ? String(localized: "Reconnexion nécessaire") : String(localized: "Connecté·e (\(AnkiWebSync.shared.username))")
    }

    private func row(icon: String, title: String, purpose: String, status: String,
                     connected: Bool, action: (() -> Void)?, actionTitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            CarnetIconTile(systemName: icon, tint: connected ? Carnet.correct : Carnet.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Carnet.ink)
                Text(purpose).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(status, systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(connected ? Carnet.correct : Carnet.inkTertiary)
            }
            Spacer(minLength: 8)
            if let action {
                if connected, actionTitle == nil {
                    Button("Gérer", action: action).buttonStyle(.carnetSecondary)
                } else if connected {
                    Menu {
                        Button(actionTitle ?? "Reconnecter", action: action)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Carnet.inkSecondary)
                    }
                } else {
                    Button(actionTitle ?? "Connecter", action: action).buttonStyle(.carnetSecondary)
                }
            } else if !connected, status == String(localized: "Vérification…") {
                ProgressView()
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Profil › Comptes et connexions.
struct ConnectionsView: View {
    var body: some View {
        CarnetScroll(spacing: 18) {
            ConnectionsList()
        }
        .navigationTitle("Comptes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// La bannière de l'accueil : un compte a expiré et la reconnexion silencieuse
/// a échoué. Une seule à la fois, « Plus tard » la fait taire un jour.
struct ConnectionBanner: View {
    @State private var sheet: ConnectionSheet?
    private var center: ConnectionCenter { .shared }

    var body: some View {
        if let account = center.needingAttention().first {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Carnet.review)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(account.label) : reconnecte-toi")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Carnet.ink)
                    Text(account.consequence.capitalizedFirst + ".")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                    HStack(spacing: 10) {
                        Button("Se reconnecter") {
                            sheet = switch account {
                            case .moodle: .moodle
                            case .groups: .groups
                            case .ankiweb: .ankiweb
                            }
                        }
                        .buttonStyle(.carnetSecondary)
                        Button("Plus tard") {
                            withAnimation(Motion.snappy) { center.snooze(account) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .sheet(item: $sheet) { ConnectionSheetContent(sheet: $0) }
        }
    }
}
