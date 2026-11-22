-- FOOD-101: согласованность заказа и его состава (BR-7.3, BR-7.10, BR-7.14).
-- Выполнять после файлов 01..04.
-- Заказ и его позиции записываются в одной транзакции. Итоговая проверка
-- выполняется при COMMIT, когда весь состав уже заполнен.

BEGIN;

-- Согласуем конкурентные изменения состава, заголовка заказа и блюда.
-- UPDATE с прежним значением создаёт конфликт записи: при REPEATABLE READ
-- устаревший снимок будет отклонён, а не использован для проверки состава.
CREATE FUNCTION lisanov_food.prepare_order_structure_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_product_ids uuid[] := ARRAY[]::uuid[];
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_id uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_product_ids := array_append(v_product_ids, OLD.product_id);
        v_order_ids := array_append(v_order_ids, OLD.order_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_product_ids := array_append(v_product_ids, NEW.product_id);
        v_order_ids := array_append(v_order_ids, NEW.order_id);
    END IF;

    -- Сначала блюда, затем заказы; UUID внутри группы обрабатываются по порядку.
    FOR v_id IN
        SELECT DISTINCT x.id FROM unnest(v_product_ids) AS x(id) ORDER BY x.id
    LOOP
        UPDATE lisanov_food.product AS p
        SET restaurant_id = p.restaurant_id
        WHERE p.product_id = v_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Блюдо % не найдено в текущем снимке транзакции', v_id
                USING ERRCODE = '23503';
        END IF;
    END LOOP;

    FOR v_id IN
        SELECT DISTINCT x.id FROM unnest(v_order_ids) AS x(id) ORDER BY x.id
    LOOP
        UPDATE lisanov_food."order" AS o
        SET order_amount = o.order_amount
        WHERE o.order_id = v_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Заказ % не найден в текущем снимке транзакции', v_id
                USING ERRCODE = '23503';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER order_structure_prepare
BEFORE INSERT OR UPDATE OR DELETE ON lisanov_food.order_structure
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.prepare_order_structure_change();

-- Одна функция проверяет итоговый состав как после изменения заголовка,
-- так и после INSERT/UPDATE/DELETE позиций.
CREATE FUNCTION lisanov_food.check_order_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_order_id uuid;
    v_restaurant_id uuid;
    v_order_amount numeric;
    v_item_count bigint;
    v_items_amount numeric;
    v_same_restaurant boolean;
BEGIN
    -- TRUNCATE не вызывает строковые триггеры. После очистки состава
    -- заказы тоже должны отсутствовать (например, при общей очистке БД).
    IF TG_OP = 'TRUNCATE' THEN
        IF EXISTS (SELECT 1 FROM lisanov_food."order") THEN
            RAISE EXCEPTION 'BR-7.14: нельзя очистить состав, оставив заказы без позиций'
                USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
    END IF;

    -- Техническое обновление для блокировки не меняет проверяемые поля.
    -- Проверку фактической операции обеспечит триггер на составе заказа.
    IF TG_TABLE_NAME = 'order' THEN
        IF TG_OP = 'UPDATE' THEN
            IF OLD.order_id IS NOT DISTINCT FROM NEW.order_id
               AND OLD.restaurant_id IS NOT DISTINCT FROM NEW.restaurant_id
               AND OLD.order_amount IS NOT DISTINCT FROM NEW.order_amount THEN
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
        -- Читаем текущее состояние, а не снимок OLD/NEW отложенного события.
        SELECT o.restaurant_id, o.order_amount
        INTO v_restaurant_id, v_order_amount
        FROM lisanov_food."order" AS o
        WHERE o.order_id = v_order_id;

        -- Заказ мог быть удалён после удаления всех его позиций.
        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        SELECT count(*),
               COALESCE(round(sum(os.unit_price * os.quantity), 2), 0),
               COALESCE(bool_and(p.restaurant_id = v_restaurant_id), true)
        INTO v_item_count, v_items_amount, v_same_restaurant
        FROM lisanov_food.order_structure AS os
        JOIN lisanov_food.product AS p ON p.product_id = os.product_id
        WHERE os.order_id = v_order_id;

        IF v_item_count = 0 THEN
            RAISE EXCEPTION 'BR-7.14: заказ % должен содержать хотя бы одну позицию', v_order_id
                USING ERRCODE = '23514';
        END IF;

        IF NOT v_same_restaurant THEN
            RAISE EXCEPTION 'BR-7.3: все блюда заказа % должны принадлежать ресторану заказа', v_order_id
                USING ERRCODE = '23514';
        END IF;

        -- BR-7.10: сначала суммируем точные стоимости позиций,
        -- затем один раз округляем сумму заказа до копеек.
        IF v_order_amount IS DISTINCT FROM v_items_amount THEN
            RAISE EXCEPTION 'BR-7.10: сумма заказа % равна %, а стоимость позиций равна %',
                v_order_id, v_order_amount, v_items_amount
                USING ERRCODE = '23514';
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER order_consistency_check
AFTER INSERT OR UPDATE ON lisanov_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.check_order_consistency();

CREATE CONSTRAINT TRIGGER order_structure_consistency_check
AFTER INSERT OR UPDATE OR DELETE ON lisanov_food.order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.check_order_consistency();

CREATE TRIGGER order_structure_truncate_check
AFTER TRUNCATE ON lisanov_food.order_structure
FOR EACH STATEMENT
EXECUTE FUNCTION lisanov_food.check_order_consistency();

-- BR-7.3 нужно проверять также при смене ресторана самого блюда.
CREATE FUNCTION lisanov_food.check_product_restaurant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM lisanov_food.product AS p
        JOIN lisanov_food.order_structure AS os ON os.product_id = p.product_id
        JOIN lisanov_food."order" AS o ON o.order_id = os.order_id
        WHERE p.product_id = NEW.product_id
          AND p.restaurant_id <> o.restaurant_id
    ) THEN
        RAISE EXCEPTION 'BR-7.3: ресторан блюда % не совпадает с рестораном использующего его заказа',
            NEW.product_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER product_restaurant_consistency_check
AFTER UPDATE OF restaurant_id ON lisanov_food.product
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION lisanov_food.check_product_restaurant();

COMMIT;
