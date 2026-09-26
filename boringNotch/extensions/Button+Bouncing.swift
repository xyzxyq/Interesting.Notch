//
//  Button+Bouncing.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import SwiftUI
import Defaults

struct BouncingButtonStyle: ButtonStyle {
    let vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduced
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Defaults[.cornerRadiusScaling] ? 10 : MusicPlayerImageSizes.cornerRadiusInset.closed)
                    .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                    .strokeBorder(.white.opacity(0.04), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduced ? 0.96 : 1)
            .animation(NotchMotionEnvironment.interactionAnimation, value: configuration.isPressed)
    }
}

extension Button {
    func bouncingStyle(vm: BoringViewModel) -> some View {
        self.buttonStyle(BouncingButtonStyle(vm: vm))
    }
}
