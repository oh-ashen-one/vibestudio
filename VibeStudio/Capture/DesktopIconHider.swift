import Foundation

/// Hides/restores desktop icons via Finder's CreateDesktop default.
enum DesktopIconHider {
    static func setHidden(_ hidden: Bool) {
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"]
        try? write.run()
        write.waitUntilExit()

        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Finder"]
        try? restart.run()
    }
}
