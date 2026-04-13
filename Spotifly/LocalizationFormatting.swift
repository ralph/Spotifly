//
//  LocalizationFormatting.swift
//  Spotifly
//
//  Lightweight helpers for replacing legacy printf-style localization usage.
//

import Foundation

func localizedString(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func localizedNumberString(_ key: String, _ value: Int) -> String {
    // String(format:) is intentional: it handles all printf specifiers (%d, %1$d,
    // multiple occurrences) correctly and produces locale-neutral ASCII digits.
    // .formatted() would insert locale-specific thousands separators and numerals.
    String(format: localizedString(key), value)
}

func localizedTextString(_ key: String, _ value: String) -> String {
    // String(format:) is intentional: same reasons as localizedNumberString,
    // plus it correctly handles positional specifiers (%1$@) if ever added.
    String(format: localizedString(key), value)
}
