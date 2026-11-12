import SwiftUI

/// Colours from the design canvas (design/canvas, Aqua-Salbei). Text on pastel is always dark ink (≥ 11:1).
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32, hcLight: UInt32? = nil, hcDark: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .accessibilityHighContrastDarkAqua?: return rgb(hcDark ?? dark)
            case .accessibilityHighContrastAqua?: return rgb(hcLight ?? light)
            case .darkAqua?: return rgb(dark)
            default: return rgb(light)
            }
        })
    }
    static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static let accent = Color(nsColor: rgb(0xBAD8D1))      // Aqua-Salbei: logo + play button
    static let ink = Color(nsColor: rgb(0x1D1D1F))         // text on pastel
    static let switchOn = Color(nsColor: rgb(0x6DB6A5))
    static let soft = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0xBAD8D1, 0.22) : rgb(0xE2EEEB)
    })
    static let bg = dyn(0xF5F5F7, 0x1E1E21)
    static let surface = dyn(0xFFFFFF, 0x2A2A2E)
    static let text = dyn(0x1D1D1F, 0xF2F2F3)
    static let text2 = dyn(0x5F5F66, 0xA1A1A8, hcLight: 0x3A3A40, hcDark: 0xD0D0D6)  // 5.8:1 / 6.1:1; Increase Contrast ≥ 10:1
    static let border = dyn(0xE0E0E5, 0x3A3A3F, hcLight: 0x6E6E73, hcDark: 0x9A9AA0)
    static let field = dyn(0xDADADF, 0x4A4A50, hcLight: 0x6E6E73, hcDark: 0x9A9AA0)
    static let segBg = dyn(0xE3E3E8, 0x3A3A3F)
    static let segOn = dyn(0xFFFFFF, 0x5A5A60)
    static let logo = dyn(0xE3E3E8, 0x3A3A3F)
}

/// Capsule switch from the design; reports On/Off to VoiceOver.
struct FonaSwitch: View {
    @Binding var isOn: Bool
    let label: String
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.switchOn : Theme.segBg).frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5).padding(2))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? L.t(.on) : L.t(.off))
        .accessibilityAddTraits(.isToggle)
    }
}

/// Square with initials – logos are never loaded from the net (security decision).
struct StationLogo: View {
    let initials: String
    var size: CGFloat = 28
    var active = false
    var body: some View {
        Text(verbatim: initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(active ? Theme.ink : Theme.text)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.21).fill(active ? Theme.accent : Theme.logo))
            .accessibilityHidden(true)
    }
}

/// Bordered button like the text fields (radius 6, light outline).
struct FieldButtonStyle: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? Theme.ink : Theme.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Theme.accent : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(filled ? .clear : Theme.field))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// VoiceOver announcement for changes that happen without the user's action (news switch, errors, toasts).
@MainActor func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}
