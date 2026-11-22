-- FOOD-101: принадлежность отзыва заказу клиента (BR-9.1, BR-9.2).
-- FOOD-105: автоматический пересчёт рейтингов (BR-9.6, BR-9.7).
-- Выполнять после файлов 01..06, до генерации тестовых данных.
-- Связи проверяются по итоговому состоянию транзакции при COMMIT.
-- Рейтинг пересчитывается сразу после изменения отзывов.

BEGIN;

CREATE INDEX review_entity_idx
    ON lisanov_food.review (entity_type, entity_id);

-- Сначала блокируем оцениваемые блюда/рестораны, затем заказы.
-- Как в файлах 05 и 06, UPDATE с прежним значением создаёт конфликт
-- записи, защищая пересчёт и проверку от устаревшего снимка транзакции.
CREATE FUNCTION lisanov_food.prepare_review_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_old_type lisanov_food.review_entity_type;
    v_new_type lisanov_food.review_entity_type;
    v_old_id uuid;
    v_new_id uuid;
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_target record;
    v_order_id uuid;
    v_found boolean;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_type := OLD.entity_type;
        v_old_id := OLD.entity_id;
        v_order_ids := array_append(v_order_ids, OLD.order_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_type := NEW.entity_type;
        v_new_id := NEW.entity_id;
        v_order_ids := array_append(v_order_ids, NEW.order_id);
    END IF;

    -- Порядок значений enum: сначала «блюдо», затем «ресторан».
    FOR v_target IN
        SELECT DISTINCT x.entity_type, x.entity_id
        FROM (VALUES (v_old_type, v_old_id), (v_new_type, v_new_id))
             AS x(entity_type, entity_id)
        WHERE x.entity_type IN ('блюдо', 'ресторан')
        ORDER BY x.entity_type, x.entity_id
    LOOP
        IF v_target.entity_type = 'блюдо' THEN
            UPDATE lisanov_food.product AS p
            SET rating = p.rating
            WHERE p.product_id = v_target.entity_id;
            v_found := FOUND;
        ELSE
            UPDATE lisanov_food.restaurant AS r
            SET rating = r.rating
            WHERE r.restaurant_id = v_target.entity_id;
            v_found := FOUND;
        END IF;

        -- Новая цель должна существовать. Отсутствие старой цели
        -- разрешаем: её могли удалить вместе с позицией заказа раньше
        -- в этой же транзакции, а теперь удаляют/переносят сам отзыв.
        IF NOT v_found
           AND v_target.entity_type = v_new_type
           AND v_target.entity_id = v_new_id THEN
            RAISE EXCEPTION 'BR-9.2: объект отзыва % (%) не найден',
                v_target.entity_id, v_target.entity_type
                USING ERRCODE = '23503';
        END IF;
    END LOOP;

    FOR v_order_id IN
        SELECT DISTINCT x.id FROM unnest(v_order_ids) AS x(id) ORDER BY x.id
    LOOP
        UPDATE lisanov_food."order" AS o
        SET order_amount = o.order_amount
        WHERE o.order_id = v_order_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'BR-9.2: заказ % не найден в текущем снимке транзакции', v_order_id
                USING ERRCODE = '23503';
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER review_prepare
BEFORE INSERT OR UPDATE OR DELETE ON lisanov_food.review
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.prepare_review_change();

-- Проверяем все отзывы затронутого заказа по текущим строкам таблиц.
-- Это также ловит нарушение при смене клиента/ресторана заказа
-- или при удалении/переносе блюда из его состава.
CREATE FUNCTION lisanov_food.check_review_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_order_ids uuid[] := ARRAY[]::uuid[];
    v_order_id uuid;
    v_review_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'order_structure' AND TG_OP = 'UPDATE' THEN
        IF OLD.order_id IS NOT DISTINCT FROM NEW.order_id
           AND OLD.product_id IS NOT DISTINCT FROM NEW.product_id THEN
            RETURN NULL;
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
        SELECT r.review_id INTO v_review_id
        FROM lisanov_food.review AS r
        JOIN lisanov_food."order" AS o ON o.order_id = r.order_id
        WHERE r.order_id = v_order_id
          AND (
              r.client_id <> o.client_id
              OR (r.entity_type = 'заказ' AND r.entity_id <> o.order_id)
              OR (r.entity_type = 'ресторан' AND r.entity_id <> o.restaurant_id)
              OR (r.entity_type = 'блюдо' AND NOT EXISTS (
                  SELECT 1
                  FROM lisanov_food.order_structure AS os
                  WHERE os.order_id = o.order_id
                    AND os.product_id = r.entity_id
              ))
          )
        ORDER BY r.review_id
        LIMIT 1;

        IF FOUND THEN
            RAISE EXCEPTION 'BR-9.2: отзыв % должен принадлежать клиенту заказа % и оценивать объект этого заказа',
                v_review_id, v_order_id
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER review_consistency_check
AFTER INSERT OR UPDATE OR DELETE ON lisanov_food.review
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.check_review_consistency();

CREATE CONSTRAINT TRIGGER order_review_consistency_check
AFTER UPDATE ON lisanov_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (OLD.order_id IS DISTINCT FROM NEW.order_id
      OR OLD.client_id IS DISTINCT FROM NEW.client_id
      OR OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION lisanov_food.check_review_consistency();

CREATE CONSTRAINT TRIGGER order_structure_review_consistency_check
AFTER UPDATE OR DELETE ON lisanov_food.order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.check_review_consistency();

-- FOOD-105: возвращает TRIGGER; вызывается после I/U/D отзывов.
-- AVG берётся по всем отзывам на сущность, независимо от заказа.
CREATE FUNCTION lisanov_food.rating_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_old_type lisanov_food.review_entity_type;
    v_new_type lisanov_food.review_entity_type;
    v_old_id uuid;
    v_new_id uuid;
    v_target record;
    v_rating numeric;
BEGIN
    -- TRUNCATE не вызывает строковые триггеры I/U/D.
    -- При общей очистке всех таблиц эти UPDATE просто не найдут строк.
    IF TG_OP = 'TRUNCATE' THEN
        UPDATE lisanov_food.product SET rating = NULL WHERE rating IS NOT NULL;
        UPDATE lisanov_food.restaurant SET rating = NULL WHERE rating IS NOT NULL;
        RETURN NULL;
    END IF;

    IF TG_OP <> 'INSERT' THEN
        v_old_type := OLD.entity_type;
        v_old_id := OLD.entity_id;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_type := NEW.entity_type;
        v_new_id := NEW.entity_id;
    END IF;

    FOR v_target IN
        SELECT DISTINCT x.entity_type, x.entity_id
        FROM (VALUES (v_old_type, v_old_id), (v_new_type, v_new_id))
             AS x(entity_type, entity_id)
        WHERE x.entity_type IN ('блюдо', 'ресторан')
        ORDER BY x.entity_type, x.entity_id
    LOOP
        -- Без отзывов AVG возвращает NULL: не заменяем его нулём.
        SELECT round(avg(r.rating), 2) INTO v_rating
        FROM lisanov_food.review AS r
        WHERE r.entity_type = v_target.entity_type
          AND r.entity_id = v_target.entity_id;

        IF v_target.entity_type = 'блюдо' THEN
            UPDATE lisanov_food.product
            SET rating = v_rating
            WHERE product_id = v_target.entity_id
              AND rating IS DISTINCT FROM v_rating;
        ELSE
            UPDATE lisanov_food.restaurant
            SET rating = v_rating
            WHERE restaurant_id = v_target.entity_id
              AND rating IS DISTINCT FROM v_rating;
        END IF;
    END LOOP;

    -- У отзыва на заказ нет агрегата. AFTER-триггер не изменяет review
    -- и не вызывает себя повторно; возвращаемое значение игнорируется.
    RETURN NULL;
END;
$$;

CREATE TRIGGER review_rating_change
AFTER INSERT OR UPDATE OR DELETE ON lisanov_food.review
FOR EACH ROW
EXECUTE FUNCTION lisanov_food.rating_change();

CREATE TRIGGER review_truncate_ratings
AFTER TRUNCATE ON lisanov_food.review
FOR EACH STATEMENT
EXECUTE FUNCTION lisanov_food.rating_change();

COMMIT;
