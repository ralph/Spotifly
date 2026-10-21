//
//  DetailHeader.swift
//  Spotifly
//
//  The head of a list's page: its art, kind, title, a line about it, and what can be done with it
//

import SwiftUI

/// The redesign's detail header (`plans/done/redesign-favorites.md`): 132 pt art beside the kind,
/// the title, a metadata line and the page's actions, stacked under the art below 520 pt.
struct DetailHeader<Art: View, Metadata: View, Actions: View>: View {
    let kind: String
    let title: String
    var description: String?
    @ViewBuilder var art: Art
    @ViewBuilder var metadata: Metadata
    @ViewBuilder var actions: Actions

    /// The side of the art.
    private static var artSize: CGFloat {
        132
    }

    @State private var isNarrow = false

    var body: some View {
        let layout = isNarrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 22))

        layout {
            art
                .frame(width: Self.artSize, height: Self.artSize)

            VStack(alignment: .leading, spacing: 0) {
                Text(kind)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: isNarrow ? 24 : 30, weight: .bold))
                    .lineLimit(2)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                if let description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.bottom, 2)
                }
                metadata
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    actions
                }
                .controlSize(.large)
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, isNarrow ? 20 : 28)
        .padding(.top, 8)
        .padding(.bottom, isNarrow ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < 520 } action: { isNarrow = $0 }
    }
}

/// The header's playback buttons: Abspielen, prominent, and Zufällig where the page has it.
struct PlayAndShuffleButtons: View {
    let play: () -> Void
    var shuffle: (() -> Void)?

    var body: some View {
        Button(action: play) {
            Label("detail.play", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)

        if let shuffle {
            Button(action: shuffle) {
                Label("detail.shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
        }
    }
}

/// The header's toggle for whether the page's subject is in the library: off, it adds; on, it
/// asks the page to confirm the removal.
struct LibraryToggleButton: View {
    let isOn: Bool
    var onTitle: LocalizedStringKey = "detail.in_library"
    var offTitle: LocalizedStringKey = "detail.add_to_library"
    let add: () -> Void
    let confirmRemoval: () -> Void

    var body: some View {
        Button(action: isOn ? confirmRemoval : add) {
            Label(isOn ? onTitle : offTitle, systemImage: isOn ? "checkmark" : "plus")
        }
        .buttonStyle(.bordered)
    }
}
