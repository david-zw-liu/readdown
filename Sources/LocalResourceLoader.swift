import AppKit
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let localResourceAccessDenied = Notification.Name("localResourceAccessDenied")
}

/// Maps between a document's directory on disk and the custom-scheme base URL
/// the page is loaded with.
///
/// `loadHTMLString(_:baseURL:)` gives the web content process no read access to
/// `file:` subresources, so every local `<img>` fails. Loading the page from a
/// custom scheme instead routes those requests back to us, where the app
/// process can read the bytes itself.
enum LocalResource {
    static let scheme = "readdown-resource"
    private static let host = "local"

    static func baseURL(forDirectory directory: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var path = directory.standardizedFileURL.path
        if !path.hasSuffix("/") { path += "/" }
        components.path = path
        return components.url
    }

    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, !url.path.isEmpty else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
}

/// Security-scoped grants for folders the reader allowed us to read.
///
/// The sandbox only hands us the document the user opened, not its siblings —
/// so a README's `screenshots/shot.png` is unreadable until the reader grants
/// the enclosing folder once. Grants persist as bookmarks and cover subfolders.
enum FolderAccess {
    private static let bookmarksKey = "grantedFolderBookmarks"
    private static let lock = NSLock()
    private static var active: [String: URL] = [:]

    /// Starts security-scoped access for a stored grant covering `directory`.
    /// Returns `false` when no grant covers it.
    @discardableResult
    static func activate(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if active.keys.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        guard let stored = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] else {
            return false
        }
        for (grantedPath, data) in stored where path == grantedPath || path.hasPrefix(grantedPath + "/") {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() else { continue }
            active[grantedPath] = url
            return true
        }
        return false
    }

    /// Asks the reader to grant the folder, then persists the grant.
    static func requestAccess(to directory: URL, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = "Allow"
        panel.message = "Allow Readdown to read images from this folder."

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            completion(store(url))
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    private static func store(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        let path = url.standardizedFileURL.path
        var stored = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        stored[path] = data
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
        lock.lock()
        if url.startAccessingSecurityScopedResource() {
            active[path] = url
        }
        lock.unlock()
        return true
    }
}

/// Serves the images a document references, and nothing else: the request must
/// resolve to an image file inside the document's own directory tree.
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let queue = DispatchQueue(label: "com.heya.readdown.localresource", qos: .userInitiated)
    private var stopped = Set<ObjectIdentifier>()

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = LocalResource.fileURL(for: url),
              isInsideRoot(fileURL),
              let type = UTType(filenameExtension: fileURL.pathExtension),
              type.conforms(to: .image) else {
            finish(urlSchemeTask, with: URLError(.unsupportedURL))
            return
        }

        FolderAccess.activate(root)
        let id = ObjectIdentifier(urlSchemeTask)
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try Data(contentsOf: fileURL, options: .mappedIfSafe) }
            DispatchQueue.main.async {
                guard self.stopped.remove(id) == nil else { return }
                switch result {
                case .success(let data):
                    let response = URLResponse(
                        url: url,
                        mimeType: type.preferredMIMEType ?? "application/octet-stream",
                        expectedContentLength: data.count,
                        textEncodingName: nil
                    )
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                case .failure(let error):
                    if (error as? CocoaError)?.code == .fileReadNoPermission {
                        NotificationCenter.default.post(name: .localResourceAccessDenied, object: self.root)
                    }
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }

    private func isInsideRoot(_ fileURL: URL) -> Bool {
        let path = fileURL.path
        return path == root.path || path.hasPrefix(root.path + "/")
    }

    private func finish(_ task: WKURLSchemeTask, with error: Error) {
        task.didFailWithError(error)
    }
}
