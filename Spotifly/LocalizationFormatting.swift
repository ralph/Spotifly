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
    localizedString(key).replacing("%d", with: value.formatted())
}

func localizedTextString(_ key: String, _ value: String) -> String {
    localizedString(key).replacing("%@", with: value)
}
