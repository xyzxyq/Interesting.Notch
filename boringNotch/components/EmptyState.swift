//
//  EmptyState.swift
//
// Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import SwiftUI

struct EmptyStateView: View {
    var message: String
    
    var body: some View {
        HStack {
            MinimalFaceFeatures(
                height: 70, width: 80)
            Text(message)
                .font(.system(size:14))
                .foregroundColor(.gray)
        }.transition(.opacity.animation(NotchMotionEnvironment.interactionAnimation))
    }
}

#Preview {
    EmptyStateView(message: "Play some music babies")
}
