-- FOOD-104: добавление блюда. Выполнять после файлов 01..08.
-- Все атрибуты product, кроме генерируемого product_id, есть в параметрах.
--
-- Конфликт примера E.1 (templates/tests.md) с BR-9.7:
-- пример передаёт рейтинг 4.5 новому блюду, у которого ещё нет отзывов.
-- По docs/onboarding.md источник истины — docs/company-rules.md.
-- Поэтому p_rating сохранён в сигнатуре, но должен быть NULL.
-- Любое значение, кроме NULL, отклоняется с объяснением ошибки.
-- Цена округляется до копеек по типу product.price numeric(12, 2).

BEGIN;

CREATE PROCEDURE lisanov_food.add_product(
    p_restaurant_id uuid,
    p_product_category_id uuid,
    p_name text,
    p_price numeric,
    p_rating numeric,
    p_status lisanov_food.product_status,
    p_description text,
    p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
BEGIN
    IF p_restaurant_id IS NULL THEN
        RAISE EXCEPTION 'BR-5.1: restaurant_id обязателен'
            USING ERRCODE = '23502';
    END IF;
    IF p_product_category_id IS NULL THEN
        RAISE EXCEPTION 'BR-5.1: product_category_id обязателен'
            USING ERRCODE = '23502';
    END IF;

    IF p_name IS NULL THEN
        RAISE EXCEPTION 'BR-5.2: название блюда обязательно'
            USING ERRCODE = '23502';
    END IF;
    IF btrim(p_name) = '' THEN
        RAISE EXCEPTION 'BR-5.2: название блюда не может быть пустым'
            USING ERRCODE = '23514';
    END IF;
    IF char_length(p_name) > 200 THEN
        RAISE EXCEPTION 'Название блюда не должно превышать 200 символов'
            USING ERRCODE = '22001';
    END IF;

    IF p_price IS NULL THEN
        RAISE EXCEPTION 'BR-5.3: цена блюда обязательна'
            USING ERRCODE = '23502';
    END IF;
    -- Проверяем исходное значение: например, -0.001 при записи
    -- в numeric(12,2) округлилось бы до 0.00 и прошло CHECK таблицы.
    IF p_price < 0
       OR p_price IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) THEN
        RAISE EXCEPTION 'BR-5.3: цена блюда должна быть конечным неотрицательным числом'
            USING ERRCODE = '23514';
    END IF;
    IF round(p_price, 2) > 9999999999.99 THEN
        RAISE EXCEPTION 'Цена после округления не должна превышать 9999999999.99'
            USING ERRCODE = '22003';
    END IF;

    IF p_rating IS NOT NULL THEN
        RAISE EXCEPTION 'BR-9.7: у нового блюда ещё нет отзывов; передайте p_rating => NULL'
            USING ERRCODE = '23514';
    END IF;
    IF p_status IS NULL THEN
        RAISE EXCEPTION 'BR-5.5: статус блюда обязателен'
            USING ERRCODE = '23502';
    END IF;
    IF p_description IS NULL THEN
        RAISE EXCEPTION 'BR-5.2: описание блюда обязательно'
            USING ERRCODE = '23502';
    END IF;
    IF btrim(p_description) = '' THEN
        RAISE EXCEPTION 'BR-5.2: описание блюда не может быть пустым'
            USING ERRCODE = '23514';
    END IF;
    IF p_photo_url IS NOT NULL AND btrim(p_photo_url) = '' THEN
        RAISE EXCEPTION 'BR-5.6: укажите ссылку на фотографию или NULL'
            USING ERRCODE = '23514';
    END IF;

    -- Блокировка ключа не позволяет удалить родительскую строку
    -- между нашей проверкой существования и INSERT блюда.
    PERFORM 1
    FROM lisanov_food.restaurant
    WHERE restaurant_id = p_restaurant_id
    FOR KEY SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BR-5.1: ресторан с ID % не существует', p_restaurant_id
            USING ERRCODE = '23503';
    END IF;

    PERFORM 1
    FROM lisanov_food.product_category
    WHERE product_category_id = p_product_category_id
    FOR KEY SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BR-5.1: категория с ID % не существует', p_product_category_id
            USING ERRCODE = '23503';
    END IF;

    INSERT INTO lisanov_food.product
        (product_name, product_category_id, price, restaurant_id,
         photo_url, rating, status, description)
    VALUES
        (p_name, p_product_category_id, p_price, p_restaurant_id,
         p_photo_url, p_rating, p_status, p_description);
    -- product_id создаётся DEFAULT exts.uuid_generate_v4().
END;
$$;

COMMIT;
