import AppKit
import Combine
import CryptoKit
import Darwin

// Only ordinary arrows are replaced. ArrowCtx is a contextual-menu badge.
enum PaperPlaneArtwork {
    static let size = CGSize(width: 32, height: 32)
    static let hotSpot = CGPoint(x: 4, y: 3)

    static func normalizedSize(_ value: Double) -> Double {
        value.isFinite ? min(1.75, max(0.75, value)) : 1
    }

    static func image(scale: Int, magnification: Double = 1) -> CGImage {
        precondition((1...4).contains(scale))
        let factor = normalizedSize(magnification)
        let pixels = Int((32 * factor * Double(scale)).rounded())
        let context = CGContext(data: nil, width: pixels, height: pixels,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 32, y: CGFloat(pixels) / 32)
        context.translateBy(x: 0, y: 32)
        context.scaleBy(x: 1, y: -1)
        let outline = CGMutablePath()
        // Long tangent transitions remain visibly rounded at normal cursor sizes.
        outline.move(to: CGPoint(x: 5.6, y: 7))
        outline.addQuadCurve(to: CGPoint(x: 8, y: 4.6), control: CGPoint(x: 2.7, y: 1.7))
        outline.addLine(to: CGPoint(x: 23.5, y: 10.8))
        outline.addQuadCurve(to: CGPoint(x: 23.5, y: 14.6), control: CGPoint(x: 28.8, y: 12.8))
        outline.addLine(to: CGPoint(x: 19.1, y: 16.7))
        outline.addQuadCurve(to: CGPoint(x: 17.8, y: 18), control: CGPoint(x: 18.2, y: 17.1))
        outline.addLine(to: CGPoint(x: 15.7, y: 23))
        outline.addQuadCurve(to: CGPoint(x: 11.9, y: 22.85), control: CGPoint(x: 13.8, y: 28.1))
        outline.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0.35, height: 0.9), blur: 1.1,
                          color: CGColor(gray: 0, alpha: 0.32))
        context.addPath(outline)
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(outline)
        context.clip()
        let wingGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                      colors: [CGColor(gray: 0.13, alpha: 1),
                                               CGColor(gray: 0.035, alpha: 1),
                                               CGColor(gray: 0.012, alpha: 1)] as CFArray,
                                      locations: [0, 0.45, 1])!
        context.drawLinearGradient(wingGradient, start: CGPoint(x: 9, y: 5),
                                   end: CGPoint(x: 20, y: 20), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: 5.5, y: 5.1))
        fold.addLine(to: CGPoint(x: 18.2, y: 17.1))
        fold.addLine(to: CGPoint(x: 13.8, y: 27))
        fold.closeSubpath()
        context.saveGState()
        context.addPath(fold)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 0.25, alpha: 1), CGColor(gray: 0.075, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 8, y: 7),
                                   end: CGPoint(x: 15, y: 26), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
        // A shaded crease and a narrow highlight give the two solid faces depth.
        context.move(to: CGPoint(x: 6.1, y: 5.2))
        context.addLine(to: CGPoint(x: 18.6, y: 17))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        context.setLineWidth(0.85)
        context.setLineCap(.round)
        context.strokePath()
        context.move(to: CGPoint(x: 5.7, y: 5.2))
        context.addLine(to: CGPoint(x: 18, y: 17.1))
        context.setStrokeColor(CGColor(gray: 0.6, alpha: 0.6))
        context.setLineWidth(0.45)
        context.strokePath()
        context.restoreGState()
        context.addPath(outline)
        context.setStrokeColor(CGColor(gray: 0.82, alpha: 0.8))
        context.setLineWidth(0.55)
        context.setLineJoin(.round)
        context.strokePath()
        return context.makeImage()!
    }

    static func preview(magnification: Double = 1) -> NSImage {
        let factor = normalizedSize(magnification)
        return NSImage(cgImage: image(scale: 3, magnification: factor),
                       size: CGSize(width: 32 * factor, height: 32 * factor))
    }
}

struct PointerImage: Codable {
    var size: CGSize
    var hotSpot: CGPoint
    var frames: Int
    var duration: Double
    var pngs: [Data]

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PointerError.message(Brand.localized("Unable to save original pointer images; the pointer was not changed."))
        }
        return data
    }

    func images() throws -> [CGImage] {
        guard size.width > 0, size.width <= 256, size.height > 0, size.height <= 256,
              hotSpot.x >= 0, hotSpot.x < size.width, hotSpot.y >= 0, hotSpot.y < size.height,
              frames == 1, duration.isFinite, duration >= 0, (1...8).contains(pngs.count) else {
            throw PointerError.message(Brand.localized("The pointer backup format is invalid; changes were stopped."))
        }
        return try pngs.map {
            guard let image = NSBitmapImageRep(data: $0)?.cgImage,
                  image.width <= 2048, image.height <= 2048 else {
                throw PointerError.message(Brand.localized("Unable to read a pointer backup image."))
            }
            return image
        }
    }

    func matches(_ other: PointerImage) throws -> Bool {
        // WindowServer round-trips cursor geometry through single-precision floats.
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
        guard same(size.width, other.size.width), same(size.height, other.size.height),
              same(hotSpot.x, other.hotSpot.x), same(hotSpot.y, other.hotSpot.y), frames == other.frames,
              duration == other.duration else { return false }
        func signatures(_ value: PointerImage) throws -> [String] {
            try value.images().map { image in
                guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PointerError.message(Brand.localized("Unable to validate a pointer image."))
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let pixels = Data(bytes: context.data!, count: context.bytesPerRow * context.height)
                return "\(image.width)x\(image.height):\(SHA256.hash(data: pixels))"
            }.sorted()
        }
        return try signatures(self) == signatures(other)
    }

    static func paperPlane(magnification: Double = 1) throws -> PointerImage {
        let factor = PaperPlaneArtwork.normalizedSize(magnification)
        return try PointerImage(size: CGSize(width: 32 * factor, height: 32 * factor),
                         hotSpot: CGPoint(x: 4 * factor, y: 3 * factor),
                         frames: 1, duration: 0, pngs: (1...4).map {
                             try png(PaperPlaneArtwork.image(scale: $0, magnification: factor))
                         })
    }
}

enum PointerError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case let .message(text): return text } }
}

// ABI references: alexzielenski/Mousecape, mousecloak/CGSInternal/CGSCursor.h.
// Dynamic lookup keeps unsupported macOS versions from failing at app launch.
struct PointerRegistry {
    var read: (String) throws -> PointerImage
    var write: (String, PointerImage) throws -> Void
    static let arrowNames = ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS"]

    static func system() throws -> PointerRegistry {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY) else {
            throw PointerError.message(Brand.localized("This macOS version does not support the paper-plane pointer."))
        }
        // The function pointers live as long as the process; retain the library handle.
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else {
                throw PointerError.message(Brand.localized("This macOS version is missing the pointer interface; the pointer was not changed."))
            }
            return unsafeBitCast(address, to: T.self)
        }
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> Int32
        typealias Register = @convention(c) (Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint, Int, Double, CFArray, UnsafeMutablePointer<Int32>) -> Int32
        let connection = try symbol("CGSMainConnectionID", Connection.self)()
        let copy = try symbol("CGSCopyRegisteredCursorImages", Copy.self)
        let register = try symbol("CGSRegisterCursorWithImages", Register.self)
        return PointerRegistry(read: { name in
            var size = CGSize.zero, hotSpot = CGPoint.zero, frames = 0, duration = 0.0
            var result: Unmanaged<CFArray>?
            let error = copy(connection, name, &size, &hotSpot, &frames, &duration, &result)
            let array = result?.takeRetainedValue()
            guard error == 0, let images = array as? [CGImage], !images.isEmpty else {
                throw PointerError.message(Brand.localized("Unable to read the system arrow (%@); this pointer was not changed.", error))
            }
            return try PointerImage(size: size, hotSpot: hotSpot, frames: frames, duration: duration,
                                    pngs: images.map { try PointerImage.png($0) })
        }, write: { name, image in
            let images = try image.images()
            var seed: Int32 = 0
            let error = register(connection, name, true, true, image.size, image.hotSpot,
                                 image.frames, image.duration, images as CFArray, &seed)
            guard error == 0 else { throw PointerError.message(Brand.localized("The system did not accept the pointer change (%d).", error)) }
        })
    }
}

// The journal is written before registration, including for a partially failed enable.
// ponytail: recover after a crash on next launch; no always-running recovery daemon.
final class PointerTheme {
    struct Journal: Codable {
        var originals: [String: PointerImage]
        var installed: PointerImage
    }
    let registry: PointerRegistry
    let journalURL: URL

    init(registry: PointerRegistry, journalURL: URL) {
        self.registry = registry
        self.journalURL = journalURL
    }

    static var systemUsesCustomizedColors: Bool {
        let domain = "com.apple.universalaccess" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("cursorIsCustomized" as CFString, domain) as? NSNumber)?.boolValue ?? false
    }

    func enable(customizedColors: Bool, magnification: Double = 1) throws {
        try restore()
        guard !customizedColors else {
            throw PointerError.message(Brand.localized("Custom system pointer colors limit the paper-plane pointer to areas such as the Dock. Restore pointer colors in System Settings → Accessibility → Display → Pointer, then enable this feature again."))
        }
        let image = try PointerImage.paperPlane(magnification: magnification)
        var originals: [String: PointerImage] = [:]
        // Arrow is required; ArrowS only exists on some system versions.
        originals[PointerRegistry.arrowNames[0]] = try registry.read(PointerRegistry.arrowNames[0])
        if let secondary = try? registry.read(PointerRegistry.arrowNames[1]) {
            originals[PointerRegistry.arrowNames[1]] = secondary
        }
        for original in originals.values { _ = try original.images() }
        let journal = Journal(originals: originals, installed: image)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(journal).write(to: journalURL, options: .atomic)
        do {
            for name in originals.keys.sorted() {
                try registry.write(name, image)
            }
            // Both names must be registered before reading either alias.
            for name in originals.keys.sorted() {
                let received = try registry.read(name)
                guard try received.matches(image) else {
                    throw PointerError.message(Brand.localized("System pointer verification failed; the original pointer was restored."))
                }
            }
        } catch {
            // No event-loop yield: rollback our attempted writes even if registration was partial.
            try restore(force: true)
            throw error
        }
    }

    func restore(force: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal = try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard !journal.originals.isEmpty,
              Set(journal.originals.keys).isSubset(of: Set(PointerRegistry.arrowNames)) else {
            throw PointerError.message(Brand.localized("The pointer recovery record is invalid; changes were stopped."))
        }
        // Arrow reads through ArrowS on macOS 26: decide ownership before any write,
        // update both aliases, and only then verify the complete group.
        let restore = try journal.originals.sorted(by: { $0.key < $1.key }).filter { name, original in
            _ = try original.images()
            return try force || registry.read(name).matches(journal.installed)
        }
        for (name, original) in restore { try registry.write(name, original) }
        for (name, original) in restore {
            guard try registry.read(name).matches(original) else {
                throw PointerError.message(Brand.localized("The original pointer did not pass verification after restoration. Try restoring it again."))
            }
        }
        try FileManager.default.removeItem(at: journalURL)
    }
}

@MainActor final class PaperPlanePointerManager: ObservableObject {
    static let shared = PaperPlanePointerManager()
    @Published private(set) var enabled = false
    @Published private(set) var status = Brand.localized("The original pointer is restored when disabled; text selection and window resizing stay unchanged.")
    @Published private(set) var hasFailure = false
    @Published private(set) var colorConflict = false
    @Published private(set) var magnification = 1.0
    private var theme: PointerTheme?
    private var started = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var suspended = Set<String>()
    private let defaults = UserDefaults.standard
    private let preference = "paperPlanePointerEnabled"

    func start() {
        guard !started else { return }
        started = true
        magnification = PaperPlaneArtwork.normalizedSize(
            defaults.object(forKey: "paperPlanePointerSize") as? Double ?? 1)
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            theme = try PointerTheme(registry: .system(), journalURL: root.appendingPathComponent("InterestingNotch/Pointer/originals.plist"))
            try theme?.restore()
            if defaults.bool(forKey: preference) { setEnabled(true) }
        } catch { fail(error) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.checkColorCompatibility() }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.checkColorCompatibility() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.suspend("sleep") }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.resume("sleep") }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.suspend("session") }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume("session") }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, .init("com.apple.screenIsLocked")) { $0.suspend("lock") }
        observe(distributed, .init("com.apple.screenIsUnlocked")) { $0.resume("lock") }
    }

    func setEnabled(_ value: Bool) {
        do {
            guard let theme else { throw PointerError.message(Brand.localized("The system pointer interface is unavailable.")) }
            colorConflict = PointerTheme.systemUsesCustomizedColors
            if value && suspended.isEmpty {
                try theme.enable(customizedColors: colorConflict, magnification: magnification)
            } else { try theme.restore() }
            enabled = value
            defaults.set(value, forKey: preference)
            hasFailure = false
            status = value ? Brand.localized("Paper-plane pointer enabled; app-specific cursors remain controlled by their apps.") : Brand.localized("Original pointer restored.")
        } catch { fail(error) }
    }

    func setMagnification(_ value: Double, apply: Bool = true) {
        magnification = PaperPlaneArtwork.normalizedSize(value)
        guard apply else { return }
        defaults.set(magnification, forKey: "paperPlanePointerSize")
        if enabled { setEnabled(true) }
    }

    func checkColorCompatibility() {
        let wasConflicting = colorConflict
        colorConflict = PointerTheme.systemUsesCustomizedColors
        if enabled && colorConflict { setEnabled(true) }
        else if wasConflicting && !colorConflict && !enabled {
            // Re-run restoration as well, so an unrelated recovery failure isn't hidden.
            setEnabled(false)
        }
    }

    func openPointerSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        do { try theme?.restore() } catch { fail(error) }
        started = false
    }

    private func fail(_ error: Error) {
        enabled = false
        defaults.set(false, forKey: preference)
        hasFailure = true
        status = error.localizedDescription
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor @Sendable (PaperPlanePointerManager) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, observer))
    }

    private func suspend(_ reason: String) {
        suspended.insert(reason)
        do { try theme?.restore() } catch { fail(error) }
    }

    private func resume(_ reason: String) {
        suspended.remove(reason)
        if enabled && suspended.isEmpty { setEnabled(true) }
    }
}
