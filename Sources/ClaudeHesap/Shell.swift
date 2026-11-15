import Foundation
import CryptoKit

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String]? = nil,
                    stdin: String? = nil) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin {
            inp.fileHandleForWriting.write(Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: o, as: UTF8.self),
                           stderr: String(decoding: e, as: UTF8.self))
    }

    /// claude binary'sinin yolu (login shell PATH'inden).
    static let claudePath: String = {
        let r = run("/bin/zsh", ["-lc", "command -v claude"])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        for c in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                  NSHomeDirectory() + "/.local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "claude"
    }()
}

/// Claude Code'un kimlik bilgilerini tuttuğu Keychain kayıtları.
/// Varsayılan dizin için servis adı "Claude Code-credentials",
/// CLAUDE_CONFIG_DIR ile açılan dizinler için sonuna sha256(dizin)'in ilk 8 hanesi eklenir.
enum Keychain {
    static let defaultService = "Claude Code-credentials"
    static let security = "/usr/bin/security"
    // Claude Code ile aynı: bu boyutun üstündeki komutlar argv ile gönderilir.
    static let stdinLimit = 4000

    static func service(forConfigDir dir: String?) -> String {
        guard let dir else { return defaultService }
        let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(defaultService)-\(hash.prefix(8))"
    }

    static func read(_ service: String) -> [String: Any]? {
        let r = Shell.run(security, ["find-generic-password", "-s", service, "-w"])
        guard r.status == 0 else { return nil }
        let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
    }

    static func write(_ service: String, _ blob: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: blob)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let account = NSUserName()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        let r: ShellResult
        if line.utf8.count <= stdinLimit {
            r = Shell.run(security, ["-i"], stdin: line)
        } else {
            r = Shell.run(security, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        if r.status != 0 {
            throw HesapError.keychain("\(service): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

enum HesapError: LocalizedError {
    case keychain(String)
    case missingCredentials(String)
    case config(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let m): return "Keychain'e yazılamadı: \(m)"
        case .missingCredentials(let m): return "\(m) için kayıtlı oturum yok. Önce bu hesapla giriş yap."
        case .config(let m): return m
        }
    }
}
