# Compiler et configurer

Le détail que le README ne porte pas : compiler, relire l'interface, brancher les services, distribuer.

## Compiler

```bash
./build.sh                      # Debug (simulateur)
CONFIGURATION=Release ./build.sh
```

Ou directement :

```bash
xcodebuild -project Polymestre.xcodeproj -scheme Polymestre \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" build
```

> **Pourquoi `-disable-sandbox` ?** Le compilateur Swift exécute les macros
> (`@Model`, `@Observable`, `@State`…) dans un `swift-plugin-server` qu'il encapsule
> dans son propre `sandbox-exec`. Dans un environnement déjà sandboxé, ce sandbox
> imbriqué est refusé (`sandbox_apply: Operation not permitted`) et la compilation
> échoue avec `swift-plugin-server produced malformed response`. Le drapeau désactive
> ce sandbox interne. **Dans Xcode normal, aucun drapeau n'est nécessaire** — ouvrez
> simplement `Polymestre.xcodeproj`.

### Si Xcode signale un fichier introuvable ou « Multiple commands produce »

Exemple : `Build input file cannot be found: …/Polymestre/Domain/ColorContrast.swift`,
ou `Multiple commands produce …/<Fichier>.stringsdata`, pour un fichier qui a été
**déplacé**. Le projet est alors sain : c'est la **description de build mise en
cache** dans `~/Library/Developer/Xcode/DerivedData/Polymestre-*` qui référence
encore l'ancien chemin (et, s'il existe deux fichiers de même nom dans une même
cible, fait produire deux fois le même `.stringsdata`).

`Product ▸ Clean Build Folder` ne supprime **pas** cette description. Il faut
quitter Xcode (⌘Q) — sinon il la réécrit — puis :

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Polymestre-*
```

Les dossiers `PBXFileSystemSynchronizedRootGroup` (`Polymestre/`, `PolymestreWidgets/`,
`Shared/`) sont résolus à l'ouverture du projet : rouvrez et recompilez.

### Vérifier la logique métier

La validation exécutable compile `Models/` + `Domain/` + les services d'import en un
binaire macOS et teste :

- le schéma SwiftData (13 entités) et les relations inverses ;
- les moteurs de progression et de charge EPFL, le parcours exercice par exercice (`ExerciseFlow`) et les segments du chrono ;
- le **parseur iCalendar** (occurrences hebdomadaires, fuseaux, `BYDAY`) ;
- l'**import d'horaire** (cours reconnu vs créé, section, détection « a un cours ») ;
- l'**import CSV** (vidéos, exercices, bonus, évaluations) ;
- le **bornage de la semaine** et le planificateur du jour ;
- la **persistance du chrono** (`FocusTimerState` : pause, reprise, restauration) ;
- les **agrégats de sessions** (totaux par jour, historique) ;
- la **sauvegarde** : export → import dans un conteneur vierge, progression
  identique, réimport sans doublon ; format d'heures du widget.

```bash
./validate.sh     # se termine par « ✅ TOUS LES CONTRÔLES SONT PASSÉS »
```

`validate.sh` commence par `scripts/check-strings.py`, le garde-fou de traduction :
un littéral français rendu dans une `String` (`return "Progression"`, `nom ?? "au total"`,
`cond ? "Jour" : heure`) ne passe jamais par le catalogue et reste en français quand
l'app est en anglais. Le script refuse ces trois formes dans les dossiers d'interface,
et tout `String(localized:)` sans anglais au catalogue ; `// l10n: tel quel` sur la
ligne laisse passer un texte voulu tel quel (consigne envoyée à Claude, nom propre).

`./validate.sh --bench` ajoute des **repères de performance** : il construit un
semestre simulé (6 cours, 240 vidéos, 576 exercices, 480 sessions) et chronomètre
les dérivations que les écrans refont à chaque rendu. La mesure porte sur la logique
pure (`Domain/`), pas sur le rendu SwiftUI.

### Relire l'interface dans le simulateur

Un simulateur iOS est installé : l'app se lance et se capture réellement.

```bash
xcodebuild -project Polymestre.xcodeproj -scheme Polymestre -sdk iphonesimulator \
  -configuration Debug -derivedDataPath /tmp/simbuild \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox" build

xcrun simctl install booted /tmp/simbuild/Build/Products/Debug-iphonesimulator/Polymestre.app
xcrun simctl launch booted ch.polymestre.app -seedSampleData -tab 0
xcrun simctl io booted screenshot /tmp/today-ipad.png
```

`xcrun simctl` ne sait pas taper dans l'interface, et ouvrir un lien profond
déclenche un « Ouvrir dans Polymestre ? » qu'on ne peut pas confirmer. Ces
arguments, **compilés en Debug seulement** (`PreviewLaunch`), rendent donc chaque
écran atteignable :

| Argument | Effet |
|---|---|
| `-seedSampleData` | installe le semestre d'exemple, saute l'accueil, et supprime le prompt de notifications qui recouvrirait la capture |
| `-tab <0,1,3,4>` | ouvre directement un onglet (0 Aujourd'hui, 1 Cours, 3 Groupes, 4 Agenda). **`-tab 2` ouvre la feuille Focus** : 2 était l'onglet du chrono, et les valeurs brutes n'ont pas bougé pour que liens et captures restent valables |
| `-course <code>` | présélectionne un cours dans le volet de droite (`-course CS-250`) |
| `-courseTab <theory\|exercises\|progress\|exams>` | avec `-course`, ouvre cet onglet de la fiche (ou la page Progression / Examens) |
| `-contentImport <moodle\|courseware\|botafogo\|auto>` | ouvre « Importer du contenu » sur cette source (avec `-course`, pour ce cours) ; `auto` lance l'import Moodle automatique |
| `-assistant` | avec `-profile`, ouvre Profil › Intelligence artificielle › Assistant IA |
| `-botafogoCourse <index>` | avec `-contentImport botafogo`, lit ce polycopié du catalogue et ouvre la relecture |
| `-onboardingStep <0…3>` | ouvre une étape de l'accueil — à lancer sur une installation **fraîche**, le seeding marquant l'accueil comme terminé |
| `-profile` | ouvre « Profil & réglages » : les onze écrans de configuration sont autrement inatteignables sans taper |
| `-school` | avec `-profile`, ouvre « Section et semestre » (section, cours, dates) |
| `-stats` | ouvre « Statistiques » (feuille depuis « Aujourd'hui ») |
| `-group <index>` | ouvre la fiche du groupe à cet index (`-tab 3` requis) |
| `-groupSubject <code>` | avec `-group`, ouvre l'avancement d'une matière (`-groupSubject CS-250`) |
| `-groupInvite` | avec `-group`, ouvre la feuille d'invitation (QR code et lien) |
| `-groupSubjects` | avec `-group`, ouvre l'éditeur des matières du groupe |
| `-groupPage <members\|time\|series\|planning>` | avec `-group`, ouvre une sous-page de la fiche |
| `-importFile <chemin absolu>` | ouvre l'import de série sur ce PDF, comme un partage depuis une autre app (le simulateur non signé n'a pas de conteneur de groupe) |
| `-exerciseDetail <numéro>` | avec `-course` et `-courseTab exercises`, ouvre le détail de cet exercice (`-exerciseDetail 3.1`) |
| `-timerSeconds <n>` | pré-remplit le chrono et le lance : un chrono en marche est autrement inatteignable sans taper |
| `-pomodoro` | active le mode Pomodoro sur le chrono — avec `-timerSeconds`, montre un bloc en cours |
| `-shortcuts` | ouvre l'éditeur des raccourcis du chrono |
| `-search <requête>` | ouvre la recherche, pré-remplie |
| `-examActivity` | lance l'activité **« jour d'examen »** sur l'écran verrouillé. Elle se déclenche par le *temps* (douze heures avant l'épreuve) : sans ce drapeau, la vérifier demanderait d'attendre la veille d'un vrai examen |
| `-aiImport` | avec `-profile`, ouvre « Import intelligent » |
| `-coverage`, `-epflLife` | avec `-stats`, ouvrent « Couverture du suivi » et « Vie de l'EPFL » |
| `-breakTermLink` | **casse** le lien cours ↔ semestre (et remet les séries à la semaine 1) pour vérifier la réparation au lancement suivant |
| `-breakGroupRole` | **rétrograde** le créateur du groupe à « membre », pour vérifier qu'il garde ses droits |

Pour repartir d'un état vierge : `xcrun simctl erase <udid>` (le prompt système
d'une capture précédente survit à une simple désinstallation).

Ces arguments ouvrent un écran, pas une **feuille dans une feuille** : ce qui est
sous la ligne de flottaison d'un formulaire, ou derrière un second tap, reste hors
de portée d'une capture automatique. C'est une limite connue de cette méthode.

## Configuration

Tout est optionnel : **l'app fonctionne entièrement hors ligne**.

- **Section, cours et dates du semestre** : Profil › **Section et semestre** —
  tout ce que l'accueil guidé a demandé reste modifiable après coup, **y compris la
  date de début du semestre**, qui commande le numéro de semaine affiché partout.
- **Horaire** : Profil › Calendrier et horaire › *Importer un horaire / JSON / CSV*.
  L'URL du flux est mémorisée pour un réimport en un tap.
- **Tâches** : Profil › Tâches › **Fournisseurs de tâches** — un écran dédié, un
  bloc par fournisseur, avec l'état, l'aide et un bouton **Tester** qui interroge
  réellement le service.
- **Groupes (Supabase)** : la configuration est **compilée dans l'app**, pas saisie
  par l'utilisateur. Voir « Relier les groupes » ci-dessous ; le schéma SQL est dans
  `Support/supabase-schema.sql`.
- **Charge EPFL** : Profil › Charge de travail (heures par crédit ECTS).

> **Le mode opératoire complet est dans [`Support/SUPABASE.md`](../Support/SUPABASE.md)** :
> création du projet, clés, SQL, vérification, connexion, déploiement de la fonction
> IA, et un tableau des erreurs courantes avec leur cause réelle.

### Relier les groupes (configuration de build)

L'URL du projet Supabase et la clé `anon` ne sont **jamais demandées à
l'utilisateur** : ce sont des constantes de build. Les saisir dans les réglages
obligeait chaque étudiant·e à les trouver avant de pouvoir se connecter — alors que
la clé `anon` est publique par conception, puisqu'elle n'autorise que ce que les
politiques RLS de la base permettent.

1. Édite **`Support/Supabase.xcconfig`** — c'est un simple fichier texte, visible
   dans le navigateur Xcode sous le groupe racine. Deux lignes à remplir :
   `SUPABASE_HOST` (le domaine du projet, **sans** `https://`) et `SUPABASE_ANON_KEY`.
2. Exécute **`Support/supabase-schema.sql`** dans Supabase ▸ SQL Editor. Ce fichier
   contient tout : les tables, la fonction de classement
   `group_leaderboard`, le déclencheur
   qui crée le profil à l'inscription, les politiques RLS, et le
   rechargement du cache PostgREST. Il est idempotent.
3. Rien d'autre : ce fichier est la configuration de base du projet, `Support/Info.plist`
   l'injecte (`SupabaseHost`, `SupabaseAnonKey`) et `SupabaseConfig` compose l'URL au
   lancement.

> **Pourquoi le domaine sans `https://` ?** Un fichier `.xcconfig` considère `//`
> comme le début d'un commentaire : `https://xyz.supabase.co` y serait tronqué à
> `https:`. Le schéma est donc ajouté par le code.

**Une build sans ces valeurs reste pleinement utilisable.** Le suivi des cours, le
temps de travail, l'agenda et les widgets fonctionnent ; seuls les groupes sont
indisponibles. L'écran Compte l'annonce alors explicitement — *« Groupes non
configurés dans cette version »* — au lieu d'afficher deux champs que personne ne
peut remplir. `validate.sh` vérifie qu'une valeur absente, vide, ou restée littérale
(`$(SUPABASE_URL)`) n'est jamais prise pour une configuration.

### Analyse des PDF par IA : déployer la fonction Supabase (une fois)

> **À vérifier avant tout** : Profil › Import intelligent affiche l'état **réel** de
> la fonction. S'il dit « Pas encore déployée », l'import se rabat sur la lecture
> par motifs — ce n'est pas une panne, c'est une fonction jamais installée.

Pour que l'analyse fonctionne **sans jeton** chez les étudiant·e·s dont l'appareil n'a
pas Apple Intelligence, la clé du fournisseur vit dans une Edge Function du projet
Supabase — jamais dans l'app :

```bash
supabase link --project-ref <ref>
supabase functions deploy extract-series --project-ref <ref>
supabase secrets set LLM_API_KEY=gsk_…                                 # Groq : palier gratuit
supabase secrets set LLM_BASE_URL=https://api.groq.com/openai/v1       # facultatif (défaut)
supabase secrets set LLM_MODEL=llama-3.1-8b-instant                    # facultatif (défaut)
```

Le code est dans `supabase/functions/extract-series/index.ts` ; n'importe quelle
API compatible OpenAI convient (OpenRouter avec un modèle `:free`, Mistral…). Sans
déploiement, l'app le détecte (HTTP 404) et passe au maillon suivant.

#### La voie « vision » : le modèle regarde les pages

Le texte extrait d'un PDF perd la mise en page, et c'est précisément elle qui dit
ce qui est une sous-question. Les pages sont donc **aussi** envoyées en images
(`Services/PDFPageRenderer.swift`, JPEG 1240 px), avec le texte en appui. Cela
demande un fournisseur qui accepte les images, distinct de celui du texte :

```bash
supabase secrets set LLM_VISION_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
supabase secrets set LLM_VISION_API_KEY=…            # Google AI Studio
supabase secrets set LLM_VISION_MODEL=gemini-flash-latest
```

Trois modes de requête : `{"text": …}` (texte, sur Groq), `{"images": […],
"text": …, "seriesHint": 3}` (vision), et `{"listModels": true}`, qui renvoie les
modèles utilisables par chaque clé — un diagnostic, sans secrets.

**La course.** Les modèles Flash de Google sont souvent « en forte demande »
(503). La fonction fait donc courir jusqu'à **5 candidats** par lot de 5 pages :
le modèle configuré, puis le dernier Gemini Flash, Flash-Lite, Pro, et Groq en
dernier recours. Les modèles « Lite » ne partent qu'après 5 s — ils sont plus
rapides mais moins bons, et les laisser partir en même temps revenait à choisir
le moins bon presque à chaque fois. Le dernier modèle qui a répondu est retenu
pour la fois suivante, et un modèle qui renvoie 503/429 est mis au repos deux
minutes. La réponse porte `timings` et `fallbacks` : on sait **qui** a répondu.

Compter en temps réel : 7–13 s sur la Série 3 (3 pages), 22–30 s quand Google est
congestionné. Le palier gratuit de Groq (7 000 jetons/minute en entrée) impose
2 pages par appel et aucun texte en appui quand la vision passe par lui.

**Type-checker la fonction sans Deno** — copier `index.ts` à côté d'un fichier
`deno.d.ts` contenant
`declare const Deno: { env: { get(k: string): string | undefined }; serve(h: (r: Request) => Promise<Response> | Response): void };`
puis :

```bash
npx -p typescript@5 tsc --noEmit --strict --target es2022 \
  --lib es2022,es2021.promise,dom index.ts deno.d.ts
```

### Assistant IA : le serveur MCP (`supabase/functions/mcp`)

Un assistant — Claude (app, web, Desktop, Code), ChatGPT, tout client MCP —
lit l'état d'étude et **demande** des modifications. Profil › Intelligence
artificielle › Assistant IA › « Relier un assistant » tire un jeton de 256 bits
et affiche l'adresse `https://<projet>.supabase.co/functions/v1/mcp/<jeton>`, à
coller comme connecteur personnalisé.

- **Transport** : MCP Streamable HTTP, réponses JSON (protocoles 2025-06-18,
  2025-03-26, 2024-11-05). Vérifié avec l'inspecteur MCP officiel.
- **Outils** : lecture — `get_overview`, `list_courses`, `get_course`,
  `what_to_do`, `search`, `upcoming_dates`, `study_time`,
  `list_pending_changes`, `list_files`, `read_file` ; écriture —
  `update_exercise`, `check_questions`, `update_theory`, `log_study_session`,
  `add_series`, `add_exam`. Rien ne supprime.
- **Fichiers et notes** (Profil › Assistant IA › « Fichiers et notes », éteint
  par défaut) : `list_files` donne énoncés et corrigés PDF, notes de cours, fiche
  de révision, corrigés rédigés, notes d'anciens examens et fichiers ajoutés ;
  `read_file(id)` rend le texte, ou le PDF en pièce jointe (Claude Code
  l'enregistre et l'ouvre avec `Read`). Les textes voyagent dans l'instantané ;
  les PDF **déjà sur l'iPhone** (cache des séries, bibliothèque hors ligne,
  fichiers ajoutés) sont envoyés un à un, par SHA-256, dans un stockage privé
  (`assistant-files`) — le serveur répond à chaque synchronisation par ceux qui
  lui manquent, efface ceux qu'on n'annonce plus (et tout si le réglage est
  coupé ou l'assistant déconnecté). Rien n'est téléchargé pour l'occasion :
  activer « Garder les énoncés » (Hors ligne) pour avoir toutes les séries. 10 Mo
  au plus par fichier (une réponse MCP plafonne à 16 Mo, base64 compris). Les
  notes du dossier du Mac (`NotesStore`) n'y sont pas : le jeton est propre à
  l'iPhone, seul à synchroniser.
- **Serveur local des fichiers (Mac)** (Réglages › Mode étude › « Fichiers pour
  Claude », éteint par défaut) : un second serveur MCP, `polymestre-files`, dans
  l'app du Mac (`Domain/LocalMCP.swift`, `MacLocalMCP`), sur `127.0.0.1` seulement.
  Il lève les limites du serveur en ligne : il lit les données du Mac, a la
  session Moodle et le dossier de notes, et rend des **chemins** (pas des octets),
  donc sans plafond de taille. `list_files` (cours, type, série, mots),
  `read_file(id)` — met le fichier sur le disque, téléchargé au besoin, dans
  `<projet Claude>/cours/<CODE>/`, que l'agent ouvre avec `Read` —, et
  `fetch_all_files` (tout préparer, par lots de 25 s). Couvre : énoncés et
  corrigés PDF, anciens examens, transparents et documents des cours, ressources
  ajoutées, cahiers du dossier de notes, notes, fiche, corrigés rédigés. Le projet
  Claude de l'app le déclare tout seul quand il tourne. Sécurité : jeton de
  256 bits dans l'adresse, en-tête `Origin` refusé (une page web ne l'atteint
  pas), `Host` vérifié (DNS rebinding), écoute limitée à la boucle locale. Le
  serveur en ligne reste pour le téléphone, claude.ai et l'écriture.
- **Dans l'app Claude (Desktop), sans étape compliquée** : Réglages › Mode étude ›
  « Fichiers pour Claude » › **Ajouter à l'app Claude**. L'app allume le serveur
  local, fabrique `Polymestre.mcpb` (`ClaudeDesktopExtension`, manifeste 0.4,
  validé par `mcpb validate`) et l'ouvre : un clic « Installer » dans l'app
  Claude. L'extension est un pont Node sans dépendance : il relaie au serveur
  local (adresse lue dans `~/Library/Application Support/Polymestre/local-mcp.json`,
  donc rien à réinstaller si le port change), rouvre Polymestre s'il est fermé, et
  demande `read_file` en mode `inline` : les pages d'un PDF reviennent en
  **images** (formules intactes ; 5 pages par défaut, 8 au plus, `pages="9-16"`
  pour la suite), le texte et les `.docx` en texte — l'app Claude ne sait pas ouvrir
  un chemin. Claude Code, lui, reçoit des chemins.
- **Données** : l'app publie un instantané (`AssistantExport`, v3 ; v2 avec
  identifiants) à l'ouverture, au passage en arrière-plan et quelques secondes
  après chaque enregistrement (`AssistantSync`). L'assistant dépose des
  commandes ; l'app les applique à sa synchronisation suivante
  (`AssistantCommandApplier`, testé) et renvoie un compte rendu. L'instantané est
  mis à jour tout de suite côté serveur : l'assistant relit ce qu'il a écrit.
- **Sécurité** : le jeton est dans l'adresse (les connecteurs n'acceptent pas
  d'en-tête) et la base n'en garde que le SHA-256. Tables
  `assistant_links` / `assistant_commands`, RLS sans politique : seule la
  fonction (clé de service) y accède. « Déconnecter » efface tout côté serveur.
- **Déploiement** : `supabase db push` (ou la migration
  `20260930000000_assistant_mcp.sql`) puis
  `supabase functions deploy mcp --no-verify-jwt`. Déployé sur le projet
  `aaigscutkuefhqftfszv` le 30 septembre 2026.

L'ancien serveur local (`mcp/server.js`, lisant un fichier exporté à la main)
est retiré.

### Widgets : App Group à enregistrer

L'app et l'extension widget partagent leurs données via l'App Group
**`group.com.polymestre.app`**. Pour que le widget affiche quelque chose sur un
appareil réel :

1. Dans le portail Apple Developer, créez un App Group `group.ch.polymestre.app`
   et ajoutez-le aux *deux* identifiants (`ch.polymestre.app` et
   `ch.polymestre.app.widgets`).
2. Les entitlements sont déjà fournis (`Support/Polymestre.entitlements` et
   `Support/PolymestreWidgets.entitlements`) et référencés par les deux cibles.

Sans App Group, l'app fonctionne normalement : `WidgetBridge.write` est simplement
un no-op et le widget affiche « Ouvre Polymestre » au lieu de planter.

> L'identifiant est défini une seule fois (`POLYMESTRE_APP_GROUP` dans le projet)
> et injecté dans les deux `Info.plist` et les deux entitlements.

L'app publie l'instantané quand elle passe au premier plan / arrière-plan
(`WidgetSnapshotWriter`, appelé depuis `RootTabView`) et recharge les timelines.

### Sign in with Apple (appareil réel)

L'entitlement `com.apple.developer.applesignin` est **déjà déclaré** dans
`Support/Polymestre.entitlements`. Il reste deux choses à faire, qui ne sont pas dans
le dépôt :

1. **Portail Apple Developer** — active « Sign in with Apple » sur l'identifiant
   `ch.polymestre.app`. Avec la signature automatique, Xcode le fait pour toi au
   premier build signé ; si le build échoue à signer, c'est que l'identifiant est géré
   ailleurs.
2. **Supabase** — Authentication ▸ Providers ▸ Apple : renseigne le *Service ID*, la
   *Team ID*, le *Key ID* et la clé `.p8`.

**Dans le simulateur, il faut en plus être connecté à iCloud** (Réglages ▸ Se connecter
à votre iPhone). Sans compte iCloud, `ASAuthorizationController` échoue avec
`Code=1000 "(null)"` — l'erreur la plus opaque d'Apple, et la plus fréquente.

Sans compte Apple Developer, la connexion e-mail/mot de passe Supabase fonctionne et
le bouton Apple affiche désormais un message explicite au lieu de `(null)`.

### Avec mesure : le temps de Claude Code (Mac)

Un mod Claude Code (`ClaudePlugin/mesure`) et une page de Polymestre (Réglages ›
Claude Code, carte du Bilan, ligne de la barre des menus, carte du Bilan de
l'iPhone). Éteint par défaut.

- **Étude / projets / libre**, d'après le dossier de la séance : les dossiers
  d'étude (`~/EPFL`, le projet Claude réglé dans Polymestre) ne sont jamais
  limités, seulement comptés ; le reste (« projets ») suit les règles.
- **Règles**, dans l'ordre : verrou du mode étude (tout sauf l'étude), mode
  étude, cours de l'horaire, couvre-feu, d'abord étudier (minutes du jour
  dans Polymestre), pause après une longue série, budget du jour.
- **Passes** : `/mesure encore <raison>` — trois mots au moins, un délai de
  réflexion, un nombre par jour ; la raison va au Bilan. Pas de pass pendant un
  cours ni en mode étude.
- **Durcir tout de suite, assouplir le lendemain** (4 h, au moins 12 h plus
  tard), couper Avec mesure compris ; le premier jour observe seulement.
- **Fichiers** (`~/Library/Application Support/Polymestre/Claude/`) :
  `policy.json` (Polymestre → mod), `sessions/<jour>/<séance>.json` et
  `passes/<jour>/…` (mod → Polymestre), `mod.json`. Le calcul existe deux fois,
  `ClaudePlugin/mesure/hooks/policy.ts` et `Polymestre/Domain/ClaudeMeasure.swift`,
  avec les mêmes cas de test (`claude plugin test ClaudePlugin/mesure`, `./validate.sh`).
- **Brancher** : Réglages › Claude Code › « Brancher Claude Code » copie le mod
  (dans l'app : référence de dossier `ClaudePlugin`) vers Application Support,
  puis `claude plugin marketplace add` et `claude plugin install mesure@polymestre`.
  Une séance sans clavier (`claude -p`, le tuteur) n'est ni comptée ni bloquée ;
  un mod cassé laisse passer les demandes (pas de `.catch` sur `prompt.submit`).

### Distribuer : TestFlight (iPhone) et Developer ID (Mac)

`./release.sh ios` archive, exporte pour App Store Connect et envoie la build ;
`./release.sh mac` archive le Mac, le fait notariser et produit `Polymestre.dmg`
et le `latest.json` du site. Avant chaque envoi : monter `CURRENT_PROJECT_VERSION`
(le numéro de build doit être neuf pour App Store Connect, et le Mac compare ce
numéro pour annoncer une mise à jour).

- **Signature et envoi** : le compte du titulaire dans Xcode (signature « dans le
  nuage » : une clé App Store Connect « App Manager » ne peut pas signer).
- **Notarisation du Mac** : la clé App Store Connect — `ASC_KEY_ID`,
  `ASC_ISSUER_ID` dans l'environnement, `AuthKey_<ID>.p8` à la racine (ignoré par git).
- **Temps d'écran** : `POLYMESTRE_SCREEN_TIME` (`Support/Supabase.xcconfig`) vaut
  `YES` partout depuis qu'Apple a accordé « Family Controls (Distribution) » au
  compte (27 octobre 2026 ; sans cet accord, l'export d'une build distribuée
  échoue). `NO` retire le droit (app et extension), le code du bouclier
  (`SCREEN_TIME`) et l'interface du blocage sur l'iPhone ; le Mac bloque toujours.
- **Schéma CloudKit** : une build TestFlight parle à l'environnement **Production**.
  Avant la première, et après tout ajout au modèle : lancer la build Debug signée
  du Mac avec `-initCloudKitSchema` (tout le schéma dans Development), puis console
  CloudKit › Deploy Schema Changes.
- **Retours et site** : `FEEDBACK_EMAIL` et `SITE_HOST` (xcconfig). Le site
  (dépôt `polymestre-site`, servi sur **polymestre.ch**) porte la confidentialité,
  `mac.html` et `mac/latest.json`, lu par le Mac une fois par jour (`MacUpdater`).
  L'ancienne adresse `studytrack.hczr.ch` doit **rester une redirection 301**
  vers `polymestre.ch` (règle Cloudflare, chemin conservé) : les Mac installés
  avant le changement lisent encore `studytrack.hczr.ch/mac/latest.json`.
- **Changement d'identité** (StudyTrack → Polymestre) : la mise en service, dans l'ordre, et ce
  qui garde l'ancien nom sont dans [`docs/rename-polymestre.md`](rename-polymestre.md).
- Une build TestFlight **expire au bout de 90 jours** : en refaire une à
  mi-semestre.
