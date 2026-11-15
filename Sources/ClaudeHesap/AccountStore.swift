import Foundation
import SwiftUI

struct UsageWindow: Identifiable, Hashable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
}

struct Account: Identifiable, Hashable {
    let id: String            // oauthAccount.accountUuid
    var label: String
    var email: String
    var orgName: String
    /// Hesabın kendi config dizini (~/.claude-xxx). Varsayılandayken de saklanır;
    /// varsayılandan çıkarken kimlik bilgisi buraya geri yazılır.
    var home: String?
    var plan: String?
    var isDefault = false
    var hasCredentials = false
    var usage: [UsageWindow] = []
    var usageError: String?
    var loadingUsage = false
}

/// Kullanıcının verdiği ad ve gizleme tercihleri.
struct Registry: Codable {
    struct Entry: Codable { var label: String?; var hidden: Bool? }
    var accounts: [String: Entry] = [:]
    var desktopSync: Bool?
}

@MainActor
final class AccountStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var lastError: String?
    @Published var notice: String?
    @Published var lastRefresh: Date?
    @Published var busy = false
    @Published var desktopAccountId: String?
    @Published var desktopBusy = false

    let home = NSHomeDirectory()
    var defaultDir: String { home + "/.claude" }
    var defaultConfigFile: String { home + "/.claude.json" }
    var appDir: String { home + "/.claude-hesap" }
    var registryFile: String { appDir + "/accounts.json" }

    private var registry = Registry()

    init() {
        try? FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        loadRegistry()
        reload()
    }

    var defaultAccount: Account? { accounts.first(where: \.isDefault) }
    var visibleAccounts: [Account] {
        accounts.filter { $0.isDefault || registry.accounts[$0.id]?.hidden != true }
    }

    // MARK: Keşif

    func reload() {
        let fm = FileManager.default
        desktopAccountId = DesktopSync.currentAccount()
        let defaultOauth = readJSON(defaultConfigFile)?["oauthAccount"] as? [String: Any]
        let defaultUuid = defaultOauth?["accountUuid"] as? String
        let defaultBlob = Keychain.read(Keychain.defaultService)

        var found: [String: Account] = [:]
        let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for name in entries.sorted() where name.hasPrefix(".claude-") {
            let dir = home + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  let oauth = readJSON(dir + "/.claude.json")?["oauthAccount"] as? [String: Any],
                  let uuid = oauth["accountUuid"] as? String else { continue }
            let suffix = String(name.dropFirst(".claude-".count))
            var acc = makeAccount(uuid: uuid, oauth: oauth, fallbackLabel: suffix)
            acc.home = dir
            let blob = Keychain.read(Keychain.service(forConfigDir: dir))
            acc.hasCredentials = blob?["claudeAiOauth"] != nil
            acc.plan = planName(blob)
            found[uuid] = acc
        }

        if let defaultUuid, let defaultOauth {
            var acc = found[defaultUuid]
                ?? makeAccount(uuid: defaultUuid, oauth: defaultOauth,
                               fallbackLabel: defaultLabel(defaultOauth))
            acc.isDefault = true
            acc.hasCredentials = defaultBlob?["claudeAiOauth"] != nil
            acc.plan = planName(defaultBlob) ?? acc.plan
            found[defaultUuid] = acc
        }

        // Var olan kullanım verisini koru, yenileme sırasında boş görünmesin.
        let old = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = found.values.map { a in
            var a = a
            if let o = old[a.id] { a.usage = o.usage; a.usageError = o.usageError }
            return a
        }.sorted { ($0.isDefault ? 0 : 1, $0.label.lowercased()) < ($1.isDefault ? 0 : 1, $1.label.lowercased()) }
    }

    private func makeAccount(uuid: String, oauth: [String: Any], fallbackLabel: String) -> Account {
        let email = oauth["emailAddress"] as? String ?? "?"
        var org = oauth["organizationName"] as? String ?? ""
        if org.hasSuffix("'s Organization") { org = "Kişisel" }
        // Dizin adı kurum adının küçük harfli hâliyse (".claude-hayratyardim") kurumun yazımını kullan.
        let fromOrg = !org.isEmpty && org != "Kişisel" && slug(org) == slug(fallbackLabel) ? org : nil
        let label = registry.accounts[uuid]?.label ?? fromOrg ?? prettyLabel(fallbackLabel)
        return Account(id: uuid, label: label, email: email, orgName: org)
    }

    private func prettyLabel(_ s: String) -> String {
        switch s.lowercased() {
        case "is": return "İş"
        case "kisisel": return "Kişisel"
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    private func defaultLabel(_ oauth: [String: Any]) -> String {
        let org = oauth["organizationName"] as? String ?? ""
        if !org.isEmpty && !org.hasSuffix("'s Organization") { return org }
        return emailLocal(oauth["emailAddress"] as? String)
    }

    private func emailLocal(_ email: String?) -> String {
        String((email ?? "hesap").split(separator: "@").first ?? "hesap")
    }

    private func planName(_ blob: [String: Any]?) -> String? {
        guard let o = blob?["claudeAiOauth"] as? [String: Any] else { return nil }
        let tier = (o["rateLimitTier"] as? String ?? "").lowercased()
        let sub = (o["subscriptionType"] as? String ?? "").lowercased()
        var name = sub.isEmpty ? "?" : sub.prefix(1).uppercased() + sub.dropFirst()
        if tier.contains("20x") { name += " 20x" } else if tier.contains("5x") { name += " 5x" }
        return name
    }

    // MARK: Varsayılanı değiştir (fvm global gibi)

    func makeDefault(_ target: Account, desktop: Bool = true) {
        guard !target.isDefault else {
            if desktop && desktopSyncEnabled && desktopAccountId != target.id { switchDesktop(to: target) }
            return
        }
        busy = true
        defer { busy = false }
        do {
            try switchDefault(to: target)
            notice = "Varsayılan hesap artık \(target.label). Açık Claude Code oturumları yeniden başlatılana kadar eski hesapta kalır."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            reload()
            return
        }
        reload()
        Task { await refreshUsage() }
        if desktop && desktopSyncEnabled && desktopAccountId != target.id { switchDesktop(to: target) }
    }

    // MARK: Claude masaüstü

    var desktopInstalled: Bool { DesktopSync.isInstalled }

    var desktopSyncEnabled: Bool {
        get { desktopInstalled && (registry.desktopSync ?? true) }
        set { registry.desktopSync = newValue; saveRegistry(); objectWillChange.send() }
    }

    var desktopAccount: Account? { accounts.first { $0.id == desktopAccountId } }

    func switchDesktop(to target: Account) {
        guard !desktopBusy else { return }
        desktopBusy = true
        let id = target.id, label = target.label
        Task.detached {
            let result = Result { try DesktopSync.switchTo(id) }
            await MainActor.run {
                self.desktopBusy = false
                self.desktopAccountId = DesktopSync.currentAccount()
                switch result {
                case .success(.needsLogin):
                    self.desktopAccountId = nil
                    self.notice = (self.notice.map { $0 + "\n" } ?? "")
                        + "Claude masaüstü açıldı: \(label) hesabıyla bir kez giriş yap, sonraki geçişler otomatik olur."
                case .success:
                    break
                case .failure(let e):
                    self.lastError = e.localizedDescription
                }
            }
        }
    }

    private func switchDefault(to target: Account) throws {
        guard let targetHome = target.home else {
            throw HesapError.config("\(target.label) hesabının config dizini yok.")
        }
        let targetService = Keychain.service(forConfigDir: targetHome)
        guard let targetBlob = Keychain.read(targetService),
              let targetOauth = targetBlob["claudeAiOauth"] else {
            throw HesapError.missingCredentials(target.label)
        }
        guard let targetAccount = readJSON(targetHome + "/.claude.json")?["oauthAccount"] else {
            throw HesapError.config("\(targetHome)/.claude.json içinde oauthAccount yok.")
        }

        var defaultBlob = Keychain.read(Keychain.defaultService) ?? [:]
        guard var global = readJSON(defaultConfigFile) else {
            throw HesapError.config("~/.claude.json okunamadı.")
        }
        try backupConfig()

        // 1) Şu anki varsayılan hesabın güncel token'ını kendi yuvasına geri yaz.
        if let current = defaultAccount, let currentOauth = defaultBlob["claudeAiOauth"] {
            let currentHome = current.home ?? home + "/.claude-" + slug(current.label)
            try FileManager.default.createDirectory(atPath: currentHome, withIntermediateDirectories: true)
            let service = Keychain.service(forConfigDir: currentHome)
            var slot = Keychain.read(service) ?? [:]
            slot["claudeAiOauth"] = currentOauth
            try Keychain.write(service, slot)

            var cfg = readJSON(currentHome + "/.claude.json") ?? ["hasCompletedOnboarding": true]
            cfg["oauthAccount"] = global["oauthAccount"]
            try writeJSON(cfg, to: currentHome + "/.claude.json")
        }

        // 2) Hedef hesabı varsayılana koy. mcpOAuth gibi diğer alanlar ortak kalır.
        defaultBlob["claudeAiOauth"] = targetOauth
        try Keychain.write(Keychain.defaultService, defaultBlob)
        global["oauthAccount"] = targetAccount
        try writeJSON(global, to: defaultConfigFile)
    }

    private func backupConfig() throws {
        let dir = appDir + "/backups"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.copyItem(atPath: defaultConfigFile, toPath: "\(dir)/claude.json.\(stamp)")
        // Son 20 yedeği tut.
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for f in files.dropLast(20) { try? FileManager.default.removeItem(atPath: dir + "/" + f) }
    }

    func slug(_ s: String) -> String {
        let map: [Character: String] = ["ı": "i", "İ": "i", "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g",
                                        "ü": "u", "Ü": "u", "ö": "o", "Ö": "o", "ç": "c", "Ç": "c"]
        let out = s.lowercased().map { c -> String in
            if let m = map[c] { return m }
            return c.isLetter || c.isNumber ? String(c) : "-"
        }.joined()
        return out.split(separator: "-").joined(separator: "-").isEmpty ? "hesap"
            : out.split(separator: "-").joined(separator: "-")
    }

    // MARK: Ad, gizleme

    func rename(_ acc: Account, to label: String) {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        registry.accounts[acc.id, default: .init()].label = l
        saveRegistry()
        if let i = accounts.firstIndex(where: { $0.id == acc.id }) { accounts[i].label = l }
    }

    func setHidden(_ acc: Account, _ hidden: Bool) {
        registry.accounts[acc.id, default: .init()].hidden = hidden
        saveRegistry()
        objectWillChange.send()
    }

    var hiddenCount: Int { accounts.count - visibleAccounts.count }

    func unhideAll() {
        for k in registry.accounts.keys { registry.accounts[k]?.hidden = nil }
        saveRegistry()
        objectWillChange.send()
    }

    // MARK: Terminal

    /// Hesabı varsayılanı değiştirmeden tek bir terminalde açar (fvm use gibi, oturumluk).
    func openTerminal(_ acc: Account) {
        let env = acc.isDefault ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(shq(acc.home ?? defaultDir))"
        launchScript(name: "ac-\(slug(acc.label))", body: """
        \(env)
        cd ~
        printf '\\033]0;Claude · %s\\007' \(shq(acc.label))
        exec \(shq(Shell.claudePath))
        """)
    }

    /// Yeni bir config dizini açıp orada giriş yaptırır.
    func addAccount(named name: String) {
        let dir = home + "/.claude-" + slug(name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        launchScript(name: "giris-\(slug(name))", body: """
        export CLAUDE_CONFIG_DIR=\(shq(dir))
        echo "Claude Hesap · \(name) için giriş"
        echo "Tarayıcıda açılan sayfada eklemek istediğin hesapla giriş yap."
        echo
        \(shq(Shell.claudePath)) auth login --claudeai
        echo
        echo "Bitti. Bu pencereyi kapatabilirsin; Claude Hesap listeyi yeniler."
        read -k 1
        """)
        notice = "Giriş penceresi açıldı. Giriş bitince listeyi yenile."
    }

    func relogin(_ acc: Account) {
        let env = acc.isDefault ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(shq(acc.home ?? defaultDir))"
        launchScript(name: "giris-\(slug(acc.label))", body: """
        \(env)
        \(shq(Shell.claudePath)) auth login --claudeai --email \(shq(acc.email))
        read -k 1
        """)
    }

    private func launchScript(name: String, body: String) {
        let dir = appDir + "/launch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(name).command"
        let script = "#!/bin/zsh -l\n" + body + "\n"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            Shell.run("/usr/bin/open", [path])
        } catch {
            lastError = "Terminal açılamadı: \(error.localizedDescription)"
        }
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Kullanım limitleri

    func refreshUsage() async {
        for i in accounts.indices { accounts[i].loadingUsage = true }
        await withTaskGroup(of: (String, [UsageWindow], String?).self) { group in
            for acc in accounts {
                group.addTask { await Self.fetchUsage(for: acc, defaultDir: self.defaultDir) }
            }
            for await (id, usage, err) in group {
                if let i = accounts.firstIndex(where: { $0.id == id }) {
                    accounts[i].loadingUsage = false
                    if err == nil || usage.isEmpty == false { accounts[i].usage = usage }
                    accounts[i].usageError = err
                }
            }
        }
        lastRefresh = Date()
    }

    nonisolated private static func fetchUsage(for acc: Account, defaultDir: String) async
        -> (String, [UsageWindow], String?) {
        let configDir: String? = acc.isDefault ? nil : acc.home
        if !acc.isDefault && acc.home == nil { return (acc.id, [], "Oturum yok") }
        let service = Keychain.service(forConfigDir: configDir)

        func token() -> (String, Double)? {
            guard let o = Keychain.read(service)?["claudeAiOauth"] as? [String: Any],
                  let t = o["accessToken"] as? String else { return nil }
            return (t, o["expiresAt"] as? Double ?? 0)
        }

        guard var (tok, exp) = token() else { return (acc.id, [], "Oturum yok") }
        // Varsayılan hesabın token'ını açık Claude oturumları yeniler; biz yalnız
        // kenarda bekleyen hesapların token'ını yenileyip kendi yuvasına yazarız.
        if exp / 1000 < Date().timeIntervalSince1970 + 60 {
            if acc.isDefault {
                refreshViaClaude(configDir: nil)
            } else if let err = await refreshToken(service: service) {
                return (acc.id, [], err)
            }
            guard let t = token() else { return (acc.id, [], "Oturum yok") }
            (tok, exp) = t
        }

        let result = await requestUsage(token: tok)
        switch result {
        case .ok(let w): return (acc.id, w, nil)
        case .unauthorized: return (acc.id, [], "Oturum süresi dolmuş, yeniden giriş gerekli")
        case .failed(let m): return (acc.id, [], m)
        }
    }

    /// Claude Code'un OAuth istemcisiyle refresh token akışı. Dönen yeni token'lar
    /// aynı Keychain yuvasına yazılır (refresh token her yenilemede değişir).
    nonisolated private static func refreshToken(service: String) async -> String? {
        guard var blob = Keychain.read(service),
              var o = blob["claudeAiOauth"] as? [String: Any],
              let refresh = o["refreshToken"] as? String else { return "Oturum yok" }
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        if let scopes = o["scopes"] as? [String] { body["scope"] = scopes.joined(separator: " ") }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                return code == 400 || code == 401 ? "Oturum süresi dolmuş, yeniden giriş gerekli"
                                                  : "Token yenilenemedi (HTTP \(code))"
            }
            o["accessToken"] = access
            if let r = json["refresh_token"] as? String { o["refreshToken"] = r }
            if let e = (json["expires_in"] as? NSNumber)?.doubleValue {
                o["expiresAt"] = Int64((Date().timeIntervalSince1970 + e) * 1000)
            }
            blob["claudeAiOauth"] = o
            try Keychain.write(service, blob)
            return nil
        } catch {
            return "Token yenilenemedi: \(error.localizedDescription)"
        }
    }

    nonisolated private static func refreshViaClaude(configDir: String?) {
        var env = ProcessInfo.processInfo.environment
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir } else { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Shell.claudePath)
        p.arguments = ["auth", "status", "--json"]
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    enum UsageResult { case ok([UsageWindow]), unauthorized, failed(String) }

    nonisolated private static func requestUsage(token: String) async -> UsageResult {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .unauthorized }
            guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Limit bilgisi alınamadı (HTTP \(code))")
            }
            return .ok(parseUsage(json))
        } catch {
            return .failed("Bağlantı hatası")
        }
    }

    nonisolated static func parseUsage(_ json: [String: Any]) -> [UsageWindow] {
        let titles: [(String, String)] = [
            ("five_hour", "5 saatlik"),
            ("seven_day", "Haftalık"),
            ("seven_day_opus", "Haftalık · Opus"),
            ("seven_day_sonnet", "Haftalık · Sonnet"),
        ]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        return titles.compactMap { key, title in
            guard let w = json[key] as? [String: Any],
                  let pct = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resets_at"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            return UsageWindow(id: key, title: title, percent: pct, resetsAt: reset)
        }
    }

    // MARK: Dosya yardımcıları

    private func loadRegistry() {
        if let d = FileManager.default.contents(atPath: registryFile),
           let r = try? JSONDecoder().decode(Registry.self, from: d) { registry = r }
    }

    private func saveRegistry() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(registry) { try? d.write(to: URL(fileURLWithPath: registryFile)) }
    }

    func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func writeJSON(_ obj: [String: Any], to path: String) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        let tmp = path + ".hesap-tmp"
        try d.write(to: URL(fileURLWithPath: tmp))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    }
}
