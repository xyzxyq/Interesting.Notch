import AppKit

@main @MainActor struct PaperPlanePointerChecks {
    static func check(_ condition: Bool) { assert(condition) }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let root = URL(fileURLWithPath: "/tmp/interestingnotch-pointer/check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plane = try PointerImage.paperPlane()
        check(try plane.images().map(\.width) == [32, 64, 96, 128])
        assert(plane.hotSpot == CGPoint(x: 4, y: 3))
        for factor in [0.75, 1.0, 1.25, 1.75] {
            let resized = try PointerImage.paperPlane(magnification: factor)
            check(resized.size.width == 32 * factor)
            check(resized.hotSpot == CGPoint(x: 4 * factor, y: 3 * factor))
            check(try resized.images().map(\.width) == (1...4).map { Int((32 * factor * Double($0)).rounded()) })
        }
        check(PaperPlaneArtwork.normalizedSize(.nan) == 1)
        check(PaperPlaneArtwork.normalizedSize(0) == 0.75)
        check(PaperPlaneArtwork.normalizedSize(10) == 1.75)
        let fractional = try PointerImage.paperPlane(magnification: 1.05)
        var rounded = fractional
        rounded.size.width = CGFloat(Float(rounded.size.width))
        rounded.size.height = CGFloat(Float(rounded.size.height))
        rounded.hotSpot.x = CGFloat(Float(rounded.hotSpot.x))
        rounded.hotSpot.y = CGFloat(Float(rounded.hotSpot.y))
        check(try fractional.matches(rounded))
        rounded.hotSpot.x += 0.01
        check(try !fractional.matches(rounded))
        let encoded = try PropertyListEncoder().encode(plane)
        check(try plane.matches(PropertyListDecoder().decode(PointerImage.self, from: encoded)))
        var invalid = plane
        invalid.hotSpot.x = -1
        do { _ = try invalid.images(); fatalError("Invalid hotspot accepted") } catch {}
        // A different image, so a missing restore cannot pass the check.
        var original = plane
        original.hotSpot = CGPoint(x: 5, y: 4)
        var values = Dictionary(uniqueKeysWithValues: PointerRegistry.arrowNames.map { ($0, original) })
        var writes = 0
        var failWrite: Int?
        let registry = PointerRegistry(read: { name in
            guard let value = values[name] else { throw PointerError.message("missing") }
            return value
        }, write: { name, image in
            writes += 1
            if writes == failWrite { throw PointerError.message("write failed") }
            values[name] = image
        })
        let url = root.appendingPathComponent("originals.plist")
        let theme = PointerTheme(registry: registry, journalURL: url)
        try theme.enable(customizedColors: false)
        check(try values.values.allSatisfy { try $0.matches(plane) })
        // A fresh instance recovers the journal after an abnormal app exit.
        try PointerTheme(registry: registry, journalURL: url).restore()
        check(try values.values.allSatisfy { try $0.matches(original) })
        assert(!FileManager.default.fileExists(atPath: url.path))
        failWrite = writes + 2
        do { try theme.enable(customizedColors: false); fatalError("Partial failure accepted") } catch {}
        check(try values.values.allSatisfy { try $0.matches(original) })
        failWrite = nil
        try theme.enable(customizedColors: false)
        try theme.enable(customizedColors: false, magnification: 1.75)
        let enlarged = try PointerImage.paperPlane(magnification: 1.75)
        check(try values.values.allSatisfy { try $0.matches(enlarged) })
        try theme.enable(customizedColors: false) // must not back up the already-installed plane
        try theme.restore()
        check(try values.values.allSatisfy { try $0.matches(original) })
        try theme.enable(customizedColors: false)
        var foreign = original
        foreign.hotSpot = CGPoint(x: 7, y: 7)
        values[PointerRegistry.arrowNames[0]] = foreign
        try theme.restore()
        check(try values[PointerRegistry.arrowNames[0]]!.matches(foreign))
        try Data("invalid journal".utf8).write(to: url)
        let before = writes
        do { try theme.enable(customizedColors: false); fatalError("Corrupt journal accepted") } catch {}
        assert(writes == before)
        try FileManager.default.removeItem(at: url)
        // macOS 26 reads Arrow through ArrowS; verify only after the full batch.
        var aliased = original
        var pendingArrow = original
        let aliases = PointerRegistry(read: { _ in aliased }, write: { name, image in
            if name == PointerRegistry.arrowNames[0] { pendingArrow = image }
            else { aliased = image }
        })
        let aliasTheme = PointerTheme(registry: aliases, journalURL: url)
        try aliasTheme.enable(customizedColors: false)
        check(try aliased.matches(plane))
        try aliasTheme.restore()
        check(try aliased.matches(original))
        check(try pendingArrow.matches(original))
        // A failed restore must retain the recovery journal for another attempt.
        values = Dictionary(uniqueKeysWithValues: PointerRegistry.arrowNames.map { ($0, original) })
        try theme.enable(customizedColors: false)
        failWrite = writes + 1
        do { try theme.restore(); fatalError("Restore failure accepted") } catch {}
        assert(FileManager.default.fileExists(atPath: url.path))
        failWrite = nil
        try theme.restore()
        check(try values.values.allSatisfy { try $0.matches(original) })
        // An unwritable journal location prevents any system mutation.
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let blockedTheme = PointerTheme(registry: registry, journalURL: blocked.appendingPathComponent("backup.plist"))
        let writesBeforeBackup = writes
        do { try blockedTheme.enable(customizedColors: false); fatalError("Backup failure accepted") } catch {}
        assert(writes == writesBeforeBackup)
        // Customized system colors bypass registered arrows in ordinary AppKit windows.
        let beforeColorConflict = writes
        do { try theme.enable(customizedColors: true); fatalError("Color conflict accepted") } catch {}
        assert(writes == beforeColorConflict)
        assert(!FileManager.default.fileExists(atPath: url.path))
        try theme.enable(customizedColors: false)
        do { try theme.enable(customizedColors: true); fatalError("Active color conflict accepted") } catch {}
        check(try values.values.allSatisfy { try $0.matches(original) })
        assert(!FileManager.default.fileExists(atPath: url.path))
        try PointerImage.png(PaperPlaneArtwork.image(scale: 4)).write(to: URL(fileURLWithPath: "/tmp/interestingnotch-pointer/paper-plane.png"))
        print("Pointer checks passed: artwork, journal recovery, partial rollback, repeated enable, foreign theme, alias batch, restore retry, backup failure, system color conflict")
        if CommandLine.arguments.contains("--live") {
            let system = try PointerRegistry.system()
            try PointerTheme(registry: system, journalURL: URL(fileURLWithPath: "/tmp/interestingnotch-pointer/live-originals.plist")).restore()
            let originals = try Dictionary(uniqueKeysWithValues: PointerRegistry.arrowNames.map { ($0, try system.read($0)) })
            let preservedNames = ["com.apple.coregraphics.IBeam", "com.apple.coregraphics.ArrowCtx", "com.apple.coregraphics.Copy"]
            let preserved = try Dictionary(uniqueKeysWithValues: preservedNames.map { ($0, try system.read($0)) })
            let liveURL = URL(fileURLWithPath: "/tmp/interestingnotch-pointer/live-originals.plist")
            let live = PointerTheme(registry: system, journalURL: liveURL)
            defer { try? live.restore() }
            try live.enable(customizedColors: PointerTheme.systemUsesCustomizedColors)
            print("LIVE_APPLIED; restoring in 15 seconds")
            fflush(stdout)
            RunLoop.current.run(until: Date().addingTimeInterval(15))
            for name in originals.keys { check(try system.read(name).matches(plane)) }
            for (name, image) in preserved { check(try system.read(name).matches(image)) }
            for step in 15...35 {
                let factor = Double(step) / 20
                try live.enable(customizedColors: PointerTheme.systemUsesCustomizedColors, magnification: factor)
                let resized = try PointerImage.paperPlane(magnification: factor)
                for name in originals.keys { check(try system.read(name).matches(resized)) }
            }
            try live.restore()
            for (name, image) in originals { check(try system.read(name).matches(image)) }
            print("Live checks passed: both arrows registered, text and drag/context badges unchanged, originals restored")
        }
    }
}
