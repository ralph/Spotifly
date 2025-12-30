//
//  TrackInfoView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct TrackInfoView: View {
    let track: TrackMetadata

    var body: some View {
        VStack(spacing: 16) {
            // Album artwork
            AsyncImage(url: track.albumImageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 200, height: 200)
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                case .failure:
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                        .frame(width: 200, height: 200)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                @unknown default:
                    EmptyView()
                }
            }

            // Track info
            VStack(spacing: 4) {
                Text(track.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(track.artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(track.albumName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(track.durationFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            // Track ID for reference
            GroupBox {
                HStack {
                    Text("Track ID:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(track.id)
                        .font(.caption)
                        .monospaced()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("spotify:track:\(track.id)", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy track URI")
                }
            }
        }
        .padding()
    }
}
