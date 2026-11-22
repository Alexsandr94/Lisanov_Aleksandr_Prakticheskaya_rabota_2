-- FOOD-101: рестораны, блюда, курьеры и история выплат.
-- Выполнять после 01_schema_types.sql и 02_base_tables.sql.
-- BR-11.6: цены и выплаты храним с двумя знаками после запятой;
-- рейтинги и коэффициенты — также с двумя знаками.

BEGIN;

-- BR-4.1, BR-4.5: основные сведения о ресторане.
CREATE TABLE lisanov_food.restaurant (
    restaurant_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    restaurant_name varchar(200) NOT NULL,
    address_id uuid NOT NULL,
    description text NOT NULL,
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL,
    rating numeric(3, 2), -- BR-9.7: без отзывов рейтинг NULL.
    status lisanov_food.restaurant_status NOT NULL,

    -- BR-3.3: ровно один адрес у ресторана; один адрес нельзя делить.
    CONSTRAINT restaurant_address_key UNIQUE (address_id),
    CONSTRAINT restaurant_address_fk
        FOREIGN KEY (address_id) REFERENCES lisanov_food.address (address_id)
        ON DELETE RESTRICT,

    -- BR-4.1, BR-4.5, BR-11.3, BR-11.4: обязательные сведения непустые.
    CONSTRAINT restaurant_name_not_blank CHECK (btrim(restaurant_name) <> ''),
    CONSTRAINT restaurant_description_not_blank CHECK (btrim(description) <> ''),
    CONSTRAINT restaurant_company_details_not_blank
        CHECK (btrim(company_details) <> ''),

    -- BR-4.2: диапазон рейтинга; NULL допускается по BR-9.7.
    CONSTRAINT restaurant_rating_check CHECK (rating BETWEEN 0 AND 5),
    -- BR-4.4: закрытие строго позже открытия в тот же день.
    CONSTRAINT restaurant_work_hours_check CHECK (work_end > work_start)
);

-- BR-5.1, BR-5.2: блюдо связано с одним рестораном и одной категорией.
CREATE TABLE lisanov_food.product (
    product_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    product_name varchar(200) NOT NULL,
    product_category_id uuid NOT NULL,
    price numeric(12, 2) NOT NULL,
    restaurant_id uuid NOT NULL,
    photo_url text, -- BR-5.6: фотография необязательна.
    rating numeric(3, 2), -- BR-9.7: без отзывов рейтинг NULL.
    status lisanov_food.product_status NOT NULL,
    description text NOT NULL,

    -- BR-5.1: ресторан и категория должны существовать.
    CONSTRAINT product_restaurant_fk
        FOREIGN KEY (restaurant_id)
        REFERENCES lisanov_food.restaurant (restaurant_id)
        ON DELETE RESTRICT,
    CONSTRAINT product_category_fk
        FOREIGN KEY (product_category_id)
        REFERENCES lisanov_food.product_category (product_category_id)
        ON DELETE RESTRICT,

    -- BR-5.2, BR-11.3, BR-11.4: название и описание обязательны.
    CONSTRAINT product_name_not_blank CHECK (btrim(product_name) <> ''),
    CONSTRAINT product_description_not_blank CHECK (btrim(description) <> ''),
    -- BR-5.6: отсутствие ссылки обозначается NULL, а не пустой строкой.
    CONSTRAINT product_photo_url_not_blank
        CHECK (photo_url IS NULL OR btrim(photo_url) <> ''),

    -- BR-5.3: неотрицательная цена; NaN не является денежной суммой.
    -- numeric с заданной точностью также не допускает бесконечность.
    CONSTRAINT product_price_check CHECK (price >= 0 AND price <> 'NaN'::numeric),
    -- BR-5.4, BR-9.7: рейтинг в диапазоне 0..5 либо NULL без отзывов.
    CONSTRAINT product_rating_check CHECK (rating BETWEEN 0 AND 5)
);

-- BR-6.1: сведения о курьере. ФИО хранится именно у курьера.
CREATE TABLE lisanov_food.courier (
    courier_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    fio varchar(200) NOT NULL,
    phone_number varchar(20) NOT NULL,
    status lisanov_food.courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date, -- BR-6.3: у работающего курьера может отсутствовать.
    coefficient numeric(3, 2) DEFAULT 0.10 NOT NULL,

    -- BR-6.1, BR-11.3, BR-11.4: ФИО и телефон обязательны.
    CONSTRAINT courier_fio_not_blank CHECK (btrim(fio) <> ''),
    CONSTRAINT courier_phone_number_not_blank CHECK (btrim(phone_number) <> ''),

    -- BR-6.3: у уволенного курьера обязательно есть дата увольнения.
    CONSTRAINT courier_dismissal_required_check
        CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL),
    -- BR-6.1, BR-6.3; также проверка D.13 в templates/tests.md:
    -- увольнение не может предшествовать найму.
    CONSTRAINT courier_employment_dates_check
        CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date),
    -- BR-6.4, BR-6.5: допустимый диапазон; начальное значение — 0.1.
    CONSTRAINT courier_coefficient_check CHECK (coefficient BETWEEN 0.10 AND 0.50)
);

-- BR-10.1, BR-10.2: месячная история выплат и применённых коэффициентов.
CREATE TABLE lisanov_food.courier_pay (
    year integer NOT NULL,
    month integer NOT NULL,
    courier_id uuid NOT NULL,
    amount numeric(14, 2) NOT NULL,
    coefficient_used numeric(3, 2) NOT NULL,

    -- BR-10.3: одна запись на курьера за конкретный год и месяц.
    -- Год и месяц — части календарного периода, а не UUID-идентификаторы.
    CONSTRAINT courier_pay_pkey PRIMARY KEY (year, month, courier_id),
    -- BR-10.1, BR-10.6: выплаты относятся к существующему курьеру;
    -- удаление курьера с историей выплат запрещено.
    CONSTRAINT courier_pay_courier_fk
        FOREIGN KEY (courier_id) REFERENCES lisanov_food.courier (courier_id)
        ON DELETE RESTRICT,

    -- BR-10.1, BR-10.2: календарный месяц 1..12, положительный год.
    CONSTRAINT courier_pay_year_check CHECK (year > 0),
    CONSTRAINT courier_pay_month_check CHECK (month BETWEEN 1 AND 12),
    -- BR-10.4: выплата неотрицательна; NaN недопустим для денежной суммы.
    CONSTRAINT courier_pay_amount_check CHECK (amount >= 0 AND amount <> 'NaN'::numeric),
    -- BR-6.4, BR-10.2: сохраняем коэффициент, действовавший при расчёте.
    CONSTRAINT courier_pay_coefficient_check
        CHECK (coefficient_used BETWEEN 0.10 AND 0.50)
);

COMMIT;
