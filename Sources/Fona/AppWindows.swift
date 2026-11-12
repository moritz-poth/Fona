import AppKit
import SwiftUI

/// While the settings or the manual window is open, Fona behaves like a normal app: Dock icon, ⌘-Tab and its own menu
/// bar (user request 2026-11-12, like Mountpoint's settings app). Back to a menu bar app when they close.
/// Not a second program as in Mountpoint: in the sandbox a second app would get its own, separate data container.
@MainActor
enum AppWindows {
    static var open = Set<String>()
    static var aboutRequested = false

    static func opened(_ id: String) {
        open.insert(id)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI builds its own menu when the policy changes; ours replaces it right after
        DispatchQueue.main.async { buildMenu() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { buildMenu() }
    }

    static func closed(_ id: String) {
        open.remove(id)
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// Mountpoint's settings menu: "Fona" (About, Hide, Close Settings ⌘Q) and "Edit"; ⌘W hidden, no Window menu.
    static func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil,
                  mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let close = item(L.t(.close), #selector(NSWindow.performClose(_:)), "w")
        close.isHidden = true
        close.allowsKeyEquivalentWhenHidden = true
        menu("Fona", [
            item(L.t(.about), #selector(MenuTarget.about), "", target: MenuTarget.shared),
            .separator(),
            item(L.t(.hideFona), #selector(NSApplication.hide(_:)), "h"),
            item(L.t(.closeSettings), #selector(MenuTarget.closeWindows), "q", target: MenuTarget.shared),
            close,
        ])
        menu(L.t(.edit), [
            item(L.t(.undo), Selector(("undo:")), "z"),
            item(L.t(.redo), Selector(("redo:")), "z", mods: [.command, .shift]),
            .separator(),
            item(L.t(.cut), #selector(NSText.cut(_:)), "x"),
            item(L.t(.copy), #selector(NSText.copy(_:)), "c"),
            item(L.t(.paste), #selector(NSText.paste(_:)), "v"),
            item(L.t(.selectAll), #selector(NSText.selectAll(_:)), "a"),
        ])
        NSApp.mainMenu = main
    }
}

@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    var openSettings: (() -> Void)?

    /// ⌘Q closes Fona's windows – Fona itself keeps playing in the menu bar.
    @objc func closeWindows() {
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) { w.performClose(nil) }
    }

    @objc func about() {
        AppWindows.aboutRequested = true
        openSettings?()
        NotificationCenter.default.post(name: .fonaShowAbout, object: nil)
    }
}

extension Notification.Name { static let fonaShowAbout = Notification.Name("fonaShowAbout") }

/// Registers a window with AppWindows while it is on screen.
struct TracksWindow: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content
            .onAppear { AppWindows.opened(id) }
            .onDisappear { AppWindows.closed(id) }
    }
}
