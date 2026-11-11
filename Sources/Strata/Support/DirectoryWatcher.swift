import Foundation

/// Calls `onChange` (debounced, on the main thread) when entries are added to, removed from, or renamed inside a
/// directory.
package nonisolated final class DirectoryWatcher: Sendable {
    private let source: DispatchSourceFileSystemObject

    /// Watchers of those of `urls` that open, opened and watching on a thread of their own before this returns: on a
    /// server that stopped answering, opening a folder waits, and nothing on the main thread waits with it. A change
    /// made after this returns is caught. One dropped stops watching and closes its folder.
    package static func watching(_ urls: [URL], onChange: @escaping @MainActor @Sendable () -> Void) async -> [DirectoryWatcher] {
        let paths = urls.map(\.path)
        return await OwnThread.run { paths.compactMap { DirectoryWatcher(path: $0, onChange: onChange) } }
    }

    private init?(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main)
        let debounce = Debounce(onChange)
        source.setEventHandler { MainActor.assumeIsolated { debounce.schedule() } }
        source.setCancelHandler {
            close(fd)
            MainActor.assumeIsolated { debounce.cancel() }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Calls `onChange` (debounced, on the main thread) when an item directly inside a folder changes where it is: a file
/// rewritten in place changes its contents, size and date but not the folder's entries, which is all a
/// `DirectoryWatcher` hears. File-level FSEvents for the folder; events deeper down are ignored.
package nonisolated final class FolderContentsWatcher: @unchecked Sendable {
    private let stream: FSEventStreamRef

    /// Watchers of those of `urls` that start, each started on a thread of its own before this returns.
    package static func watching(_ urls: [URL], onChange: @escaping @MainActor @Sendable () -> Void) async -> [FolderContentsWatcher] {
        let paths = urls.map(\.path)
        return await OwnThread.run { paths.compactMap { FolderContentsWatcher(path: $0, onChange: onChange) } }
    }

    private init?(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        // FSEvents reports real paths (/private/var, not /var); Foundation's resolving drops the /private.
        guard let resolved = realpath(path, nil) else { return nil }
        let real = String(cString: resolved)
        free(resolved)
        // The whole disk's file events for one folder's children: the folder's own watcher has to do there.
        guard real != "/" else { return nil }
        let context = FolderContentsContext(folder: real, debounce: Debounce(onChange))
        var streamContext = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(context).toOpaque(),
                                                 retain: nil, release: folderContentsRelease, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, folderContentsCallback, &streamContext, [real] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            Unmanaged.passUnretained(context).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, FolderContentsContext.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

private nonisolated final class FolderContentsContext: @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.strata.folder-contents", qos: .utility)
    let folder: String
    let debounce: Debounce
    /// When watching began. Changes made before can still arrive just after (FSEvents writes its log late); the
    /// folder's first read, which waits for this watcher, already has them.
    let start = Date().timeIntervalSince1970

    /// The file's contents or metadata changed after watching began, by its own clock, read without following links.
    func changedSinceStart(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        func seconds(_ time: timespec) -> Double { Double(time.tv_sec) + Double(time.tv_nsec) / 1e9 }
        return max(seconds(info.st_mtimespec), seconds(info.st_ctimespec)) >= start
    }

    init(folder: String, debounce: Debounce) {
        self.folder = folder
        self.debounce = debounce
    }

    /// A file changed where it is: its contents, size or metadata. A folder's own event (its contents changed, deeper
    /// down) is not a change to what the list shows of it, and entries coming and going are the `DirectoryWatcher`'s.
    /// FSEvents merges a path's recent flags, so a file made a moment ago and rewritten still says "created" too: what
    /// counts is that it was modified.
    static func isRewrite(_ flags: FSEventStreamEventFlags) -> Bool {
        let modified = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
            | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod
        return flags & UInt32(modified) != 0
            && flags & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0
    }

    func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard events.contains(where: { Self.isRewrite($0.flags) && ($0.path as NSString).deletingLastPathComponent == folder
                                       && changedSinceStart($0.path) })
        else { return }
        DispatchQueue.main.async { [debounce] in MainActor.assumeIsolated { debounce.schedule() } }
    }
}

nonisolated private func folderContentsCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                                                _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                                                _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info, count > 0 else { return }
    let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    Unmanaged<FolderContentsContext>.fromOpaque(info).takeUnretainedValue()
        .handle((0..<count).map { (String(cString: cPaths[$0]), flags[$0]) })
}

nonisolated private func folderContentsRelease(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    let context = Unmanaged<FolderContentsContext>.fromOpaque(info).takeRetainedValue()
    // Stopped with its stream: nothing scheduled after this runs.
    DispatchQueue.main.async { [debounce = context.debounce] in MainActor.assumeIsolated { debounce.cancel() } }
}

/// A burst of changes as one call, a moment after the last; none once its watcher has stopped.
@MainActor private final class Debounce {
    private let action: @MainActor @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private var stopped = false

    nonisolated init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func schedule() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.action()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancel() {
        stopped = true
        pending?.cancel()
    }
}
