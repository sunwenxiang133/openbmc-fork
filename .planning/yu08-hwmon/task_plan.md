# YU08 hwmon migration

Approved scope: restore SRM3-C0 stash in the current checkout, fix the hwmon to D-Bus and fan chain, remove superseded collection code, verify and commit only relevant paths. Preserve unrelated ASRock and editor changes and original stash.

- [x] Inspect stash and working tree; apply only meta-SRM3-C0 changes.
- [x] Add regression checks; fix driver and configuration contracts.
- [x] Preserve Host power recovery with a binding coordinator; remove Shell collection.
- [x] Build affected recipes and image, inspect artifacts, document board checks.
- [x] Review scoped changes and commit.

Design: static DT aliases 80-87 for the eight mux channels, one YU08 Entity Manager exposure per chip using Bus/Address/Name/Name1/PowerState, a minimal dbus-sensors type-map and range patch. Existing schema accepts YU08. Configure all 16 fan inputs. Do not invent a reset GPIO or delay patch without hardware mapping.
