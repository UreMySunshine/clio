import SwiftUI
import Combine

/// Particle simulation behind the milestone overlay.
///
/// Ported from the project's `confetti.html`: each burst is a radial spray with
/// an upward bias, then gravity, drag, sway and a life-based fade bring it down.
/// One celebration fires eight sprays over ~1.9s and clears itself.
@MainActor
final class ConfettiEngine: ObservableObject {
    struct Particle {
        var x: Double, y: Double
        var vx: Double, vy: Double
        var gravity: Double
        var size: Double
        var color: Color
        var rotation: Double
        var spin: Double
        var isRect: Bool
        var life: Double
        var decay: Double
        var sway: Double
        var swayPhase: Double
    }

    private static let palette: [Color] = [
        Color(hex: 0xFF5E5B), Color(hex: 0xFFD23F), Color(hex: 0x1F9D63),
        Color(hex: 0x34C27E), Color(hex: 0x3B82F6), Color(hex: 0xA855F7),
        Color(hex: 0xFF8C42), Color(hex: 0xEC4899), Color(hex: 0x00C2FF),
        Color(hex: 0xFFFFFF),
    ]

    /// Spray offsets in seconds, matching the original's staggered fireworks.
    private static let sprayDelays: [Double] = [0, 0.14, 0.34, 0.58, 0.85, 1.15, 1.5, 1.9]

    @Published private(set) var particles: [Particle] = []
    @Published private(set) var isRunning = false

    private var size: CGSize = .zero
    private var timer: Timer?
    private var elapsed: Double = 0
    private var firedSprays = 0

    /// Particle scale follows the canvas width, so the effect reads the same on
    /// a laptop display and a 5K one.
    private var scale: Double { max(0.35, min(1, size.width / 1440)) }

    func start(in size: CGSize) {
        self.size = size
        particles.removeAll()
        elapsed = 0
        firedSprays = 0
        isRunning = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step(1.0 / 60) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        particles.removeAll()
        isRunning = false
    }

    /// One simulation step. Driven by the timer in normal use; called directly
    /// when rendering a frame off-screen.
    func step(_ dt: Double) {
        elapsed += dt
        while firedSprays < Self.sprayDelays.count, elapsed >= Self.sprayDelays[firedSprays] {
            firework()
            firedSprays += 1
        }
        advance()
        if particles.isEmpty && firedSprays == Self.sprayDelays.count {
            stop()
        }
    }

    private func firework() {
        let s = scale
        spray(x: size.width * .random(in: 0.2...0.8),
              y: size.height * .random(in: 0.22...0.66),
              count: Int.random(in: 65...95),
              power: Double.random(in: 11...15) * s,
              upBias: 2 * s)
    }

    private func spray(x: Double, y: Double, count: Int, power: Double, upBias: Double) {
        for _ in 0..<count {
            let angle = Double.random(in: 0...(2 * .pi))
            let speed = Double.random(in: (power * 0.35)...power)
            particles.append(Particle(
                x: x,
                y: y,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed - Double.random(in: (upBias * 0.4)...upBias),
                gravity: .random(in: 0.12...0.22),
                size: Double.random(in: 6...12) * scale,
                color: Self.palette.randomElement() ?? .white,
                rotation: .random(in: 0...(2 * .pi)),
                spin: .random(in: -0.3...0.3),
                isRect: Bool.random(),
                life: 1,
                decay: .random(in: 0.005...0.012),
                sway: .random(in: 0.4...1.4),
                swayPhase: .random(in: 0...(2 * .pi))
            ))
        }
    }

    /// One 60 Hz step of the original integration.
    private func advance() {
        let s = scale
        let height = size.height
        particles = particles.compactMap { p in
            var p = p
            p.vy += p.gravity * s
            p.vx *= 0.99
            p.swayPhase += 0.08
            p.x += p.vx + sin(p.swayPhase) * p.sway * 0.3
            p.y += p.vy
            p.rotation += p.spin
            p.life -= p.decay
            if p.life <= 0 || p.y > height + 40 { return nil }
            return p
        }
    }
}
