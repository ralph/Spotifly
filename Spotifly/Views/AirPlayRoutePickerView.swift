//
//  AirPlayRoutePickerView.swift
//  Spotifly
//
//  NSViewRepresentable wrapper for AVRoutePickerView (macOS only)
//

#if os(macOS)
    import AVKit
    import SwiftUI

    /// The system's AirPlay picker, bound to the app's player: it routes Spotifly alone, and the
    /// rest of the Mac's audio stays where it is.
    struct AirPlayRoutePickerView: NSViewRepresentable {
        func makeNSView(context _: Context) -> AVRoutePickerView {
            let routePickerView = AVRoutePickerView()
            routePickerView.isRoutePickerButtonBordered = false
            routePickerView.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
            routePickerView.setRoutePickerButtonColor(.controlAccentColor, for: .active)
            routePickerView.player = AudioOutputPlayer.shared.player
            return routePickerView
        }

        func updateNSView(_: AVRoutePickerView, context _: Context) {}
    }
#endif
