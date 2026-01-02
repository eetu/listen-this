//
//  ChapterTitleView.swift
//  Listen This
//

import SwiftUI

struct ChapterTitleView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(titleFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.bottom, bottomPadding)
    }

    private var titleFont: Font {
        #if os(iOS)
            .headline
        #else
            .system(size: 12)
        #endif
    }

    private var bottomPadding: CGFloat {
        #if os(iOS)
            12
        #else
            0
        #endif
    }
}
