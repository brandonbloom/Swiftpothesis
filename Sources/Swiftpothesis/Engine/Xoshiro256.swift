/// A seedable xoshiro256** generator, so that a seed reproduces a run on every platform.
struct Xoshiro256: RandomNumberGenerator, Sendable {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        // Expand the seed with SplitMix64, as the xoshiro authors recommend.
        var s = seed
        func splitMix() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        state = (splitMix(), splitMix(), splitMix(), splitMix())
    }

    mutating func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    /// A random choice in `0...bound`, skewed toward small values and the bounds, where bugs live.
    mutating func biasedChoice(atMost bound: UInt64) -> UInt64 {
        switch next(upperBound: 16 as UInt64) {
        case 0: return 0
        case 1: return bound
        case 2, 3, 4: return next(upperBound: Swift.min(bound, 16) &+ 1)
        default: return bound == .max ? next() : next(upperBound: bound &+ 1)
        }
    }
}
