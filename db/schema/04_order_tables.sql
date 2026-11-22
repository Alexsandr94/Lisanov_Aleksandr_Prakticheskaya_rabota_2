-- FOOD-101: заказы, состав заказов, попытки оплаты и отзывы.
-- Выполнять после файлов 01, 02 и 03.
-- Межтабличные проверки состава, сумм, оплат и отзывов добавляются
-- отдельным следующим скриптом. До их установки схема ещё не завершена.

BEGIN;

-- BR-13.1: имя "order" заключено в кавычки, поскольку это ключевое слово.
CREATE TABLE lisanov_food."order" (
    order_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    courier_id uuid NOT NULL,
    client_id uuid NOT NULL,
    address_id uuid NOT NULL,
    restaurant_id uuid NOT NULL,
    order_timestamp timestamp DEFAULT localtimestamp NOT NULL,
    delivery_timestamp timestamp, -- BR-7.12: до доставки может отсутствовать.
    order_amount numeric(14, 2) NOT NULL,

    -- BR-1.4, BR-7.10: комиссия 10%, денежные значения округляем до копеек.
    commission numeric(14, 2)
        GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED NOT NULL,
    -- Generated-колонка не может ссылаться на другую generated-колонку.
    total_amount numeric(14, 2)
        GENERATED ALWAYS AS (
            order_amount + round(order_amount * 0.10, 2)
        ) STORED NOT NULL,

    status lisanov_food.order_status NOT NULL,
    -- Техническое начальное значение до регистрации попыток оплаты.
    -- Пересчёт по BR-8.7 будет выполняться отдельным триггером.
    pay_status lisanov_food.order_pay_status DEFAULT 'ожидает' NOT NULL,
    description text NOT NULL,

    -- BR-7.2, BR-7.4, BR-7.5: все участники и адрес должны существовать.
    CONSTRAINT order_client_fk
        FOREIGN KEY (client_id) REFERENCES lisanov_food.client (client_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_restaurant_fk
        FOREIGN KEY (restaurant_id)
        REFERENCES lisanov_food.restaurant (restaurant_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_courier_fk
        FOREIGN KEY (courier_id) REFERENCES lisanov_food.courier (courier_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_address_fk
        FOREIGN KEY (address_id) REFERENCES lisanov_food.address (address_id)
        ON DELETE RESTRICT,
    -- BR-7.4: адрес должен быть привязан именно к клиенту этого заказа.
    CONSTRAINT order_client_address_fk
        FOREIGN KEY (client_id, address_id)
        REFERENCES lisanov_food.client_address (client_id, address_id)
        ON DELETE RESTRICT,

    -- BR-7.10: стоимость блюд неотрицательна и не является NaN.
    CONSTRAINT order_amount_check
        CHECK (order_amount >= 0 AND order_amount <> 'NaN'::numeric),
    -- BR-7.11: минимум 1000 рублей относится к сумме С КОМИССИЕЙ.
    CONSTRAINT order_total_amount_check CHECK (total_amount >= 1000),
    -- BR-7.12: доставленный заказ обязательно имеет время доставки.
    CONSTRAINT order_delivery_required_check
        CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL),
    -- BR-7.13: доставка не раньше создания заказа.
    CONSTRAINT order_delivery_time_check
        CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    -- Атрибут из ERD; обязательность — BR-11.3, BR-11.4.
    CONSTRAINT order_description_not_blank CHECK (btrim(description) <> '')
);

CREATE TABLE lisanov_food.order_structure (
    order_id uuid NOT NULL,
    product_id uuid NOT NULL,
    quantity numeric(12, 3) NOT NULL,
    -- Логическая детализация BR-7.10: цена единицы блюда на момент заказа.
    -- Она сохраняет сумму старого заказа при изменении цены в меню.
    unit_price numeric(12, 2) NOT NULL,

    -- BR-7.16: одно блюдо встречается в составе заказа только один раз.
    CONSTRAINT order_structure_pkey PRIMARY KEY (order_id, product_id),
    -- BR-7.14: позиция относится к существующему заказу и блюду.
    CONSTRAINT order_structure_order_fk
        FOREIGN KEY (order_id) REFERENCES lisanov_food."order" (order_id)
        ON DELETE RESTRICT,
    CONSTRAINT order_structure_product_fk
        FOREIGN KEY (product_id) REFERENCES lisanov_food.product (product_id)
        ON DELETE RESTRICT,
    -- BR-7.15: количество положительное, допускаются дробные значения.
    CONSTRAINT order_structure_quantity_check
        CHECK (quantity > 0 AND quantity <> 'NaN'::numeric),
    -- BR-5.3, BR-7.10: зафиксированная цена неотрицательна.
    CONSTRAINT order_structure_unit_price_check
        CHECK (unit_price >= 0 AND unit_price <> 'NaN'::numeric)
);

-- BR-8.2: дополняем намеренно неполную сущность payment из ERD.
CREATE TABLE lisanov_food.payment (
    payment_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    order_id uuid NOT NULL,
    payment_type lisanov_food.payment_type NOT NULL,
    amount numeric(14, 2) NOT NULL,
    -- BR-8.3: внешний идентификатор провайдера, а не внутренний UUID.
    transaction_reference varchar(128) NOT NULL,
    transaction_timestamp timestamp DEFAULT localtimestamp NOT NULL,
    status lisanov_food.payment_status NOT NULL,

    -- BR-8.1: попытка оплаты относится к существующему заказу.
    CONSTRAINT payment_order_fk
        FOREIGN KEY (order_id) REFERENCES lisanov_food."order" (order_id)
        ON DELETE RESTRICT,
    -- BR-8.3: идентификатор внешней транзакции уникален и непустой.
    CONSTRAINT payment_transaction_reference_key UNIQUE (transaction_reference),
    CONSTRAINT payment_transaction_reference_not_blank
        CHECK (btrim(transaction_reference) <> ''),
    -- BR-8.4: неотрицательная сумма; равенство итогу заказа проверит триггер.
    CONSTRAINT payment_amount_check CHECK (amount >= 0 AND amount <> 'NaN'::numeric)
);

-- BR-8.1: не более одной успешной попытки на заказ.
-- Наличие успешной попытки требует отдельной отложенной проверки.
CREATE UNIQUE INDEX payment_one_success_per_order
    ON lisanov_food.payment (order_id)
    WHERE status = 'успех';

CREATE TABLE lisanov_food.review (
    review_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    client_id uuid NOT NULL,
    review_timestamp timestamp DEFAULT localtimestamp NOT NULL,
    entity_id uuid NOT NULL,
    entity_type lisanov_food.review_entity_type NOT NULL,
    order_id uuid NOT NULL,
    description text NOT NULL,
    photo_url text, -- BR-9.3: фотография необязательна.
    rating numeric(3, 2) NOT NULL,

    -- BR-9.2: существующие клиент и заказ; их соответствие проверит триггер.
    CONSTRAINT review_client_fk
        FOREIGN KEY (client_id) REFERENCES lisanov_food.client (client_id)
        ON DELETE RESTRICT,
    CONSTRAINT review_order_fk
        FOREIGN KEY (order_id) REFERENCES lisanov_food."order" (order_id)
        ON DELETE RESTRICT,
    -- BR-9.5: один отзыв на объект в рамках конкретного заказа.
    CONSTRAINT review_order_entity_key UNIQUE (order_id, entity_type, entity_id),
    -- BR-9.1, BR-9.2: отзыв на заказ указывает на этот же заказ.
    CONSTRAINT review_order_entity_check
        CHECK (entity_type <> 'заказ' OR entity_id = order_id),
    -- BR-9.4: допускается числовой рейтинг от 1 до 5.
    CONSTRAINT review_rating_check CHECK (rating BETWEEN 1 AND 5),
    -- BR-9.3, BR-11.3, BR-11.4: текст обязателен, фото может отсутствовать.
    CONSTRAINT review_description_not_blank CHECK (btrim(description) <> ''),
    CONSTRAINT review_photo_url_not_blank
        CHECK (photo_url IS NULL OR btrim(photo_url) <> '')
);

COMMIT;
