import AppKit
import SwiftUI

@MainActor
struct PanelViewport: View {
    @ObservedObject var store: Store
    let initialViewportHeight: CGFloat
    let maxContentHeight: CGFloat
    let onContentHeightChange: (CGFloat) -> Void
    @State private var contentHeight: CGFloat?

    init(store: Store, initialViewportHeight: CGFloat = 640, maxContentHeight: CGFloat,
         onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.store = store
        self.initialViewportHeight = initialViewportHeight
        self.maxContentHeight = maxContentHeight
        self.onContentHeightChange = onContentHeightChange
    }

    var body: some View {
        ScrollView {
            Panel(store: store)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { reportContentHeight(geometry.size.height) }
                            .onChange(of: geometry.size.height) { height in
                                reportContentHeight(height)
                            }
                    }
                }
        }
        .frame(width: 500, height: min(contentHeight ?? initialViewportHeight, max(1, maxContentHeight)))
        .background(Color.bg)
    }

    private func reportContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        DispatchQueue.main.async {
            guard contentHeight != height else { return }
            contentHeight = height
            onContentHeightChange(height)
        }
    }
}

@MainActor
struct MenuBarPanel: View {
    @ObservedObject var store: Store
    @State private var maxContentHeight: CGFloat

    init(store: Store) {
        self.store = store
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        _maxContentHeight = State(initialValue: Self.heightLimit(for: screenHeight))
    }

    var body: some View {
        PanelViewport(store: store, maxContentHeight: maxContentHeight)
            .background(PanelScreenHeightReader { screenHeight in
                let height = Self.heightLimit(for: screenHeight)
                if maxContentHeight != height { maxContentHeight = height }
            })
    }

    private static func heightLimit(for screenHeight: CGFloat) -> CGFloat {
        let screenLimit = max(1, screenHeight - 24)
        guard demoMode,
              let rawValue = Bundle.main.object(forInfoDictionaryKey: "CSPreviewMaxPanelHeight") as? NSNumber else {
            return screenLimit
        }
        let previewLimit = CGFloat(rawValue.doubleValue)
        guard previewLimit.isFinite, previewLimit > 0 else { return screenLimit }
        return min(screenLimit, previewLimit)
    }
}

private struct PanelScreenHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> PanelScreenObservingView {
        let view = PanelScreenObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: PanelScreenObservingView, context: Context) {
        view.onChange = onChange
        view.reportScreenHeight()
    }
}

private final class PanelScreenObservingView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var lastHeight: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportScreenHeight()
    }

    override func layout() {
        super.layout()
        reportScreenHeight()
    }

    func reportScreenHeight() {
        guard let height = window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height,
              height.isFinite, height > 0, lastHeight != height else { return }
        lastHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(height)
        }
    }
}
