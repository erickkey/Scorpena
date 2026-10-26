import SwiftUI
import AppKit

// The look shared by every window: soft rounded cards on the system background,
// one dark "pill" for the main action of a window and a pale pill for the rest.

/// The one main action of a window: dark pill with light text (grey when it can't be used).
struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundColor(isEnabled ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(isEnabled ? Color.primary : Color.primary.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Everything else: a pale pill with normal text.
struct SoftPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundColor(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(isEnabled ? 0.09 : 0.05)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// A rounded content card.
    func card(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// The look of a text field: a rounded, bordered field instead of the system bezel.
    func fieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// App icon + a window's title, the way the main window shows the brand.
struct WindowTitleRow: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.bold())
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Put in the background of a ScrollView's content: gives its scroll view the
/// classic always-visible scroll bar (shown only when there is more to scroll),
/// instead of the overlay one that fades away and hides that the window scrolls.
struct AlwaysVisibleScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PinView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class PinView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        private func pin() {
            var current: NSView? = superview
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollerStyle = .legacy
                    scrollView.hasVerticalScroller = true
                    scrollView.autohidesScrollers = true
                    return
                }
                current = view.superview
            }
        }
    }
}
