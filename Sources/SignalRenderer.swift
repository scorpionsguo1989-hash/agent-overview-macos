import AppKit
import Foundation

enum SignalPalette {
    static let offline = NSColor(srgbRed: 1.00, green: 0.271, blue: 0.227, alpha: 1)
    static let idle = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)
    static let unknown = NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1)
    static let awaiting = NSColor(srgbRed: 0.902, green: 0.655, blue: 0.00, alpha: 1)
    static let completed = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.00, alpha: 1)
    static let error = offline

    static func color(for state: AgentSignalState) -> NSColor {
        switch state {
        case .offline: return offline
        case .idle: return idle
        case .unknown: return unknown
        case .awaiting: return awaiting
        case .working: return idle
        case .completed: return completed
        case .error: return error
        }
    }
}

enum SignalRenderer {
    static func statusBarImage(
        agents: [AgentSignalSnapshot],
        spinnerAngle: CGFloat
    ) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
        let measurementAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let itemWidths = agents.map { agent -> CGFloat in
            let textWidth = ceil((agent.definition.shortLabel as NSString).size(withAttributes: measurementAttributes).width)
            return max(26, textWidth + 12)
        }
        let totalWidth = max(20, itemWidths.reduce(0, +) + CGFloat(max(0, agents.count - 1)) * 7 + 4)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let image = NSImage(size: NSSize(width: totalWidth, height: 20), flipped: false) { bounds in
            var offset: CGFloat = 2
            for (index, agent) in agents.enumerated() {
                let alpha = agent.state == .working && !reduceMotion
                    ? 0.2 + 0.8 * ((cos(spinnerAngle) + 1) / 2)
                    : 1
                let badgeRect = NSRect(
                    x: offset,
                    y: bounds.midY - 9,
                    width: itemWidths[index],
                    height: 18
                )
                SignalPalette.color(for: agent.state).withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()

                let foreground = agent.state == .awaiting
                    ? NSColor(srgbRed: 0.251, green: 0.188, blue: 0, alpha: alpha)
                    : NSColor.white.withAlphaComponent(alpha)
                let text = NSAttributedString(
                    string: agent.definition.shortLabel,
                    attributes: [.font: font, .foregroundColor: foreground]
                )
                let textSize = text.size()
                text.draw(at: CGPoint(
                    x: offset + (itemWidths[index] - textSize.width) / 2,
                    y: bounds.midY - textSize.height / 2 + 0.4
                ))
                offset += itemWidths[index] + 7
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func menuImage(
        state: AgentSignalState,
        spinnerAngle: CGFloat
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            drawLamp(
                state: state,
                center: CGPoint(x: bounds.midX, y: bounds.midY),
                spinnerAngle: spinnerAngle
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawLamp(
        state: AgentSignalState,
        center: CGPoint,
        spinnerAngle: CGFloat
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let color = SignalPalette.color(for: state)

        switch state {
        case .working:
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: spinnerAngle)
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            for spoke in 0..<8 {
                context.saveGState()
                context.rotate(by: CGFloat(spoke) * .pi / 4)
                context.setStrokeColor(color.withAlphaComponent(CGFloat(spoke + 2) / 10).cgColor)
                context.move(to: CGPoint(x: 0, y: 2.1))
                context.addLine(to: CGPoint(x: 0, y: 4.8))
                context.strokePath()
                context.restoreGState()
            }
            context.restoreGState()
        case .error:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x, y: center.y + 5.8))
            path.addLine(to: CGPoint(x: center.x + 6.0, y: center.y - 5.0))
            path.addLine(to: CGPoint(x: center.x - 6.0, y: center.y - 5.0))
            path.closeSubpath()
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()
        default:
            context.setShadow(offset: .zero, blur: 1.1, color: NSColor.black.withAlphaComponent(0.24).cgColor)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        }
    }
}
