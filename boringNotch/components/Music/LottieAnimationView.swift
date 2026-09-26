//
//  LottieAnimationContainer.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 29..
//

import SwiftUI
import Defaults

struct LottieAnimationContainer: View {
    @ObservedObject private var music = MusicManager.shared
    @Default(.selectedVisualizer) var selectedVisualizer
    var body: some View {
        if selectedVisualizer == nil {
            LottieView(url: URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!, speed: 1.0, loopMode: .loop, isPlaying: music.isPlaying)
        } else {
            LottieView(url: selectedVisualizer!.url, speed: selectedVisualizer!.speed, loopMode: .loop, isPlaying: music.isPlaying)
        }
    }
}

#Preview {
    LottieAnimationContainer()
}
