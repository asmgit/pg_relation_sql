# Changelog

## 0.2.0 — 2026-08-02

- Explicit relation role via the `_rel` constraint-name suffix: name an FK constraint `<role>_rel` and the role is taken verbatim — `delivery_address_rel` gives `delivery_address(document)`.
- Renaming the constraint renames the relation — the event trigger picks it up.
- ORM-generated constraint names (`_fkey`, `fk_*`, hashes) never match the suffix, so existing schemas are unaffected; the degenerate name `_rel` is ignored.
- Example schema demonstrates the suffix on the composite delivery-address FK.

## 0.1.0 — 2026-08-02

- Initial release: relation functions generated from foreign keys.
- Every FK becomes a pair of inlined SQL functions — lookup (`client(document)`) and list (`client_document_list(profile)`); plans identical to hand-written joins (PostgreSQL 11+).
- Single self-installing SQL file: `curl | psql` creates the functions and the DDL-tracking event trigger, prints a dashboard.
- `relation_sql(mode)`: show / sync / install / uninstall / drop, statuses per FK, COMMENT marker, loud renames, graceful no-superuser install.
- Demo schema, 19 side-by-side query pairs, docker stand with a 1.35M-row dataset, EXPLAIN walkthroughs.
