import AppKit
import Foundation

/// Claude masaüstü uygulamasının (Electron) oturumunu hesaplar arasında değiştirir.
/// Oturum iki yerde durur: `Cookies` (claude.ai sessionKey) ve `config.json` içindeki
/// OAuth token önbelleği. Her hesabın kopyası ~/.claude-hesap/desktop/<accountUuid>/ altında saklanır.
enum DesktopSync {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let dataDir = NSHomeDirectory() + "/Library/Application Support/Claude"
    static let storeDir = NSHomeDirectory() + "/.claude-hesap/desktop"
    static let sessionKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Masaüstünde o an oturum açık hesabın accountUuid'si.
    static func currentAccount() -> String? {
        readConfig()?["lastKnownAccountUuid"] as? String
    }

    static func hasSnapshot(_ uuid: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(storeDir)/\(uuid)/Cookies")
    }

    enum Outcome { case switched, needsLogin, alreadyThere }

    /// Claude.app'i kapatır, oturumu değiştirir ve yeniden açar. Ana thread dışında çağrılmalı.
    static func switchTo(_ target: String) throws -> Outcome {
        let fm = FileManager.default
        let current = currentAccount()
        if current == target && fm.fileExists(atPath: dataDir + "/Cookies") { return .alreadyThere }

        try quitClaude()

        try fm.createDirectory(atPath: storeDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard var config = readConfig() else { throw HesapError.config("Claude masaüstü config.json okunamadı.") }
        let backups = NSHomeDirectory() + "/.claude-hesap/backups"
        try? fm.createDirectory(atPath: backups, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: dataDir + "/config.json",
                         toPath: "\(backups)/desktop-config.json.\(Int(Date().timeIntervalSince1970))")

        // 1) Şu anki oturumu sahibinin yuvasına sakla (sahibi bilinmiyorsa tarihli yedeğe).
        let owner = current ?? "bilinmeyen-\(Int(Date().timeIntervalSince1970))"
        let ownerDir = "\(storeDir)/\(owner)"
        if fm.fileExists(atPath: dataDir + "/Cookies") {
            try? fm.removeItem(atPath: ownerDir)
            try fm.createDirectory(atPath: ownerDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.copyItem(atPath: dataDir + "/Cookies", toPath: ownerDir + "/Cookies")
            var session: [String: Any] = [:]
            for k in sessionKeys { session[k] = config[k] }
            try writeJSON(session, to: ownerDir + "/session.json")
        }

        // 2) Hedef hesabın oturumunu yerine koy; yoksa çıkış yapılmış hâlde aç.
        let targetDir = "\(storeDir)/\(target)"
        try? fm.removeItem(atPath: dataDir + "/Cookies")
        try? fm.removeItem(atPath: dataDir + "/Cookies-journal")
        let outcome: Outcome
        if hasSnapshot(target) {
            try fm.copyItem(atPath: targetDir + "/Cookies", toPath: dataDir + "/Cookies")
            let session = readJSON(targetDir + "/session.json") ?? [:]
            for k in sessionKeys { config[k] = session[k] }
            config["lastKnownAccountUuid"] = target
            outcome = .switched
        } else {
            for k in sessionKeys { config.removeValue(forKey: k) }
            // Sahibi belirsiz kalsın: giriş yapılmadan tekrar geçilirse boş oturum
            // eski hesabın yuvasının üstüne yazılmasın.
            config.removeValue(forKey: "lastKnownAccountUuid")
            outcome = .needsLogin
        }
        try writeJSON(config, to: dataDir + "/config.json")

        openClaude()
        return outcome
    }

    private static func runningClaude() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    private static func quitClaude() throws {
        let apps = runningClaude()
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if runningClaude().allSatisfy(\.isTerminated) {
                Thread.sleep(forTimeInterval: 0.8)   // dosyaların diske yazılması için
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw HesapError.config("Claude masaüstü kapanmadı (açık bir onay penceresi olabilir). Masaüstü hesabı değiştirilmedi.")
    }

    private static func openClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    private static func readConfig() -> [String: Any]? { readJSON(dataDir + "/config.json") }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func writeJSON(_ obj: [String: Any], to path: String) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        let tmp = path + ".hesap-tmp"
        try d.write(to: URL(fileURLWithPath: tmp))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        }
    }
}
