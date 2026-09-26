//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var animating = false
    private var lowPower = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            layer?.addSublayer(barLayer)
        }
        resetBars()
    }
    
    private func startAnimating() {
        guard !animating else { return }
        animating = true
        // ponytail: repeat a decorative 3.6s pattern; use sampled audio if a real spectrum is needed.
        for bar in barLayers {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            let values = (0..<12).map { _ in CGFloat.random(in: 0.35...1) }
            animation.values = values + [values[0]]
            animation.duration = 3.6
            animation.repeatCount = .infinity
            animation.calculationMode = .cubic
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: lowPower ? 15 : 24, maximum: lowPower ? 15 : 24, preferred: lowPower ? 15 : 24)
            bar.add(animation, forKey: "scaleY")
        }
    }

    private func stopAnimating() {
        guard animating else { return }
        animating = false
        resetBars()
    }

    private func resetBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for barLayer in barLayers {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
        }
    }
    
    func setPlaying(_ playing: Bool, lowPower: Bool = false) {
        if self.lowPower != lowPower {
            self.lowPower = lowPower
            stopAnimating()
        }
        if playing {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @Environment(\.accessibilityReduceMotion) private var reduced
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying && !motion.suspended && !reduced, lowPower: motion.lowPower)
        return spectrum
    }
    
    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying && !motion.suspended && !reduced, lowPower: motion.lowPower)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
