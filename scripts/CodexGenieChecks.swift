import AppKit
import QuartzCore

@main struct CodexGenieChecks {
    static func main() {
        let rect = CGRect(x: 12, y: 64, width: 516, height: 536)
        let source = CGPoint(x: 240, y: 32)
        let handoff = CodexGenieGeometry.handoffPhase
        let materialMidpoint = (1 + handoff) / 2
        func transformed(_ point: CGPoint, by t: CATransform3D, position: CGPoint) -> CGPoint {
            let w = point.x * t.m14 + point.y * t.m24 + t.m44
            return CGPoint(x: position.x + (point.x * t.m11 + point.y * t.m21 + t.m41) / w,
                           y: position.y + (point.x * t.m12 + point.y * t.m22 + t.m42) / w)
        }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.00001 }
        for step in 0...100 {
            let p = CGFloat(step) / 100
            var previousBottom: CGPoint?
            for index in 0..<40 {
                let start = CGFloat(index) / 40, end = CGFloat(index + 1) / 40
                let row = CodexGenieGeometry.strip(from: start, to: end, progress: p, rect: rect, source: source)
                let top = CodexGenieGeometry.edge(at: start, progress: p, rect: rect, source: source)
                let bottom = CodexGenieGeometry.edge(at: end, progress: p, rect: rect, source: source)
                for side in [CGFloat(-1), 1] {
                    let a = transformed(CGPoint(x: rect.width * side / 2, y: 0), by: row.transform, position: row.position)
                    let b = transformed(CGPoint(x: rect.width * side / 2, y: rect.height * (end - start)), by: row.transform, position: row.position)
                    assert(near(a, CGPoint(x: top.center.x + side * top.width / 2, y: top.center.y)))
                    assert(near(b, CGPoint(x: bottom.center.x + side * bottom.width / 2, y: bottom.center.y)))
                    assert(a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite)
                }
                if let previousBottom { assert(near(previousBottom, top.center), "Adjacent strips must meet") }
                assert(bottom.center.y >= top.center.y && top.width >= 0 && top.width <= rect.width)
                if p == 0 { assert(top.center == source && bottom.center == source) }
                if p >= handoff {
                    assert(abs(row.transform.m11 - 1) < 0.00001 && abs(row.transform.m22 - 1) < 0.00001)
                    assert(abs(row.transform.m21) < 0.00001 && abs(row.transform.m24) < 0.00001)
                    assert(near(top.center, CGPoint(x: rect.midX, y: rect.minY + rect.height * start)))
                    assert(near(bottom.center, CGPoint(x: rect.midX, y: rect.minY + rect.height * end)))
                }
                if CodexGenieGeometry.materialOpacity(at: p) > 0 {
                    assert(top.width == rect.width && bottom.width == rect.width,
                           "Reveal native material only after the snapshot is fully settled")
                }
                previousBottom = bottom.center
            }
        }
        let neck = CodexGenieGeometry.edge(at: 0, progress: handoff * (0.28 / 0.67), rect: rect, source: source)
        let foot = CodexGenieGeometry.edge(at: 1, progress: handoff * (0.28 / 0.67), rect: rect, source: source)
        assert(neck.width < foot.width * 0.2, "The early phase must form a funnel, not uniform scaling")
        assert(CodexGenieGeometry.materialOpacity(at: handoff) == 0)
        assert(abs(CodexGenieGeometry.materialOpacity(at: materialMidpoint) - 0.5) < 0.00001)
        assert(CodexGenieGeometry.materialOpacity(at: 1) == 1)
        var previousOpacity: CGFloat = 0
        for step in 0...100 {
            let opacity = CodexGenieGeometry.materialOpacity(at: CGFloat(step) / 100)
            assert(opacity >= previousOpacity && opacity <= 1, "The live material must blend in continuously")
            previousOpacity = opacity
        }
        let duration = CodexGenieTransition.duration
        assert(abs(duration * Double(handoff) - 0.88 * 0.67) < 0.00001,
               "Deformation must retain its original duration")
        assert(abs(duration * Double(1 - handoff) - 2 * 0.88 * 0.33) < 0.00001,
               "The material handoff must last exactly twice as long")
        assert(abs(duration - 1.1704) < 0.00001)
        for showing in [false, true] {
            for step in 0...100 {
                let p = CGFloat(step) / 100
                let time = CodexGenieGeometry.timelineTime(at: p, showing: showing)
                assert(abs(CodexGenieGeometry.phase(atTimelineTime: time, showing: showing) - p) < 0.00001,
                       "Reversals must preserve the exact visible phase on either timeline")
            }
        }
        let closeTotal = CodexGenieGeometry.timelineTime(at: 1, showing: false)
        assert(abs(closeTotal - 0.7096) < 0.00001)
        let afterTakeover = CodexGenieGeometry.phase(atTimelineTime: closeTotal - 0.20, showing: false)
        assert(afterTakeover < handoff, "Closing must already deform by 200 ms, not hold for the opening material fade")
        let moving = CodexGenieGeometry.edge(at: 0, progress: afterTakeover, rect: rect, source: source)
        assert(moving.width < rect.width - 1, "The close must visibly move soon after submission")
        print("PASS: Genie geometry, strip joins, funnel and continuous live-material crossfade")
    }
}
