CREATE TABLE profile (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY
  , email TEXT NOT NULL UNIQUE
  , name TEXT NOT NULL
  , type TEXT NOT NULL CHECK (type IN ('client', 'manager', 'admin'))
  , client_id BIGINT UNIQUE GENERATED ALWAYS AS (CASE WHEN type = 'client' THEN id END) STORED
  , manager_id BIGINT UNIQUE GENERATED ALWAYS AS (CASE WHEN type = 'manager' THEN id END) STORED
  , created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE profile_detail (
  profile_id BIGINT PRIMARY KEY REFERENCES profile (id)
  , bio TEXT
  , phone TEXT
);

CREATE TABLE address (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY
  , profile_id BIGINT NOT NULL REFERENCES profile (id)
  , city TEXT NOT NULL
  , street TEXT NOT NULL
  , UNIQUE (id, profile_id)
);

CREATE INDEX address_profile_id_idx ON address (profile_id);

CREATE TABLE item (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY
  , parent_item_id BIGINT REFERENCES item (id)
  , sku TEXT NOT NULL UNIQUE
  , name TEXT NOT NULL
  , price NUMERIC(12, 2) NOT NULL DEFAULT 0
);

CREATE INDEX item_parent_item_id_idx ON item (parent_item_id);

CREATE TABLE document (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY
  , client_id BIGINT NOT NULL REFERENCES profile (client_id)
  , manager_id BIGINT REFERENCES profile (manager_id)
  , delivery_address_id BIGINT
  , doc_number TEXT NOT NULL UNIQUE
  , issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  , CONSTRAINT document_delivery_address_id_client_id_fkey
    FOREIGN KEY (delivery_address_id, client_id) REFERENCES address (id, profile_id)
);

CREATE INDEX document_client_id_idx ON document (client_id);
CREATE INDEX document_manager_id_idx ON document (manager_id);
CREATE INDEX document_delivery_address_id_idx ON document (delivery_address_id);

CREATE TABLE document_item (
  document_id BIGINT NOT NULL REFERENCES document (id)
  , item_id BIGINT NOT NULL REFERENCES item (id)
  , quantity INT NOT NULL DEFAULT 1 CHECK (quantity > 0)
  , PRIMARY KEY (document_id, item_id)
);

CREATE INDEX document_item_item_id_idx ON document_item (item_id);

INSERT INTO profile (email, name, type) VALUES
  ('c1@x.io', 'Client One', 'client')
  , ('c2@x.io', 'Client Two', 'client')
  , ('m@x.io', 'Manager', 'manager')
  , ('c3@x.io', 'Client Three', 'client')
;

INSERT INTO profile_detail (profile_id, bio, phone) VALUES
  (1, 'Regular buyer', '+49 30 1111111')
  , (3, 'Sales manager', '+49 30 5555555')
;

INSERT INTO address (profile_id, city, street) VALUES
  (1, 'Berlin', 'Alexanderplatz 1')
  , (2, 'Paris', 'Rue de Rivoli 2')
;

INSERT INTO item (parent_item_id, sku, name, price) VALUES
  (NULL, 'SKU-1', 'Laptop', 1200)
  , (1, 'SKU-2', 'Mouse', 25)
  , (1, 'SKU-3', 'Keyboard', 90)
  , (2, 'SKU-4', 'Mouse Pro', 45)
;

INSERT INTO document (client_id, manager_id, delivery_address_id, doc_number, issued_at) VALUES
  (1, 3, 1, 'DOC-1', '2026-07-01')
  , (1, NULL, NULL, 'DOC-2', '2026-07-15')
  , (2, 3, 2, 'DOC-3', '2026-07-20')
;

INSERT INTO document_item (document_id, item_id, quantity) VALUES
  (1, 1, 1)
  , (1, 2, 2)
  , (2, 3, 1)
  , (3, 2, 5)
;
