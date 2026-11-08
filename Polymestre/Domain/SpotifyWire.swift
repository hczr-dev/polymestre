import CryptoKit
import Foundation

/// Spotify comme le lecteur web de Spotify se parle à lui-même (d'après SpotAPI, Aran404/SpotAPI) :
/// la session du site (`sp_dc`, posée par la vraie page de connexion), un jeton du lecteur web
/// (`/api/token`, protégé par un TOTP), un jeton client, puis Spotify Connect (`connect-state`)
/// pour lire ce qui joue et piloter n'importe quel appareil du compte — gratuit ou Premium.
///
/// Ce fichier est **pur** (aucun réseau) : les adresses, les corps de requête, le TOTP et la
/// lecture de l'état. Il se teste dans `validate.sh`. Le réseau vit dans `SpotifyAccount` (Mac,
/// iPhone) et `windows/src/services/spotifyAccount.ts` (Windows), qui suivent ce même protocole.
///
/// **Non officiel** : Spotify peut changer ces appels sans préavis (l'app le dit, et le pilotage
/// local reste là). Rien ne passe par un autre serveur que Spotify, sauf la clé publique du TOTP
/// (le dépôt communautaire que lit SpotAPI), avec une clé de secours embarquée.
enum SpotifyWire {
    static let site = URL(string: "https://open.spotify.com/")!
    static let login = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!
    static let secretsURL = URL(string: "https://code.thetadev.de/ThetaDev/spotify-secrets/raw/branch/main/secrets/secretDict.json")!
    static let clientTokenURL = URL(string: "https://clienttoken.spotify.com/v1/clienttoken")!
    static let spclient = "https://gue1-spclient.spotify.com"
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    /// Une version du lecteur web plausible si la page n'en donne pas.
    static let fallbackClientVersion = "1.2.70.61.g856ccd63"

    /// La clé de secours du TOTP (celle de SpotAPI), si le dépôt des clés ne répond pas.
    static let fallbackSecret: (version: Int, bytes: [UInt8]) = (61, [44, 55, 47, 42, 70, 40, 34, 114, 76, 74, 50, 111, 120, 97, 75, 76, 94, 102, 43, 69, 49, 120, 118, 80, 64, 78])

    /// Connecté·e : le cookie de session de Spotify existe.
    static func isSignedIn(cookieNames: [String]) -> Bool { cookieNames.contains("sp_dc") }

    // MARK: TOTP

    /// La dernière clé du dictionnaire `{"61": [44, 55, …], …}`.
    static func latestSecret(from json: Data) -> (version: Int, bytes: [UInt8])? {
        guard let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let best = dict.compactMap { key, value -> (Int, [UInt8])? in
            guard let version = Int(key), let list = value as? [Int], !list.isEmpty else { return nil }
            return (version, list.map { UInt8(truncatingIfNeeded: $0) })
        }.max { $0.0 < $1.0 }
        return best.map { (version: $0.0, bytes: $0.1) }
    }

    /// La clé HMAC : chaque octet transformé (`e ^ (t % 33 + 9)`), écrit en décimal, mis bout à bout.
    static func totpKey(_ secret: [UInt8]) -> Data {
        let joined = secret.enumerated().map { String(Int($0.element) ^ (($0.offset % 33) + 9)) }.joined()
        return Data(joined.utf8)
    }

    /// TOTP standard (RFC 6238 : HMAC-SHA1, 30 s, 6 chiffres).
    static func totp(secret: [UInt8], at date: Date) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: totpKey(secret))))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let code = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        return String(format: "%06d", code % 1_000_000)
    }

    static func tokenURL(totp: String, version: Int) -> URL {
        var components = URLComponents(string: "https://open.spotify.com/api/token")!
        components.queryItems = [
            .init(name: "reason", value: "init"), .init(name: "productType", value: "web-player"),
            .init(name: "totp", value: totp), .init(name: "totpServer", value: totp), .init(name: "totpVer", value: String(version)),
        ]
        return components.url!
    }

    struct WebToken: Equatable { var accessToken: String; var clientID: String; var expires: Date; var anonymous: Bool }

    static func webToken(from data: Data) -> WebToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty else { return nil }
        let ms = (json["accessTokenExpirationTimestampMs"] as? NSNumber)?.doubleValue ?? 0
        return WebToken(accessToken: token, clientID: json["clientId"] as? String ?? "",
                        expires: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : Date().addingTimeInterval(3000),
                        anonymous: json["isAnonymous"] as? Bool ?? false)
    }

    /// La version du lecteur, dans la configuration que la page embarque (`appServerConfig`, en base64).
    static func clientVersion(inPage html: String) -> String? {
        guard let start = html.range(of: "<script id=\"appServerConfig\" type=\"text/plain\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let data = Data(base64Encoded: String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["clientVersion"] as? String
    }

    static func clientTokenBody(clientVersion: String, clientID: String, deviceID: String) -> [String: Any] {
        ["client_data": ["client_version": clientVersion, "client_id": clientID,
                         "js_sdk_data": ["device_brand": "unknown", "device_model": "unknown", "os": "macos", "os_version": "10.15",
                                         "device_id": deviceID, "device_type": "computer"]]]
    }

    static func clientToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["response_type"] as? String == "RESPONSE_GRANTED_TOKEN_RESPONSE",
              let granted = json["granted_token"] as? [String: Any] else { return nil }
        return granted["token"] as? String
    }

    // MARK: Connect

    static func dealerURL(token: String) -> URL {
        var components = URLComponents(string: "wss://dealer.spotify.com/")!
        components.queryItems = [.init(name: "access_token", value: token)]
        return components.url!
    }

    /// Le premier message du « dealer » porte l'identifiant de connexion.
    static func connectionID(fromDealer data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = json["headers"] as? [String: Any] else { return nil }
        return headers["Spotify-Connection-Id"] as? String
    }

    /// Observateur caché : reçoit l'état complet sans apparaître comme appareil.
    static func observerURL(deviceID: String) -> URL { URL(string: "\(spclient)/connect-state/v1/devices/hobs_\(deviceID)")! }
    static let observerBody: [String: Any] = [
        "member_type": "CONNECT_STATE",
        "device": ["device_info": ["capabilities": ["can_be_player": false, "hidden": true, "needs_full_player_state": true]]],
    ]

    static func commandURL(from: String, to: String) -> URL { URL(string: "\(spclient)/connect-state/v1/player/command/from/\(from)/to/\(to)")! }
    static func transferURL(from: String, to: String) -> URL { URL(string: "\(spclient)/connect-state/v1/connect/transfer/from/\(from)/to/\(to)")! }
    static func volumeURL(from: String, to: String) -> URL { URL(string: "\(spclient)/connect-state/v1/connect/volume/from/\(from)/to/\(to)")! }

    static func randomHex(_ count: Int) -> String {
        String((0..<count).map { _ in "0123456789abcdef".randomElement()! })
    }

    enum Command: Equatable {
        case pause, resume, next, previous
        case seek(milliseconds: Int)
        case shuffle(Bool)
        case repeatMode(context: Bool, track: Bool)
        case play(context: String)
    }

    static func commandBody(_ command: Command) -> [String: Any] {
        let logging: [String: Any] = ["page_instance_ids": [], "interaction_ids": [], "command_id": randomHex(32)]
        var body: [String: Any] = ["logging_params": logging]
        switch command {
        case .pause: body["endpoint"] = "pause"
        case .resume: body["endpoint"] = "resume"
        case .next: body["endpoint"] = "skip_next"
        case .previous: body["endpoint"] = "skip_prev"
        case .seek(let ms): body["endpoint"] = "seek_to"; body["value"] = ms
        case .shuffle(let on): body["endpoint"] = "set_shuffling_context"; body["value"] = on
        case .repeatMode(let context, let track):
            body["endpoint"] = "set_options"; body["repeating_context"] = context; body["repeating_track"] = track
        case .play(let uri):
            body["endpoint"] = "play"
            body["context"] = ["uri": uri, "url": "context://\(uri)", "metadata": [String: Any]()]
            body["play_origin"] = ["feature_identifier": uri.split(separator: ":").dropFirst().first.map(String.init) ?? "playlist", "referrer_identifier": "home"]
            body["options"] = ["license": "tft", "player_options_override": [String: Any]()]
        }
        return ["command": body]
    }

    static func transferBody(resume: Bool) -> [String: Any] {
        ["transfer_options": ["restore_paused": resume ? "resume" : "pause"], "command_id": randomHex(32)]
    }

    /// Le volume de Connect va de 0 à 65 535.
    static func volumeBody(_ fraction: Double) -> [String: Any] { ["volume": Int((min(max(fraction, 0), 1) * 65535).rounded())] }

    // MARK: État

    struct Device: Equatable, Identifiable {
        var id: String; var name: String; var type: String; var volume: Double?; var canPlay: Bool
        var icon: String {
            switch type.lowercased() {
            case "smartphone": return "iphone"
            case "tablet": return "ipad"
            case "speaker", "cast_audio", "audio_dongle": return "hifispeaker"
            case "tv", "cast_video", "stb": return "tv"
            case "game_console": return "gamecontroller"
            case "automobile": return "car"
            default: return "laptopcomputer"
            }
        }
    }

    struct Track: Equatable {
        var uri: String; var title: String; var artist: String; var album: String; var artwork: URL?
        var id: String? { uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : nil }
    }

    struct Now: Equatable {
        var track: Track?
        var isPlaying = false
        /// La position mesurée, et quand (pour la faire avancer sans redemander).
        var position: TimeInterval = 0
        var measuredAt = Date()
        var duration: TimeInterval = 0
        var shuffle = false
        var repeatContext = false
        var repeatTrack = false
        var contextURI: String?
        var originDevice: String?
        var activeDevice: String?
        var devices: [Device] = []
        var upNext: [Track] = []

        func elapsed(at date: Date) -> TimeInterval {
            guard isPlaying else { return min(position, duration) }
            return min(position + date.timeIntervalSince(measuredAt), max(duration, 0))
        }

        var volume: Double? { devices.first { $0.id == activeDevice }?.volume }
    }

    /// `spotify:image:ab67…` → l'adresse de l'image.
    static func imageURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("spotify:image:") { return URL(string: "https://i.scdn.co/image/" + raw.dropFirst("spotify:image:".count)) }
        return URL(string: raw)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func track(_ raw: [String: Any]?) -> Track? {
        guard let raw, let uri = raw["uri"] as? String, !uri.isEmpty else { return nil }
        let meta = raw["metadata"] as? [String: Any] ?? [:]
        let artwork = meta["image_large_url"] as? String ?? meta["image_url"] as? String ?? meta["image_xlarge_url"] as? String
        return Track(uri: uri, title: meta["title"] as? String ?? "",
                     artist: meta["artist_name"] as? String ?? meta["album_artist_name"] as? String ?? "",
                     album: meta["album_title"] as? String ?? "", artwork: imageURL(artwork))
    }

    /// L'état Connect (`{active_device_id, player_state, devices}`, ou `{cluster: …}` du dealer).
    static func now(fromCluster object: [String: Any], at date: Date = Date()) -> Now {
        let cluster = object["cluster"] as? [String: Any] ?? object
        var now = Now(measuredAt: date)
        now.activeDevice = cluster["active_device_id"] as? String
        if let devices = cluster["devices"] as? [String: Any] {
            now.devices = devices.compactMap { id, value in
                guard let d = value as? [String: Any] else { return nil }
                let caps = d["capabilities"] as? [String: Any] ?? [:]
                if caps["hidden"] as? Bool == true { return nil }
                let volume = number(d["volume"]).map { $0 / 65535 }
                return Device(id: d["device_id"] as? String ?? id, name: d["name"] as? String ?? String(localized: "Appareil"),
                              type: d["device_type"] as? String ?? "computer", volume: volume,
                              canPlay: d["can_play"] as? Bool ?? true)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        guard let state = cluster["player_state"] as? [String: Any] else { return now }
        now.track = track(state["track"] as? [String: Any])
        let playing = state["is_playing"] as? Bool ?? false
        let paused = state["is_paused"] as? Bool ?? false
        now.isPlaying = playing && !paused && now.activeDevice != nil
        now.duration = (number(state["duration"]) ?? 0) / 1000
        var position = (number(state["position_as_of_timestamp"]) ?? 0) / 1000
        // La position date de `timestamp` (ms) : on la ramène à maintenant si ça joue.
        if now.isPlaying, let stamp = number(state["timestamp"]), let server = number(cluster["server_timestamp_ms"]) {
            position += max(0, (server - stamp) / 1000)
        }
        now.position = max(0, position)
        let options = state["options"] as? [String: Any] ?? [:]
        now.shuffle = options["shuffling_context"] as? Bool ?? false
        now.repeatContext = options["repeating_context"] as? Bool ?? false
        now.repeatTrack = options["repeating_track"] as? Bool ?? false
        now.contextURI = state["context_uri"] as? String
        now.originDevice = (state["play_origin"] as? [String: Any])?["device_identifier"] as? String
        now.upNext = ((state["next_tracks"] as? [[String: Any]]) ?? []).compactMap { track($0) }
            .filter { !$0.uri.hasPrefix("spotify:delimiter") && !$0.uri.isEmpty }
            .prefix(20).map { $0 }
        return now
    }

    /// Le message du dealer est-il une mise à jour de l'état ? Rend ses charges utiles (JSON).
    static func clusterPayloads(fromDealer data: Data) -> [Data] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["uri"] as? String)?.hasPrefix("hm://connect-state/v1/cluster") == true,
              let payloads = json["payloads"] as? [Any] else { return [] }
        let gzip = ((json["headers"] as? [String: Any])?["Transfer-Encoding"] as? String)?.lowercased() == "gzip"
        return payloads.compactMap { payload in
            if let object = payload as? [String: Any] { return try? JSONSerialization.data(withJSONObject: object) }
            guard let text = payload as? String, let raw = Data(base64Encoded: text) else { return nil }
            return gzip ? gunzip(raw) : raw
        }
    }

    /// Décompresse un flux gzip (en-tête de 10 octets, champs optionnels, puis DEFLATE brut).
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0, index + 2 <= bytes.count { index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        let deflate = Data(bytes[index..<(bytes.count - 8)])
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: Web API (lecture seule, avec le jeton du lecteur web)

    struct Playlist: Equatable, Identifiable { var id: String { uri }; var uri: String; var name: String; var image: URL?; var owner: String }

    static let playlistsURL = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!

    static func playlists(from data: Data) -> [Playlist] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let uri = item["uri"] as? String, let name = item["name"] as? String else { return nil }
            let image = ((item["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap(URL.init(string:))
            let owner = (item["owner"] as? [String: Any])?["display_name"] as? String ?? ""
            return Playlist(uri: uri, name: name, image: image, owner: owner)
        }
    }

    static func trackURL(id: String) -> URL { URL(string: "https://api.spotify.com/v1/tracks/\(id)")! }

    /// L'artiste et la pochette d'un morceau, quand Connect ne les donne pas.
    static func trackDetails(from data: Data) -> (artist: String, album: String, artwork: URL?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let artist = ((json["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let album = json["album"] as? [String: Any]
        let artwork = ((album?["images"] as? [[String: Any]])?.first?["url"] as? String).flatMap(URL.init(string:))
        return (artist, album?["name"] as? String ?? "", artwork)
    }
}
