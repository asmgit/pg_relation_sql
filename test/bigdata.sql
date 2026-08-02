INSERT INTO profile (id, email, name, type) OVERRIDING SYSTEM VALUE
SELECT i
  , 'user' || i || '@load.test'
  , 'User ' || i
  , CASE WHEN i <= 101000 THEN 'client' ELSE 'manager' END
FROM generate_series(1001, 102000) i
;

INSERT INTO profile_detail (profile_id, bio, phone)
SELECT i
  , 'bio ' || i
  , '+49 30 ' || i
FROM generate_series(1001, 102000) i
WHERE i % 10 < 7
;

INSERT INTO address (id, profile_id, city, street) OVERRIDING SYSTEM VALUE
SELECT i
  , 1001 + ((i - 1001) % 100000)
  , (ARRAY['Berlin', 'Paris', 'Madrid', 'Rome', 'Vienna'])[i % 5 + 1]
  , 'Street ' || i
FROM generate_series(1001, 121000) i
;

INSERT INTO item (id, parent_item_id, sku, name, price) OVERRIDING SYSTEM VALUE
SELECT i
  , CASE
    WHEN i <= 3000 THEN NULL
    WHEN i <= 13000 THEN 1001 + ((i - 3001) % 2000)
    ELSE 3001 + ((i - 13001) % 10000)
  END
  , 'SKU-' || i
  , 'Item ' || i
  , (i % 990 + 10)::numeric
FROM generate_series(1001, 21000) i
;

INSERT INTO document (id, client_id, manager_id, delivery_address_id, doc_number, issued_at) OVERRIDING SYSTEM VALUE
SELECT i
  , 1001 + ((i - 1001) % 100000)
  , CASE WHEN i % 10 < 7 THEN 101001 + (i % 1000) END
  , CASE WHEN i % 5 < 3 THEN 1001 + ((i - 1001) % 100000) END
  , 'DOC-' || i
  , timestamptz '2025-01-01' + (i % 500) * interval '1 hour'
FROM generate_series(1001, 301000) i
;

INSERT INTO document_item (document_id, item_id, quantity)
SELECT i
  , 1001 + ((i * 7 + l * 13) % 20000)
  , l % 5 + 1
FROM generate_series(1001, 301000) i
CROSS JOIN LATERAL generate_series(1, i % 8 + 1) l
;

SELECT setval(pg_get_serial_sequence('profile', 'id'), (SELECT max(id) FROM profile));
SELECT setval(pg_get_serial_sequence('address', 'id'), (SELECT max(id) FROM address));
SELECT setval(pg_get_serial_sequence('item', 'id'), (SELECT max(id) FROM item));
SELECT setval(pg_get_serial_sequence('document', 'id'), (SELECT max(id) FROM document));

ANALYZE;
