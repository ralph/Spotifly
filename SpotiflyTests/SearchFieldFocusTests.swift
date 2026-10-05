//
//  SearchFieldFocusTests.swift
//  SpotiflyTests
//

import AppKit
@testable import Spotifly
import Testing

/// A click outside the search field ends its editing, so Space reaches Play/Pause again.
@MainActor
struct SearchFieldFocusTests {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: false,
    )

    /// Adds `field` at the window's top left and makes it the one being edited.
    private func edit(_ field: NSTextField) {
        field.frame = NSRect(x: 10, y: 160, width: 200, height: 22)
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect((window.firstResponder as? NSText)?.delegate === field)
    }

    private func click(_ type: NSEvent.EventType = .leftMouseDown, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1,
        )!
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown])
    func `a click elsewhere in the window ends the search's editing`(type: NSEvent.EventType) {
        edit(NSSearchField())

        endSearchEditing(onClickOf: click(type, at: NSPoint(x: 300, y: 40)))
        #expect(window.firstResponder === window)
    }

    /// The field's own clear button is inside it.
    @Test func `a click in the field leaves it editing`() {
        let field = NSSearchField()
        edit(field)

        endSearchEditing(onClickOf: click(at: NSPoint(x: 200, y: 170)))
        #expect((window.firstResponder as? NSText)?.delegate === field)
    }

    /// A playlist's name in its sheet, say: only the search field holds on to Space.
    @Test func `another text field keeps its editing`() {
        let field = NSTextField()
        edit(field)

        endSearchEditing(onClickOf: click(at: NSPoint(x: 300, y: 40)))
        #expect((window.firstResponder as? NSText)?.delegate === field)
    }
}
