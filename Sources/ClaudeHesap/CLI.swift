import Foundation

/// fvm benzeri komut satırı: `claude-hesap list`, `claude-hesap use <ad>`.
enum CLI {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        let store = AccountStore()
        switch args[0] {
        case "list", "ls":
            for a in store.visibleAccounts {
                let mark = a.isDefault ? "●" : " "
                print("\(mark) \(a.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(a.email)  \(a.plan ?? "")")
            }
            return 0
        case "use", "global":
            guard args.count > 1 else { print("kullanım: claude-hesap use <ad|e-posta>"); return 1 }
            let q = args[1].lowercased()
            guard let acc = store.accounts.first(where: {
                $0.label.lowercased() == q || $0.email.lowercased() == q || store.slug($0.label) == store.slug(q)
            }) else {
                print("Hesap bulunamadı: \(args[1])"); return 1
            }
            if acc.isDefault {
                print("\(acc.label) zaten varsayılan.")
            } else {
                store.makeDefault(acc, desktop: false)
                if let e = store.lastError { print("Hata: \(e)"); return 1 }
                print("Varsayılan hesap: \(acc.label) (\(acc.email))")
            }
            if store.desktopSyncEnabled && DesktopSync.currentAccount() != acc.id {
                print("Claude masaüstü geçiriliyor…")
                do {
                    if try DesktopSync.switchTo(acc.id) == .needsLogin {
                        print("Claude masaüstünde \(acc.label) hesabıyla bir kez giriş yap.")
                    }
                } catch {
                    print("Masaüstü: \(error.localizedDescription)"); return 1
                }
            }
            return 0
        case "version", "--version", "-v":
            // brew bağlantısıyla çağrılınca Bundle.main paketi bulamaz; bağlantıyı çözüp .app'e çık.
            let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
            let app = exe.flatMap { Bundle(url: $0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
            print(app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "geliştirme")
            return 0
        case "current":
            print(store.defaultAccount.map { "\($0.label) (\($0.email))" } ?? "yok")
            return 0
        default:
            print("""
            claude-hesap — Claude hesapları arasında geçiş

              list            hesapları listele (● varsayılan)
              use <ad>        varsayılan hesabı değiştir
              current         varsayılan hesabı göster
              version         sürümü göster

            Argümansız açılırsa arayüz başlar.
            """)
            return args[0] == "help" || args[0] == "-h" ? 0 : 1
        }
    }
}
