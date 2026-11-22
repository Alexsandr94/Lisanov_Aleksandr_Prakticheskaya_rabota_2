-- FOOD-101: клиенты, адреса, категории блюд и связи клиентов с адресами.
-- Выполнять после 01_schema_types.sql в базе foodexpress.
-- BR-11.1: UUID новых сущностей генерируются на сервере.
-- BR-11.6: длины varchar выбраны для логина, телефона, названий и адресов.

BEGIN;

-- BR-2.1, BR-2.6: храним логин, пароль и телефон, без ФИО клиента.
CREATE TABLE lisanov_food.client (
    client_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    login varchar(100) NOT NULL,
    password varchar(32) NOT NULL,
    phone_number varchar(20) NOT NULL,

    -- BR-2.2: логин и телефон уникальны независимо друг от друга.
    CONSTRAINT client_login_key UNIQUE (login),
    CONSTRAINT client_phone_number_key UNIQUE (phone_number),

    -- BR-2.1, BR-11.3, BR-11.4: обязательные строки не могут быть пустыми.
    CONSTRAINT client_login_not_blank CHECK (btrim(login) <> ''),
    CONSTRAINT client_phone_number_not_blank CHECK (btrim(phone_number) <> ''),

    -- BR-2.3: формат MD5 — 32 шестнадцатеричных символа.
    CONSTRAINT client_password_md5_check
        CHECK (password ~ '^[0-9A-Fa-f]{32}$')
);

-- BR-3.1: адрес состоит из улицы, дома и квартиры/офиса.
CREATE TABLE lisanov_food.address (
    address_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    street varchar(200) NOT NULL,
    house_number varchar(20) NOT NULL,
    apartment_office varchar(20), -- NULL разрешён BR-3.2.

    -- BR-3.1, BR-3.3: одинаковый набор реквизитов хранится одним адресом,
    -- чтобы два ресторана не обходили уникальность адреса разными UUID.
    -- NULLS NOT DISTINCT учитывает также адреса без квартиры/офиса.
    CONSTRAINT address_location_key UNIQUE NULLS NOT DISTINCT
        (street, house_number, apartment_office),

    -- BR-3.1, BR-11.3, BR-11.4: улица и номер дома обязательны.
    CONSTRAINT address_street_not_blank CHECK (btrim(street) <> ''),
    CONSTRAINT address_house_number_not_blank CHECK (btrim(house_number) <> ''),
    -- BR-3.2: отсутствие квартиры обозначается NULL, а не пустой строкой.
    CONSTRAINT address_apartment_office_not_blank
        CHECK (apartment_office IS NULL OR btrim(apartment_office) <> '')
);

-- BR-5.7: справочник содержит идентификатор и название категории.
CREATE TABLE lisanov_food.product_category (
    product_category_id uuid DEFAULT exts.uuid_generate_v4() PRIMARY KEY,
    product_category_name varchar(100) NOT NULL,

    -- BR-5.7, BR-11.3, BR-11.4: название категории обязательно.
    CONSTRAINT product_category_name_not_blank
        CHECK (btrim(product_category_name) <> '')
);

-- BR-2.4, BR-3.4: несколько клиентов могут использовать один адрес.
-- Здесь UUID уже существующих клиентов и адресов, поэтому DEFAULT нет.
CREATE TABLE lisanov_food.client_address (
    client_id uuid NOT NULL,
    address_id uuid NOT NULL,

    -- BR-2.5: одна пара «клиент — адрес» не может повторяться.
    CONSTRAINT client_address_pkey PRIMARY KEY (client_id, address_id),

    -- BR-2.4, BR-3.5: удаление клиента удаляет только его привязки;
    -- сама запись в address сохраняется.
    CONSTRAINT client_address_client_fk
        FOREIGN KEY (client_id) REFERENCES lisanov_food.client (client_id)
        ON DELETE CASCADE,

    -- BR-2.4, BR-3.4: привязать можно только существующий адрес.
    CONSTRAINT client_address_address_fk
        FOREIGN KEY (address_id) REFERENCES lisanov_food.address (address_id)
        ON DELETE RESTRICT
);

COMMIT;
