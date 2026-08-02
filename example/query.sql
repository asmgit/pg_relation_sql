-- example 1: documents with client (lookup)
-- classic joins
SELECT d.doc_number, p.name
FROM document d
JOIN profile p ON p.client_id = d.client_id
;
-- relation functions
SELECT d.doc_number, p.name
FROM document d, client(d) p
;
-- relation functions, no aliases
SELECT document.doc_number, client.name
FROM document, client(document)
;

-- example 2: document lines with item, client and optional manager (relation chain)
-- classic joins
SELECT i.name item_name, p.name client_name, m.name manager_name, di.quantity, md.phone manager_phone
FROM document_item di
JOIN document d ON d.id = di.document_id
JOIN item i ON i.id = di.item_id
JOIN profile p ON p.client_id = d.client_id
LEFT JOIN profile m ON m.manager_id = d.manager_id
LEFT JOIN profile_detail md ON md.profile_id = m.id
;
-- relation functions
SELECT i.name item_name, p.name client_name, m.name manager_name, di.quantity, md.phone manager_phone
FROM document_item di, document(di) d, item(di) i, client(d) p
LEFT JOIN manager(d) m ON true
LEFT JOIN profile_detail(m) md ON true
;
-- relation functions, no aliases
SELECT item.name item_name, client.name client_name, manager.name manager_name, document_item.quantity, profile_detail.phone manager_phone
FROM document_item, document(document_item), item(document_item), client(document)
LEFT JOIN manager(document) ON true
LEFT JOIN profile_detail(manager) ON true
;

-- example 3: document count per client (list + aggregate)
-- classic joins
SELECT p.name, count(d.id) doc_count
FROM profile p
LEFT JOIN document d ON d.client_id = p.client_id
WHERE p.type = 'client'
GROUP BY p.id
;
-- relation functions
SELECT p.name, count(d.id) doc_count
FROM profile p
LEFT JOIN client_document_list(p) d ON true
WHERE p.type = 'client'
GROUP BY p.id
;

-- example 4: relations as fields, incl. composite FK (attribute notation)
-- classic
SELECT doc_number
  , (SELECT name FROM profile WHERE client_id = document.client_id) client_name
  , (SELECT city FROM address WHERE (id, profile_id) = (document.delivery_address_id, document.client_id)) delivery_city
FROM document
;
-- relation functions
SELECT doc_number, (document.client).name client_name, (document.delivery_address).city delivery_city
FROM document
;

-- example 5: filter by related table (delivery to Berlin)
-- classic joins
SELECT d.doc_number, a.city
FROM document d
JOIN address a ON (a.id, a.profile_id) = (d.delivery_address_id, d.client_id)
WHERE a.city = 'Berlin'
;
-- relation functions
SELECT d.doc_number, a.city
FROM document d, delivery_address(d) a
WHERE a.city = 'Berlin'
;

-- example 6: anti-join (clients without documents)
-- classic joins
SELECT name
FROM profile
WHERE type = 'client'
  AND NOT EXISTS (SELECT FROM document WHERE document.client_id = profile.client_id)
;
-- relation functions
SELECT name
FROM profile
WHERE type = 'client'
  AND NOT EXISTS (SELECT FROM client_document_list(profile))
;

-- example 7: aggregate over m:n (document total)
-- classic joins
SELECT d.doc_number, sum(di.quantity * i.price) total
FROM document d
JOIN document_item di ON di.document_id = d.id
JOIN item i ON i.id = di.item_id
GROUP BY d.id
;
-- relation functions
SELECT d.doc_number, sum(di.quantity * i.price) total
FROM document d, document_item_list(d) di, item(di) i
GROUP BY d.id
;

-- example 8: self-reference tree (item parent and children)
-- classic joins
SELECT i.name, pi.name parent_name
FROM item i
LEFT JOIN item pi ON pi.id = i.parent_item_id
;
SELECT pi.name, i.name child_name
FROM item pi
JOIN item i ON i.parent_item_id = pi.id
;
-- relation functions
SELECT i.name, pi.name parent_name
FROM item i
LEFT JOIN parent_item(i) pi ON true
;
SELECT pi.name, i.name child_name
FROM item pi, item_list(pi) i
;

-- example 9: two FKs to the same table (documents where profile is the manager)
-- classic joins
SELECT p.name, d.doc_number
FROM profile p
JOIN document d ON d.manager_id = p.manager_id
;
-- relation functions
SELECT p.name, d.doc_number
FROM profile p, manager_document_list(p) d
;

-- example 10: nested json (document with its lines)
-- classic joins
SELECT d.doc_number, jsonb_agg(jsonb_build_object('item', i.name, 'quantity', di.quantity) ORDER BY i.name) lines
FROM document d
JOIN document_item di ON di.document_id = d.id
JOIN item i ON i.id = di.item_id
GROUP BY d.id
;
-- relation functions
SELECT d.doc_number, jsonb_agg(jsonb_build_object('item', i.name, 'quantity', di.quantity) ORDER BY i.name) lines
FROM document d, document_item_list(d) di, item(di) i
GROUP BY d.id
;

-- example 11: top-n per group (latest document of each client)
-- classic joins
SELECT p.name, ld.doc_number, ld.issued_at
FROM profile p
CROSS JOIN LATERAL (
  SELECT * FROM document WHERE document.client_id = p.client_id ORDER BY issued_at DESC, id DESC LIMIT 1
) ld
WHERE p.type = 'client'
;
-- relation functions
SELECT p.name, ld.doc_number, ld.issued_at
FROM profile p
CROSS JOIN LATERAL (
  SELECT * FROM client_document_list(p) ORDER BY issued_at DESC, id DESC LIMIT 1
) ld
WHERE p.type = 'client'
;

-- example 12: dml with relation navigation (raise prices of items bought by a client)
-- classic joins
BEGIN;
UPDATE item SET price = price * 1.10
WHERE EXISTS (
  SELECT FROM document_item di
  JOIN document d ON d.id = di.document_id
  JOIN profile p ON p.client_id = d.client_id
  WHERE di.item_id = item.id
    AND p.email = 'c2@x.io'
)
RETURNING item.name, item.price
;
ROLLBACK;
-- relation functions
BEGIN;
UPDATE item SET price = price * 1.10
WHERE EXISTS (
  SELECT FROM document_item_list(item) di, document(di) d, client(d) p
  WHERE p.email = 'c2@x.io'
)
RETURNING item.name, item.price
;
ROLLBACK;

-- example 13: recursive tree walk (item and all descendants)
-- classic joins
WITH RECURSIVE tree AS (
  SELECT * FROM item WHERE parent_item_id IS NULL
  UNION ALL
  SELECT i.* FROM tree t JOIN item i ON i.parent_item_id = t.id
)
SELECT name FROM tree
;
-- relation functions
WITH RECURSIVE tree AS (
  SELECT item node FROM item WHERE parent_item_id IS NULL
  UNION ALL
  SELECT c node FROM tree t, item_list(t.node) c
)
SELECT (node).name FROM tree
;

-- example 14: aggregate over a deep relation chain (revenue per client)
-- classic joins
SELECT p.name, sum(di.quantity * i.price) revenue
FROM profile p
JOIN document d ON d.client_id = p.client_id
JOIN document_item di ON di.document_id = d.id
JOIN item i ON i.id = di.item_id
GROUP BY p.id
;
-- relation functions
SELECT p.name, sum(di.quantity * i.price) revenue
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
GROUP BY p.id
;

-- example 15: order by a related field (documents by client name)
-- classic
SELECT doc_number
FROM document
ORDER BY (SELECT name FROM profile WHERE client_id = document.client_id) DESC, doc_number
;
-- relation functions
SELECT doc_number
FROM document
ORDER BY (document.client).name DESC, doc_number
;

-- example 16: max brevity (relations expanded in the select list)
-- classic joins
SELECT p.name, d.doc_number
FROM profile p
JOIN document d ON d.client_id = p.client_id
;
SELECT d.doc_number, p.*
FROM document d
JOIN profile p ON p.client_id = d.client_id
;
SELECT name, (SELECT count(*) FROM document WHERE client_id = profile.client_id) doc_count
FROM profile
ORDER BY id
;
-- relation functions
SELECT name, (profile.client_document_list).doc_number
FROM profile
;
SELECT doc_number, (document.client).*
FROM document
;
SELECT name, (SELECT count(*) FROM client_document_list(profile)) doc_count
FROM profile
ORDER BY id
;

-- example 17: subquery membership with IN (clients who ever ordered an item)
-- classic joins
SELECT name
FROM profile
WHERE client_id IN (
  SELECT d.client_id FROM document d
  JOIN document_item di ON di.document_id = d.id
  JOIN item i ON i.id = di.item_id
  WHERE i.name = 'Mouse'
)
ORDER BY id
;
-- relation functions
SELECT name
FROM profile
WHERE client_id IN (
  SELECT d.client_id FROM item i, document_item_list(i) di, document(di) d
  WHERE i.name = 'Mouse'
)
ORDER BY id
;

-- example 18: set operations (items ordered by both clients, then only by the first)
-- classic joins
SELECT i.name
FROM item i
JOIN document_item di ON di.item_id = i.id
JOIN document d ON d.id = di.document_id
JOIN profile p ON p.client_id = d.client_id
WHERE p.email = 'c1@x.io'
INTERSECT
SELECT i.name
FROM item i
JOIN document_item di ON di.item_id = i.id
JOIN document d ON d.id = di.document_id
JOIN profile p ON p.client_id = d.client_id
WHERE p.email = 'c2@x.io'
ORDER BY 1
;
SELECT i.name
FROM item i
JOIN document_item di ON di.item_id = i.id
JOIN document d ON d.id = di.document_id
JOIN profile p ON p.client_id = d.client_id
WHERE p.email = 'c1@x.io'
EXCEPT
SELECT i.name
FROM item i
JOIN document_item di ON di.item_id = i.id
JOIN document d ON d.id = di.document_id
JOIN profile p ON p.client_id = d.client_id
WHERE p.email = 'c2@x.io'
ORDER BY 1
;
-- relation functions
SELECT i.name
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
WHERE p.email = 'c1@x.io'
INTERSECT
SELECT i.name
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
WHERE p.email = 'c2@x.io'
ORDER BY 1
;
SELECT i.name
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
WHERE p.email = 'c1@x.io'
EXCEPT
SELECT i.name
FROM profile p, client_document_list(p) d, document_item_list(d) di, item(di) i
WHERE p.email = 'c2@x.io'
ORDER BY 1
;

-- example 19: cte carrying whole rows (top clients by document count, their documents)
-- classic joins
WITH vip AS (
  SELECT p.id, p.name, p.client_id
  FROM profile p
  LEFT JOIN document d ON d.client_id = p.client_id
  WHERE p.type = 'client'
  GROUP BY p.id
  ORDER BY count(d.id) DESC, p.id
  LIMIT 2
)
SELECT v.name, d.doc_number
FROM vip v
JOIN document d ON d.client_id = v.client_id
ORDER BY 1, 2
;
-- relation functions
WITH vip AS (
  SELECT p client
  FROM profile p
  LEFT JOIN client_document_list(p) d ON true
  WHERE p.type = 'client'
  GROUP BY p.id
  ORDER BY count(d.id) DESC, p.id
  LIMIT 2
)
SELECT (v.client).name, d.doc_number
FROM vip v, client_document_list(v.client) d
ORDER BY 1, 2
;
