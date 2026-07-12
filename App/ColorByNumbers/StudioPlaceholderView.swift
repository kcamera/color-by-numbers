import CBNKit
import SwiftUI

/// M0 placeholder for the Studio (the kid's library + canvas, arriving in
/// M2). Establishes the paper-warm desk surface from the soft-analog north
/// star in docs/DESIGN.md, and proves the app links CBNKit.
struct StudioPlaceholderView: View {
    // A first guess at the craft-table desk tone; expect this to be tuned
    // (and probably tokenized) during M2/M6 design work.
    private let deskColor = Color(red: 0.96, green: 0.94, blue: 0.90)
    private let inkColor = Color(red: 0.36, green: 0.32, blue: 0.28)

    var body: some View {
        ZStack {
            deskColor.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Color by Numbers")
                    .font(.system(.largeTitle, design: .rounded))
                Text("The Studio arrives in M2.")
                    .font(.system(.body, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(inkColor)
        }
    }
}

#Preview(traits: .landscapeLeft) {
    StudioPlaceholderView()
}
