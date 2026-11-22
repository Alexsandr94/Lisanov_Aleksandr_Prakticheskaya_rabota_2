-- Отпечатки всех базовых таблиц для сравнения исходного снимка и восстановления.
-- psql -X -qAt -v ON_ERROR_STOP=1 -f ...: только строки результата, без заголовков.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL DateStyle TO 'ISO, YMD';
SET LOCAL TIME ZONE 'UTC';

CREATE TEMP TABLE food_data_fingerprints (
    table_name text PRIMARY KEY,
    row_count bigint NOT NULL,
    data_md5 text NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    v_table text;
    v_count bigint;
    v_digest text;
BEGIN
    FOR v_table IN
        SELECT tablename FROM pg_catalog.pg_tables
        WHERE schemaname = 'lisanov_food' ORDER BY tablename
    LOOP
        EXECUTE format(
            'SELECT count(*), md5(coalesce('
            'jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text COLLATE "C"), '
            '''[]''::jsonb)::text) FROM lisanov_food.%I AS t', v_table
        ) INTO v_count, v_digest;
        INSERT INTO food_data_fingerprints VALUES (v_table, v_count, v_digest);
    END LOOP;
END;
$$;

SELECT table_name, row_count, data_md5
FROM food_data_fingerprints ORDER BY table_name;

COMMIT;
