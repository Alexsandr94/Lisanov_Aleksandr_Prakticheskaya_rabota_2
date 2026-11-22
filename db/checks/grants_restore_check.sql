-- Только права в новой копии; общие реквизиты роли inspector не меняются.
BEGIN;

DO $$
BEGIN
    IF current_database() <> 'foodexpress_final_restore_check' THEN
        RAISE EXCEPTION 'Права кандидата выдаются только в foodexpress_final_restore_check';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'inspector' AND rolcanlogin
    ) THEN
        RAISE EXCEPTION 'Ожидалась ранее созданная LOGIN-роль inspector';
    END IF;
    EXECUTE format(
        'GRANT CONNECT ON DATABASE %I TO inspector', current_database()
    );
    EXECUTE format(
        'ALTER ROLE inspector IN DATABASE %I '
        'SET search_path TO lisanov_food, exts', current_database()
    );
END;
$$;

GRANT ALL PRIVILEGES ON SCHEMA lisanov_food TO inspector;
GRANT USAGE ON SCHEMA information_schema, pg_catalog, exts TO inspector;

-- Права на схему сами по себе не выдают права на её объекты.
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA lisanov_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA lisanov_food TO inspector;
GRANT ALL PRIVILEGES ON ALL ROUTINES IN SCHEMA lisanov_food TO inspector;

GRANT USAGE ON TYPE
    lisanov_food.restaurant_status,
    lisanov_food.product_status,
    lisanov_food.courier_status,
    lisanov_food.order_status,
    lisanov_food.order_pay_status,
    lisanov_food.payment_status,
    lisanov_food.payment_type,
    lisanov_food.review_entity_type
TO inspector;

GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;

-- Только необходимые представления метаданных, без доступа
-- к закрытым системным таблицам с паролями и настройками ролей.
GRANT SELECT ON information_schema.tables, pg_catalog.pg_tables TO inspector;

COMMIT;
