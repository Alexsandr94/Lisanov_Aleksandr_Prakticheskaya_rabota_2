-- Только чтение метаданных. Подходит исходной итоговой базе и её копии.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'lisanov_food'
          AND ((table_name = 'payment' AND column_name = 'amount')
               OR (table_name = 'review' AND column_name = 'client_id'))
    ) THEN
        RAISE EXCEPTION 'Ожидалась схема после нормализации';
    END IF;
    IF (SELECT count(*) FROM pg_catalog.pg_tables
        WHERE schemaname = 'lisanov_food') <> 12
       OR (SELECT count(*) FROM pg_catalog.pg_type
           WHERE typnamespace = 'lisanov_food'::regnamespace
             AND typtype = 'e') <> 8
       OR (SELECT count(*) FROM information_schema.views
           WHERE table_schema = 'lisanov_food') <> 3
       OR (SELECT count(*) FROM information_schema.views
           WHERE table_schema = 'lisanov_food'
             AND table_name IN ('payment_details', 'review_details')
             AND is_updatable = 'NO') <> 2
       OR (SELECT count(*) FROM pg_catalog.pg_constraint
           WHERE connamespace = 'lisanov_food'::regnamespace
             AND contype = 'f') <> 15
       OR (SELECT count(*) FROM pg_catalog.pg_trigger AS t
           JOIN pg_catalog.pg_class AS c ON c.oid = t.tgrelid
           WHERE c.relnamespace = 'lisanov_food'::regnamespace
             AND NOT t.tgisinternal) <> 16 THEN
        RAISE EXCEPTION 'Структура итоговой схемы не соответствует ожидаемой';
    END IF;
END;
$$;
