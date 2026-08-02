# Test environment

Fresh PostgreSQL 18 in Docker with everything installed on first start: the [example schema](../example/README.md) and seed data (`example/init.sql`), bulk data for plan comparisons (`bigdata.sql`) and the self-installing generator (`relation_sql.sql`) — loading it creates the event trigger and all relation functions.

Bulk volumes: 100k clients + 1k managers, 70k profile details, 120k addresses, 20k items in a 3-level tree, 300k documents, 1.35M document lines. First start takes about a minute.

## Start

```bash
docker compose up -d
```

## Connect

```bash
psql postgresql://postgres:postgres@localhost:5440/postgres
```

## Check

```sql
SELECT status, command FROM relation_sql();
```

Expected: `event trigger: installed`, `relation functions: 16 ok, 0 to sync, 0 foreign, 0 duplicate`.

## Play

```bash
psql postgresql://postgres:postgres@localhost:5440/postgres -f ../example/query.sql
```

Or add a table and watch the functions appear on their own:

```sql
CREATE TABLE note (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY
  , profile_id BIGINT NOT NULL REFERENCES profile (id)
  , body TEXT NOT NULL
);
```

```sql
SELECT p.name, n.body FROM profile p, note_list(p) n;
```

Dropping a table needs `CASCADE` — its relation functions depend on the row type; the event trigger cleans up whatever remains:

```sql
DROP TABLE note CASCADE;
```

## Compare plans

```sql
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT d.doc_number
FROM profile p, client_document_list(p) d
WHERE p.email = 'user50000@load.test'
;
```

Run each query twice and read the second, warm-cache run — the first one pays for cold buffers; `TIMING OFF` keeps totals free of instrumentation overhead. Same query with an explicit `JOIN document d ON d.client_id = p.client_id` produces a node-for-node identical plan; captured side-by-side pairs live in [EXPLAIN.md](../EXPLAIN.md).

## Reset

```bash
docker compose down -v
```
