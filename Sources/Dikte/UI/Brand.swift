import SwiftUI

/// URLuc paleti: elektrik mavi + mor, imza gradyanı mavi→mor.
enum Brand {
    static let blue = Color(red: 0x0A / 255, green: 0x7C / 255, blue: 0xFF / 255)
    static let deepBlue = Color(red: 0x00 / 255, green: 0x5A / 255, blue: 0xE1 / 255)
    static let purple = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)

    static let gradient = LinearGradient(colors: [blue, purple], startPoint: .leading, endPoint: .trailing)
    static let softGradient = LinearGradient(
        colors: [blue.opacity(0.16), purple.opacity(0.16)],
        startPoint: .leading, endPoint: .trailing
    )

    static func color(for speaker: Speaker) -> Color {
        speaker == .me ? blue : purple
    }
}
