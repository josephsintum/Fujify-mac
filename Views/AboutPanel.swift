import AppKit
import SwiftUI

/// The Fujify ▸ About Fujify panel.
///
/// Uses the standard AppKit panel with custom credits rather than a bespoke
/// window, so it looks like every other Mac app's About box. The credits
/// carry the three things that have to be said somewhere: who wrote the
/// original, that this is not a Fujifilm product, and the licences of the
/// tools shipped inside the bundle.
enum AboutPanel {

    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(
            options: [
                .credits: credits(),
                NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                    "Copyright © 2026 Joseph Sintum · GPL v3",
            ]
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func credits() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 11)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2

        let text = NSMutableAttributedString()

        func line(_ string: String, font: NSFont = body) {
            text.append(
                NSAttributedString(
                    string: string + "\n",
                    attributes: [
                        .font: font,
                        .paragraphStyle: paragraph,
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
        }

        func secondary(_ string: String) {
            text.append(
                NSAttributedString(
                    string: string + "\n",
                    attributes: [
                        .font: body,
                        .paragraphStyle: paragraph,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
        }

        line("Unlocks Fujifilm film simulations in Lightroom", font: bold)
        secondary("for RAW files from any camera.")
        line("")

        secondary("Not affiliated with, or endorsed by, Fujifilm.")
        line("")

        line("Original Fujify by Isidore Paulin", font: bold)
        secondary("The metadata trick and the original Windows app.")
        line("")

        line("Bundled tools", font: bold)
        secondary("ExifTool by Phil Harvey — Perl Artistic License")
        secondary("dnglab by the DNGLab project — LGPL 2.1")
        secondary("Full licence texts are inside the app bundle.")

        return text
    }
}

/// Replaces the standard About menu item so it opens the panel above.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Fujify") { AboutPanel.show() }
        }
    }
}
