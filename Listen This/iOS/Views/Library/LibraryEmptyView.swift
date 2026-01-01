//
//  LibraryEmptyView.swift
//  Listen This
//
//  Placeholder view shown when no audiobook is selected
//

import SwiftUI

struct LibraryEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            "Select an Audiobook",
            systemImage: "book.fill",
            description: Text("Choose an audiobook from the sidebar to begin listening")
        )
    }
}

#Preview {
    LibraryEmptyView()
}
