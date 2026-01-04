//
//  AirPlayRoutePickerView.swift
//  Spotifly
//
//  System AirPlay route picker for macOS
//

import AVKit
import SwiftUI

#if os(macOS)
    /// A SwiftUI wrapper for AVRoutePickerView on macOS
    struct AirPlayRoutePickerView: NSViewRepresentable {
        func makeNSView(context _: Context) -> AVRoutePickerView {
            let routePickerView = AVRoutePickerView()
            routePickerView.isRoutePickerButtonBordered = false
            return routePickerView
        }

        func updateNSView(_: AVRoutePickerView, context _: Context) {}
    }
#endif
