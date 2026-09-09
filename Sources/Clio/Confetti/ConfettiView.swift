import SwiftUI

/// Draws the engine's particles. Transparent everywhere else so the overlay
/// never obscures what the user is doing.
struct ConfettiView: View {
    @ObservedObject var engine: ConfettiEngine

    var body: some View {
        Canvas { context, _ in
            for particle in engine.particles {
                var layer = context
                layer.opacity = max(0, min(1, particle.life))
                layer.translateBy(x: particle.x, y: particle.y)
                layer.rotate(by: .radians(particle.rotation))
                let path: Path = particle.isRect
                    ? Path(CGRect(x: -particle.size / 2,
                                  y: -particle.size / 3,
                                  width: particle.size,
                                  height: particle.size * 0.66))
                    : Path(ellipseIn: CGRect(x: -particle.size / 2,
                                             y: -particle.size / 2,
                                             width: particle.size,
                                             height: particle.size))
                layer.fill(path, with: .color(particle.color))
            }
        }
        .background(.clear)
        .allowsHitTesting(false)
    }
}
