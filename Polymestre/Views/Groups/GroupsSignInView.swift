import SwiftUI
import AuthenticationServices

/// La porte des groupes : un compte d'abord, puis tout le reste.
///
/// Se connecter était rangé dans Moi › Réglages › Compte, et l'onglet Groupes
/// laissait créer des groupes « locaux » qu'on ne pouvait inviter à rien. Ici,
/// une page : ce que les groupes apportent, « Continuer avec Apple », ou
/// e-mail et mot de passe — créer un compte et se connecter étant deux onglets
/// d'un même formulaire.
struct GroupsSignInView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    @State private var mode: Mode = .signUp
    @State private var email = ""
    @State private var password = ""
    @State private var nonce = ""
    @State private var isWorking = false
    @State private var message: String?
    /// Le formulaire e-mail, replié : Apple d'abord, l'e-mail pour qui le veut.
    @State private var usesEmail = false
    @FocusState private var focused: Field?

    enum Mode: String, CaseIterable, Identifiable {
        case signUp, signIn
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .signUp ? "Créer un compte" : "J'ai un compte" }
    }

    enum Field { case email, password }

    var body: some View {
        CarnetScroll(spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Carnet.ink)
                Text("Travailler ensemble")
                    .font(Carnet.serif(.largeTitle))
                    .foregroundStyle(Carnet.ink)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)

            CarnetSheet {
                benefit("dot.radiowaves.left.and.right", String(localized: "Qui travaille en ce moment"))
                CarnetRule()
                benefit("square.grid.3x3.fill", String(localized: "Qui en est où, série par série"))
                CarnetRule()
                benefit("questionmark.bubble", String(localized: "Entraide sur un exercice"))
                CarnetRule()
                benefit("calendar", "Sessions ensemble")
            }

            if SupabaseConfig.isConfigured {
                VStack(spacing: 14) {
                    SignInWithAppleButton(.continue) { request in
                        let value = AppleSignInSupport.randomNonce()
                        nonce = value
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = ProfileView.sha256Hex(value)
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    // Noir le jour, blanc la nuit (recommandation d'Apple) : le
                    // contour blanc posé sur le papier crème faisait un bouton
                    // délavé, ni plein ni vide. `.id` : le style d'un bouton
                    // Apple ne suit pas un changement d'apparence tout seul.
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .id(colorScheme)
                    .frame(height: 50)
                    .clipShape(Capsule())

                    Button {
                        Task {
                            isWorking = true
                            let ok = await app.social.signInWithGoogle()
                            isWorking = false
                            if ok { Haptics.success(); message = nil } else { message = app.social.lastError }
                        }
                    } label: {
                        Label { Text(ui: "Continuer avec Google") } icon: { Image(systemName: "g.circle.fill") }
                    }
                    .buttonStyle(.carnetSecondaryWide)
                    .disabled(isWorking)

                    if !usesEmail {
                        Button {
                            withAnimation(Motion.snappy) { usesEmail = true }
                            focused = .email
                        } label: {
                            Text("Continuer avec un e-mail")
                        }
                        .buttonStyle(.carnetSecondaryWide)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(Mode.allCases) { value in
                                Button {
                                    withAnimation(Motion.snappy) { mode = value }
                                } label: {
                                    CarnetChip(text: value.title, isSelected: mode == value)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }

                        VStack(spacing: 0) {
                            TextField("Adresse e-mail", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focused, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focused = .password }
                                .padding(14)
                            Rectangle().fill(Carnet.rule).frame(height: 1)
                            SecureField("Mot de passe", text: $password)
                                .textContentType(mode == .signUp ? .newPassword : .password)
                                .focused($focused, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { Task { await submit() } }
                                .padding(14)
                        }
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))

                        Button {
                            Task { await submit() }
                        } label: {
                            if isWorking {
                                ProgressView().tint(Carnet.ground)
                            } else {
                                Text(mode.title)
                            }
                        }
                        .buttonStyle(.carnetPrimaryWide)
                        .disabled(!isValid || isWorking)
                        if mode == .signUp, !password.isEmpty, password.count < 6 {
                            Text("6 caractères au moins.")
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Carnet.wrong)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                CarnetEmpty(icon: "icloud.slash",
                            title: String(localized: "Groupes indisponibles"),
                            message: String(localized: "Pas de serveur de groupes dans cette version."))
            }
        }
        .navigationTitle("Groupes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isValid: Bool {
        email.contains("@") && password.count >= 6
    }

    private func benefit(_ icon: String, _ title: String) -> some View {
        CarnetRow(icon: icon, tint: Carnet.ink, title: title)
    }

    private func submit() async {
        guard isValid else { return }
        isWorking = true
        defer { isWorking = false }
        let ok = mode == .signUp
            ? await app.social.signUp(email: email, password: password)
            : await app.social.signIn(email: email, password: password)
        if ok {
            Haptics.success()
            message = nil
        } else {
            message = explain(app.social.lastError)
        }
    }

    /// Les erreurs d'authentification, en phrases qu'on peut suivre.
    private func explain(_ raw: String?) -> String {
        let text = (raw ?? "").lowercased()
        if text.contains("already") || text.contains("registered") {
            return String(localized: "Un compte existe déjà avec cette adresse : choisis « J'ai un compte ».")
        }
        if text.contains("invalid") && text.contains("credential") {
            return String(localized: "Adresse ou mot de passe incorrect.")
        }
        if text.contains("confirm") {
            return String(localized: "Confirme ton adresse avec le lien reçu par e-mail, puis connecte-toi.")
        }
        if text.contains("network") || text.contains("offline") || text.contains("internet") {
            return String(localized: "Pas de connexion : réessaie une fois en ligne.")
        }
        return raw.map { String(localized: "Connexion impossible : \($0)") } ?? String(localized: "Connexion impossible.")
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                message = String(localized: "Jeton Apple illisible.")
                return
            }
            if let given = credential.fullName?.givenName, app.settings.displayName.isEmpty {
                app.settings.displayName = given
            }
            Task {
                isWorking = true
                let ok = await app.social.signInWithApple(idToken: idToken, nonce: nonce)
                isWorking = false
                if ok { Haptics.success() } else { message = explain(app.social.lastError) }
            }
        case .failure(let error):
            message = ProfileView.appleMessage(for: error)
        }
    }
}
