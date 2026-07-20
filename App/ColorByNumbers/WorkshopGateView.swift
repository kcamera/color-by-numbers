import SwiftUI

/// The parental gate at the Workshop door (DESIGN.md's agency model: ONE
/// gate, and it lives here). The recognized Kids-Category pattern: three
/// random digits (1-9) spoken as lowercase words a pre-reader can't sound
/// out, entered on a plain digit keypad a literate adult solves in seconds.
/// A miss is never a "wrong" screen — DESIGN.md's no-error-feedback contract
/// extended to grown-up space: the gate silently deals new words and clears
/// whatever was typed, a door that didn't open rather than a test that was
/// failed. `onUnlocked` is the only way out toward the Workshop; the close
/// control below is the only way out back to the Studio.
struct WorkshopGateView: View {
    let onUnlocked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var digits: [Int] = WorkshopGateView.randomDigits()
    @State private var entered: [Int] = []

    private static let words: [Int: String] = [
        1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
        6: "six", 7: "seven", 8: "eight", 9: "nine",
    ]

    /// Re-randomized every presentation (a fresh `WorkshopGateView` instance
    /// per `fullScreenCover` presentation gives this for free) and every
    /// failure (`enter(_:)` below calls this again on a mismatch).
    private static func randomDigits() -> [Int] {
        (0..<3).map { _ in Int.random(in: 1...9) }
    }

    private var wordsText: String {
        digits.compactMap { Self.words[$0] }.joined(separator: " ")
    }

    var body: some View {
        ZStack {
            DeskStyle.deskColor.ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    CloseControl { dismiss() }
                }

                Spacer()

                VStack(spacing: 40) {
                    Text(wordsText)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .foregroundStyle(DeskStyle.inkColor)
                        // The UI test reads WHICH words were dealt off this
                        // identifier, then translates them back to digits —
                        // the element's spoken label is the rendered text
                        // itself, same as any plain Text.
                        .accessibilityIdentifier("Gate words")

                    GateKeypad(onTap: enter)
                }

                Spacer()
                Spacer()
            }
            .padding(32)
        }
    }

    /// One keypad tap. Waits for all three before judging anything — a
    /// partial entry is never "wrong," it's just unfinished. A match
    /// unlocks; a mismatch is the calm silent reset (DESIGN.md): no
    /// message, no sound, no shake, just new words and an empty slate.
    private func enter(_ digit: Int) {
        entered.append(digit)
        guard entered.count == digits.count else { return }
        if entered == digits {
            onUnlocked()
        } else {
            digits = Self.randomDigits()
            entered = []
        }
    }
}

/// The 1-2-3/4-5-6/7-8-9 digit pad: plain, rounded, ≥64pt targets in the
/// same white-ish "material" fill used throughout the app (Circle rather
/// than Capsule per key, matching `PaletteSwatch`/`UndoControl`'s round
/// controls elsewhere).
private struct GateKeypad: View {
    let onTap: (Int) -> Void

    private static let rows = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { digit in
                        Button(action: { onTap(digit) }) {
                            Text("\(digit)")
                                .font(.system(.title2, design: .rounded, weight: .semibold))
                                .foregroundStyle(DeskStyle.inkColor)
                                .frame(width: 64, height: 64)
                        }
                        .buttonStyle(KeypadButtonStyle())
                        // Spoken name for VoiceOver; also the UI-test
                        // driver's handle, same dual purpose as every other
                        // symbol/digit control in this app.
                        .accessibilityLabel("\(digit)")
                    }
                }
            }
        }
    }
}

/// `.plain` gave these keys NO press feedback at all — a parent tapping
/// through three digits couldn't tell a tap had registered (Kevin's
/// report). This swaps the fill to a noticeably darker ink tint and
/// scales the key down slightly the instant a finger lands, so the
/// confirmation is felt before the digit even joins `entered`.
private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(
                    configuration.isPressed
                        ? DeskStyle.inkColor.opacity(0.35)
                        : Color.white.opacity(0.7)
                )
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A quiet close control, same white-ish material as the app's other quiet
/// controls. Two callers: the Gate (leaving without the code — no wrong-
/// code feedback exists, so this is simply "not now") and the Workshop
/// (leaving back to the Studio once inside). Grown-up space, so a standard
/// 44pt target rather than the Studio/Canvas's small-finger 64pt floor.
struct CloseControl: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DeskStyle.inkColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

#if DEBUG
#Preview(traits: .landscapeLeft) {
    WorkshopGateView(onUnlocked: {})
}
#endif
