#if DEBUG && os(iOS)
import Darwin
import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Times a first scan of the person's own library on a real device, without
/// losing the database they already have.
///
/// `--bench-scan` parks the real `Application Support/flaccy` folder (the
/// database and everything indexed) under `Library/ScanBench` before anything
/// opens it, so the launch scans the real Documents folder into an empty
/// database the way a new install would; `--bench-fresh` also discards the
/// previous bench database and forgets that a library was ever indexed, and
/// `--bench-poison` drops files that only pretend to be audio into
/// `Documents/Bench Poison`. A generated library pushed to `Documents/Bench FLAC`
/// (`scripts/scan-bench/make-flac-library.py`) is scanned with the rest. Any
/// launch without `--bench-scan` puts the parked folder back and removes the
/// poison and the pushed library before the database opens. Enrichment,
/// watch sync, scrobble retries and history import stay off while it runs.
/// The bench logs `SCAN BENCH` lines: progress every five seconds with memory,
/// the worst main-thread stall and the worst wait for the database, one
/// `SCAN BENCH RESULT` line when the load settles, and fifteen seconds later
/// `SCAN BENCH MAIN` lines ranking where the main thread was busy, sampled in
/// process because Instruments cannot always attach to a device over the
/// network.
@MainActor
enum ScanBench {

    nonisolated static let launchArgument = "--bench-scan"
    private static let freshArgument = "--bench-fresh"
    private static let poisonArgument = "--bench-poison"
    private static let poisonFolder = "Bench Poison"
    private static let pushedFolder = "Bench FLAC"

    nonisolated private static var arguments: [String] { CommandLine.arguments }

    nonisolated static var isRequested: Bool { arguments.contains(launchArgument) }

    nonisolated(unsafe) private static var refusal: String?
    private static var restored = false
    private static var parkedNow = false
    private static var firstSongsMs: Double?
    private static var firstSongsCount = 0
    private static var observers: [NSObjectProtocol] = []
    private static var sawLoading = false
    private static var reported = false
    private static let watch = MainThreadWatch()
    private static let databaseWatch = DatabaseWaitWatch()
    private static let sampler = MainThreadSampler()

    private static var storeFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy", isDirectory: true)
    }

    private static var benchFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanBench", isDirectory: true)
    }

    private static var parkedStore: URL {
        benchFolder.appendingPathComponent("real-flaccy", isDirectory: true)
    }

    /// Runs first thing at launch, before logging and before anything opens the
    /// database: parks the real store for a bench launch, or puts it back for
    /// any other launch.
    static func prepare() {
        guard isRequested else {
            restoreParkedStore()
            return
        }
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: parkedStore.path) {
                try fileManager.createDirectory(at: benchFolder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: storeFolder.path) {
                    try fileManager.moveItem(at: storeFolder, to: parkedStore)
                } else {
                    try fileManager.createDirectory(at: parkedStore, withIntermediateDirectories: true)
                }
                parkedNow = true
            } else if arguments.contains(freshArgument) {
                try? fileManager.removeItem(at: storeFolder)
            }
        } catch {
            refusal = "could not park the real store: \(error.localizedDescription)"
            return
        }
        if arguments.contains(freshArgument) {
            LibraryStartupProbe.clear()
        }
        let poison = LibraryPaths.root.appendingPathComponent(poisonFolder, isDirectory: true)
        if arguments.contains(poisonArgument) {
            writePoison(into: poison)
        } else {
            try? fileManager.removeItem(at: poison)
        }
    }

    /// Puts the person's own store back in place of the bench's, and takes the
    /// poison out of their Documents folder.
    private static func restoreParkedStore() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: parkedStore.path) else { return }
        for folder in [poisonFolder, pushedFolder] {
            try? fileManager.removeItem(at: LibraryPaths.root.appendingPathComponent(folder, isDirectory: true))
        }
        try? fileManager.removeItem(at: storeFolder)
        guard (try? fileManager.moveItem(at: parkedStore, to: storeFolder)) != nil else { return }
        try? fileManager.removeItem(at: benchFolder)
        restored = true
    }

    /// Starts the clock, the main-thread watch and the five-second progress
    /// line. Called once logging is configured.
    static func start() {
        if restored {
            MidgarLog.info("SCAN BENCH RESTORED the real library store", category: .performance)
        }
        guard isRequested else { return }
        if let refusal {
            MidgarLog.error("SCAN BENCH REFUSED: \(refusal)", category: .performance)
            return
        }
        MidgarLog.info(
            "SCAN BENCH START parkedNow=\(parkedNow) fresh=\(arguments.contains(freshArgument)) "
                + "hadIndexed=\(LibraryStartupProbe.hadIndexedLibrary) launchedAgoMs=\(Int(sinceLaunchMs()))",
            category: .performance
        )
        watch.start()
        databaseWatch.start()
        sampler.start()
        observers.append(NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { noteLibraryUpdate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: Library.loadingStateChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { noteLoadingChange() }
        })
        Task { await reportProgress() }
    }

    /// Whether this launch is a bench that may run, so launch work that would
    /// reach the network or the watch on the person's behalf can stand down.
    nonisolated static var isRunning: Bool { isRequested && refusal == nil }

    /// Files a person's folder really does end up holding: an empty download, a
    /// renamed text file, random bytes, a FLAC with nothing after its marker,
    /// and a real song cut off a few kilobytes in.
    private static func writePoison(into folder: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var noise = Data(count: 2_000_000)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let files: [(String, Data)] = [
            ("01 Empty.flac", Data()),
            ("02 Notes.mp3", Data(String(repeating: "not a song\n", count: 500).utf8)),
            ("03 Noise.flac", noise),
            ("04 Noise.m4a", noise.prefix(500_000)),
            ("05 Marker Only.flac", Data("fLaC".utf8) + noise.prefix(64)),
        ]
        for (name, data) in files {
            fileManager.createFile(atPath: folder.appendingPathComponent(name).path, contents: data)
        }
        if let song = firstSong(under: LibraryPaths.root, excluding: folder),
           let head = try? FileHandle(forReadingFrom: song).read(upToCount: 96_000) {
            let name = "06 Cut Short." + song.pathExtension
            fileManager.createFile(atPath: folder.appendingPathComponent(name).path, contents: head)
        }
    }

    private static func firstSong(under root: URL, excluding folder: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        while let url = walker.nextObject() as? URL {
            guard !url.path.hasPrefix(folder.path) else { continue }
            if Library.audioExtensions.contains(url.pathExtension.lowercased()) { return url }
        }
        return nil
    }

    private static func noteLibraryUpdate() {
        let library = Library.shared
        guard firstSongsMs == nil, !library.allTracks.isEmpty else { return }
        firstSongsMs = sinceLaunchMs()
        firstSongsCount = library.allTracks.count
        MidgarLog.info(
            "SCAN BENCH FIRST SONGS at \(Int(firstSongsMs ?? 0)) ms: \(firstSongsCount) songs, "
                + "\(library.albums.count) albums, loading=\(library.isLoading)",
            category: .performance
        )
    }

    private static func noteLoadingChange() {
        let library = Library.shared
        if library.isLoading { sawLoading = true }
        guard !library.isLoading, sawLoading, !reported else { return }
        reported = true
        Task {
            try? await Task.sleep(for: .seconds(15))
            for line in sampler.report(top: 45) {
                MidgarLog.info("SCAN BENCH MAIN \(line)", category: .performance)
            }
        }
        let settled = sinceLaunchMs()
        let hangs = watch.snapshot()
        MidgarLog.info(
            "SCAN BENCH RESULT first_songs_ms=\(Int(firstSongsMs ?? -1)) first_songs=\(firstSongsCount) "
                + "settled_ms=\(Int(settled)) songs=\(library.allTracks.count) albums=\(library.albums.count) "
                + "peak_mb=\(Int(peakFootprint)) worst_hang_ms=\(Int(hangs.worst)) "
                + "hangs_over_250=\(hangs.over250) hangs_over_1000=\(hangs.over1000) "
                + "worst_db_wait_ms=\(Int(databaseWatch.snapshot().worst))",
            category: .performance
        )
    }

    private static var peakFootprint: Double = 0

    private static func reportProgress() async {
        while true {
            let footprint = footprintMB()
            peakFootprint = max(peakFootprint, footprint)
            let progress = Library.shared.loadProgress
            let hangs = watch.snapshot()
            MidgarLog.info(
                "SCAN BENCH t=\(Int(sinceLaunchMs())) ms phase=\(progress.phase) \(progress.completed)/\(progress.total) "
                    + "songs=\(Library.shared.allTracks.count) mb=\(Int(footprint)) peak_mb=\(Int(peakFootprint)) "
                    + "worst_hang_ms=\(Int(hangs.worst)) hangs_over_250=\(hangs.over250) "
                    + "worst_db_wait_ms=\(Int(databaseWatch.snapshot().worst))",
                category: .performance
            )
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Milliseconds since the kernel started this process, so time spent before
    /// `main` counts against the launch like a person would count it.
    nonisolated private static func sinceLaunchMs() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let started = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }

    nonisolated private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

/// Samples the main thread's stack every 5 ms from a thread of its own, for the
/// device Instruments cannot attach to: suspend, copy the program counter and
/// the frame-pointer chain into a buffer allocated up front (nothing may
/// allocate while the main thread is stopped, it may hold the malloc lock),
/// resume, then count each symbol once per sample. `report` lists the symbols
/// with the most samples in which the main thread was busy.
nonisolated private final class MainThreadSampler: @unchecked Sendable {

    private static let depth = 96
    private let lock = NSLock()
    private let mainThread: thread_act_t = mach_thread_self()
    private var inclusive: [UInt: Int] = [:]
    private var busySamples = 0
    private var idleSamples = 0
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: depth)

    func start() {
        let thread = Thread { [self] in
            while true {
                sampleOnce()
                usleep(5_000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func sampleOnce() {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        var frames = 0
        if read == KERN_SUCCESS {
            buffer[frames] = Self.strip(UInt(state.__pc)); frames += 1
            buffer[frames] = Self.strip(UInt(state.__lr)); frames += 1
            var framePointer = UInt(state.__fp)
            var pair: (UInt, UInt) = (0, 0)
            while frames < Self.depth, framePointer != 0, framePointer & 0x7 == 0 {
                var copied: vm_size_t = 0
                let status = withUnsafeMutablePointer(to: &pair) {
                    vm_read_overwrite(
                        mach_task_self_, vm_address_t(framePointer), vm_size_t(16),
                        vm_address_t(UInt(bitPattern: $0)), &copied
                    )
                }
                guard status == KERN_SUCCESS, pair.0 > framePointer else { break }
                buffer[frames] = Self.strip(pair.1); frames += 1
                framePointer = pair.0
            }
        }
        thread_resume(mainThread)
        guard frames > 0 else { return }
        let stack = Array(UnsafeBufferPointer(start: buffer, count: frames))
        let idle = Self.isIdle(stack.prefix(3))
        lock.withLock {
            if idle {
                idleSamples += 1
                return
            }
            busySamples += 1
            for pc in Set(stack) { inclusive[pc, default: 0] += 1 }
        }
    }

    func report(top: Int) -> [String] {
        let (counts, busy, idle) = lock.withLock { (inclusive, busySamples, idleSamples) }
        var bySymbol: [String: Int] = [:]
        for (pc, hits) in counts {
            let name = Self.symbol(pc)
            bySymbol[name] = max(bySymbol[name] ?? 0, hits)
        }
        let lines = bySymbol.sorted { $0.value > $1.value }.prefix(top).map { "\($0.value * 5) ms  \($0.key)" }
        return ["busy \(busy * 5) ms, idle \(idle * 5) ms"] + lines
    }

    private static func isIdle(_ top: ArraySlice<UInt>) -> Bool {
        top.contains { symbol($0).contains("mach_msg") }
    }

    private static func strip(_ address: UInt) -> UInt {
        address & 0x0000_000F_FFFF_FFFF
    }

    private static func symbol(_ pc: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0, let name = info.dli_sname else { return "?" }
        let mangled = String(cString: name)
        return demangle(mangled).prefix(140).description
    }

    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangler: Demangler? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangler.self)
    }()

    private static func demangle(_ mangled: String) -> String {
        guard let demangler else { return mangled }
        return mangled.withCString { pointer in
            guard let result = demangler(pointer, strlen(pointer), nil, nil, 0) else { return mangled }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

/// Times a one-row indexed lookup every 200 ms from a thread of its own: how
/// long any read, the main thread's included, waits for the database while the
/// scan and the listings use it.
nonisolated private final class DatabaseWaitWatch: @unchecked Sendable {

    private let lock = NSLock()
    private var worst: Double = 0

    func start() {
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func snapshot() -> MainThreadWatch.Snapshot {
        lock.withLock { MainThreadWatch.Snapshot(worst: worst, over250: 0, over1000: 0) }
    }

    private func loop() {
        while true {
            let sent = DispatchTime.now().uptimeNanoseconds
            _ = try? DatabaseManager.shared.fetchTrack(byRelativePath: "scan-bench-probe")
            let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            lock.withLock { worst = max(worst, waited) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}

/// Pings the main queue every 50 ms from a thread of its own and keeps the
/// worst wait and how many waits a person would have felt as a stall.
nonisolated private final class MainThreadWatch: @unchecked Sendable {

    struct Snapshot {
        let worst: Double
        let over250: Int
        let over1000: Int
    }

    private let lock = NSLock()
    private var worst: Double = 0
    private var over250 = 0
    private var over1000 = 0

    func start() {
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(worst: worst, over250: over250, over1000: over1000) }
    }

    private func loop() {
        while true {
            let sent = DispatchTime.now().uptimeNanoseconds
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            answered.wait()
            record(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func record(_ milliseconds: Double) {
        lock.withLock {
            worst = max(worst, milliseconds)
            if milliseconds > 250 { over250 += 1 }
            if milliseconds > 1000 { over1000 += 1 }
        }
    }
}
#endif
