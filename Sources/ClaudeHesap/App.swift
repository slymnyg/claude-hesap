import SwiftUI

@main
struct ClaudeHesapEntry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if !args.isEmpty && !args[0].hasPrefix("-psn") && !args[0].hasPrefix("-NS") {
            exit(MainActor.assumeIsolated { CLI.run(args) })
        }
        ClaudeHesapApp.main()
    }
}

struct ClaudeHesapApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        Window("Claude Hesap", id: "main") {
            MainView().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarPanel().environmentObject(store)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menü çubuğunda uygulama logosunun tek renkli (template) sürümü.
struct MenuBarIcon: View {
    var body: some View {
        if let img = Bundle.main.image(forResource: "menubar") {
            let _ = (img.isTemplate = true)
            Image(nsImage: img)
        } else {
            Image(systemName: "person.2.crop.square.stack")
        }
    }
}
