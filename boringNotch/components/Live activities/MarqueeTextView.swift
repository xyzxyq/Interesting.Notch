//
//  MarqueeTextView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
    }

    private var scrolling: Bool {
        textSize.width > frameWidth && frameWidth > 0 && !reduced && !motion.suspended
    }

    var body: some View {
        HStack(spacing: 20) {
            Text(text)
                .modifier(MeasureSizeModifier())
            if scrolling { Text(text).accessibilityHidden(true) }
        }
        .font(font)
        .foregroundColor(textColor)
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: animate ? -(textSize.width + 20) : 0)
        .frame(width: max(0, frameWidth), alignment: .leading)
        .clipped()
        .background(backgroundColor)
        .onPreferenceChange(SizePreferenceKey.self) { size in
            if textSize != size { textSize = size }
        }
        .task(id: "\(text)-\(textSize.width)-\(frameWidth)-\(minDuration)-\(scrolling)") {
            reset()
            guard scrolling else { return }
            // Commit the reset before starting; cancellation discards old titles/resizes.
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            withAnimation(.linear(duration: Double(textSize.width + 20) / 30)
                .delay(max(0, minDuration)).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
        .onDisappear { reset() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .help(text)
    }

    private func reset() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { animate = false }
    }
}
