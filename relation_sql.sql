DROP FUNCTION IF EXISTS relation_sql(text);

CREATE FUNCTION relation_sql(mode text DEFAULT 'status') RETURNS TABLE (
  status text
  , command text
  , schema_name text
  , table_name text
  , fk_name text
  , fk_columns text[]
  , ref_schema_name text
  , ref_table_name text
  , ref_columns text[]
  , direction text
  , calc_name text
  , calc_args text
  , calc_return text
  , calc_body text
  , db_name text
  , db_args text
  , db_return text
  , db_body text
  , drop_db_sql text
  , create_replace_body_sql text
  , status_drop_sql text
) LANGUAGE plpgsql SET search_path FROM CURRENT
AS $fn$
#variable_conflict use_column
DECLARE
  r record;
BEGIN
  IF mode = 'show' THEN
    RETURN QUERY
    WITH fk AS (
      SELECT c.oid fk_oid
        , c.conname fk_name
        , cn.nspname schema_name
        , cn.oid schema_oid
        , cr.relname table_name
        , cr.oid table_oid
        , cr.reltype table_type_oid
        , rn.nspname ref_schema_name
        , rn.oid ref_schema_oid
        , rr.relname ref_table_name
        , rr.oid ref_table_oid
        , rr.reltype ref_table_type_oid
        , c.conkey
        , c.confkey
        , pk.ref_pk_attnum
        , pk.ref_pk_name
      FROM pg_constraint c
      JOIN pg_class cr ON cr.oid = c.conrelid
      JOIN pg_namespace cn ON cn.oid = cr.relnamespace
      JOIN pg_class rr ON rr.oid = c.confrelid
      JOIN pg_namespace rn ON rn.oid = rr.relnamespace
      LEFT JOIN LATERAL (
        SELECT p.conkey[1] ref_pk_attnum, a.attname ref_pk_name
        FROM pg_constraint p
        JOIN pg_attribute a ON (a.attrelid, a.attnum) = (p.conrelid, p.conkey[1])
        WHERE (p.conrelid, p.contype) = (c.confrelid, 'p')
          AND cardinality(p.conkey) = 1
      ) pk ON true
      WHERE c.contype = 'f'
        AND c.conparentid = 0
        AND cn.nspname NOT LIKE 'pg\_%'
        AND cn.nspname <> 'information_schema'
    )
    , fk_col_pos AS (
      SELECT f.fk_oid
        , f.table_oid
        , f.ref_table_oid
        , u.ord
        , a.attname col
        , ra.attname ref_col
        , u.ref_attnum
        , f.ref_pk_attnum
      FROM fk f
      JOIN LATERAL unnest(f.conkey, f.confkey) WITH ORDINALITY u(attnum, ref_attnum, ord) ON true
      JOIN pg_attribute a ON (a.attrelid, a.attnum) = (f.table_oid, u.attnum)
      JOIN pg_attribute ra ON (ra.attrelid, ra.attnum) = (f.ref_table_oid, u.ref_attnum)
    )
    , fk_cols AS (
      SELECT fk_oid
        , array_agg(col ORDER BY ord) fk_columns
        , array_agg(ref_col ORDER BY ord) ref_columns
        , min(col) FILTER (WHERE ref_attnum = ref_pk_attnum) pk_ref_column
      FROM fk_col_pos
      GROUP BY fk_oid
    )
    , pos_variant AS (
      SELECT table_oid, ref_table_oid, ord, count(DISTINCT col) variants
      FROM fk_col_pos
      GROUP BY table_oid, ref_table_oid, ord
    )
    , fk_diff AS (
      SELECT p.fk_oid
        , min(p.col) FILTER (WHERE v.variants > 1) diff_column
        , min(p.ref_col) FILTER (WHERE v.variants > 1) diff_ref_column
        , count(*) FILTER (WHERE v.variants > 1) diff_count
      FROM fk_col_pos p
      JOIN pos_variant v ON (v.table_oid, v.ref_table_oid, v.ord) = (p.table_oid, p.ref_table_oid, p.ord)
      GROUP BY p.fk_oid
    )
    , uniq AS (
      SELECT fk_oid
        , EXISTS (
          SELECT FROM pg_index
          WHERE indrelid = fk.table_oid
            AND indisunique
            AND indpred IS NULL
            AND indexprs IS NULL
            AND (
              SELECT array_agg(t.k) FROM unnest(indkey::smallint[]) WITH ORDINALITY t(k, ord)
              WHERE t.ord <= indnkeyatts
            ) <@ fk.conkey
        ) one_to_one
      FROM fk
    )
    , named AS (
      SELECT f.*
        , fc.fk_columns
        , fc.ref_columns
        , u.one_to_one
        , coalesce(
          nullif(
            CASE
              WHEN s.sem IS NULL OR w.cut IS NULL THEN NULL
              WHEN s.sem = w.cut THEN ''
              WHEN right(s.sem, length(w.cut) + 1) = '_' || w.cut THEN left(s.sem, -(length(w.cut) + 1))
              WHEN right(s.sem, length(initcap(w.cut))) = initcap(w.cut) THEN left(s.sem, -length(initcap(w.cut)))
              ELSE s.sem
            END
            , ''
          )
          , f.ref_table_name
        ) role_name
        , count(*) OVER (PARTITION BY f.table_oid, f.ref_table_oid) > 1 ambiguous
      FROM fk f
      JOIN fk_cols fc ON fc.fk_oid = f.fk_oid
      JOIN fk_diff fd ON fd.fk_oid = f.fk_oid
      JOIN uniq u ON u.fk_oid = f.fk_oid
      CROSS JOIN LATERAL (
        SELECT CASE
            WHEN cardinality(fc.fk_columns) = 1 THEN fc.fk_columns[1]
            WHEN fc.pk_ref_column IS NOT NULL THEN fc.pk_ref_column
            WHEN fd.diff_count = 1 THEN fd.diff_column
          END sem
          , CASE
            WHEN cardinality(fc.fk_columns) = 1 THEN fc.ref_columns[1]
            WHEN fc.pk_ref_column IS NOT NULL THEN f.ref_pk_name
            WHEN fd.diff_count = 1 THEN fd.diff_ref_column
          END sem_ref
      ) s
      CROSS JOIN LATERAL (
        SELECT CASE WHEN s.sem = s.sem_ref THEN f.ref_pk_name ELSE s.sem_ref END cut
      ) w
    )
    , calc AS (
      SELECT n.schema_name
        , n.table_name
        , n.fk_name
        , n.fk_columns
        , n.ref_schema_name
        , n.ref_table_name
        , n.ref_columns
        , d.direction
        , d.arg_schema
        , d.arg_table
        , d.arg_nsp_oid
        , d.arg_type_oid
        , d.ret_schema
        , d.ret_table
        , d.ret_type_oid
        , (CASE WHEN EXISTS (
            SELECT FROM pg_attribute
            WHERE (attrelid, attname) = (d.arg_table_oid, d.calc_name)
              AND attnum > 0
              AND NOT attisdropped
          ) THEN d.calc_name || '_ref' ELSE d.calc_name END)::name::text calc_name
        , format(
          'SELECT * FROM %I.%I WHERE (%s) = (%s)'
          , d.ret_schema, d.ret_table
          , (
            SELECT string_agg(format('%I', m.col), ', ' ORDER BY m.ord)
            FROM unnest(d.ret_match_columns) WITH ORDINALITY m(col, ord)
          )
          , (
            SELECT string_agg(format('($1).%I', m.col), ', ' ORDER BY m.ord)
            FROM unnest(d.arg_match_columns) WITH ORDINALITY m(col, ord)
          )
        ) calc_body
        , format('%I.%I', d.arg_schema, d.arg_table) calc_args
        , format('SETOF %I.%I', d.ret_schema, d.ret_table) calc_return
      FROM named n
      CROSS JOIN LATERAL (
        VALUES (
          'lookup'
          , n.schema_name, n.table_name, n.schema_oid, n.table_oid, n.table_type_oid
          , n.ref_schema_name, n.ref_table_name, n.ref_table_type_oid
          , n.role_name
          , n.ref_columns, n.fk_columns
        ), (
          'list'
          , n.ref_schema_name, n.ref_table_name, n.ref_schema_oid, n.ref_table_oid, n.ref_table_type_oid
          , n.schema_name, n.table_name, n.table_type_oid
          , CASE WHEN n.ambiguous THEN n.role_name || '_' ELSE '' END
            || n.table_name
            || CASE WHEN n.one_to_one THEN '' ELSE '_list' END
          , n.fk_columns, n.ref_columns
        )
      ) d(direction, arg_schema, arg_table, arg_nsp_oid, arg_table_oid, arg_type_oid, ret_schema, ret_table, ret_type_oid, calc_name, ret_match_columns, arg_match_columns)
    )
    , db AS (
      SELECT c.*
        , format(
          'CREATE OR REPLACE FUNCTION %I.%I(%I.%I) RETURNS SETOF %I.%I LANGUAGE sql STABLE PARALLEL SAFE AS %L;'
          , c.arg_schema, c.calc_name, c.arg_schema, c.arg_table, c.ret_schema, c.ret_table, c.calc_body
        ) create_replace_body_sql
        , format('COMMENT ON FUNCTION %I.%I(%I.%I) IS %L;', c.arg_schema, c.calc_name, c.arg_schema, c.arg_table, 'pg_relation_sql') comment_sql
        , p.oid db_oid
        , p.proname db_name
        , pg_get_function_arguments(p.oid) db_args
        , pg_get_function_result(p.oid) db_return
        , p.prosrc db_body
        , p.proretset db_retset
        , p.prorettype db_rettype_oid
        , p.proparallel db_parallel
        , coalesce(obj_description(p.oid, 'pg_proc') = 'pg_relation_sql', false) db_marked
        , CASE WHEN p.oid IS NOT NULL THEN format('DROP FUNCTION %s;', p.oid::regprocedure) END drop_db_sql
        , count(*) OVER (PARTITION BY c.arg_nsp_oid, c.calc_name, c.arg_type_oid) name_claims
      FROM calc c
      LEFT JOIN pg_proc p ON (p.pronamespace, p.proname) = (c.arg_nsp_oid, c.calc_name)
        AND p.pronargs = 1
        AND p.proargtypes[0] = c.arg_type_oid
    )
    , verdict AS (
      SELECT db.*
        , CASE
          WHEN name_claims > 1 THEN 'DUPLICATE_NAME'
          WHEN db_oid IS NULL THEN 'NEED_CREATE_OR_REPLACE'
          WHEN NOT db_marked THEN 'FOREIGN_FUNCTION'
          WHEN NOT (db_retset AND db_rettype_oid = ret_type_oid) THEN 'NEED_DROP_CREATE'
          WHEN db_body <> calc_body OR db_parallel <> 's' THEN 'NEED_CREATE_OR_REPLACE'
          ELSE 'OK'
        END status
      FROM db
    )
    , orphan AS (
      SELECT pn.nspname schema_name
        , p.proname db_name
        , pg_get_function_arguments(p.oid) db_args
        , pg_get_function_result(p.oid) db_return
        , p.prosrc db_body
        , format('DROP FUNCTION %s;', p.oid::regprocedure) drop_db_sql
      FROM pg_proc p
      JOIN pg_namespace pn ON pn.oid = p.pronamespace
      WHERE obj_description(p.oid, 'pg_proc') = 'pg_relation_sql'
        AND NOT EXISTS (
          SELECT FROM calc c
          WHERE (c.arg_nsp_oid, c.calc_name, c.arg_type_oid) = (p.pronamespace, p.proname, p.proargtypes[0])
        )
    )
    , result AS (
      SELECT status
        , CASE status
          WHEN 'NEED_DROP_CREATE' THEN drop_db_sql || ' ' || create_replace_body_sql || ' ' || comment_sql
          WHEN 'NEED_CREATE_OR_REPLACE' THEN create_replace_body_sql || ' ' || comment_sql
        END command
        , schema_name::text
        , table_name::text
        , fk_name::text
        , fk_columns::text[]
        , ref_schema_name::text
        , ref_table_name::text
        , ref_columns::text[]
        , direction
        , calc_name::text
        , calc_args
        , calc_return
        , calc_body
        , db_name::text
        , db_args
        , db_return
        , db_body
        , drop_db_sql
        , create_replace_body_sql
        , CASE WHEN status NOT IN ('FOREIGN_FUNCTION', 'DUPLICATE_NAME') THEN drop_db_sql END status_drop_sql
      FROM verdict
      UNION ALL
      SELECT 'ORPHANED'
        , drop_db_sql
        , schema_name::text
        , NULL, NULL, NULL::text[], NULL, NULL, NULL::text[], NULL, NULL, NULL, NULL, NULL
        , db_name::text
        , db_args
        , db_return
        , db_body
        , drop_db_sql
        , NULL
        , drop_db_sql
      FROM orphan
    )
    SELECT * FROM result
    ORDER BY 3, 4, 5, 10;
    RETURN;
  ELSIF mode IN ('sync', 'drop') THEN
    FOR r IN
      SELECT c.q
      FROM relation_sql('show') s
      , LATERAL (SELECT CASE mode WHEN 'sync' THEN s.command ELSE s.status_drop_sql END q) c
      WHERE c.q IS NOT NULL
    LOOP
      EXECUTE r.q;
    END LOOP;
  ELSIF mode IN ('install', 'uninstall') THEN
    BEGIN
      EXECUTE 'DROP EVENT TRIGGER IF EXISTS relation_sql_ddl';
      EXECUTE 'DROP FUNCTION IF EXISTS relation_sql_event()';
      IF mode = 'install' THEN
        EXECUTE $e$
          CREATE FUNCTION relation_sql_event() RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path FROM CURRENT
          AS $b$ BEGIN PERFORM count(*) FROM relation_sql('sync'); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'pg_relation_sql sync failed: %', SQLERRM; END $b$
        $e$;
        EXECUTE 'CREATE EVENT TRIGGER relation_sql_ddl ON ddl_command_end WHEN TAG IN (''CREATE TABLE'', ''ALTER TABLE'', ''DROP TABLE'', ''CREATE SCHEMA'', ''DROP SCHEMA'') EXECUTE FUNCTION relation_sql_event()';
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE WARNING 'pg_relation_sql: event trigger needs superuser rights, skipped — %', SQLERRM;
    END;
    IF mode = 'install' THEN
      PERFORM count(*) FROM relation_sql('sync');
    END IF;
  ELSIF mode <> 'status' THEN
    RAISE EXCEPTION 'unknown mode: %', mode USING HINT = 'status, show, sync, install, uninstall, drop';
  END IF;
  RETURN QUERY
  WITH trg AS (
    SELECT EXISTS (SELECT FROM pg_event_trigger WHERE evtname = 'relation_sql_ddl') installed
      , 'SELECT status, command FROM relation_sql(%L)' cmd
  )
  , agg AS (
    SELECT count(*) FILTER (WHERE status = 'OK') n_ok
      , count(*) FILTER (WHERE status IN ('NEED_CREATE_OR_REPLACE', 'NEED_DROP_CREATE', 'ORPHANED')) n_pending
      , count(*) FILTER (WHERE status = 'FOREIGN_FUNCTION') n_foreign
      , count(*) FILTER (WHERE status = 'DUPLICATE_NAME') n_duplicate
    FROM relation_sql('show')
  )
  , board(status, command) AS (
    SELECT 'pg_relation_sql 0.1.0 — relation functions generated from foreign keys'
      , 'SELECT status, command FROM relation_sql()'
    UNION ALL
    SELECT 'event trigger: ' || CASE WHEN installed THEN 'installed' ELSE 'not installed' END
      , format(cmd, CASE WHEN installed THEN 'uninstall' ELSE 'install' END)
    FROM trg
    UNION ALL
    SELECT format('relation functions: %s ok, %s to sync, %s foreign, %s duplicate', a.n_ok, a.n_pending, a.n_foreign, a.n_duplicate)
      , format(t.cmd, CASE WHEN a.n_pending > 0 THEN 'sync' ELSE 'drop' END)
    FROM agg a, trg t
    UNION ALL
    SELECT 'details', 'SELECT * FROM relation_sql(''show'')'
  )
  SELECT status, command
    , NULL, NULL, NULL, NULL::text[], NULL, NULL, NULL::text[], NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM board;
END $fn$;

SELECT status, command FROM relation_sql('install');
