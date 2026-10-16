# How Shrinking Works

Why Swiftpothesis shrinks choices instead of values, and what that means for your generators.

## Overview

Every generated value is a function of the primitive choices its generator drew from a ``Source``. Swiftpothesis records those choices as a ``ChoiceSequence``. To shrink a failure, it proposes simpler sequences, replays each through the same generator, and keeps any that still fail the same way.

A sequence is simpler if it's shorter, or the same length and lexicographically smaller. Generators are written so that simpler choices produce simpler values: integers draw a distance from zero, arrays draw a "continue" choice before each element, and choosing between alternatives prefers the first.

This approach, called *internal* shrinking, comes from [Hypothesis](https://hypothesis.readthedocs.io), described in MacIver and Donaldson's [*Test-Case Reduction via Test-Case Generation*](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ECOOP.2020.13). It has three consequences:

- **No shrinkers to write.** A generator built from other generators shrinks without extra code.
- **Shrinking survives `flatMap` and `filter`.** Shrinking an array also shrinks an index drawn from its count, because both are replayed from the same choices.
- **Shrunk values are valid.** Every candidate is produced by the generator, so it satisfies the generator's constraints.

## Helping the shrinker

- Prefer constructing valid values over filtering. A filter that rejects most candidates also rejects most shrink attempts.
- In a custom ``Generator``, draw choices so that zero means "simplest", and wrap each meaningful unit in ``Source/span(_:)``.
- Keep the shrink target in mind when mapping: `Int.arbitrary(in: 0...9).map { 9 - $0 }` shrinks toward 9.
