//
//  LocalizationFormatting.swift
//  Spotifly
//
//  Lightweight helpers for replacing legacy printf-style localization usage.
//

import Foundation

// The key is a `LocalizedStringResource`, not a `String`, so the compiler extracts the literal
// at each call site (`SWIFT_EMIT_LOC_STRINGS`), and `LocalizationTests` sees it as named.

func localizedNumberString(_ key: LocalizedStringResource, _ value: Int) -> String {
    // String(format:) is intentional: it handles all printf specifiers (%d, %1$d,
    // multiple occurrences) correctly and produces locale-neutral ASCII digits.
    // .formatted() would insert locale-specific thousands separators and numerals.
    String(format: String(localized: key), value)
}

func localizedTextString(_ key: LocalizedStringResource, _ value: String) -> String {
    // String(format:) is intentional: same reasons as localizedNumberString,
    // plus it correctly handles positional specifiers (%1$@) if ever added.
    String(format: String(localized: key), value)
}
