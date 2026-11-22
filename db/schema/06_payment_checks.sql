-- FOOD-101: согласованность оплат (BR-8.1, BR-8.4, BR-8.7).
-- Выполнять после файлов 01..05.
-- Выбранная трактовка неоднозначности BR-8.1 и BR-8.7:
-- ровно одна успешная оплата требуется к COMMIT каждого существующего заказа.
-- Заказ, его состав и успешная оплата записываются в одной транзакции.
-- «ожидает» и «ошибка» — промежуточные состояния; после COMMIT все заказы
-- имеют успешную оплату. Это технический выбор момента проверки, не явный
-- момент из ТЗ; для реального сервиса его нужно согласовать с заказчиком.

BEGIN;

-- Пересчёт использует все попытки, поэтому одного частичного индекса мало.
CREATE INDEX payment_order_idx ON lisanov_food.payment (order_id);

-- Изменения оплат и суммы заказа конфликтуют по одной строке заголовка.
CREATE FUNCTION lisanov_food.prepare_payment_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_order_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_order_ids := array_append(v_order_ids, OLD.order_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_order_ids := array_append(v_order_ids, NEW.order_id);
    END IF;

    FOR v_order_id IN
        SELECT DISTINCT x.id FROM unnest(v_order_ids) AS x(id) ORDER BY x.id
    LOOP
        UPDATE lisanov_food."order" AS o
        SET order_amount = o.order_amount
        WHERE o.order_id = v_order_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Заказ % не найден в текущем снимке транзакции', v_order_id
                USING ERRCODE = '23503';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER payment_prepare
BEFORE INSERT OR UPDATE OR DELETE ON lisanov_food.payment
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.prepare_payment_change();

CREATE FUNCTION lisanov_food.refresh_order_pay_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_order_id uuid;
    v_pay_status lisanov_food.order_pay_status;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_order_ids := array_append(v_order_ids, OLD.order_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_order_ids := array_append(v_order_ids, NEW.order_id);
    END IF;

    FOR v_order_id IN
        SELECT DISTINCT x.id FROM unnest(v_order_ids) AS x(id) ORDER BY x.id
    LOOP
        -- BR-8.7: успех приоритетнее ошибок и незавершённых попыток.
        -- При отсутствии попыток временно считаем заказ ожидающим оплаты.
        SELECT CASE
            WHEN count(*) FILTER (WHERE p.status = 'успех') > 0
                THEN 'оплачен'
            WHEN count(*) > 0
                 AND count(*) FILTER (WHERE p.status = 'ошибка') = count(*)
                THEN 'ошибка'
            ELSE 'ожидает'
        END::lisanov_food.order_pay_status
        INTO v_pay_status
        FROM lisanov_food.payment AS p
        WHERE p.order_id = v_order_id;

        UPDATE lisanov_food."order" AS o
        SET pay_status = v_pay_status
        WHERE o.order_id = v_order_id
          AND o.pay_status IS DISTINCT FROM v_pay_status;
    END LOOP;
    RETURN NULL;
END;
$$;

-- Имя задаёт порядок: пересчёт раньше payment_90_consistency_check,
-- в том числе при SET CONSTRAINTS ALL IMMEDIATE.
CREATE TRIGGER payment_10_refresh_order_status
AFTER INSERT OR UPDATE OR DELETE ON lisanov_food.payment
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.refresh_order_pay_status();

CREATE FUNCTION lisanov_food.check_payment_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_order_id uuid;
    v_total_amount numeric;
    v_pay_status lisanov_food.order_pay_status;
    v_expected_status lisanov_food.order_pay_status;
    v_attempt_count bigint;
    v_success_count bigint;
    v_error_count bigint;
    v_amounts_match boolean;
BEGIN
    -- Отдельная очистка оплат не должна оставлять неоплаченные заказы.
    -- Общий TRUNCATE всех связанных таблиц одной командой допустим.
    IF TG_OP = 'TRUNCATE' THEN
        IF EXISTS (SELECT 1 FROM lisanov_food."order") THEN
            RAISE EXCEPTION 'BR-8.1: нельзя очистить оплаты, оставив заказы без успешной оплаты'
                USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
    END IF;

    -- Пропускаем технические UPDATE заголовка, не меняющие суммы и статус.
    -- Это AFTER-триггер, поэтому generated total_amount уже вычислен.
    IF TG_TABLE_NAME = 'order' THEN
        IF TG_OP = 'UPDATE' THEN
            IF OLD.order_id IS NOT DISTINCT FROM NEW.order_id
               AND OLD.total_amount IS NOT DISTINCT FROM NEW.total_amount
               AND OLD.pay_status IS NOT DISTINCT FROM NEW.pay_status THEN
                RETURN NULL;
            END IF;
        END IF;
    END IF;

    IF TG_OP <> 'INSERT' THEN
        v_order_ids := array_append(v_order_ids, OLD.order_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_order_ids := array_append(v_order_ids, NEW.order_id);
    END IF;

    FOR v_order_id IN
        SELECT DISTINCT x.id FROM unnest(v_order_ids) AS x(id) ORDER BY x.id
    LOOP
        SELECT o.total_amount, o.pay_status
        INTO v_total_amount, v_pay_status
        FROM lisanov_food."order" AS o
        WHERE o.order_id = v_order_id;
        -- Удаление оплат и самого заказа в одной транзакции разрешено.
        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        SELECT count(*),
               count(*) FILTER (WHERE p.status = 'успех'),
               count(*) FILTER (WHERE p.status = 'ошибка'),
               COALESCE(bool_and(p.amount = v_total_amount), true)
        INTO v_attempt_count, v_success_count, v_error_count, v_amounts_match
        FROM lisanov_food.payment AS p
        WHERE p.order_id = v_order_id;

        -- Частичный UNIQUE из файла04 запрещает второй успех сразу;
        -- эта отложенная проверка также запрещает отсутствие успеха.
        IF v_success_count <> 1 THEN
            RAISE EXCEPTION 'BR-8.1: заказ % должен иметь ровно одну успешную оплату', v_order_id
                USING ERRCODE = '23514';
        END IF;

        -- BR-8.4: сверяем каждую попытку, в том числе ошибочную/незавершённую.
        IF NOT v_amounts_match THEN
            RAISE EXCEPTION 'BR-8.4: сумма каждой попытки оплаты заказа % должна равняться %',
                v_order_id, v_total_amount
                USING ERRCODE = '23514';
        END IF;

        v_expected_status := CASE
            WHEN v_success_count > 0 THEN 'оплачен'
            WHEN v_attempt_count > 0 AND v_error_count = v_attempt_count THEN 'ошибка'
            ELSE 'ожидает'
        END::lisanov_food.order_pay_status;

        -- BR-8.7: также ловим ручную подмену агрегированного статуса заказа.
        IF v_pay_status IS DISTINCT FROM v_expected_status THEN
            RAISE EXCEPTION 'BR-8.7: статус оплаты заказа % должен быть %, получен %',
                v_order_id, v_expected_status, v_pay_status
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER payment_90_consistency_check
AFTER INSERT OR UPDATE OR DELETE ON lisanov_food.payment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.check_payment_consistency();

CREATE CONSTRAINT TRIGGER order_payment_consistency_check
AFTER INSERT OR UPDATE ON lisanov_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.check_payment_consistency();

CREATE TRIGGER payment_truncate_check
AFTER TRUNCATE ON lisanov_food.payment
FOR EACH STATEMENT
EXECUTE FUNCTION lisanov_food.check_payment_consistency();

COMMIT;
