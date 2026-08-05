# pg_relation_sql — JOIN BY FOREIGN KEY

**Join relations by foreign keys in plain SQL.**

Every foreign key becomes a pair of SQL functions — lookup and list — fully inlined by the PostgreSQL planner: the function is the relation, its argument is the model. Queries navigate declared relations instead of restating them in every `ON`:

```sql
SELECT document.doc_number, client.name, item.name, quantity
FROM document
, client(document)
, document_item_list(document)
, item(document_item_list)
WHERE document.doc_number = 'DOC-1'
```

instead of

```sql
SELECT d.doc_number, p.name, i.name, di.quantity
FROM document d
JOIN profile p ON p.client_id = d.client_id
JOIN document_item di ON di.document_id = d.id
JOIN item i ON i.id = di.item_id
WHERE d.doc_number = 'DOC-1'
```

## Install

One plain SQL file, no extension, PostgreSQL 11+:

```bash
curl -sf https://raw.githubusercontent.com/asmgit/pg_relation_sql/main/relation_sql.sql | psql postgresql://postgres:postgres@localhost:5432/postgres
```

Alternatively, open [relation_sql.sql](relation_sql.sql) and execute it in your SQL client — same result.

Check the state anytime:

```sql
SELECT status, command FROM relation_sql();
```

And the relations that appeared, each with a ready-to-run query:

```sql
SELECT tbl || ' → ' || calc_name relation
  , 'SELECT * FROM ' || tbl || ', ' || calc_name || '(' || tbl || ')' example
FROM relation_sql('show'), split_part(calc_args, '.', 2) tbl
ORDER BY 1
```

```
        relation        |                   example
------------------------+----------------------------------------------
 address → profile      | SELECT * FROM address, profile(address)
 profile → address_list | SELECT * FROM profile, address_list(profile)
```

Modes, details and removal: [The generator](#the-generator).

## How it works

Every foreign key gets a pair of generated functions — the relation query itself, written once: a row in, related rows out.

```sql
CREATE TABLE profile (
  id BIGINT PRIMARY KEY
  , name TEXT
);
CREATE TABLE address (
  id BIGINT PRIMARY KEY
  , profile_id BIGINT REFERENCES profile (id)
  , city TEXT
);
-- relation_sql generates the pair: the lookup and the list
CREATE FUNCTION profile(address) RETURNS SETOF profile LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT * FROM public.profile WHERE (id) = (($1).profile_id) $$
;
CREATE FUNCTION address_list(profile) RETURNS SETOF address LANGUAGE sql STABLE PARALLEL SAFE
AS $$ SELECT * FROM public.address WHERE (profile_id) = (($1).id) $$
;
-- queries navigate
SELECT a.city, p.name FROM address a, profile(a) p
;
SELECT p.name, a.city FROM profile p, address_list(p) a
;
```

### Zero runtime cost

When a relation function is used in `FROM`, the planner fully inlines it: `EXPLAIN` is node-for-node identical to the hand-written join — same nested-loop/hash strategies, same indexes, same parallel workers. Verified on 1.35M rows: [EXPLAIN.md](EXPLAIN.md).

The requirements, all guaranteed by the generator: `LANGUAGE sql`, `STABLE`, not `STRICT`, not `SECURITY DEFINER`, and `PARALLEL SAFE` — parallel safety is decided before inlining, so the default `PARALLEL UNSAFE` would silently block parallel workers for the whole query. The full inlining conditions: [Inlining of SQL functions](https://wiki.postgresql.org/wiki/Inlining_of_SQL_functions).

Two spellings do not inline — both fine for selective queries, both documented with plans in [EXPLAIN.md](EXPLAIN.md):

- attribute notation in a select list (`ProjectSet`, one call per row);
- `EXISTS (SELECT FROM f(x))` — sublinks become semi/anti joins before functions inline, so this stays a correlated index probe per row; on full-table anti-joins the classic subquery wins.

Two more practical notes. The generated body is `SELECT *`, so column-level privileges (`GRANT SELECT (id, name)`) don't mix with relation functions — after inlining the query needs the whole row; RLS composes as usual, policies apply to the table after inlining. And queries using relation functions run only where the functions exist — the same portability as queries against views; IDEs autocomplete them as ordinary catalog functions.

## Query patterns

```sql
-- document lines with item, client and optional manager
SELECT d.doc_number, i.name, di.quantity, p.name, m.name
FROM document_item di, document(di) d, item(di) i, client(d) p
LEFT JOIN manager(d) m ON true
;
-- deliveries to Berlin: the composite FK stays hidden
SELECT d.doc_number, a.street
FROM document d, delivery_address(d) a
WHERE a.city = 'Berlin'
;
-- revenue per client: three hops, zero ON
SELECT p.name, sum(di.quantity * i.price) revenue
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
GROUP BY p.id
;
-- the whole related row as a field
SELECT doc_number, (document.client).* FROM document
;
-- clients without documents
SELECT name FROM profile
WHERE type = 'client' AND NOT EXISTS (SELECT FROM client_document_list(profile))
;
-- recursive tree walk: the row travels as a value, the relation makes the step
WITH RECURSIVE tree AS (
  SELECT item node FROM item WHERE parent_item_id IS NULL
  UNION ALL
  SELECT c node FROM tree t, item_list(t.node) c
)
SELECT (node).name FROM tree
;
```

These queries run on the [demo schema](example/README.md) — an ER diagram where every edge carries its function pair, plus all 19 side-by-side pairs, classic vs relations.

## The generator

[relation_sql.sql](relation_sql.sql) is a single function, `relation_sql(mode)`; the event trigger and its support function are created and dropped by `install` / `uninstall`. The dashboard right after install:

```
                                 status                                 |                        command
------------------------------------------------------------------------+-------------------------------------------------------
 pg_relation_sql 0.2.0 — relation functions generated from foreign keys | SELECT status, command FROM relation_sql()
 event trigger: installed                                               | SELECT status, command FROM relation_sql('uninstall')
 relation functions: 16 ok, 0 to sync, 0 foreign, 0 duplicate           | SELECT status, command FROM relation_sql('drop')
 details                                                                | SELECT * FROM relation_sql('show')
```

The function always returns the same wide row — `status` and `command` plus every introspection column; project what you need:

- `relation_sql()` — read-only dashboard: shows the state and suggests the next command; only `status` and `command` are filled.
- `relation_sql('show')` — the heart: one row per FK per direction; `status` is the diff status, `command` the ready-to-run sync SQL, the rest of the columns hold the computed name, arguments, return type and body plus the actual state in the database.
- `relation_sql('sync')` — apply the diff once; no special rights. The team default: as a migration step, so the functions ship through the same pipeline and review as the rest of your DDL.
- `relation_sql('install')` / `relation_sql('uninstall')` — a single `ddl_command_end` event trigger that re-syncs automatically on `CREATE / ALTER / DROP TABLE`, `CREATE / DROP SCHEMA`. Needs superuser; without the rights the trigger is skipped with a `WARNING` while the sync still runs. Safe by construction: `SECURITY DEFINER` with a pinned `search_path`, and a blocked sync step logs a `WARNING` instead of failing your DDL.
- `relation_sql('drop')` — remove everything generated; together with `'uninstall'` and `DROP FUNCTION relation_sql(text)` the module leaves without a trace.

Statuses of `relation_sql('show')`:

| status | meaning | on sync |
|---|---|---|
| `OK` | function matches the computed definition | — |
| `NEED_CREATE_OR_REPLACE` | absent, or body/parallel flag differs | `CREATE OR REPLACE` |
| `NEED_DROP_CREATE` | return type differs (FK repointed) | `DROP` + `CREATE` |
| `FOREIGN_FUNCTION` | name taken by a function without the marker | never touched |
| `ORPHANED` | marked function whose FK is gone | dropped |
| `DUPLICATE_NAME` | two FKs computed the same name | nothing, human resolves |

Generated functions carry a `COMMENT` marker — that is how foreign functions are protected and orphans are found, and how both IDE tooling and schema-diff tools (migra, atlas) can filter the generated set out; with `sync` as a migration step they are ordinary managed DDL anyway. Renames cascade both ways. Dropping one of two same-target FKs makes the collision disappear — one sync drops the role-prefixed orphans and creates the short names. Adding a second FK to a target renames the existing short list function to a role-prefixed one — dependent queries fail loudly at compile time, and `'show'` displays the new names.

Dropping a table with relation functions requires `DROP TABLE ... CASCADE` — the functions depend on its row type; the event trigger then removes the partner-side leftovers. `pg_dump` / restore round-trips cleanly: generated functions travel as ordinary objects and the event trigger is restored after the schema, so it does not fire mid-restore.

### Naming rules

- Lookup role = FK column minus the referenced column's name: `(client_id) → (id)` gives `client(document)`; identical names (`client_id → client_id`) subtract the target's PK name instead. Subtraction respects `_`/CamelCase boundaries — `paid` and `clientid` are never mangled.
- Explicit role: name the FK constraint `<role>_rel` and the role is taken verbatim — `delivery_address_rel` gives `delivery_address(document)`; renaming the constraint renames the relation. ORM-generated names (`_fkey`, `fk_*`) never match the suffix.
- Composite FK: the semantic column is the one referencing the target's single-column PK — `(org_id, customer_id) → (org_id, id)` gives `customer`. Both keys composite — the shared context columns are discarded: `from_warehouse` / `to_warehouse`.
- No semantic column left (a column named just `id`) — the referenced table name: `profile(profile_extra)`.
- List: `<referencing_table>_list` — `document_item_list(document)`; the same name over different argument types is plain overloading.
- Several FKs to one target — lists get role prefixes: `client_document_list`, `manager_document_list`.
- 1:1 (FK columns unique) — singular, no suffix: `profile_detail(profile)`.
- Name taken by a column — `_ref` suffix: `document.client` stays the column, `document.client_ref` navigates.
- Names over 63 bytes are pre-truncated to the identifier limit; any collision, truncation or not, is `DUPLICATE_NAME` — nothing created, a human resolves.

Functions live in the schema of their argument table; cross-schema FKs work; partition clones and temp tables are skipped.

## Demo

No install at all — a [db&lt;&gt;fiddle sandbox](https://dbfiddle.uk/jpxmtrIr) with the demo schema, pre-generated relation functions and five navigation queries.

Full environment:

```bash
git clone https://github.com/asmgit/pg_relation_sql.git
cd pg_relation_sql/test && docker compose up -d
```

Fresh PostgreSQL in Docker with the example schema, bulk data (300k documents, 1.35M lines) and the module fully installed on first start, in about a minute — details in the [test environment guide](test/README.md).

## Status

Verified live, end to end:

- **DDL automation** — `CREATE TABLE` with an FK produces its pair mid-command, dropping the FK cleans it up, renames cascade on collisions.
- **Plans** — node-for-node identical to hand-written joins on 1.35M rows, parallel plans included.
- **Edge matrix** — mixed-case and reserved-word identifiers, cross-schema FKs, composite keys with positional roles, 63-byte truncation, duplicate names, foreign functions, orphans, partitioned and temp tables, dump/restore, DDL under arbitrary `search_path`.

## Support

If relation functions save you keystrokes, a star helps others find the project. Sponsoring keeps it maintained — via the Sponsor button above or a coffee at [ko-fi.com/asmgit](https://ko-fi.com/asmgit) — thank you.
