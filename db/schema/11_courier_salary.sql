-- FOOD-107: расчёт выплат курьерам за текущий месяц.
-- Выполнять после файлов 01..10.
-- BR-10.2: текущая выплата использует старый коэффициент;
-- новый коэффициент записывается для следующего месяца.
-- Повторный расчёт сохраняет coefficient_used из истории текущего месяца.

BEGIN;

CREATE PROCEDURE lisanov_food.courier_salary()
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_month timestamp := date_trunc('month', localtimestamp);
    v_year integer := extract(year FROM v_month)::integer;
    v_month_number integer := extract(month FROM v_month)::integer;
    v_courier_ids uuid[];
BEGIN
    -- Два одновременных расчёта блокируют курьеров в одном порядке.
    -- Следующая команда при READ COMMITTED увидит результат предыдущего
    -- расчёта после ожидания блокировки. Новые курьеры, добавленные позже
    -- этого SELECT, будут обработаны следующим вызовом процедуры.
    SELECT array_agg(locked.courier_id)
    INTO v_courier_ids
    FROM (
        SELECT c.courier_id
        FROM lisanov_food.courier AS c
        ORDER BY c.courier_id
        FOR NO KEY UPDATE
    ) AS locked;

    IF v_courier_ids IS NULL THEN
        RETURN;
    END IF;

    WITH totals AS MATERIALIZED (
        SELECT c.courier_id,
               coalesce(cp.coefficient_used, c.coefficient) AS coefficient_used,
               count(o.order_id) AS delivery_count,
               coalesce(sum(o.commission), 0::numeric) AS commission_sum
        FROM lisanov_food.courier AS c
        LEFT JOIN lisanov_food.courier_pay AS cp
          ON cp.courier_id = c.courier_id
         AND cp.year = v_year
         AND cp.month = v_month_number
        LEFT JOIN lisanov_food."order" AS o
          ON o.courier_id = c.courier_id
         AND o.status = 'доставлен'
         -- Месяц заказа определяется по order_timestamp, как в тесте C.8.
         AND o.order_timestamp >= v_month
         AND o.order_timestamp < v_month + interval '1 month'
        WHERE c.courier_id = ANY(v_courier_ids)
        GROUP BY c.courier_id, c.coefficient, cp.coefficient_used
    ), paid AS (
        INSERT INTO lisanov_food.courier_pay
            (year, month, courier_id, amount, coefficient_used)
        SELECT v_year, v_month_number, t.courier_id,
               round(t.coefficient_used * t.commission_sum, 2),
               t.coefficient_used
        FROM totals AS t
        ORDER BY t.courier_id
        -- BR-10.3: повторный вызов обновляет выплату за тот же месяц.
        -- Применённый коэффициент сохраняется: он уже выбран в totals.
        ON CONFLICT (year, month, courier_id) DO UPDATE
        SET amount = EXCLUDED.amount
        RETURNING courier_id
    )
    UPDATE lisanov_food.courier AS c
    SET coefficient = CASE
        WHEN t.delivery_count <= 150 THEN 0.10
        WHEN t.delivery_count <= 250 THEN 0.20
        WHEN t.delivery_count <= 500 THEN 0.30
        ELSE 0.50 END
    FROM totals AS t
    JOIN paid AS p ON p.courier_id = t.courier_id
    WHERE c.courier_id = t.courier_id
      -- BR-10.6: уволенным выплата положена, но коэффициент не меняется.
      AND c.status <> 'уволен';
END;
$$;

COMMIT;
