import Foundation

public actor DuplicateScanner {
    private final class State {
        var session: ScanSession
        var errors: [String] = []
        var cacheHits = 0
        var lastUpdate = Date.distantPast
        var lastSave = Date.distantPast
        var persistenceFailed = false
        var lastSaveSucceeded = false
        var aliases: [String: [String]] = [:]
        let previousDirectoryPaths: Set<String>
        let started = Date()
        let previousElapsed: TimeInterval
        let sessionURL: URL?
        let progress: @Sendable (ScanProgress) -> Void
        init(session: ScanSession, sessionURL: URL?, progress: @escaping @Sendable (ScanProgress) -> Void) {
            self.session = session; self.sessionURL = sessionURL; self.progress = progress
            previousElapsed = session.elapsed
            previousDirectoryPaths = Set(session.directories.keys).union(session.pendingDirectories.map { $0.url.path })
                .union(session.blockedDirectories.map { $0.url.path })
        }
        func report(_ phase: ScanProgress.Phase, _ count: Int, _ done: Int, _ path: String, force: Bool = false) {
            session.phase = phase
            if force || Date().timeIntervalSince(lastUpdate) > 0.12 {
                progress(.init(phase: phase, discovered: count, processed: done, currentPath: path)); lastUpdate = Date()
            }
        }
        func save(force: Bool = false) {
            let interval: TimeInterval = session.files.count >= 50_000 ? 15 : session.files.count >= 10_000 ? 8 : 3
            guard let sessionURL, force || Date().timeIntervalSince(lastSave) > interval else { return }
            session.updatedAt = Date(); session.elapsed = previousElapsed + Date().timeIntervalSince(started)
            do { try ScanSessionStore.save(session, to: sessionURL); lastSaveSucceeded = true }
            catch {
                if !persistenceFailed { errors.append("任务保存失败：\(error.localizedDescription)") }
                persistenceFailed = true
                lastSaveSucceeded = false
            }
            lastSave = Date()
        }
        func remember(_ item: Work, hash: String, sample: Bool) {
            for path in aliases[item.stamp.identity] ?? [item.file.id] {
                guard path == item.file.id || !session.failedFiles.contains(path) else { continue }
                guard var entry = session.files[path], entry.stamp == item.stamp else { continue }
                if sample {
                    entry.sample = hash
                    if item.stamp.size <= 196608 { entry.full = hash }
                } else { entry.full = hash }
                session.files[path] = entry; session.failedFiles.remove(path)
            }
        }
    }
    private struct Cached: Codable, Sendable {
        let stamp: FileStamp
        var sample: String?
        var full: String?
    }
    private struct Work: Sendable { let file: FileRecord; let stamp: FileStamp }
    private struct Answer: Sendable { let work: Work; let hash: String?; let error: String? }
    private var cache: [String: Cached] = [:]
    private let cacheURL: URL?
    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let restored = try? JSONDecoder().decode([String: Cached].self, from: data) { cache = restored }
    }
    public func clearCache() throws {
        cache = [:]
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
            try Data("{}".utf8).write(to: cacheURL, options: .atomic)
        }
    }

    public func scan(roots: [URL], options requestedOptions: ScanOptions, control: ScanControl = ScanControl(),
                     sessionURL: URL? = nil, resume: Bool = false,
                     progress: @escaping @Sendable (ScanProgress) -> Void) async -> ScanResult {
        let session: ScanSession
        do {
            if resume {
                guard let sessionURL else { throw ScanSessionStore.StoreError.invalidPaths }
                session = try ScanSessionStore.load(sessionURL)
            } else {
                try ScanSessionStore.validate(roots: roots, options: requestedOptions)
                session = ScanSession(roots: roots.map(\.standardizedFileURL), options: requestedOptions)
            }
        } catch {
            var result = ScanResult(groups: [], similarImageGroups: [], scannedFiles: 0,
                                    errors: [error.localizedDescription], duration: 0)
            result.isIncomplete = true
            return result
        }
        let options = session.options
        let state = State(session: session, sessionURL: sessionURL, progress: progress)
        state.session.status = .running
        // Save the frontier before issuing an SMB call, which can block inside the OS.
        state.save(force: true)
        if resume { validateSession(state, control: control) }
        if !control.isCancelled { await discover(state, options: options, control: control) }

        // Inventory every pathname for folder comparisons; count hardlinks once as file copies.
        var work: [Work] = [], firstPathByIdentity: [String: String] = [:]
        let blockedScopes = (state.session.pendingDirectories + state.session.blockedDirectories).map { $0.url.path }
        for entry in state.session.files.values {
            guard state.session.directories[entry.file.url.deletingLastPathComponent().path] != nil,
                  !blockedScopes.contains(where: { ScanSessionStore.within(entry.file.id, $0) }) else { continue }
            if let first = firstPathByIdentity[entry.stamp.identity] {
                if state.aliases[entry.stamp.identity] == nil { state.aliases[entry.stamp.identity] = [first] }
                state.aliases[entry.stamp.identity]!.append(entry.file.id)
            } else {
                firstPathByIdentity[entry.stamp.identity] = entry.file.id
                work.append(.init(file: entry.file, stamp: entry.stamp))
            }
        }
        firstPathByIdentity.removeAll(keepingCapacity: false)
        if !control.isCancelled {
            if options.mode == .reference || options.detectDuplicateFolders {
                _ = await hashes(work, sample: false, options: options, control: control, state: state)
            } else {
                let candidates = Dictionary(grouping: work, by: { $0.file.size }).values.filter { $0.count > 1 }.flatMap { $0 }
                let sampled = await hashes(candidates, sample: true, options: options, control: control, state: state)
                if !control.isCancelled {
                    _ = await hashes(sampled.values.filter { $0.count > 1 }.flatMap { $0 },
                                     sample: false, options: options, control: control, state: state)
                }
            }
        }
        var full: [String: [FileRecord]] = [:]
        for item in work {
            if let hash = state.session.files[item.file.id]?.full { full[hash, default: []].append(item.file) }
        }
        var groups = full.filter { $0.value.count > 1 }.map {
            DuplicateGroup(hash: $0.key, files: $0.value.sorted { $0.id < $1.id })
        }.sorted { $0.reclaimableBytes != $1.reclaimableBytes ? $0.reclaimableBytes > $1.reclaimableBytes : $0.id < $1.id }
        if options.mode == .reference { groups = LibraryComparison.crossGroups(groups, referencePaths: options.referencePaths) }
        var similar: [SimilarImageGroup] = []
        if options.similarImages && !control.isCancelled {
            state.save(force: true)
            let images = work.filter { ImageSimilarity.isSupported($0.file.url) }.sorted { $0.file.id < $1.file.id }
            var prints: [(FileRecord, ImageSimilarity.Signature)] = []
            for (index, item) in images.enumerated() {
                do {
                    try control.checkpoint()
                    let hash: ImageSimilarity.Signature
                    if let saved = state.session.files[item.file.id]?.imageSignature,
                       try FileStamp.read(item.file.url) == item.stamp {
                        hash = saved; state.cacheHits += 1
                    } else { hash = try autoreleasepool { try ImageSimilarity.differenceHash(item.file.url) } }
                    guard try FileStamp.read(item.file.url) == item.stamp else { throw VerificationError.changed }
                    state.session.files[item.file.id]?.imageSignature = hash
                    prints.append((item.file, hash))
                } catch is CancellationError { break }
                catch {
                    state.errors.append("\(item.file.url.path): \(error.localizedDescription)")
                    state.session.failedFiles.insert(item.file.id)
                    state.session.files[item.file.id]?.imageSignature = nil
                }
                state.report(.analyzingImages, images.count, index + 1, item.file.url.path); state.save()
            }
            if !control.isCancelled {
                similar = ImageSimilarity.makeGroups(prints, threshold: options.similarityThreshold, control: control)
                if options.mode == .reference {
                    similar = similar.filter { group in
                        group.files.contains { LibraryComparison.isReference($0, referencePaths: options.referencePaths) }
                        && group.files.contains { !LibraryComparison.isReference($0, referencePaths: options.referencePaths) }
                    }
                }
            }
        }
        let contentHashes = state.session.files.compactMapValues(\.full)
        var folderGroups: [DuplicateFolderGroup] = []
        if options.detectDuplicateFolders && !control.isCancelled {
            state.report(.comparingFolders, work.count, 0, "", force: true); state.save(force: true)
            let incomplete = Set((state.session.blockedDirectories + state.session.pendingDirectories).map { $0.url.path })
                .union(state.session.failedFiles.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
                .union(state.session.shallowDirectories)
            folderGroups = LibraryComparison.duplicateFolders(files: state.session.files.values.map(\.file),
                hashes: contentHashes, directories: state.session.directories.values.map(\.task.url),
                referencePaths: options.referencePaths, mode: options.mode, control: control,
                incompleteDirectories: incomplete)
        }
        let pending = Set((state.session.pendingDirectories + state.session.blockedDirectories).map { $0.url.path })
            .union(state.session.failedFiles)
        let incomplete = control.isCancelled || !pending.isEmpty
        let unique = options.mode == .reference && !incomplete
            ? LibraryComparison.uniqueTargets(files: work.map(\.file), hashes: contentHashes, referencePaths: options.referencePaths) : []
        if cache.count > 50000 { cache = Dictionary(uniqueKeysWithValues: cache.prefix(50000).map { ($0.key, $0.value) }) }
        if let cacheURL {
            do {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
            } catch { state.errors.append("本地缓存保存失败：\(error.localizedDescription)") }
        }
        var result = ScanResult(groups: groups, similarImageGroups: similar, scannedFiles: work.count,
                                errors: state.errors, duration: state.previousElapsed + Date().timeIntervalSince(state.started),
                                wasCancelled: control.isCancelled, cacheHits: state.cacheHits)
        result.mode = options.mode; result.referencePaths = options.mode == .reference ? options.referencePaths : []
        result.uniqueFiles = unique; result.duplicateFolderGroups = folderGroups
        result.isIncomplete = incomplete; result.pendingPaths = pending.sorted()
        result.sessionID = sessionURL == nil ? nil : state.session.id
        result.sessionSaved = sessionURL != nil
        state.session.status = control.isCancelled ? .interrupted : incomplete ? .needsRetry : .completed
        state.session.result = result; state.save(force: true)
        result.errors = state.errors
        result.sessionSaved = state.lastSaveSucceeded
        state.report(.finished, work.count, work.count, "", force: true)
        return result
    }

    private func validateSession(_ state: State, control: ScanControl) {
        let options = state.session.options
        state.report(.validatingSession, state.session.files.count, 0, "", force: true)
        state.session.pendingDirectories.append(contentsOf: state.session.blockedDirectories)
        state.session.blockedDirectories = []
        for path in state.session.failedFiles where state.session.files[path] == nil {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            let recursive = state.session.directories[parent.path]?.task.recursive ?? options.recursive
            state.session.pendingDirectories.append(.init(url: parent, recursive: recursive))
            state.session.directories.removeValue(forKey: parent.path)
        }
        state.session.failedFiles = []
        var invalidated: [String] = []
        for (path, directory) in state.session.directories.sorted(by: { $0.key.count < $1.key.count }) {
            if (try? control.checkpoint()) == nil { return }
            guard !invalidated.contains(where: { ScanSessionStore.within(path, $0) }) else { continue }
            let disconnected = state.session.networkRoots.contains(path)
                && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) != false
            if disconnected || (try? DirectoryStamp.read(directory.task.url)) != directory.stamp {
                invalidated.append(path); state.session.pendingDirectories.append(directory.task)
            }
            state.save()
        }
        for path in invalidated {
            state.session.directories = state.session.directories.filter { !ScanSessionStore.within($0.key, path) }
            state.session.shallowDirectories = state.session.shallowDirectories.filter { !ScanSessionStore.within($0, path) }
        }
        for (index, entry) in state.session.files.values.sorted(by: { $0.file.id < $1.file.id }).enumerated() {
            if (try? control.checkpoint()) == nil { return }
            // A changed ancestor may now be a symlink or disconnected mount. Rediscover it before
            // touching any descendants; a successful listing refreshes their stamps below.
            guard state.session.directories[entry.file.url.deletingLastPathComponent().path] != nil else { continue }
            do {
                let stamp = try FileStamp.read(entry.file.url)
                if stamp != entry.stamp {
                    let info = try entry.file.url.resourceValues(forKeys: [.volumeIsLocalKey, .contentModificationDateKey])
                    let size = UInt64(max(0, stamp.size))
                    if accepts(entry.file.url, size: size, options: options) {
                        state.session.files[entry.file.id] = .init(file: .init(url: entry.file.url, size: size,
                            modifiedAt: info.contentModificationDate, isNetworkVolume: info.volumeIsLocal != true), stamp: stamp)
                    } else { state.session.files.removeValue(forKey: entry.file.id) }
                }
            } catch {
                state.session.files[entry.file.id]?.sample = nil; state.session.files[entry.file.id]?.full = nil
                state.session.files[entry.file.id]?.imageSignature = nil
                state.session.failedFiles.insert(entry.file.id)
            }
            state.report(.validatingSession, state.session.files.count, index + 1, entry.file.id); state.save()
        }
        state.session.pendingDirectories = Array(Set(state.session.pendingDirectories)).sorted { $0.url.path > $1.url.path }
        state.save(force: true)
    }

    private func accepts(_ url: URL, size: UInt64, options: ScanOptions) -> Bool {
        size >= options.minimumFileSize && (options.maximumFileSize.map { size <= $0 } ?? true)
            && (options.extensions.isEmpty || options.extensions.contains(url.pathExtension.lowercased()))
    }
    private func discover(_ state: State, options: ScanOptions, control: ScanControl) async {
        func excluded(_ url: URL) -> Bool {
            options.excludedPaths.contains { ScanSessionStore.within(url.standardizedFileURL.path, $0) }
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
            .fileSizeKey, .contentModificationDateKey, .volumeIsLocalKey]
        let oldFiles = Dictionary(grouping: state.session.files.keys, by: { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        let oldChildDirectories = Dictionary(grouping: state.previousDirectoryPaths, by: {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })
        func discardSubtree(_ path: String) {
            state.session.files = state.session.files.filter { !ScanSessionStore.within($0.key, path) }
            state.session.directories = state.session.directories.filter { !ScanSessionStore.within($0.key, path) }
            state.session.failedFiles = state.session.failedFiles.filter { !ScanSessionStore.within($0, path) }
            state.session.shallowDirectories = state.session.shallowDirectories.filter { !ScanSessionStore.within($0, path) }
            state.session.pendingDirectories.removeAll { ScanSessionStore.within($0.url.path, path) }
            state.session.blockedDirectories.removeAll { ScanSessionStore.within($0.url.path, path) }
        }
        while let task = state.session.pendingDirectories.last {
            if (try? control.checkpoint()) == nil { break }
            let directory = task.url
            if excluded(directory) { state.session.pendingDirectories.removeLast(); continue }
            if let completed = state.session.directories[directory.path], completed.task.recursive || !task.recursive {
                state.session.pendingDirectories.removeLast(); continue
            }
            do {
                if state.session.roots.contains(where: { $0.path == directory.path }) {
                    let isLocal = try URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
                    if state.session.networkRoots.contains(directory.path), isLocal != false {
                        throw ScanSessionStore.StoreError.networkDisconnected
                    }
                    if isLocal == false, state.session.networkRoots.insert(directory.path).inserted { state.save(force: true) }
                }
                let before = try DirectoryStamp.read(directory)
                // Foundation may enumerate /var through /private/var. Keep inventory keys,
                // FileRecord IDs and pending directory paths in the same normalized form.
                let urls = try await readDirectory(directory, keys: keys, options: options, control: control)
                    .map(\.standardizedFileURL)
                var children: [DirectoryTask] = []
                let present = Set(urls.map { $0.standardizedFileURL.path })
                state.session.shallowDirectories.remove(directory.path)
                for path in oldChildDirectories[directory.path] ?? [] where !present.contains(path) {
                    discardSubtree(path)
                }
                for path in oldFiles[directory.path] ?? [] where !present.contains(path) {
                    state.session.files.removeValue(forKey: path); state.session.failedFiles.remove(path)
                }
                // Only a successful ancestor listing confirms that a missing subtree was deleted.
                for path in state.session.failedFiles where ScanSessionStore.within(path, directory.path) {
                    let relative = String(path.dropFirst(directory.path == "/" ? 1 : directory.path.count + 1))
                    if let first = relative.split(separator: "/").first,
                       !present.contains(directory.appendingPathComponent(String(first)).path) {
                        state.session.files.removeValue(forKey: path); state.session.failedFiles.remove(path)
                    }
                }
                for url in urls {
                    try control.checkpoint()
                    guard !excluded(url) else { continue }
                    do {
                        let info = try url.resourceValues(forKeys: keys)
                        guard info.isSymbolicLink != true else {
                            if state.previousDirectoryPaths.contains(url.path) { discardSubtree(url.path) }
                            else { state.session.files.removeValue(forKey: url.path); state.session.failedFiles.remove(url.path) }
                            continue
                        }
                        if info.isDirectory == true {
                            state.session.files.removeValue(forKey: url.path); state.session.failedFiles.remove(url.path)
                            if task.recursive { children.append(.init(url: url, recursive: true)) }
                            else { state.session.shallowDirectories.insert(directory.path) }
                            continue
                        }
                        if state.previousDirectoryPaths.contains(url.path) { discardSubtree(url.path) }
                        let size = UInt64(max(0, info.fileSize ?? 0))
                        guard info.isRegularFile == true, accepts(url, size: size, options: options) else {
                            state.session.files.removeValue(forKey: url.path); state.session.failedFiles.remove(url.path); continue
                        }
                        let stamp = try FileStamp.read(url)
                        let old = state.session.files[url.path]
                        state.session.files[url.path] = .init(file: .init(url: url, size: UInt64(max(0, stamp.size)),
                            modifiedAt: info.contentModificationDate, isNetworkVolume: info.volumeIsLocal != true), stamp: stamp,
                            sample: old?.stamp == stamp ? old?.sample : nil, full: old?.stamp == stamp ? old?.full : nil)
                        if old?.stamp == stamp { state.session.files[url.path]?.imageSignature = old?.imageSignature }
                        state.session.failedFiles.remove(url.path)
                    } catch {
                        state.errors.append("\(url.path): \(error.localizedDescription)"); state.session.failedFiles.insert(url.path)
                        state.session.files[url.path]?.sample = nil; state.session.files[url.path]?.full = nil
                        state.session.files[url.path]?.imageSignature = nil
                    }
                    state.report(.discovering, state.session.files.count, 0, url.path, force: state.session.files.count == 1)
                    state.save()
                }
                let after = try DirectoryStamp.read(directory)
                guard before == after else { throw VerificationError.changed }
                state.session.pendingDirectories.removeLast()
                state.session.directories[directory.path] = .init(task: task, stamp: after)
                state.session.pendingDirectories.append(contentsOf: children)
            } catch is CancellationError { break }
            catch {
                state.errors.append("\(directory.path): \(error.localizedDescription)")
                state.session.pendingDirectories.removeLast(); state.session.blockedDirectories.append(task)
            }
            state.save()
        }
        state.save(force: true)
    }

    private func readDirectory(_ url: URL, keys: Set<URLResourceKey>, options: ScanOptions, control: ScanControl) async throws -> [URL] {
        var failure: Error = CocoaError(.fileReadUnknown)
        let retries = max(0, min(3, options.retryCount))
        for attempt in 0...retries {
            try control.checkpoint()
            do {
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                    options: options.includeHidden ? [] : [.skipsHiddenFiles])
            } catch {
                failure = error
                if attempt < retries { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
            }
        }
        throw failure
    }
    private func hashes(_ inputs: [Work], sample: Bool, options: ScanOptions, control: ScanControl, state: State) async -> [String: [Work]] {
        var outputs: [String: [Work]] = [:], pending: [Work] = []
        var done = 0
        let phase: ScanProgress.Phase = sample ? .fingerprinting : .hashing
        state.report(phase, inputs.count, 0, "", force: true); state.save()
        for item in inputs {
            if (try? control.checkpoint()) == nil { break }
            let stored = state.session.files[item.file.id]
            let savedHash = sample ? (stored?.sample ?? (item.stamp.size <= 196608 ? stored?.full : nil)) : stored?.full
            let cached = cache[item.file.id]
            let cacheHash = cached?.stamp == item.stamp ? (sample ? cached?.sample : cached?.full) : nil
            if let value = savedHash ?? cacheHash, (try? FileStamp.read(item.file.url)) == item.stamp {
                if sample { outputs[value, default: []].append(item) }; state.cacheHits += 1; done += 1
                state.remember(item, hash: value, sample: sample); state.save()
            } else { pending.append(item) }
        }
        for network in [false, true] {
            guard !control.isCancelled else { break }
            let batch = pending.filter { $0.file.isNetworkVolume == network }
            let limit = max(1, min(network ? options.networkConcurrency : options.localConcurrency, 8))
            await withTaskGroup(of: Answer.self) { group in
                var next = 0
                func submit(_ item: Work) {
                    group.addTask {
                        let retries = max(0, min(3, options.retryCount))
                        for attempt in 0...retries {
                            do {
                                try control.checkpoint()
                                let hash = try FileVerification.hash(item.file.url, expected: item.stamp, sample: sample, control: control)
                                return Answer(work: item, hash: hash, error: nil)
                            } catch is CancellationError { return Answer(work: item, hash: nil, error: nil) }
                            catch {
                                if !network || attempt == retries || error is VerificationError {
                                    return Answer(work: item, hash: nil, error: error.localizedDescription)
                                }
                                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                            }
                        }
                        return Answer(work: item, hash: nil, error: nil)
                    }
                }
                while next < min(limit, batch.count) { submit(batch[next]); next += 1 }
                while let answer = await group.next() {
                    done += 1
                    let item = answer.work
                    if let hash = answer.hash {
                        if sample { outputs[hash, default: []].append(item) }; state.remember(item, hash: hash, sample: sample)
                        var entry = cache[item.file.id].flatMap { $0.stamp == item.stamp ? $0 : nil } ?? Cached(stamp: item.stamp)
                        if sample { entry.sample = hash; if item.stamp.size <= 196608 { entry.full = hash } }
                        else { entry.full = hash }
                        if cache.count < 50000 || cache[item.file.id] != nil { cache[item.file.id] = entry }
                    }
                    if let error = answer.error {
                        state.errors.append("\(item.file.url.path): \(error)")
                        state.session.failedFiles.insert(item.file.id); state.session.files[item.file.id]?.full = nil
                    }
                    state.report(phase, inputs.count, done, item.file.url.path); state.save()
                    if next < batch.count && !control.isCancelled { submit(batch[next]); next += 1 }
                }
            }
        }
        state.save(force: true)
        return outputs
    }
}
