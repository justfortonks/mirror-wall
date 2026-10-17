# ADR 0004: Android app identity and signing

Status: accepted, October 2026

## Context

Upstream's Android companion and the earlier DemoCast pilot used their own app IDs. SE devices are
managed by MDM, and the app needed an Imprivata identity that won't collide with either.

## Decision

- The application ID is `com.imprivata.mirrorwallcast`. The Kotlin package stays
  `com.justfortonks.mirrorwall.cast` to keep upstream merges simple.
- Builds are signed with the repository's public test key for now, so every build installs over
  the last.
- The version code is the commit count (`MIRROR_WALL_BUILD`), so it always increases.

## Consequences

- MDM assignments target `com.imprivata.mirrorwallcast`; the old app IDs should be removed from
  devices.
- Moving to a team signing key later means uninstalling once on every device. The key and its
  passwords must never be committed.
- The test key means anyone could sign an update; acceptable for demo devices, not for anything
  holding real data.
