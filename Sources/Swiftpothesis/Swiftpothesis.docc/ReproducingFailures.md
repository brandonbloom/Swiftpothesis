# Reproducing Failures

Replay a failure on the next run, on another machine, or from a seed.

## Overview

Swiftpothesis saves the choices behind every shrunk failure in an ``ExampleDatabase``. The next run of the property replays saved failures before generating anything new, so a failure keeps failing until it's fixed, and then the database forgets it.

The default database, ``DirectoryDatabase/default``, lives in `.swiftpothesis/examples` at the package root. Add `.swiftpothesis/` to `.gitignore`, or commit it to share failures with collaborators and CI. Set `SWIFTPOTHESIS_DATABASE` to move it.

## Seeds

Every failure report includes the run's seed. Setting `SWIFTPOTHESIS_SEED` to it repeats the run's generation exactly, which is useful when the database isn't available, such as for a failure seen only in CI:

```sh
SWIFTPOTHESIS_SEED=13006135410322903826 swift test --filter everyArrayIsShort
```

To fix the seed for one test, use a trait:

```swift
@Test(.propertySettings { $0.seed = 42 })
func deterministic() async { … }
```

## Topics

- ``ExampleDatabase``
- ``DirectoryDatabase``
- ``InMemoryDatabase``
- ``ChoiceSequence``
- ``Settings/seed``
