import SwiftUI
import FonaCore

/// Manual window: our own Markdown from Resources/help/<de|en>.md (trusted text, shipped in the bundle).
struct ManualView: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 500, idealHeight: 700)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
    }

    var lines: [String] {
        guard let url = Bundle.main.url(forResource: L.language.rawValue, withExtension: "md", subdirectory: "help"),
              let data = FileManager.default.contents(atPath: url.path) else { return ["# " + L.t(.manual)] }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    @ViewBuilder func row(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.system(size: 22, weight: .semibold)).padding(.bottom, 4)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.system(size: 15, weight: .semibold)).padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(Theme.text2)
                Text(inline(String(line.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(inline(line)).fixedSize(horizontal: false, vertical: true)
        }
    }

    func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
