-- FOOD-101: схема и перечисляемые типы.
-- Схема exts с uuid-ossp уже подготовлена отдельно (BR-13.3).

BEGIN;

CREATE SCHEMA IF NOT EXISTS lisanov_food;

-- BR-4.3: статус ресторана.
CREATE TYPE lisanov_food.restaurant_status AS ENUM (
    'активен', 'неактивен'
);

-- BR-5.5: статус блюда.
CREATE TYPE lisanov_food.product_status AS ENUM (
    'доступно', 'нет_в_наличии', 'архив'
);

-- BR-6.2: статус курьера.
CREATE TYPE lisanov_food.courier_status AS ENUM (
    'свободен', 'занят', 'на_доставке', 'уволен'
);

-- BR-7.7: статус заказа.
CREATE TYPE lisanov_food.order_status AS ENUM (
    'создан', 'готовится', 'в_доставке', 'доставлен', 'отменён'
);

-- BR-7.9: общий статус оплаты заказа.
CREATE TYPE lisanov_food.order_pay_status AS ENUM (
    'ожидает', 'оплачен', 'ошибка'
);

-- BR-8.2: статус отдельной попытки оплаты.
CREATE TYPE lisanov_food.payment_status AS ENUM (
    'успех', 'ошибка', 'в_обработке'
);

-- BR-8.2: способ оплаты.
CREATE TYPE lisanov_food.payment_type AS ENUM (
    'карта', 'наличные', 'безнал'
);

-- BR-9.1: объект, на который оставлен отзыв.
CREATE TYPE lisanov_food.review_entity_type AS ENUM (
    'блюдо', 'ресторан', 'заказ'
);

COMMIT;
