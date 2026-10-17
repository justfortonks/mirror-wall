# ADR 0001: Fork tracks upstream on a separate branch

Status: accepted, October 2026

## Context

Mirror Wall is maintained upstream at justfortonks/mirror-wall and moves quickly. The SE edition
needs Imprivata branding and demo-specific behavior that upstream may never want, but we also
want upstream's fixes and features (for example, the Spectralink photo frames).

## Decision

- The fork's `main` mirrors upstream and is never committed to.
- All SE work lives on `cody-changes`.
- Upstream changes come in through a short-lived branch from `cody-changes` that merges
  `upstream/main`, is built, tested and checked on a Mac, and only then fast-forwards
  `cody-changes`.
- Check for Update reads this fork's releases, so an upstream release can never replace the SE
  build on a presenter's Mac.
- Changes that would help everyone can be offered upstream as pull requests from a clean branch.

## Consequences

- Merges have predictable conflict hot spots (bezels, `Slot.swift`, `SyphonFeed.swift`,
  `LatestRelease.swift`, `CHANGELOG.md`); [AGENTS.md](../../AGENTS.md) lists them.
- The fork must publish its own releases for updates to work.
- Windows stays at upstream behavior unless someone ports the SE changes.
