//
//  LottieView.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-14.
//

import SwiftUI
import Lottie

struct LottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loopMode: LottieLoopMode

    var isPlaying = true
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @Environment(\.accessibilityReduceMotion) private var reduced

    @MainActor final class Coordinator {
        var url: URL?
        var shouldPlay = false
        var loadTask: Task<Void, Never>?

        func applyPlayback(to view: LottieAnimationView) {
            if shouldPlay, view.animation != nil {
                if !view.isAnimationPlaying { view.play() }
            } else {
                view.pause()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let animationView = LottieAnimationView()
        animationView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let animationView = nsView.subviews.first as? LottieAnimationView else { return }
        let coordinator = context.coordinator
        coordinator.shouldPlay = isPlaying && !motion.suspended && !reduced
        animationView.loopMode = loopMode
        animationView.animationSpeed = CGFloat(speed)
        guard coordinator.url != url else {
            coordinator.applyPlayback(to: animationView)
            return
        }

        // Mark in flight before loading: unrelated view updates must not load again.
        coordinator.loadTask?.cancel()
        coordinator.url = url
        animationView.pause()
        animationView.animation = nil
        coordinator.loadTask = Task { @MainActor [weak animationView, weak coordinator] in
            let animation = await LottieAnimation.loadedFrom(url: url)
            guard !Task.isCancelled, let animationView, let coordinator, coordinator.url == url else { return }
            animationView.animation = animation
            coordinator.applyPlayback(to: animationView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        coordinator.shouldPlay = false
        if let view = nsView.subviews.first as? LottieAnimationView { view.pause() }
    }
}
