import SwiftUI

// MARK: Tema

enum Theme {
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)        // #D97757
    static let clayText = Color(red: 0.90, green: 0.57, blue: 0.45)    // #E59274
    static let cardRadius: CGFloat = 16

    static func tint(for acc: Account) -> Color {
        let tints: [Color] = [clayText, Color(red: 0.56, green: 0.65, blue: 0.92),
                              Color(red: 0.42, green: 0.78, blue: 0.71), Color(red: 0.70, green: 0.58, blue: 0.90),
                              Color(red: 0.88, green: 0.55, blue: 0.70)]
        let h = acc.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return tints[h % tints.count]
    }

    static func usage(_ p: Double) -> Color {
        p >= 90 ? Color(red: 0.87, green: 0.27, blue: 0.25)
            : p >= 70 ? Color(red: 0.93, green: 0.58, blue: 0.20)
            : Color(red: 0.30, green: 0.70, blue: 0.48)
    }

    static let danger = Color(red: 0.94, green: 0.54, blue: 0.52)
}

private func resetText(_ d: Date?) -> String? {
    guard let d else { return nil }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "sıfırlandı" }
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    let t = days > 0 ? "\(days) g \(h) sa" : h > 0 ? "\(h) sa \(m) dk" : "\(max(m, 1)) dk"
    return "\(t) sonra"
}

private extension Account {
    func window(_ id: String) -> UsageWindow? { usage.first { $0.id == id } }
    var isMaxed: Bool { usage.contains { $0.percent >= 100 } }
}

/// Uygulama logosu (bundle'daki AppIcon); geliştirme sırasında yoksa düz bir yedek.
struct AppLogo: View {
    var size: CGFloat = 40
    var body: some View {
        if let img = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.23).fill(Theme.clay.gradient).frame(width: size, height: size)
        }
    }
}

// MARK: Ana pencere (A · Rafine kartlar)

struct MainView: View {
    @EnvironmentObject var store: AccountStore
    @State private var showAdd = false

    private var others: [Account] { store.visibleAccounts.filter { !$0.isDefault } }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                if let n = store.notice { Banner(text: n, kind: .info) { store.notice = nil } }
                if let e = store.lastError { Banner(text: e, kind: .error) { store.lastError = nil } }

                if let def = store.defaultAccount {
                    SectionTitle("Varsayılan")
                    DefaultCard(account: def)
                }

                if !others.isEmpty {
                    SectionTitle("Diğer hesaplar").padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { i, acc in
                            if i > 0 { Divider().opacity(0.6).padding(.leading, 62) }
                            AccountRow(account: acc)
                        }
                    }
                    .cardStyle()
                }
            }
            .padding(.horizontal, 22)
            footer
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowBackground())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.accounts.map(\.id))
        .sheet(isPresented: $showAdd) { AddAccountSheet() }
        .task { await store.refreshUsage() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppLogo(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Hesap").font(.system(size: 18, weight: .semibold))
                (Text("Düz ") + Text("claude").font(.system(size: 12, design: .monospaced)).foregroundColor(.primary.opacity(0.85))
                    + Text(" hangi hesapla açılsın?"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            RefreshButton(size: 30)
        }
        .padding(.horizontal, 22)
        .padding(.top, 36)   // gizli başlık çubuğundaki trafik ışıklarının altı
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack {
            Button { showAdd = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    Text("Hesap ekle").font(.system(size: 12.5, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.clayText)
            Spacer()
            if store.desktopInstalled {
                Toggle(isOn: Binding(get: { store.desktopSyncEnabled }, set: { store.desktopSyncEnabled = $0 })) {
                    Text("Masaüstünü de geçir").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.clay)
                .help("Varsayılan yapılan hesaba Claude masaüstü uygulaması da geçer (uygulama yeniden başlar)")
                .padding(.leading, 12)
            }
            if store.hiddenCount > 0 {
                Button("\(store.hiddenCount) gizli hesap") { store.unhideAll() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            if let t = store.lastRefresh {
                Text("Güncellendi \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

struct WindowBackground: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        Group {
            if scheme == .dark {
                LinearGradient(stops: [.init(color: Color(red: 0.169, green: 0.141, blue: 0.125), location: 0),
                                       .init(color: Color(red: 0.118, green: 0.118, blue: 0.118), location: 0.38)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(stops: [.init(color: Color(red: 0.98, green: 0.94, blue: 0.91), location: 0),
                                       .init(color: Color(red: 0.965, green: 0.953, blue: 0.937), location: 0.38)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "tr")))
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

extension View {
    func cardStyle(highlight: Color? = nil) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(highlight?.opacity(0.45) ?? Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct RefreshButton: View {
    @EnvironmentObject var store: AccountStore
    var size: CGFloat = 28
    private var loading: Bool { store.accounts.contains(where: \.loadingUsage) }
    var body: some View {
        Button {
            store.reload()
            Task { await store.refreshUsage() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size * 0.42, weight: .semibold))
                .rotationEffect(.degrees(loading ? 360 : 0))
                .animation(loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: loading)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.8))
        .help("Limitleri yenile (⌘R)")
        .keyboardShortcut("r")
    }
}

// MARK: Varsayılan hesap kartı

struct DefaultCard: View {
    @EnvironmentObject var store: AccountStore
    let account: Account

    private var extra: [UsageWindow] { account.usage.filter { $0.id != "five_hour" && $0.id != "seven_day" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(account: account, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label).font(.system(size: 15, weight: .semibold))
                        if let plan = account.plan { PlanTag(text: plan, color: Theme.tint(for: account)) }
                    }
                    EmailText(account: account, size: 12)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Aktif").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Theme.clayText)
                AccountMenu(account: account)
            }

            if account.usage.isEmpty {
                UsagePlaceholder(account: account)
            } else {
                HStack(spacing: 10) {
                    RingStat(window: account.window("five_hour"), title: "5 saat")
                    RingStat(window: account.window("seven_day"), title: "Hafta")
                }
                if !extra.isEmpty {
                    VStack(spacing: 8) { ForEach(extra) { BarStat(window: $0, title: $0.title) } }
                }
            }
            if store.desktopInstalled { DesktopStatus(account: account) }
        }
        .padding(16)
        .cardStyle(highlight: Theme.clay)
        .contextMenu { AccountMenuItems(account: account) }
    }
}

struct RingStat: View {
    let window: UsageWindow?
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Ring(percent: window?.percent ?? 0, lineWidth: 6)
                .frame(width: 46, height: 46)
                .overlay(
                    Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "—")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(resetText(window?.resetsAt) ?? " ").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct Ring: View {
    let percent: Double
    var lineWidth: CGFloat = 4
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: lineWidth)
            if percent > 0 {
                Circle()
                    .trim(from: 0, to: max(0.02, min(percent, 100) / 100))
                    .stroke(Theme.usage(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .animation(.easeOut(duration: 0.6), value: percent)
    }
}

/// Başlık + yüzde üstte, ince çubuk altta (A tasarımındaki diğer hesap limitleri).
struct BarStat: View {
    let window: UsageWindow?
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.replacingOccurrences(of: "Haftalık · ", with: "Hafta · "))
                Spacer()
                if let w = window {
                    Text("%\(Int(w.percent.rounded()))")
                        .fontWeight(w.percent >= 90 ? .semibold : .regular)
                        .foregroundStyle(w.percent >= 90 ? Theme.danger : .secondary)
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .help(window.flatMap { resetText($0.resetsAt) }.map { "\($0) sıfırlanır" } ?? "")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let w = window, w.percent > 0 {
                        Capsule().fill(Theme.usage(w.percent))
                            .frame(width: max(4, g.size.width * min(w.percent, 100) / 100))
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

struct UsagePlaceholder: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    var body: some View {
        HStack(spacing: 8) {
            if account.loadingUsage {
                ProgressView().controlSize(.small)
                Text("Limitler alınıyor…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if let err = account.usageError {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 11))
                Text(err).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                if err.contains("giriş") || err.contains("Oturum") {
                    Button("Giriş yap") { store.relogin(account) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.clayText)
                }
            }
        }
    }
}

struct EmailText: View {
    let account: Account
    var size: CGFloat = 11.5
    var body: some View {
        Text(account.email)
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(account.email)
    }
}

// MARK: Diğer hesap satırı

struct AccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(account: account, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.label).font(.system(size: 13.5, weight: .semibold))
                        if let plan = account.plan { PlanTag(text: plan, color: Theme.tint(for: account)) }
                        if store.desktopAccountId == account.id { DesktopBadge() }
                    }
                    EmailText(account: account)
                }
                Spacer(minLength: 8)
                SwitchButton(account: account)
                AccountMenu(account: account)
            }
            Group {
                if account.usage.isEmpty {
                    UsagePlaceholder(account: account)
                } else {
                    HStack(spacing: 12) {
                        BarStat(window: account.window("five_hour"), title: "5 saat")
                        BarStat(window: account.window("seven_day"), title: "Hafta")
                    }
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, 30)
        }
        .padding(14)
        .background(hover ? Color.primary.opacity(0.025) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { AccountMenuItems(account: account) }
    }
}

struct SwitchButton: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    @State private var hover = false

    var body: some View {
        Button { store.makeDefault(account) } label: {
            Text("Varsayılan yap")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(hover ? Color.white : Theme.clayText)
                .background(Capsule().fill(hover ? Theme.clay : Theme.clay.opacity(0.13)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(store.busy || !account.hasCredentials)
        .opacity(account.hasCredentials ? 1 : 0.4)
        .help(account.isMaxed ? "Bu hesabın bir limiti dolu" :
              account.hasCredentials ? "Düz `claude` komutu bu hesapla açılsın" : "Bu hesap için kayıtlı oturum yok")
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct AccountMenuItems: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    var onRename: (() -> Void)? = nil

    var body: some View {
        Button("Bu hesapla terminal aç") { store.openTerminal(account) }
        if store.desktopInstalled && store.desktopAccountId != account.id {
            Button("Claude masaüstünü bu hesaba geçir") { store.switchDesktop(to: account) }
        }
        if let onRename { Button("Yeniden adlandır…", action: onRename) }
        Button("Yeniden giriş yap") { store.relogin(account) }
        if let home = account.home {
            Button("Config dizinini göster") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: home) }
        }
        if !account.isDefault {
            Divider()
            Button("Listeden gizle") { store.setHidden(account, true) }
        }
    }
}

struct AccountMenu: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        Menu {
            AccountMenuItems(account: account) { draft = account.label; renaming = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Hesabı yeniden adlandır", isPresented: $renaming) {
            TextField("Ad", text: $draft)
            Button("Kaydet") { store.rename(account, to: draft) }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}

struct Avatar: View {
    let account: Account
    var size: CGFloat = 36
    var body: some View {
        let initials = account.label.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        let tint = Theme.tint(for: account)
        ZStack {
            Circle().fill(tint.opacity(0.18))
            Text(initials.isEmpty ? "?" : initials.uppercased(with: Locale(identifier: "tr")))
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct PlanTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "tr")))
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.15)))
    }
}

struct Banner: View {
    enum Kind { case info, error }
    let text: String
    let kind: Kind
    let close: () -> Void

    var body: some View {
        let c: Color = kind == .error ? .red : Theme.clay
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(c).font(.system(size: 12))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(c.opacity(0.1)))
        .padding(.bottom, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppLogo(size: 32)
                Text("Yeni hesap ekle").font(.system(size: 15, weight: .semibold))
            }
            Text("Hesaba kısa bir ad ver. Açılan terminalde tarayıcı üzerinden giriş yapacaksın; bitince liste kendiliğinden yenilenir.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("ör. Yedek", text: $name).textFieldStyle(.roundedBorder)
            Text(name.isEmpty ? " " : "~/.claude-\(store.slug(name))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Giriş yap") {
                    store.addAccount(named: name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(Theme.clay)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 380)
    }
}

// MARK: Menü çubuğu paneli (D)

struct MenuBarPanel: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppLogo(size: 22)
                Text("Claude Hesap").font(.system(size: 13, weight: .semibold))
                Spacer()
                RefreshButton(size: 24)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(store.visibleAccounts) { PanelRow(account: $0) }
            }
            .padding(.horizontal, 6)

            if let e = store.lastError {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 14).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.top, 8)
            VStack(spacing: 0) {
                PanelAction(title: "Hesapları yönet…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                if let def = store.defaultAccount {
                    PanelAction(title: "Varsayılan hesapla terminal aç") { store.openTerminal(def) }
                }
                PanelAction(title: "Çık") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(width: 312)
    }
}

struct PanelRow: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    @State private var hover = false

    private var subtitle: (String, Bool) {
        if account.isMaxed {
            let which = account.window("five_hour").map { $0.percent >= 100 } == true ? "5 saatlik" : "Haftalık"
            return ("\(which) limit dolu", true)
        }
        if !account.usage.isEmpty {
            let f = account.window("five_hour").map { "5s %\(Int($0.percent.rounded()))" }
            let w = account.window("seven_day").map { "hafta %\(Int($0.percent.rounded()))" }
            return ([f, w].compactMap { $0 }.joined(separator: " · "), false)
        }
        if account.loadingUsage { return ("Limitler alınıyor…", false) }
        if let e = account.usageError { return (e, true) }
        return (account.email, false)
    }

    var body: some View {
        Button { store.makeDefault(account) } label: {
            HStack(spacing: 10) {
                Avatar(account: account, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(account.label).font(.system(size: 12.5, weight: .semibold))
                        if store.desktopAccountId == account.id { DesktopBadge(compact: true) }
                    }
                    Text(subtitle.0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(subtitle.1 ? Theme.danger : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if account.isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.clay)
                } else {
                    Image(systemName: "circle").font(.system(size: 16, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(account.isDefault ? Theme.clay.opacity(0.14) : hover ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(account.email)
        .disabled(store.busy || (!account.hasCredentials && !account.isDefault))
    }
}

struct PanelAction: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.85))
        .onHover { hover = $0 }
    }
}

// MARK: Claude masaüstü durumu

struct DesktopBadge: View {
    var compact = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "macwindow").font(.system(size: compact ? 9 : 9.5, weight: .semibold))
            if !compact { Text("MASAÜSTÜ").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 0 : 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(compact ? 0 : 0.07)))
        .help("Claude masaüstü uygulaması bu hesapta")
    }
}

struct DesktopStatus: View {
    @EnvironmentObject var store: AccountStore
    let account: Account

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(.secondary)
            if store.desktopBusy {
                ProgressView().controlSize(.mini)
                Text("Claude masaüstü geçiyor…")
            } else if store.desktopAccountId == account.id {
                Text("Claude masaüstü de bu hesapta")
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.usage(0))
            } else {
                Text(store.desktopAccount.map { "Claude masaüstü: \($0.label)" } ?? "Claude masaüstünde oturum yok")
                Spacer(minLength: 8)
                Button("Bu hesaba geçir") { store.switchDesktop(to: account) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.clayText)
            }
            if store.desktopBusy || store.desktopAccountId == account.id { Spacer(minLength: 0) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}
