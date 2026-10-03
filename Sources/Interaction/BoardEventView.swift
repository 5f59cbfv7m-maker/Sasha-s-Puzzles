import CoreGraphics
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Receives raw pointer, scroll and zoom events from the board surface.
///
/// Points are in the board view's coordinate space with the origin at the
/// top-left and `y` running down, matching SwiftUI.
@MainActor
protocol BoardEventHandling: AnyObject {
    /// Return `true` if the press grabbed a piece; `false` lets the board pan.
    func boardPointerDown(at point: CGPoint, isSecondary: Bool) -> Bool
    func boardPointerMoved(to point: CGPoint)
    func boardPointerUp(at point: CGPoint)
    func boardPointerCancelled()
    func boardPan(by delta: CGSize)
    func boardZoom(by factor: CGFloat, at point: CGPoint)
    func boardHover(at point: CGPoint?)
}

/// A thin native surface layered over the board's `Canvas`.
///
/// The prompt's gesture contract — one finger moves a piece, two fingers move the
/// board, trackpad pinch zooms, mouse drags — is far easier to make *stable* with
/// real gesture recognisers than with overlapping SwiftUI gestures, so drawing
/// stays declarative while input goes native.
struct BoardEventView {
    weak var handler: (any BoardEventHandling)?
}

#if os(macOS)

extension BoardEventView: NSViewRepresentable {
    func makeNSView(context: Context) -> EventNSView {
        let view = EventNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: EventNSView, context: Context) {
        nsView.handler = handler
    }

    final class EventNSView: NSView {
        weak var handler: (any BoardEventHandling)?
        private var isDraggingPiece = false
        private var trackingArea: NSTrackingArea?

        /// Top-left origin so board points match SwiftUI's coordinate space.
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited,
                                                .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        private func location(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        override func mouseDown(with event: NSEvent) {
            isDraggingPiece = handler?.boardPointerDown(at: location(event), isSecondary: false) ?? false
        }

        override func mouseDragged(with event: NSEvent) {
            if isDraggingPiece {
                handler?.boardPointerMoved(to: location(event))
            } else {
                // Dragging empty table pans the board, like a canvas app.
                handler?.boardPan(by: CGSize(width: event.deltaX, height: event.deltaY))
            }
        }

        override func mouseUp(with event: NSEvent) {
            if isDraggingPiece { handler?.boardPointerUp(at: location(event)) }
            isDraggingPiece = false
        }

        override func mouseMoved(with event: NSEvent) {
            handler?.boardHover(at: location(event))
        }

        override func mouseExited(with event: NSEvent) {
            handler?.boardHover(at: nil)
        }

        override func rightMouseDown(with event: NSEvent) {
            _ = handler?.boardPointerDown(at: location(event), isSecondary: true)
        }

        override func scrollWheel(with event: NSEvent) {
            let point = location(event)
            // ⌘-scroll (and classic mouse-wheel zoom) magnifies; plain scroll pans.
            if event.modifierFlags.contains(.command) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 3
                handler?.boardZoom(by: 1 + delta * 0.005, at: point)
            } else {
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                handler?.boardPan(by: CGSize(width: event.scrollingDeltaX * factor,
                                             height: event.scrollingDeltaY * factor))
            }
        }

        override func magnify(with event: NSEvent) {
            handler?.boardZoom(by: 1 + event.magnification, at: location(event))
        }
    }
}

#else

extension BoardEventView: UIViewRepresentable {
    func makeUIView(context: Context) -> EventUIView {
        let view = EventUIView()
        view.handler = handler
        return view
    }

    func updateUIView(_ uiView: EventUIView, context: Context) {
        uiView.handler = handler
    }

    final class EventUIView: UIView, UIGestureRecognizerDelegate {
        weak var handler: (any BoardEventHandling)?
        private var isDraggingPiece = false
        private var lastPanTranslation: CGPoint = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear

            // One finger (or Pencil): move a piece, or pan when it starts on the table.
            let single = UIPanGestureRecognizer(target: self, action: #selector(handleSingle))
            single.maximumNumberOfTouches = 1
            single.delegate = self
            addGestureRecognizer(single)

            // Two fingers: always the board.
            let dual = UIPanGestureRecognizer(target: self, action: #selector(handleDual))
            dual.minimumNumberOfTouches = 2
            dual.delegate = self
            addGestureRecognizer(dual)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            pinch.delegate = self
            addGestureRecognizer(pinch)

            // Apple Pencil hovering above the glass, or a trackpad pointer.
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { Feedback.shared.canvas = self }
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: handler?.boardHover(at: recognizer.location(in: self))
            default: handler?.boardHover(at: nil)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Two-finger pan and pinch must work together; the piece drag must not.
            !(gestureRecognizer is UIPanGestureRecognizer && gestureRecognizer.numberOfTouches == 1)
                && !(other is UIPanGestureRecognizer && other.numberOfTouches == 1)
        }

        @objc private func handleSingle(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                lastPanTranslation = .zero
                Feedback.shared.dragBegan(in: self)
                isDraggingPiece = handler?.boardPointerDown(at: point, isSecondary: false) ?? false
            case .changed:
                if isDraggingPiece {
                    handler?.boardPointerMoved(to: point)
                } else {
                    let translation = recognizer.translation(in: self)
                    handler?.boardPan(by: CGSize(width: translation.x - lastPanTranslation.x,
                                                 height: translation.y - lastPanTranslation.y))
                    lastPanTranslation = translation
                }
            case .ended:
                if isDraggingPiece { handler?.boardPointerUp(at: point) }
                isDraggingPiece = false
            case .cancelled, .failed:
                if isDraggingPiece { handler?.boardPointerCancelled() }
                isDraggingPiece = false
            default:
                break
            }
        }

        @objc private func handleDual(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                lastPanTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: self)
                handler?.boardPan(by: CGSize(width: translation.x - lastPanTranslation.x,
                                             height: translation.y - lastPanTranslation.y))
                lastPanTranslation = translation
            default:
                break
            }
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .changed else {
                recognizer.scale = 1
                return
            }
            handler?.boardZoom(by: recognizer.scale, at: recognizer.location(in: self))
            recognizer.scale = 1
        }
    }
}

#endif
