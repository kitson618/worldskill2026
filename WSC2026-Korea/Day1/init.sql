-- Giftree — giftdb initialization script (provided competition asset)
-- psql -h <aurora-writer-endpoint> -U <username> -d giftdb -f init.sql

CREATE TABLE IF NOT EXISTS products (
    product_id  SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    brand       VARCHAR(50)  NOT NULL,
    category    VARCHAR(30)  NOT NULL,
    price       INTEGER      NOT NULL,
    created_at  TIMESTAMP    DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    order_id    UUID PRIMARY KEY,
    user_id     VARCHAR(36) NOT NULL,
    product_id  INTEGER REFERENCES products(product_id),
    quantity    INTEGER     NOT NULL,
    amount      INTEGER     NOT NULL,
    status      VARCHAR(16) NOT NULL,
    ordered_at  TIMESTAMP   NOT NULL
);

INSERT INTO products (name, brand, category, price) VALUES
    ('Americano Tall',           'StarBeans',  'coffee',  5),
    ('Caffe Latte Grande',       'StarBeans',  'coffee',  6),
    ('Signature Chocolate Box',  'ChocoLab',   'dessert', 18),
    ('Strawberry Cream Cake',    'SweetOven',  'dessert', 32),
    ('Fried Chicken Combo',      'CluckHouse', 'meal',    23),
    ('Premium Beef Gift Set',    'PrimeCuts',  'meal',    120),
    ('Movie Tickets (Pair)',     'CinemaOne',  'ticket',  28),
    ('Spa Day Pass',             'RelaxSpa',   'ticket',  55),
    ('Wireless Earbuds',         'SoundCore',  'goods',   89),
    ('Portable Power Bank',      'PowerGo',    'goods',   35),
    ('Fruit Gift Basket',        'FreshFarm',  'meal',    45),
    ('Premium Perfume Edition',  'AromaLuxe',  'goods',   78);
