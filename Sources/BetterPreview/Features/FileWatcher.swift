import Foundation

/// Watches one file for changes without polling.
///
/// Two kernel event sources are kept: one on the file itself (writes in place)
/// and one on the nearest existing ancestor directory (atomic replace, rename,
/// delete-and-recreate as done by LaTeX, Typst and vim `:w`, and creation of a
/// file or directory that does not exist yet). Events are debounced; when the
/// quiet period ends the sources are re-armed (a replaced file is a new inode)
/// and `onChange` runs on the main queue only if the file's identity, size or
/// modification time actually changed, so unrelated activity in the same
/// directory is ignored.
@MainActor
final class FileWatcher {
    private struct Signature: Equatable {
        var device: dev_t, inode: ino_t, size: off_t, modified: timespec

        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private let path: String
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var signature: Signature?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileInode: ino_t?
    private var directorySource: DispatchSourceFileSystemObject?
    private var watchedDirectory: String?
    private var pending: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping () -> Void) {
        path = url.standardizedFileURL.path
        self.debounce = debounce
        self.onChange = onChange
        signature = Self.signature(of: path)
        arm()
    }

    isolated deinit { cancel() }

    func cancel() {
        pending?.cancel()
        pending = nil
        fileSource?.cancel()
        fileSource = nil
        fileInode = nil
        directorySource?.cancel()
        directorySource = nil
        watchedDirectory = nil
    }

    private func arm() {
        let current = Self.signature(of: path)
        if fileSource == nil || fileInode != current?.inode {
            fileSource?.cancel()
            fileSource = nil
            fileInode = nil
            if let current, let source = Self.source(path, [.write, .extend, .delete, .rename, .attrib, .link, .revoke],
                                                     handler: { [weak self] in self?.eventArrived() }) {
                fileSource = source
                fileInode = current.inode
            }
        }
        let directory = Self.nearestExistingDirectory(above: path)
        if directory != watchedDirectory {
            directorySource?.cancel()
            directorySource = Self.source(directory, [.write, .delete, .rename, .link],
                                          handler: { [weak self] in self?.eventArrived() })
            watchedDirectory = directorySource == nil ? nil : directory
        }
    }

    private func eventArrived() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func settle() {
        pending = nil
        arm()
        let current = Self.signature(of: path)
        guard current != signature else { return }
        signature = current
        // A deleted file is reported when it comes back, not while it is gone.
        if current != nil { onChange() }
    }

    // MARK: Helpers

    private static func source(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                               handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private static func signature(of path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Signature(device: info.st_dev, inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec)
    }

    private static func nearestExistingDirectory(above path: String) -> String {
        var directory = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        while directory != "/", !(FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
                                  && isDirectory.boolValue) {
            directory = (directory as NSString).deletingLastPathComponent
        }
        return directory
    }
}
