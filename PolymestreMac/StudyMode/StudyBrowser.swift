import AppKit
import SwiftUI
import WebKit

/// Le navigateur du mode étude : des onglets, et seulement les sites permis.
///
/// Safari, Chrome et Arc sont fermés pendant le mode étude ; Moodle, Courseware,
/// Botafogo et Claude s'ouvrent ici. Chaque navigation de la page principale
/// est vérifiée (`StudyMode.isAllowed`) : un lien vers YouTube ou Instagram est
/// refusé, avec un mot pour le dire. Les ressources d'une page permise (images,
/// vidéos intégrées, scripts) ne sont pas filtrées : une page de cours doit
/// s'afficher en entier. Les connexions (Moodle, Claude) sont gardées d'une
/// session à l'autre, dans le magasin du système.
@MainActor
@Observable
final class StudyBrowserModel: NSObject {
    @MainActor
    @Observable
    final class Tab: Identifiable {
        let id = UUID()
        let webView: WKWebView
        var title: String
        var url: URL?
        var isLoading = false
        var canGoBack = false
        var canGoForward = false
        @ObservationIgnored var observations: [NSKeyValueObservation] = []

        init(webView: WKWebView, title: String) {
            self.webView = webView
            self.title = title
        }
    }

    private(set) var tabs: [Tab] = []
    var selectedID: UUID?
    /// Le dernier site refusé (bandeau), et quand.
    private(set) var refused: (host: String, at: Date)?

    /// Les sites permis : lus dans les réglages à chaque navigation.
    @ObservationIgnored var sites: () -> [String] = { StudyMode.defaultSites }
    /// Le mode étude bloque-t-il ? Sinon, tous les sites s'ouvrent.
    @ObservationIgnored var locks: () -> Bool = { true }

    private func allows(_ url: URL?) -> Bool {
        !locks() || StudyMode.isAllowed(url: url, sites: sites())
    }

    private static let configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }()

    var selected: Tab? { tabs.first { $0.id == selectedID } ?? tabs.last }

    // MARK: Onglets

    /// Ouvre un outil : l'onglet qui montre déjà ce site, sinon un nouveau.
    func open(_ url: URL, title: String) {
        if let existing = tabs.first(where: { $0.url?.host == url.host && $0.title == title }) {
            selectedID = existing.id
            return
        }
        let tab = makeTab(title: title)
        tab.webView.load(URLRequest(url: url))
        selectedID = tab.id
    }

    @discardableResult
    private func makeTab(title: String, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let webView = WKWebView(frame: .zero, configuration: configuration ?? Self.configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Une signature de Safari : certains sites (connexion Google) refusent
        // un navigateur intégré qui ne dit pas son nom.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        let tab = Tab(webView: webView, title: title)
        tab.observations = [
            webView.observe(\.title) { view, _ in
                MainActor.assumeIsolated { if let title = view.title, !title.isEmpty { tab.title = title } }
            },
            webView.observe(\.url) { view, _ in MainActor.assumeIsolated { tab.url = view.url } },
            webView.observe(\.isLoading) { view, _ in MainActor.assumeIsolated { tab.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { view, _ in MainActor.assumeIsolated { tab.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { view, _ in MainActor.assumeIsolated { tab.canGoForward = view.canGoForward } },
        ]
        tabs.append(tab)
        return tab
    }

    func close(_ tab: Tab) {
        tab.webView.stopLoading()
        tab.observations.removeAll()
        tabs.removeAll { $0.id == tab.id }
        if selectedID == tab.id { selectedID = tabs.last?.id }
    }

    func closeAll() {
        for tab in tabs { close(tab) }
    }

    fileprivate func refuse(_ url: URL?) {
        refused = ((url?.host ?? url?.absoluteString ?? "ce site").replacingOccurrences(of: "www.", with: ""), Date())
    }

    func dismissRefusal() { refused = nil }
}

extension StudyBrowserModel: WKNavigationDelegate, WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            // Les cadres d'une page permise (une vidéo intégrée) suivent la page.
            guard navigationAction.targetFrame?.isMainFrame ?? true else {
                decisionHandler(.allow)
                return
            }
            if allows(navigationAction.request.url) {
                decisionHandler(.allow)
            } else {
                refuse(navigationAction.request.url)
                decisionHandler(.cancel)
            }
        }
    }

    /// `target="_blank"` : un nouvel onglet, s'il est permis.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            guard allows(navigationAction.request.url) else {
                refuse(navigationAction.request.url)
                return nil
            }
            // Une fenêtre de connexion (« Se connecter avec… ») doit garder son
            // lien avec la page qui l'ouvre : on rend la vue créée avec cette
            // configuration.
            let tab = makeTab(title: navigationAction.request.url?.host ?? String(localized: "Nouvel onglet"), configuration: configuration)
            selectedID = tab.id
            return tab.webView
        }
    }

    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if let tab = tabs.first(where: { $0.webView === webView }) { close(tab) }
        }
    }
}

/// La vue d'un onglet.
struct StudyWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Le navigateur : onglets, barre d'adresse (lecture seule), page.
struct StudyBrowserPane: View {
    @Bindable var browser: StudyBrowserModel
    var tint: Color
    var collapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let tab = browser.selected {
                addressBar(tab)
                ZStack(alignment: .top) {
                    StudyWebView(webView: tab.webView)
                        .id(tab.id)
                    if let refused = browser.refused, Date().timeIntervalSince(refused.at) < 8 {
                        refusalBanner(refused.host)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .background(StudyPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(StudyPalette.rule))
        .animation(.smooth(duration: 0.25), value: browser.refused?.at)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(browser.tabs) { tab in
                let selected = tab.id == browser.selected?.id
                HStack(spacing: 6) {
                    if tab.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "globe").font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                    }
                    Text(tab.title).lineLimit(1).font(.callout)
                        .foregroundStyle(selected ? StudyPalette.ink : StudyPalette.inkSecondary)
                    Button { browser.close(tab) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudyPalette.inkTertiary)
                    .help("Fermer l'onglet")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 220)
                .background(selected ? StudyPalette.ground : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { browser.selectedID = tab.id }
            }
            Spacer(minLength: 8)
            Button(action: collapse) {
                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyPalette.inkSecondary)
            .help("Replier")
        }
        .padding(8)
    }

    private func addressBar(_ tab: StudyBrowserModel.Tab) -> some View {
        HStack(spacing: 12) {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
                .keyboardShortcut("[", modifiers: [.command])
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
                .keyboardShortcut("]", modifiers: [.command])
            Button { tab.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: [.command])
            HStack(spacing: 6) {
                Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.caption)
                Text(tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "")
                    .lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(StudyPalette.inkSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(StudyPalette.ground, in: Capsule())
            Image(systemName: "checkmark.shield").foregroundStyle(tint).help("Sites permis")
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyPalette.ink)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func refusalBanner(_ host: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
            Text("\(host) est bloqué.")
            Button { browser.dismissRefusal() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(StudyPalette.ground)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(StudyPalette.ink, in: Capsule())
    }
}
