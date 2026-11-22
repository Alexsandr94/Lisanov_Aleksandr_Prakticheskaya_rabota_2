-- FOOD-108: месячный отчёт по доставленным заказам и выплатам курьерам.
-- Выполнять после файлов 01..11.
-- BR-11.9: рекурсивная серия включает месяцы без заказов.
-- Без доставленных заказов диапазон не определён: результат пустой.

BEGIN;

-- Календарный отчёт требует конечной даты создания заказа.
-- Специальные timestamp +/-infinity не задают календарный месяц;
-- -infinity также не продвигается при прибавлении интервала в рекурсии.
ALTER TABLE lisanov_food."order"
    ADD CONSTRAINT order_timestamp_finite_check
    CHECK (isfinite(order_timestamp));

CREATE VIEW lisanov_food.how_much_money AS
WITH RECURSIVE order_totals AS MATERIALIZED (
    SELECT date_trunc('month', o.order_timestamp)::date AS month_start,
           sum(o.order_amount) AS sum_no_commission,
           sum(o.total_amount) AS sum_with_commission
    FROM lisanov_food."order" AS o
    WHERE o.status = 'доставлен'
    GROUP BY date_trunc('month', o.order_timestamp)::date
), months (month_start, last_month) AS (
    -- Первый месяц и граница берутся только из доставленных заказов.
    SELECT min(ot.month_start), max(ot.month_start)
    FROM order_totals AS ot
    HAVING min(ot.month_start) IS NOT NULL

    UNION ALL

    SELECT (m.month_start + interval '1 month')::date, m.last_month
    FROM months AS m
    WHERE m.month_start < m.last_month
), pay_totals AS (
    -- Независимый итог выплат исключает размножение сумм при JOIN.
    SELECT cp.year, cp.month, sum(cp.amount) AS amount
    FROM lisanov_food.courier_pay AS cp
    GROUP BY cp.year, cp.month
), monthly AS (
    SELECT m.month_start,
           coalesce(ot.sum_no_commission, 0::numeric) AS sum_no_commission,
           coalesce(ot.sum_with_commission, 0::numeric) AS sum_with_commission,
           coalesce(ot.sum_with_commission, 0::numeric)
               - coalesce(ot.sum_no_commission, 0::numeric) AS commission,
           coalesce(pt.amount, 0::numeric) AS courier_pay
    FROM months AS m
    LEFT JOIN order_totals AS ot ON ot.month_start = m.month_start
    LEFT JOIN pay_totals AS pt
      ON pt.year = extract(year FROM m.month_start)
     AND pt.month = extract(month FROM m.month_start)
), compared AS (
    -- LAG применяется после заполнения пропусков: это предыдущий
    -- календарный месяц, даже если в нём не было заказов.
    SELECT m.month_start, m.sum_no_commission, m.sum_with_commission,
           m.commission, m.courier_pay,
           lag(m.commission) OVER (ORDER BY m.month_start) AS prev_commission
    FROM monthly AS m
)
SELECT to_char(c.month_start, 'YYYY-MM') AS year_month,
       c.sum_no_commission,
       c.sum_with_commission,
       c.commission,
       c.prev_commission,
       c.commission - c.prev_commission AS commission_diff,
       c.courier_pay,
       c.commission - c.courier_pay AS net_profit
FROM compared AS c;

-- Если в месяце без заказов есть историческая выплата, она сохраняется,
-- а net_profit отрицателен. Выплаты вне диапазона заказов не добавляют
-- месяцы к отчёту: диапазон прямо определён в FOOD-108.

COMMIT;
