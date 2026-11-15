import AppKit
import Foundation

/// GitHub Releases'tan yeni sürümü denetler ve kurar.
/// Homebrew ile kurulduysa `brew upgrade --cask` kullanır, değilse zip'i indirip paketi yerinde değiştirir.
@MainActor
final class Updater: ObservableObject {
    nonisolated static let repo = "slymnyg/claude-hesap"
    nonisolated static let tap = "slymnyg/tap"
    nonisolated static let cask = "claude-hesap"
    static let interval: TimeInterval = 6 * 3600

    enum State: Equatable { case idle, checking, upToDate, installing, failed(String) }

    @Published var latest: String?
    @Published var state: State = .idle
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }

    let current: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var downloadURL: URL?
    private var timer: Timer?

    var updateAvailable: Bool {
        guard let latest, let current else { return false }
        return Self.isNewer(latest, than: current)
    }

    init() {
        autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
        // `swift run` ile paketsiz çalışırken güncelleme yok.
        guard current != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        Task { try? await Task.sleep(for: .seconds(5)); await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { await self?.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        guard state != .installing, state != .checking else { return }
        state = .checking
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("claude-hesap", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw HesapError.config("Sürüm bilgisi alınamadı.") }
            latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            downloadURL = assets.lazy
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
                .flatMap(URL.init(string:))
            state = updateAvailable ? .idle : .upToDate
        } catch {
            state = manual ? .failed("Güncelleme denetlenemedi: \(error.localizedDescription)") : .idle
            return
        }
        // Pencere kullanılırken kendiliğinden yeniden başlama; bir sonraki denetimde kurulur.
        if updateAvailable && autoUpdate && !manual && !NSApp.isActive { await install() }
    }

    func install() async {
        guard updateAvailable, state != .installing else { return }
        state = .installing
        let appURL = Bundle.main.bundleURL
        let zip = downloadURL
        let result: String? = await Task.detached {
            if appURL.path.hasPrefix("/Applications/"), let brew = Self.brewPath(), Self.isBrewManaged(brew) {
                return Self.brewUpgrade(brew)
            }
            guard let zip else { return "İndirme bağlantısı bulunamadı." }
            return await Self.replaceBundle(at: appURL, from: zip)
        }.value
        if let result {
            state = .failed(result)
        } else {
            Self.relaunch(appURL)
        }
    }

    // MARK: Kurulum

    nonisolated private static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile)
    }

    nonisolated private static func isBrewManaged(_ brew: String) -> Bool {
        Shell.run(brew, ["list", "--cask", "--versions", cask]).status == 0
    }

    /// Tap'i doğrudan çekip (brew update'ten çok daha hızlı) cask'ı yükseltir.
    nonisolated private static func brewUpgrade(_ brew: String) -> String? {
        let env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        let repo = Shell.run(brew, ["--repository", tap]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty { Shell.run("/usr/bin/git", ["-C", repo, "pull", "--ff-only", "-q"]) }
        let r = Shell.run(brew, ["upgrade", "--cask", cask], env: env)
        if r.status != 0 {
            let msg = r.stderr.split(separator: "\n").last.map(String.init) ?? "brew upgrade başarısız"
            return "Güncelleme kurulamadı: \(msg)"
        }
        return nil
    }

    nonisolated private static func replaceBundle(at appURL: URL, from zip: URL) async -> String? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("claude-hesap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (file, _) = try await URLSession.shared.download(from: zip)
            let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, tmp.path])
            try? fm.removeItem(at: file)
            guard unzip.status == 0 else { return "Arşiv açılamadı." }
            guard let newApp = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { return "Arşivde uygulama yok." }
            let old = tmp.appendingPathComponent("eski.app")
            try fm.moveItem(at: appURL, to: old)
            if Shell.run("/usr/bin/ditto", [newApp.path, appURL.path]).status != 0 {
                try? fm.moveItem(at: old, to: appURL)
                return "Uygulama değiştirilemedi."
            }
            Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
            return nil
        } catch {
            return "Güncelleme kurulamadı: \(error.localizedDescription)"
        }
    }

    private static func relaunch(_ appURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", appURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
