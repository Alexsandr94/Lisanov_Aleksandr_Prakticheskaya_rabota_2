-- FOOD-109 / FOOD-110: запускать через psql с ON_ERROR_STOP=1
-- при отдельном подключении пользователя inspector к восстановленной копии.
-- Изменения тестовых данных откатываются в конце.
BEGIN;

DO $$
BEGIN
    IF current_database() <> 'foodexpress_final_restore_check'
       OR session_user <> 'inspector' OR current_user <> 'inspector' THEN
        RAISE EXCEPTION 'Нужно подключение inspector к foodexpress_final_restore_check';
    END IF;
END;
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'lisanov_food'
          AND ((table_name = 'payment' AND column_name = 'amount')
               OR (table_name = 'review' AND column_name = 'client_id'))
    ) THEN
        RAISE EXCEPTION 'Зависимые столбцы всё ещё хранятся в базовых таблицах';
    END IF;
    IF (SELECT count(*) FROM information_schema.views
        WHERE table_schema = 'lisanov_food'
          AND table_name IN ('payment_details', 'review_details')
          AND is_updatable = 'NO') <> 2 THEN
        RAISE EXCEPTION 'Ожидались два представления для чтения';
    END IF;
END;
$$;

CALL lisanov_food.erase_test_data();

DO $$
DECLARE
    v_table text;
    v_count bigint;
BEGIN
    FOR v_table IN
        SELECT tablename FROM pg_catalog.pg_tables
        WHERE schemaname = 'lisanov_food'
    LOOP
        EXECUTE format('SELECT count(*) FROM lisanov_food.%I', v_table)
            INTO v_count;
        IF v_count <> 0 THEN
            RAISE EXCEPTION 'После очистки таблица % не пуста', v_table;
        END IF;
    END LOOP;
END;
$$;

CALL lisanov_food.insert_test_data(10);

DO $$
DECLARE
    v_restaurant_id uuid;
    v_category_id uuid;
BEGIN
    SELECT restaurant_id INTO STRICT v_restaurant_id
    FROM lisanov_food.restaurant ORDER BY restaurant_id LIMIT 1;
    SELECT product_category_id INTO STRICT v_category_id
    FROM lisanov_food.product_category ORDER BY product_category_id LIMIT 1;

    CALL lisanov_food.add_product(
        v_restaurant_id, v_category_id, 'Проверка inspector после восстановления',
        250, NULL, 'доступно', 'Проверка прав пользователя', NULL
    );
END;
$$;

CALL lisanov_food.courier_salary();

-- Принудительно выполняем накопленные отложенные проверки перед откатом.
SET CONSTRAINTS ALL IMMEDIATE;

DO $$
BEGIN
    IF (SELECT count(*) FROM lisanov_food.product) <> 51
       OR (SELECT count(*) FROM lisanov_food."order") <> 50
       OR (SELECT count(*) FROM lisanov_food.payment_details) <> 50
       OR (SELECT count(*) FROM lisanov_food.review_details) <> 50
       OR (SELECT count(*) FROM lisanov_food.get_statistic()) <> 10 THEN
        RAISE EXCEPTION 'Количество строк после генерации и add_product неверно';
    END IF;
    IF EXISTS (
        SELECT 1 FROM lisanov_food.product AS p
        WHERE p.rating IS DISTINCT FROM (
            SELECT round(avg(r.rating), 2) FROM lisanov_food.review AS r
            WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id
        )
    ) OR EXISTS (
        SELECT 1 FROM lisanov_food.restaurant AS rest
        WHERE rest.rating IS DISTINCT FROM (
            SELECT round(avg(r.rating), 2) FROM lisanov_food.review AS r
            WHERE r.entity_type = 'ресторан' AND r.entity_id = rest.restaurant_id
        )
    ) THEN
        RAISE EXCEPTION 'Рейтинг не совпадает со средним по отзывам';
    END IF;
END;
$$;

SELECT session_user AS login_user,
       current_user AS active_user,
       current_database() AS database_name,
       (SELECT count(*) FROM information_schema.tables
        WHERE table_schema = 'lisanov_food'
          AND table_type = 'BASE TABLE') AS tables_count,
       (SELECT count(*) FROM pg_catalog.pg_tables
        WHERE schemaname = 'lisanov_food') AS catalog_tables_count,
       (SELECT count(*) FROM lisanov_food.product) AS products_count,
       (SELECT count(*) FROM lisanov_food."order") AS orders_count,
       (SELECT count(*) FROM lisanov_food.get_statistic()) AS statistics_rows,
       (SELECT count(*) FROM lisanov_food.how_much_money) AS report_months,
       (SELECT count(*) FROM lisanov_food.payment_details) AS payment_rows,
       (SELECT count(*) FROM lisanov_food.review_details) AS review_rows;

ROLLBACK;
