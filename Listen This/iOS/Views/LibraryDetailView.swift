//
//  LibraryDetailView.swift
//  listen this
//
//  Created on 27.12.2025.
//

import SwiftUI

struct LibraryDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "Select an Audiobook",
            systemImage: "book.fill",
            description: Text("Choose an audiobook from the sidebar to begin listening")
        )
    }
}

#Preview {
    LibraryDetailView()
}
