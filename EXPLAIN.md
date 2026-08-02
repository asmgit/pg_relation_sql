# EXPLAIN: relation functions vs classic joins

Plans captured on the [test environment](test/README.md): PostgreSQL 18, 100k clients, 300k documents, 1.35M document lines. `EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, BUFFERS OFF)` everywhere — per-node timing is off so the totals are not skewed by instrumentation; every query is run twice and the second, warm-cache run is the one recorded. Sub-millisecond totals still jitter between runs — the point of each pair is the plan, not the decimals. In the relation-function plans the bare table names (`document`, `profile`) are the function bodies inlined by the planner — the functions themselves are gone; aliases appear only where the query itself declares them. The exact inlining conditions: [Inlining of SQL functions](https://wiki.postgresql.org/wiki/Inlining_of_SQL_functions).

## 1. Selective lookup navigation

```sql
SELECT d.doc_number
FROM profile p
JOIN document d ON d.client_id = p.client_id
WHERE p.email = 'user50000@load.test'
;
```

```
 Nested Loop (actual rows=3.00 loops=1)
   ->  Index Scan using profile_email_key on profile p (actual rows=1.00 loops=1)
         Index Cond: (email = 'user50000@load.test'::text)
   ->  Index Scan using document_client_id_idx on document d (actual rows=3.00 loops=1)
         Index Cond: (client_id = p.client_id)
 Execution Time: 0.086 ms
```

```sql
SELECT d.doc_number
FROM profile p, client_document_list(p) d
WHERE p.email = 'user50000@load.test'
;
```

```
 Nested Loop (actual rows=3.00 loops=1)
   ->  Index Scan using profile_email_key on profile p (actual rows=1.00 loops=1)
         Index Cond: (email = 'user50000@load.test'::text)
   ->  Index Scan using document_client_id_idx on document (actual rows=3.00 loops=1)
         Index Cond: (client_id = p.client_id)
 Execution Time: 0.083 ms
```

Node-for-node identical: same nested loop, same two indexes.

## 2. Relation chain by a unique key

```sql
SELECT i.name item_name, p.name client_name, di.quantity
FROM document_item di
JOIN document d ON d.id = di.document_id
JOIN item i ON i.id = di.item_id
JOIN profile p ON p.client_id = d.client_id
WHERE d.doc_number = 'DOC-200000'
;
```

```
 Nested Loop (actual rows=1.00 loops=1)
   ->  Nested Loop (actual rows=1.00 loops=1)
         ->  Nested Loop (actual rows=1.00 loops=1)
               ->  Index Scan using document_doc_number_key on document d
               ->  Index Scan using profile_client_id_key on profile p
         ->  Index Scan using document_item_pkey on document_item di
   ->  Index Scan using item_pkey on item i
 Execution Time: 0.119 ms
```

```sql
SELECT i.name item_name, p.name client_name, di.quantity
FROM document d, document_item_list(d) di, item(di) i, client(d) p
WHERE d.doc_number = 'DOC-200000'
;
```

```
 Nested Loop (actual rows=1.00 loops=1)
   ->  Nested Loop (actual rows=1.00 loops=1)
         ->  Nested Loop (actual rows=1.00 loops=1)
               ->  Index Scan using document_doc_number_key on document d
               ->  Index Scan using profile_client_id_key on profile
         ->  Index Scan using document_item_pkey on document_item
   ->  Index Scan using item_pkey on item
 Execution Time: 0.124 ms
```

Four tables, three relation hops, zero `ON` conditions — same plan shape, same indexes.

## 3. Optional relation: LEFT JOIN ... ON true

```sql
SELECT d.doc_number, m.name manager_name
FROM document d
LEFT JOIN profile m ON m.manager_id = d.manager_id
WHERE d.doc_number = 'DOC-200000'
;
```

```
 Nested Loop Left Join (actual rows=1.00 loops=1)
   ->  Index Scan using document_doc_number_key on document d (actual rows=1.00 loops=1)
         Index Cond: (doc_number = 'DOC-200000'::text)
   ->  Index Scan using profile_manager_id_key on profile m (actual rows=1.00 loops=1)
         Index Cond: (manager_id = d.manager_id)
 Execution Time: 0.079 ms
```

```sql
SELECT d.doc_number, m.name manager_name
FROM document d
LEFT JOIN manager(d) m ON true
WHERE d.doc_number = 'DOC-200000'
;
```

```
 Nested Loop Left Join (actual rows=1.00 loops=1)
   ->  Index Scan using document_doc_number_key on document d (actual rows=1.00 loops=1)
         Index Cond: (doc_number = 'DOC-200000'::text)
   ->  Index Scan using profile_manager_id_key on profile (actual rows=1.00 loops=1)
         Index Cond: (manager_id = d.manager_id)
 Execution Time: 0.072 ms
```

The `ON true` form flattens to the same `Nested Loop Left Join` — the join condition travels inside the function and lands as the inner index condition.

## 4. Composite FK over a full scan

```sql
SELECT count(*)
FROM document d
JOIN address a ON (a.id, a.profile_id) = (d.delivery_address_id, d.client_id)
WHERE a.city = 'Berlin'
;
```

```
 Finalize Aggregate (actual rows=1.00 loops=1)
   ->  Gather (Workers Launched: 1)
         ->  Partial Aggregate
               ->  Hash Join
                     Hash Cond: ((d.delivery_address_id = a.id) AND (d.client_id = a.profile_id))
                     ->  Parallel Seq Scan on document d
                     ->  Hash
                           ->  Seq Scan on address a
                                 Filter: (city = 'Berlin'::text)
 Execution Time: 28.288 ms
```

```sql
SELECT count(*)
FROM document d, delivery_address(d) a
WHERE a.city = 'Berlin'
;
```

```
 Finalize Aggregate (actual rows=1.00 loops=1)
   ->  Gather (Workers Launched: 1)
         ->  Partial Aggregate
               ->  Hash Join
                     Hash Cond: ((d.delivery_address_id = address.id) AND (d.client_id = address.profile_id))
                     ->  Parallel Seq Scan on document d
                     ->  Hash
                           ->  Seq Scan on address
                                 Filter: (city = 'Berlin'::text)
 Execution Time: 26.249 ms
```

The two-column condition of the composite FK survives inlining, parallel workers included.

## 5. Aggregate over a deep chain, full tables

```sql
SELECT p.name, sum(di.quantity * i.price) revenue
FROM profile p
JOIN document d ON d.client_id = p.client_id
JOIN document_item di ON di.document_id = d.id
JOIN item i ON i.id = di.item_id
GROUP BY p.id
ORDER BY revenue DESC
LIMIT 5
;
```

```
 Limit (actual rows=5.00 loops=1)
   ->  Sort -> Finalize GroupAggregate -> Gather Merge (Workers Launched: 2)
         ->  Sort -> Partial HashAggregate
               ->  Hash Join (di.item_id = i.id)
                     ->  Parallel Hash Join (d.client_id = p.client_id)
                           ->  Parallel Hash Join (di.document_id = d.id)
 Execution Time: 559.170 ms
```

```sql
SELECT p.name, sum(di.quantity * i.price) revenue
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
GROUP BY p.id
ORDER BY revenue DESC
LIMIT 5
;
```

```
 Limit (actual rows=5.00 loops=1)
   ->  Sort -> Finalize GroupAggregate -> Gather Merge (Workers Launched: 2)
         ->  Sort -> Partial HashAggregate
               ->  Hash Join (document_item.item_id = item.id)
                     ->  Parallel Hash Join (document.client_id = p.client_id)
                           ->  Parallel Hash Join (document_item.document_id = document.id)
 Execution Time: 549.462 ms
```

1.35M rows through a three-hop chain: same parallel hash join pyramid, same two workers. Medians of five runs: 576 ms classic vs 571 ms functions — the leader flips between runs, the gap is run-to-run noise. The parity requires the functions to be `PARALLEL SAFE` — the generator declares it; with the default `PARALLEL UNSAFE` the same query ran ~1280 ms without a single worker, because parallel safety is decided before inlining.

## 6. Known difference: NOT EXISTS

```sql
SELECT count(*)
FROM profile
WHERE type = 'client'
  AND NOT EXISTS (SELECT FROM document WHERE document.client_id = profile.client_id)
;
```

```
 Finalize Aggregate (actual rows=1.00 loops=1)
   ->  Gather (Workers Launched: 1)
         ->  Partial Aggregate
               ->  Parallel Hash Anti Join
                     Hash Cond: (profile.client_id = document.client_id)
 Execution Time: 39.833 ms
```

```sql
SELECT count(*)
FROM profile
WHERE type = 'client'
  AND NOT EXISTS (SELECT FROM client_document_list(profile))
;
```

```
 Aggregate (actual rows=1.00 loops=1)
   ->  Seq Scan on profile
         Filter: ((type = 'client'::text) AND (NOT EXISTS(SubPlan 1)))
         SubPlan 1
           ->  Index Only Scan using document_client_id_idx on document (loops=100003)
                 Index Cond: (client_id = (profile.*).client_id)
 Execution Time: 95.557 ms
```

The planner converts `EXISTS` sublinks to semi/anti joins before it inlines functions, so the function version stays a correlated subplan: an index probe per outer row. With a selective outer filter the difference vanishes; on a full-table anti-join the classic spelling wins — use it there.

## 7. Known difference: attribute notation

```sql
SELECT doc_number, (document.client).name
FROM document
WHERE id <= 1100
;
```

```
 Gather (actual rows=103.00 loops=1)
   Workers Launched: 1
   ->  Result (actual rows=51.50 loops=2)
         ->  ProjectSet (actual rows=51.50 loops=2)
               ->  Parallel Seq Scan on document
                     Filter: (id <= 1100)
 Execution Time: 30.303 ms
```

`(document.client).name` in a select list is a `ProjectSet` — the function runs once per row instead of being inlined. Sugar for small result sets; navigate in `FROM` for heavy queries.
