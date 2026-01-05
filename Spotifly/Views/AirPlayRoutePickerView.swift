//
//  AirPlayRoutePickerView.swift
//  Spotifly
//
//  NSViewRepresentable wrapper for AVRoutePickerView (macOS only)
//

#if os(macOS)
    import AVKit
    import SwiftUI

    struct AirPlayRoutePickerView: NSViewRepresentable {
        func makeNSView(context _: Context) -> AVRoutePickerView {
            let routePickerView = AVRoutePickerView()
            routePickerView.isRoutePickerButtonBordered = false
            return routePickerView
        }

        func updateNSView(_: AVRoutePickerView, context _: Context) {
            // No updates needed
        }
    }
#endif
