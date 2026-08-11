import AppKit
import Foundation

@main
struct RendererSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else { exit(64) }
        let referenceState = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "reference"
        let states: [AgentSignalState] = referenceState
            ? [.idle, .idle, .working, .completed, .idle, .idle]
            : [.offline, .idle, .unknown, .awaiting, .completed, .working]
        let agents = zip(AgentDefinition.monitored, states).map { definition, state in
            AgentSignalSnapshot(
                definition: definition,
                state: state,
                sourceLabel: state.chineseLabel,
                updatedAt: Date(),
                ready: state != .offline
            )
        }
        let image = SignalRenderer.statusBarImage(
            agents: agents,
            spinnerAngle: referenceState ? 0 : .pi / 4
        )
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            print(CommandLine.arguments[1])
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
