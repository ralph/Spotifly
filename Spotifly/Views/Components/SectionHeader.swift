//
//  SectionHeader.swift
//  Spotifly
//
//  A page section's title and the row of cards under it, as the start page and search draw them
//

import SwiftUI

/// A section's title on the page's 28 pt inset, with an optional control on its right, such as a
/// range picker or "Alle anzeigen".
struct SectionHeader<Trailing: View>: View {
    let title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            title
                .font(.title2.bold())
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: Text) {
        self.title = title
        trailing = EmptyView()
    }
}

/// A horizontal row of cards, 16 pt apart, on the page's 28 pt inset.
struct CardRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                content
            }
            .padding(.horizontal, 28)
        }
        .scrollIndicators(.hidden)
    }
}
