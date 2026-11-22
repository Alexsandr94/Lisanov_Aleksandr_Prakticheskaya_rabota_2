-- FOOD-106: статистика по ресторанам. Выполнять после файлов 01..09.
-- BR-13.2: имена пяти выходных столбцов сохраняют контракт бэкенда.
-- Без доставленных заказов: общая сумма 0; среднее и лучшие участники NULL.
-- Сохраняем результат AVG: дополнительное округление контрактом не задано.

BEGIN;

CREATE FUNCTION lisanov_food.get_statistic()
RETURNS TABLE (
    restaurant_name text,
    best_product_name text,
    total_amount numeric,
    avg_amount numeric,
    best_user text
)
LANGUAGE sql
VOLATILE -- При равных результатах победитель выбирается через random().
SET search_path = pg_catalog, lisanov_food
AS $$
    -- BR-11.8: таблицу заказов читаем один раз. Промежуточный набор
    -- используется для трёх разных расчётов: денег, блюд и клиентов.
    WITH delivered AS MATERIALIZED (
        SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
        FROM lisanov_food."order" AS o
        WHERE o.status = 'доставлен'
    ), order_totals AS (
        -- Считаем деньги до соединения с позициями: многопозиционный
        -- заказ должен войти в SUM и AVG только один раз.
        SELECT d.restaurant_id,
               sum(d.total_amount) AS total_amount,
               avg(d.total_amount) AS avg_amount
        FROM delivered AS d
        GROUP BY d.restaurant_id
    ), product_totals AS (
        SELECT d.restaurant_id, os.product_id,
               sum(os.quantity) AS quantity
        FROM delivered AS d
        JOIN lisanov_food.order_structure AS os ON os.order_id = d.order_id
        GROUP BY d.restaurant_id, os.product_id
    ), best_products AS (
        -- DISTINCT ON оставляет одного победителя на ресторан.
        -- random() разрешает ничью только при одинаковой сумме количества.
        SELECT DISTINCT ON (pt.restaurant_id)
               pt.restaurant_id, pt.product_id
        FROM product_totals AS pt
        ORDER BY pt.restaurant_id, pt.quantity DESC, random()
    ), client_totals AS (
        SELECT d.restaurant_id, d.client_id, count(*) AS order_count
        FROM delivered AS d
        GROUP BY d.restaurant_id, d.client_id
    ), best_clients AS (
        SELECT DISTINCT ON (ct.restaurant_id)
               ct.restaurant_id, ct.client_id
        FROM client_totals AS ct
        ORDER BY ct.restaurant_id, ct.order_count DESC, random()
    )
    SELECT r.restaurant_name::text,
           p.product_name::text,
           coalesce(ot.total_amount, 0::numeric),
           ot.avg_amount,
           c.login::text -- BR-2.6: у клиента хранится логин, а не ФИО.
    FROM lisanov_food.restaurant AS r
    LEFT JOIN order_totals AS ot ON ot.restaurant_id = r.restaurant_id
    LEFT JOIN best_products AS bp ON bp.restaurant_id = r.restaurant_id
    LEFT JOIN lisanov_food.product AS p ON p.product_id = bp.product_id
    LEFT JOIN best_clients AS bc ON bc.restaurant_id = r.restaurant_id
    LEFT JOIN lisanov_food.client AS c ON c.client_id = bc.client_id;
$$;

COMMIT;
