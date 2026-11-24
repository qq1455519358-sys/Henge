import SwiftUI
import UIKit

/// What a running Mac shares with this device: the Shared folder in Files, an optional zero-copy External USB-C
/// drive or folder at ~/Henge/External, host status telemetry, and the clipboard (host/share.c, tools/henge-agent.m).
enum Sharing {
    private static let externalBookmarkKey = "henge.share.externalBookmark"
    private static var securityScopedURL: URL?
    private(set) static var externalLabel: String?

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"
    /// Less background work and drawing in macOS (host/share.c, lighten_script), and back.
    static let lightenCommand = "curl -s http://10.0.2.4/.henge/lighten | sh"
    static let unlightenCommand = "curl -s http://10.0.2.4/.henge/unlighten | sh"

    /// Before a Mac starts.
    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket, Bundle.main.path(forResource: "henge-agent", ofType: "gz"))
        restoreExternalBookmarkIfNeeded()
    }

    /// Mount an external USB-C drive or folder picked in Files at ~/Henge/External with zero copying.
    @discardableResult
    static func mountExternalFolder(_ url: URL) -> Bool {
        if let prev = securityScopedURL {
            prev.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
        let accessed = url.startAccessingSecurityScopedResource()
        if accessed { securityScopedURL = url }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            if accessed {
                url.stopAccessingSecurityScopedResource()
                securityScopedURL = nil
            }
            return false
        }
        let label = url.lastPathComponent.isEmpty ? "External Drive" : url.lastPathComponent
        externalLabel = label
        henge_share_set_external(url.path, label)
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: externalBookmarkKey)
        }
        HengeLog.log("share", "mounted external folder '\(label)' at ~/Henge/External")
        HostStatusBridge.shared.pushNow()
        return true
    }

    static func unmountExternalFolder() {
        if let prev = securityScopedURL {
            prev.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
        externalLabel = nil
        UserDefaults.standard.removeObject(forKey: externalBookmarkKey)
        henge_share_set_external(nil, nil)
        HengeLog.log("share", "unmounted external folder")
        HostStatusBridge.shared.pushNow()
    }

    private static func restoreExternalBookmarkIfNeeded() {
        guard externalLabel == nil,
              let data = UserDefaults.standard.data(forKey: externalBookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return
        }
        _ = mountExternalFolder(url)
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    static func followMacClipboard() async {
        while !Task.isCancelled {
            if let text = henge_share_take_clipboard() {
                UIPasteboard.general.string = String(cString: text)
                free(text)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    static func paste(_ text: String) {
        Task { @MainActor in
            if helperRunning {
                henge_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the Mac's clipboard
                Keys.chord(Keys.command, "v")
            } else {
                await Keys.typeSlowly(text)
            }
        }
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}
