-- FOOD-102 / FOOD-103. Выполнять после файлов 01..07.
-- Повторный insert_test_data(n) ДОБАВЛЯЕТ независимую связанную партию.
-- Существующие данные он не удаляет и не использует для новых заказов.
-- UUID создаются через exts.uuid_generate_v4(), в том числе DEFAULT ID.
--
-- Трактовка противоречия samples/all_examples.sql, раздел 10:
-- прямых вызовов собственных процедур/функций здесь нет. Обычные INSERT
-- вызывают установленные триггеры целостности и рейтингов по BR-9.7.
-- Отключение обязательных триггеров не используется.
--
-- 5*n заказов и 5*n оплат при BR-8.1 означают ровно одну успешную
-- оплату на заказ. Сценарии повторных попыток проверяются отдельно.
-- История выплат: текущий календарный месяц и пять предыдущих;
-- месяц заказа определяется по order_timestamp, как в проверке C.8.

BEGIN;

CREATE PROCEDURE lisanov_food.erase_test_data()
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
BEGIN
    -- Все связанные таблицы очищаются одной командой. CASCADE не нужен:
    -- посторонние таблицы вне проекта не включаются в очистку автоматически.
    TRUNCATE TABLE
        lisanov_food.review,
        lisanov_food.payment,
        lisanov_food.order_structure,
        lisanov_food."order",
        lisanov_food.courier_pay,
        lisanov_food.product,
        lisanov_food.restaurant,
        lisanov_food.courier,
        lisanov_food.client_address,
        lisanov_food.client,
        lisanov_food.product_category,
        lisanov_food.address;
END;
$$;

CREATE PROCEDURE lisanov_food.insert_test_data(value integer)
LANGUAGE plpgsql
SET search_path = pg_catalog, lisanov_food
AS $$
DECLARE
    v_clients uuid[] := ARRAY[]::uuid[];
    v_couriers uuid[] := ARRAY[]::uuid[];
    v_categories uuid[] := ARRAY[]::uuid[];
    v_addresses uuid[] := ARRAY[]::uuid[];
    v_restaurants uuid[] := ARRAY[]::uuid[];
    v_products uuid[] := ARRAY[]::uuid[];
    v_prices numeric[] := ARRAY[]::numeric[];

    v_restaurant_statuses lisanov_food.restaurant_status[] :=
        enum_range(NULL::lisanov_food.restaurant_status);
    v_product_statuses lisanov_food.product_status[] :=
        enum_range(NULL::lisanov_food.product_status);
    v_courier_statuses lisanov_food.courier_status[] :=
        enum_range(NULL::lisanov_food.courier_status);
    v_order_statuses lisanov_food.order_status[] :=
        enum_range(NULL::lisanov_food.order_status);
    v_order_pay_statuses lisanov_food.order_pay_status[] :=
        enum_range(NULL::lisanov_food.order_pay_status);
    v_payment_statuses lisanov_food.payment_status[] :=
        enum_range(NULL::lisanov_food.payment_status);
    v_payment_types lisanov_food.payment_type[] :=
        enum_range(NULL::lisanov_food.payment_type);
    v_review_types lisanov_food.review_entity_type[] :=
        enum_range(NULL::lisanov_food.review_entity_type);

    v_now timestamp := localtimestamp;
    v_first_month timestamp := date_trunc('month', localtimestamp) - interval '5 months';
    -- Пересечение шести календарных месяцев и последних 180 дней.
    v_start timestamp := greatest(v_first_month, v_now - interval '180 days');
    v_batch text := replace(exts.uuid_generate_v4()::text, '-', '');
    v_id uuid;
    v_order_id uuid;
    v_entity_id uuid;
    v_price numeric;
    v_courier_status lisanov_food.courier_status;
    v_order_status lisanov_food.order_status;
    v_review_type lisanov_food.review_entity_type;
    v_order_time timestamp;
    v_delivery_time timestamp;
    v_review_start timestamp;
    v_order_amount numeric;
    v_total_amount numeric;
    v_month timestamp;
    v_item_ids uuid[];
    v_item_prices numeric[];
    v_quantities numeric[];
    v_item_count integer;
    v_offset integer;
    v_client_index integer;
    v_restaurant_index integer;
    v_product_index integer;
    v_i integer;
    v_j integer;
    v_m integer;
BEGIN
    -- Поведение для значений вне области задачи задаём явно.
    IF value IS NULL OR value <= 0 THEN
        RAISE EXCEPTION 'insert_test_data: value должен быть положительным целым числом'
            USING ERRCODE = '22023';
    END IF;
    IF value > 2147483647 / 5 THEN
        RAISE EXCEPTION 'insert_test_data: value слишком велик для расчёта 5 * value'
            USING ERRCODE = '22023';
    END IF;

    -- n клиентов. Проверка конфликта гарантирует уникальность телефонов
    -- также при повторном вызове. Логин содержит полный UUID клиента.
    FOR v_i IN 1..value LOOP
        LOOP
            v_id := exts.uuid_generate_v4();
            INSERT INTO lisanov_food.client (client_id, login, password, phone_number)
            VALUES (
                v_id,
                'client_' || v_id::text,
                md5(random()::text),
                '+' || (70000000000::bigint + floor(random() * 10000000000)::bigint)::text
            )
            ON CONFLICT DO NOTHING;
            EXIT WHEN FOUND;
        END LOOP;
        v_clients := array_append(v_clients, v_id);

        INSERT INTO lisanov_food.product_category (product_category_name)
        VALUES ('Категория ' || v_i || ' ' || substring(md5(random()::text), 1, 8))
        RETURNING product_category_id INTO v_id;
        v_categories := array_append(v_categories, v_id);

        v_courier_status := v_courier_statuses[
            1 + floor(random() * cardinality(v_courier_statuses))::integer
        ];
        -- BR-6.6: даже для n=1 гарантирован хотя бы один работающий курьер.
        IF v_i = 1 THEN
            v_courier_status := v_courier_statuses[
                array_position(v_courier_statuses, 'свободен'::lisanov_food.courier_status)
            ];
        END IF;

        INSERT INTO lisanov_food.courier
            (fio, phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES (
            'Курьер ' || v_i || ' ' || substring(md5(random()::text), 1, 12),
            '+' || (70000000000::bigint + floor(random() * 10000000000)::bigint)::text,
            v_courier_status,
            v_start::date,
            CASE WHEN v_courier_status = 'уволен' THEN v_now::date ELSE NULL END,
            0.10
        )
        RETURNING courier_id INTO v_id;
        v_couriers := array_append(v_couriers, v_id);
    END LOOP;

    -- Первые n адресов принадлежат ресторанам, следующие 4*n — клиентам.
    -- Имя улицы с UUID партии исключает повтор адреса между партиями.
    FOR v_i IN 1..(5 * value) LOOP
        INSERT INTO lisanov_food.address (street, house_number, apartment_office)
        VALUES (
            'Тестовая ' || v_batch || '_' || v_i,
            (1 + floor(random() * 200)::integer)::text,
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE (1 + floor(random() * 500)::integer)::text END
        )
        RETURNING address_id INTO v_id;
        v_addresses := array_append(v_addresses, v_id);
    END LOOP;

    FOR v_i IN 1..value LOOP
        -- По четыре адреса каждому клиенту; все 4*n адресов используются.
        FOR v_j IN 1..4 LOOP
            INSERT INTO lisanov_food.client_address (client_id, address_id)
            VALUES (v_clients[v_i], v_addresses[value + (v_i - 1) * 4 + v_j]);
        END LOOP;

        INSERT INTO lisanov_food.restaurant
            (restaurant_name, address_id, description, work_start, work_end,
             company_details, rating, status)
        VALUES (
            'Ресторан ' || v_i || ' ' || substring(md5(random()::text), 1, 12),
            v_addresses[v_i],
            'Описание тестового ресторана ' || v_i,
            time '08:00' + floor(random() * 4)::integer * interval '1 hour',
            time '18:00' + floor(random() * 4)::integer * interval '1 hour',
            'Тестовые реквизиты ' || v_batch || '_' || v_i,
            NULL,
            v_restaurant_statuses[
                1 + floor(random() * cardinality(v_restaurant_statuses))::integer
            ]
        )
        RETURNING restaurant_id INTO v_id;
        v_restaurants := array_append(v_restaurants, v_id);
    END LOOP;

    -- По пять блюд на ресторан, подряд в массиве: 1..5, 6..10 и т. д.
    FOR v_i IN 1..(5 * value) LOOP
        v_restaurant_index := (v_i - 1) / 5 + 1;
        -- Минимальная цена 2000 и количество от 0.5 гарантируют
        -- заказ от 1000 без комиссии, а значит выполнение BR-7.11.
        v_price := round((2000 + random() * 3000)::numeric, 2);
        INSERT INTO lisanov_food.product
            (product_name, product_category_id, price, restaurant_id,
             photo_url, rating, status, description)
        VALUES (
            'Блюдо ' || v_i || ' ' || substring(md5(random()::text), 1, 12),
            v_categories[1 + floor(random() * value)::integer],
            v_price,
            v_restaurants[v_restaurant_index],
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE 'https://example.invalid/product/' || v_batch || '/' || v_i || '.jpg' END,
            NULL,
            v_product_statuses[1 + floor(random() * cardinality(v_product_statuses))::integer],
            'Описание тестового блюда ' || v_i
        )
        RETURNING product_id INTO v_id;
        v_products := array_append(v_products, v_id);
        v_prices := array_append(v_prices, v_price);
    END LOOP;

    FOR v_i IN 1..(5 * value) LOOP
        v_client_index := 1 + floor(random() * value)::integer;
        v_restaurant_index := (v_i - 1) % value + 1;
        v_item_count := 1 + floor(random() * 5)::integer;
        v_offset := floor(random() * 5)::integer;
        v_item_ids := ARRAY[]::uuid[];
        v_item_prices := ARRAY[]::numeric[];
        v_quantities := ARRAY[]::numeric[];
        v_order_amount := 0;

        -- Случайный старт и последовательные индексы по кругу дают
        -- 1..5 разных блюд одного ресторана без сканирования таблиц.
        FOR v_j IN 1..v_item_count LOOP
            v_product_index := (v_restaurant_index - 1) * 5
                               + (v_offset + v_j - 1) % 5 + 1;
            v_item_ids := array_append(v_item_ids, v_products[v_product_index]);
            v_item_prices := array_append(v_item_prices, v_prices[v_product_index]);
            v_quantities := array_append(v_quantities,
                (1 + floor(random() * 6)::integer)::numeric / 2);
            v_order_amount := v_order_amount + v_item_prices[v_j] * v_quantities[v_j];
        END LOOP;
        v_order_amount := round(v_order_amount, 2);

        v_order_status := v_order_statuses[
            1 + floor(random() * cardinality(v_order_statuses))::integer
        ];
        -- У каждого нового ресторана будет хотя бы один доставленный заказ.
        IF v_i <= value THEN
            v_order_status := v_order_statuses[
                array_position(v_order_statuses, 'доставлен'::lisanov_food.order_status)
            ];
        END IF;
        v_order_time := v_start + random() * (v_now - v_start);
        v_delivery_time := CASE WHEN v_order_status = 'доставлен'
            THEN v_order_time + random() * least(interval '3 hours', v_now - v_order_time)
            ELSE NULL END;

        INSERT INTO lisanov_food."order"
            (courier_id, client_id, address_id, restaurant_id, order_timestamp,
             delivery_timestamp, order_amount, status, pay_status, description)
        VALUES (
            v_couriers[1 + floor(random() * value)::integer],
            v_clients[v_client_index],
            v_addresses[value + (v_client_index - 1) * 4
                        + 1 + floor(random() * 4)::integer],
            v_restaurants[v_restaurant_index],
            v_order_time,
            v_delivery_time,
            v_order_amount,
            v_order_status,
            v_order_pay_statuses[
                array_position(v_order_pay_statuses, 'ожидает'::lisanov_food.order_pay_status)
            ],
            'Тестовый заказ ' || v_batch || '_' || v_i
        )
        RETURNING order_id, total_amount INTO v_order_id, v_total_amount;

        FOR v_j IN 1..v_item_count LOOP
            INSERT INTO lisanov_food.order_structure
                (order_id, product_id, quantity, unit_price)
            VALUES (v_order_id, v_item_ids[v_j], v_quantities[v_j], v_item_prices[v_j]);
        END LOOP;

        INSERT INTO lisanov_food.payment
            (order_id, payment_type, amount, transaction_reference,
             transaction_timestamp, status)
        VALUES (
            v_order_id,
            v_payment_types[1 + floor(random() * cardinality(v_payment_types))::integer],
            v_total_amount,
            'test_' || v_order_id::text,
            v_order_time + random() * least(interval '1 hour', v_now - v_order_time),
            v_payment_statuses[
                array_position(v_payment_statuses, 'успех'::lisanov_food.payment_status)
            ]
        );

        -- Первые три отзыва охватывают все типы; далее тип случайный.
        v_review_type := v_review_types[CASE
            WHEN v_i <= cardinality(v_review_types) THEN v_i
            ELSE 1 + floor(random() * cardinality(v_review_types))::integer END];
        v_entity_id := CASE v_review_type
            WHEN 'блюдо' THEN v_item_ids[1 + floor(random() * v_item_count)::integer]
            WHEN 'ресторан' THEN v_restaurants[v_restaurant_index]
            ELSE v_order_id END;
        v_review_start := coalesce(v_delivery_time, v_order_time);

        INSERT INTO lisanov_food.review
            (client_id, review_timestamp, entity_id, entity_type, order_id,
             description, photo_url, rating)
        VALUES (
            v_clients[v_client_index],
            v_review_start + random() * (v_now - v_review_start),
            v_entity_id,
            v_review_type,
            v_order_id,
            'Тестовый отзыв ' || v_batch || '_' || v_i,
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE 'https://example.invalid/review/' || v_order_id::text || '.jpg' END,
            1 + floor(random() * 5)::integer
        );
    END LOOP;

    -- BR-10.2, BR-10.7: воспроизводим месяцы в хронологическом порядке.
    -- Один агрегат по курьерам на месяц используется для выплаты и
    -- коэффициента следующего месяца. Старые партии не затрагиваются.
    FOR v_m IN 0..5 LOOP
        v_month := v_first_month + v_m * interval '1 month';
        WITH totals AS MATERIALIZED (
            SELECT c.courier_id, c.coefficient,
                   count(o.order_id) AS delivery_count,
                   coalesce(sum(o.commission), 0) AS commission_sum
            FROM lisanov_food.courier AS c
            LEFT JOIN lisanov_food."order" AS o
              ON o.courier_id = c.courier_id
             AND o.status = 'доставлен'
             AND o.order_timestamp >= v_month
             AND o.order_timestamp < v_month + interval '1 month'
            WHERE c.courier_id = ANY(v_couriers)
            GROUP BY c.courier_id, c.coefficient
        ), inserted AS (
            INSERT INTO lisanov_food.courier_pay
                (year, month, courier_id, amount, coefficient_used)
            SELECT extract(year FROM v_month)::integer,
                   extract(month FROM v_month)::integer,
                   t.courier_id,
                   round(t.coefficient * t.commission_sum, 2),
                   t.coefficient
            FROM totals AS t
            RETURNING courier_id
        )
        UPDATE lisanov_food.courier AS c
        SET coefficient = CASE
            WHEN t.delivery_count <= 150 THEN 0.10
            WHEN t.delivery_count <= 250 THEN 0.20
            WHEN t.delivery_count <= 500 THEN 0.30
            ELSE 0.50 END
        FROM totals AS t
        JOIN inserted AS p ON p.courier_id = t.courier_id
        WHERE c.courier_id = t.courier_id
          AND (c.status <> 'уволен'
               OR v_month < date_trunc('month', c.dismissal_date));
    END LOOP;
END;
$$;

COMMIT;
