//
//  WatchProgressBar.swift
//  Listen This
//

import SwiftUI

struct WatchProgressBar: View {
    let value: Double
    let total: Double
    var height: CGFloat = 3
    var foregroundColor: Color = .white
    var backgroundColor: Color = Color.white.opacity(0.3)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(backgroundColor)
                    .frame(height: height)

                // Foreground progress
                Capsule()
                    .fill(foregroundColor)
                    .frame(width: geometry.size.width * (value / total), height: height)
            }
        }
        .frame(height: height)
    }
}

#Preview {
    VStack(spacing: 20) {
        WatchProgressBar(value: 0.3, total: 1.0)
            .frame(width: 200)

        WatchProgressBar(value: 0.7, total: 1.0, height: 4, foregroundColor: .blue)
            .frame(width: 200)

        WatchProgressBar(value: 0.5, total: 1.0, height: 10, foregroundColor: .green)
            .frame(width: 200)
    }
    .padding()
}
