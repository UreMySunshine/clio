import SwiftUI

/// Draws the engine's particles, and drives it: `TimelineView(.animation)` ticks
/// with the display's refresh, which keeps the spray smooth where a timer left it
/// stuttering. Transparent everywhere else so the overlay never obscures what the
/// user is doing.
struct ConfettiView: View {
    @ObservedObject var engine: ConfettiEngine

    var body: some View {
        TimelineView(.animation(paused: !engine.isRunning)) { timeline in
            Canvas { context, _ in
                engine.advance(to: timeline.date)
                for particle in engine.particles {
                    // The transform goes on the path and the fade into the fill
                    // colour, so no per-particle copy of the context is needed.
                    let box = particle.isRect
                        ? CGRect(x: -particle.size / 2, y: -particle.size / 3,
                                 width: particle.size, height: particle.size * 0.66)
                        : CGRect(x: -particle.size / 2, y: -particle.size / 2,
                                 width: particle.size, height: particle.size)
                    let shape = particle.isRect ? Path(box) : Path(ellipseIn: box)
                    let placed = shape.applying(
                        CGAffineTransform(rotationAngle: particle.rotation)
                            .concatenating(CGAffineTransform(translationX: particle.x,
                                                            y: particle.y)))
                    context.fill(placed,
                                 with: .color(particle.color.opacity(max(0, min(1, particle.life)))))
                }
            }
        }
        .background(.clear)
        .allowsHitTesting(false)
    }
}
