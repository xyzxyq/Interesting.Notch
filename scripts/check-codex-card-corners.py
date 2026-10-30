#!/usr/bin/env python3
"""Render the production card shell and detect rectangular shadow clipping, without showing a window."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
folder = root / 'build/card-polish'
folder.mkdir(parents=True, exist_ok=True)
source = (root / 'boringNotch/managers/CodexActivity.swift').read_text()


def shell(text):
    start = text.index('        .padding(22).frame(width: 420, height: 440)')
    end = text.index('        .padding(CodexCardReveal.panelInset)', start)
    return text[start:end] + '        .padding(CodexCardReveal.panelInset)'


current = shell(source)
before_path = root / 'build/request-reliability/CodexActivity-before-polish.swift'
if before_path.exists():
    before = shell(before_path.read_text())
else:
    # Retain the known-bad ordering as a negative control after build artifacts are cleaned.
    shadow = '        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)\n'
    before = ''.join(line for line in current.splitlines(keepends=True) if not line.strip().startswith('.shadow('))
    before = before.replace('        .clipShape(cardShape)\n', '').replace('        .compositingGroup()\n', '')
    before = before.replace('        .modifier(CodexDissolve', shadow + '        .modifier(CodexDissolve', 1)

effects = (root / 'boringNotch/components/Notch/CodexNotchEffect.swift').read_text()
effects = effects[effects.index('struct CodexCardReveal:'):]
shape = source.split('private let cardShape = ', 1)[1].split('\n', 1)[0]
swift = 'import AppKit\nimport SwiftUI\n' + effects + '\n'
swift += 'struct State { var windowDissolve: CGFloat = 0; var windowReveal: CGFloat = 0; var panelReady = true; var cardAnimating = false }\n'
for name, suffix in [('Before', before), ('Current', current)]:
    swift += f'''struct {name}: View {{
    let activity = State()
    let cardShape = {shape}
    let opaque = true
    let contrast = ColorSchemeContrast.standard
    let usesGenie = false
    var body: some View {{
        Color.clear
{suffix}
        .preferredColorScheme(.dark)
    }}
}}
'''
swift += r'''
@main @MainActor struct Check {
    static func render<V: View>(_ view: V, name: String, scale: Int) throws -> [String: Double] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(scale)
        guard let image = renderer.cgImage else { fatalError("Missing card shell render") }
        let pixels = NSBitmapImageRep(cgImage: image)
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name)-\(scale)x.png")
        try pixels.representation(using: .png, properties: [:])!.write(to: output)
        if scale == 2 {
            let whiteRenderer = ImageRenderer(content: view.background(Color.white))
            whiteRenderer.scale = 2
            guard let whiteImage = whiteRenderer.cgImage else { fatalError("Missing white-background render") }
            let whiteOutput = output.deletingLastPathComponent().appendingPathComponent("\(name)-white-2x.png")
            try NSBitmapImageRep(cgImage: whiteImage).representation(using: .png, properties: [:])!.write(to: whiteOutput)
        }
        if name == "current" {
            let center = pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
            assert(center.alphaComponent == 1 && max(center.redComponent, center.greenComponent, center.blueComponent) < 0.005,
                   "Card body must remain opaque pure black")
            let darkRenderer = ImageRenderer(content: view.background(Color.black))
            darkRenderer.scale = CGFloat(scale)
            let darkOutput = output.deletingLastPathComponent().appendingPathComponent("current-black-\(scale)x.png")
            try NSBitmapImageRep(cgImage: darkRenderer.cgImage!).representation(using: .png, properties: [:])!.write(to: darkOutput)
        }
        let x0 = 48 * scale, x1 = (48 + 420) * scale
        let y0 = 48 * scale, y1 = (48 + 440) * scale
        func alpha(_ x: Int, _ y: Int) -> Double { pixels.colorAt(x: x, y: y)!.alphaComponent }
        var jumps: [String: Double] = [:]
        for (corner, right, bottom) in [("topLeft", false, false), ("topRight", true, false),
                                         ("bottomLeft", false, true), ("bottomRight", true, true)] {
            var jump = 0.0
            var outside = 0.0
            // These points lie in the rounded cutout, clear of the opaque card's edge.
            // A natural shadow has nonzero alpha here; only a hard rectangular jump is a defect.
            for offset in (2 * scale)...(6 * scale) {
                let x = right ? x1 - 1 - offset : x0 + offset
                let y = bottom ? y1 - 1 - offset : y0 + offset
                jump = max(jump, abs(alpha(right ? x1 : x0 - 1, y) - alpha(right ? x1 - 1 : x0, y)))
                jump = max(jump, abs(alpha(x, bottom ? y1 : y0 - 1) - alpha(x, bottom ? y1 - 1 : y0)))
                outside = max(outside, alpha(right ? x1 : x0 - 1, y), alpha(x, bottom ? y1 : y0 - 1))
            }
            jumps[corner] = jump
            jumps[corner + "OutsideAlpha"] = outside
        }
        return jumps
    }
    static func main() throws {
        var results: [String: [String: Double]] = [:]
        for scale in [1, 2] {
            results["before-\(scale)x"] = try render(Before(), name: "before", scale: scale)
            results["current-\(scale)x"] = try render(Current(), name: "current", scale: scale)
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("corner-alpha.json"))
        print(String(data: data, encoding: .utf8)!)
    }
}
'''
(folder / 'CardCornerCheck.swift').write_text(swift)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-O', '-assert-config', 'Debug', '-swift-version', '5', '-parse-as-library',
                str(folder / 'CardCornerCheck.swift'), '-o', str(folder / 'card-corner-check')], env=env, check=True)
subprocess.run([str(folder / 'card-corner-check'), str(folder)], check=True)
metrics = json.loads((folder / 'corner-alpha.json').read_text())
corners = ['topLeft', 'topRight', 'bottomLeft', 'bottomRight']
# Four alpha code points allow quantization/antialiasing while rejecting the old 8–22 point jump.
limit = 4 / 255 + 1e-9
for scale in [1, 2]:
    legacy = metrics[f'before-{scale}x']
    fixed = metrics[f'current-{scale}x']
    assert all(legacy[corner] > limit for corner in corners), 'Negative control did not reproduce all four clipped corners'
    assert all(fixed[corner] <= limit for corner in corners), f'Rectangular shadow cutoff remains at {scale}x: {fixed}'
    assert all(fixed[corner + 'OutsideAlpha'] > limit for corner in corners), 'The soft shadow was removed instead of unclipped'
print('PASS: old ordering fails all four corners; production shell has smooth shadow edges at 1x/2x and retains the exterior shadow')
