import AppKit
import QuartzCore

enum CodexGenieGeometry {
    static let deformationDuration = 0.5896
    static let materialDuration = 0.5808
    static let closingMaterialDuration = 0.12
    static let duration = deformationDuration + materialDuration
    static let handoffPhase = CGFloat(deformationDuration / duration)

    // Keep the approved opening handoff; closing only needs a brief snapshot takeover.
    static func timelineTime(at progress: CGFloat, showing: Bool) -> Double {
        let p = min(1, max(0, progress))
        if showing { return Double(p) * duration }
        return Double(min(1, p / handoffPhase)) * deformationDuration
            + Double(max(0, (p - handoffPhase) / (1 - handoffPhase))) * closingMaterialDuration
    }

    static func phase(atTimelineTime time: Double, showing: Bool) -> CGFloat {
        if showing { return min(1, max(0, CGFloat(time / duration))) }
        if time <= deformationDuration {
            return handoffPhase * min(1, max(0, CGFloat(time / deformationDuration)))
        }
        return handoffPhase + (1 - handoffPhase)
            * min(1, max(0, CGFloat((time - deformationDuration) / closingMaterialDuration)))
    }

    static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return min(1, max(0, t * t * t * (10 + t * (-15 + 6 * t))))
    }

    static func materialOpacity(at progress: CGFloat) -> CGFloat {
        smooth((progress - handoffPhase) / (1 - handoffPhase))
    }

    static func edge(at fraction: CGFloat, progress: CGFloat, rect: CGRect, source: CGPoint) -> (center: CGPoint, width: CGFloat) {
        // Finish deforming before the live material dominates the handoff.
        let p = min(1, max(0, progress / handoffPhase)), u = min(1, max(0, fraction))
        if p == 0 { return (source, 0) }
        if p == 1 { return (CGPoint(x: rect.midX, y: rect.minY + rect.height * u), rect.width) }
        let delay = 0.38 * (1 - u)
        let spread = smooth((p - delay) / (1 - delay))
        let neck = min(14, rect.width) * smooth(p / 0.12)
        let top = source.y + (rect.minY - source.y) * smooth((p - 0.22) / 0.78)
        let bottom = source.y + (rect.maxY - source.y) * smooth(p)
        return (CGPoint(x: source.x + (rect.midX - source.x) * spread,
                        y: top + (bottom - top) * u), neck + (rect.width - neck) * spread)
    }

    static func strip(from start: CGFloat, to end: CGFloat, progress: CGFloat, rect: CGRect, source: CGPoint) -> (position: CGPoint, transform: CATransform3D) {
        let top = edge(at: start, progress: progress, rect: rect, source: source)
        let bottom = edge(at: end, progress: progress, rect: rect, source: source)
        let height = rect.height * (end - start)
        guard top.width > 0, bottom.width > 0, height > 0 else {
            return (source, CATransform3DMakeScale(0, 0, 1))
        }
        let ratio = top.width / bottom.width
        var transform = CATransform3DIdentity
        transform.m11 = top.width / rect.width
        transform.m21 = (bottom.center.x - top.center.x) * ratio / height
        transform.m22 = (bottom.center.y - top.center.y) * ratio / height
        transform.m24 = (ratio - 1) / height
        return (top.center, transform)
    }
}

/// Only the transition is rasterized; the hosted controls remain the source of truth.
@MainActor final class CodexGenieTransition {
    static let duration = CodexGenieGeometry.duration
    private weak var host: NSView?
    private var overlay: Overlay?
    private var strips: [(layer: CALayer, start: CGFloat, end: CGFloat)] = []
    private var rect = CGRect.zero
    private var source = CGPoint.zero
    private var startedAt = 0.0
    private var runningDuration = 0.0
    private var from: CGFloat = 0
    private var target: CGFloat = 0
    private var completionWork: DispatchWorkItem?
    private var handoffWork: DispatchWorkItem?
    private var generation = 0
    var isAnimating: Bool { overlay != nil }

    private final class Overlay: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    @discardableResult
    func animate(host: NSView, snapshotRect: NSRect, source: CGPoint, showing: Bool, completion: @escaping () -> Void) -> Bool {
        guard let parent = host.superview,
              [snapshotRect.minX, snapshotRect.minY, snapshotRect.width, snapshotRect.height, source.x, source.y].allSatisfy(\.isFinite),
              snapshotRect.width > 0, snapshotRect.height > 0,
              CGRect(origin: .zero, size: host.bounds.size).contains(snapshotRect) else {
            cancel()
            return false
        }
        let reversing = self.host === host && overlay?.superview === parent && rect == snapshotRect && self.source == source
        let current = reversing ? progress(at: CACurrentMediaTime()) : (showing ? CGFloat(0) : 1)
        if !reversing {
            cancel()
            host.layoutSubtreeIfNeeded()
            let nativeRect = CGRect(x: host.bounds.minX + snapshotRect.minX,
                                    y: host.isFlipped ? host.bounds.minY + snapshotRect.minY : host.bounds.maxY - snapshotRect.maxY,
                                    width: snapshotRect.width, height: snapshotRect.height)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: nativeRect) else { return false }
            host.cacheDisplay(in: nativeRect, to: bitmap)
            guard let image = bitmap.cgImage, image.width > 0, image.height > 0 else { return false }
            let overlay = Overlay(frame: host.frame)
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true
            guard let root = overlay.layer else { return false }
            root.isGeometryFlipped = true
            root.masksToBounds = false
            let count = min(40, image.height)
            var slices: [(layer: CALayer, start: CGFloat, end: CGFloat)] = []
            for index in 0..<count {
                let first = index * image.height / count
                let last = (index + 1) * image.height / count
                guard let slice = image.cropping(to: CGRect(x: 0, y: first, width: image.width, height: last - first)) else { return false }
                let start = CGFloat(first) / CGFloat(image.height), end = CGFloat(last) / CGFloat(image.height)
                let layer = CALayer()
                layer.contents = slice
                layer.contentsScale = CGFloat(image.width) / snapshotRect.width
                layer.contentsGravity = .resize
                layer.minificationFilter = .linear
                layer.magnificationFilter = .linear
                layer.allowsEdgeAntialiasing = false
                layer.anchorPoint = CGPoint(x: 0.5, y: 0)
                layer.bounds = CGRect(x: 0, y: 0, width: snapshotRect.width, height: snapshotRect.height * (end - start))
                root.addSublayer(layer)
                slices.append((layer, start, end))
            }
            self.host = host
            self.overlay = overlay
            self.strips = slices
            self.rect = snapshotRect
            self.source = source
            parent.addSubview(overlay, positioned: .above, relativeTo: host)
        }
        completionWork?.cancel()
        handoffWork?.cancel()
        handoffWork = nil
        generation += 1
        let token = generation
        from = current
        target = showing ? 1 : 0
        let firstTime = CodexGenieGeometry.timelineTime(at: from, showing: showing)
        let lastTime = CodexGenieGeometry.timelineTime(at: target, showing: showing)
        runningDuration = max(0.08, abs(lastTime - firstTime))
        let phases = (0...60).map {
            CodexGenieGeometry.phase(atTimelineTime: firstTime + (lastTime - firstTime) * Double($0) / 60, showing: showing)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep native backdrop compositing at full opacity throughout the handoff.
        // Only the opaque snapshot fades; reveal the host once its shape is settled.
        host.alphaValue = current >= CodexGenieGeometry.handoffPhase ? 1 : 0
        for strip in strips {
            let frames = phases.map {
                CodexGenieGeometry.strip(from: strip.start, to: strip.end, progress: $0, rect: rect, source: source)
            }
            strip.layer.removeAllAnimations()
            strip.layer.position = frames.last!.position
            strip.layer.transform = frames.last!.transform
            let positions = CAKeyframeAnimation(keyPath: "position")
            positions.values = frames.map { NSValue(point: $0.position) }
            positions.duration = runningDuration
            let transforms = CAKeyframeAnimation(keyPath: "transform")
            transforms.values = frames.map { NSValue(caTransform3D: $0.transform) }
            transforms.duration = runningDuration
            let group = CAAnimationGroup()
            group.animations = [positions, transforms]
            group.duration = runningDuration
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            strip.layer.add(group, forKey: "genie")
        }
        if let layer = overlay?.layer {
            // Preserve the initial 70.4 ms reveal independently of the longer material handoff.
            let appearancePhase = CGFloat(0.0704 / Self.duration)
            let opacities = phases.map { min(1, $0 / appearancePhase) * (1 - CodexGenieGeometry.materialOpacity(at: $0)) }
            layer.removeAllAnimations()
            layer.opacity = Float(opacities.last!)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = opacities.map { NSNumber(value: Double($0)) }
            fade.duration = runningDuration
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(fade, forKey: "genie-opacity")
        }
        CATransaction.commit()
        startedAt = CACurrentMediaTime()
        let deadline = DispatchTime.now()
        let handoff = CodexGenieGeometry.handoffPhase
        if (from < handoff && target >= handoff) || (from >= handoff && target < handoff) {
            let enteringMaterial = target > from
            let handoffTime = CodexGenieGeometry.timelineTime(at: handoff, showing: showing)
            let delay = runningDuration * abs((handoffTime - firstTime) / (lastTime - firstTime))
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.host?.alphaValue = enteringMaterial ? 1 : 0
                self.handoffWork = nil
            }
            handoffWork = work
            DispatchQueue.main.asyncAfter(deadline: deadline + delay, execute: work)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancel()
            completion()
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: deadline + runningDuration, execute: work)
        return true
    }

    private func progress(at time: Double) -> CGFloat {
        guard runningDuration > 0 else { return target }
        let showing = target > from
        let first = CodexGenieGeometry.timelineTime(at: from, showing: showing)
        let last = CodexGenieGeometry.timelineTime(at: target, showing: showing)
        let fraction = min(1, max(0, (time - startedAt) / runningDuration))
        return CodexGenieGeometry.phase(atTimelineTime: first + (last - first) * fraction, showing: showing)
    }

    func cancel() {
        completionWork?.cancel()
        completionWork = nil
        handoffWork?.cancel()
        handoffWork = nil
        generation += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host?.alphaValue = 1
        overlay?.removeFromSuperview()
        CATransaction.commit()
        overlay = nil
        strips.removeAll()
        host = nil
    }
}
