import Foundation

/// Критически затухающее движение: при смене цели сохраняет положение и скорость.
struct HUDMotion {
    private(set) var value: Double = 0
    private(set) var velocity: Double = 0
    var target: Double = 0
    let response: Double

    init(response: Double = 12) { self.response = response }

    mutating func reset(_ value: Double = 0) {
        self.value = value
        velocity = 0
        target = value
    }

    mutating func advance(_ dt: TimeInterval) {
        guard dt > 0 else { return }
        let displacement = value - target
        let coefficient = velocity + response * displacement
        let decay = exp(-response * dt)
        value = target + (displacement + coefficient * dt) * decay
        velocity = (velocity - response * coefficient * dt) * decay
    }

    var settled: Bool { abs(value-target) < 0.0001 && abs(velocity) < 0.001 }
}
