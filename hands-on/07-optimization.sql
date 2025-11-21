-- ======================================================================
-- ハンズオン07: クエリ最適化とプランニング
-- ======================================================================
-- 目的: PostgreSQLのクエリ最適化の仕組みと実践的な最適化手法を学ぶ
-- 所要時間: 45分
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン07: クエリ最適化'
\echo '========================================'

-- ======================================
-- セクション1: データ準備
-- ======================================

\echo '\n--- セクション1: サンプルデータ作成 ---'

DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS products CASCADE;

CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(255),
    country VARCHAR(50),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    category VARCHAR(50),
    price DECIMAL(10,2)
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    order_date TIMESTAMP DEFAULT NOW(),
    status VARCHAR(20)
);

CREATE TABLE order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id),
    product_id INTEGER REFERENCES products(id),
    quantity INTEGER,
    unit_price DECIMAL(10,2)
);

-- データ挿入
INSERT INTO customers (name, email, country)
SELECT
    'Customer ' || i,
    'customer' || i || '@example.com',
    (ARRAY['USA', 'Japan', 'UK', 'Germany', 'France'])[1 + floor(random() * 5)::INTEGER]
FROM generate_series(1, 10000) i;

INSERT INTO products (name, category, price)
SELECT
    'Product ' || i,
    (ARRAY['Electronics', 'Books', 'Clothing', 'Food'])[1 + floor(random() * 4)::INTEGER],
    (random() * 1000)::DECIMAL(10,2)
FROM generate_series(1, 1000) i;

INSERT INTO orders (customer_id, order_date, status)
SELECT
    1 + floor(random() * 10000)::INTEGER,
    NOW() - (random() * 365 || ' days')::INTERVAL,
    (ARRAY['pending', 'shipped', 'delivered'])[1 + floor(random() * 3)::INTEGER]
FROM generate_series(1, 50000) i;

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
    o.id,
    1 + floor(random() * 1000)::INTEGER,
    1 + floor(random() * 10)::INTEGER,
    p.price
FROM orders o
CROSS JOIN LATERAL (
    SELECT * FROM products WHERE id = 1 + floor(random() * 1000)::INTEGER LIMIT 1
) p;

ANALYZE;

\echo '✓ サンプルデータ作成完了'

-- ======================================
-- セクション2: EXPLAIN の基本
-- ======================================

\echo '\n\n--- セクション2: EXPLAIN の読み方 ---'

-- 基本的なEXPLAIN
\echo '\n--- EXPLAIN (基本) ---'
EXPLAIN
SELECT * FROM customers WHERE country = 'Japan';

\echo '\n💡 注目ポイント:'
\echo '  - cost=0.00..X.XX: 開始コスト..総コスト'
\echo '  - rows=X: 推定行数'
\echo '  - width=X: 平均行サイズ（バイト）'

-- EXPLAIN ANALYZE
\echo '\n--- EXPLAIN ANALYZE (実測値付き) ---'
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM customers WHERE country = 'Japan';

\echo '\n💡 注目ポイント:'
\echo '  - actual time: 実際の実行時間（ms）'
\echo '  - rows: 実際の行数'
\echo '  - Buffers shared hit/read: キャッシュヒット/ディスクI/O'

-- ======================================
-- セクション3: 統計情報の重要性
-- ======================================

\echo '\n\n--- セクション3: 統計情報 ---'

-- 統計情報確認
SELECT
    tablename,
    attname as column,
    n_distinct,
    most_common_vals[1:3] as top3_values,
    most_common_freqs[1:3] as top3_freqs
FROM pg_stats
WHERE tablename = 'customers'
  AND attname = 'country';

\echo '\n💡 統計情報:'
\echo '  - n_distinct: ユニーク値数の推定'
\echo '  - most_common_vals: 頻出値'
\echo '  - most_common_freqs: その頻度'
\echo '  - プランナーの選択率計算に使用'

-- 統計精度の調整
ALTER TABLE customers ALTER COLUMN country SET STATISTICS 1000;
ANALYZE customers;

\echo '\n統計精度を上げた後:'
SELECT attname, n_distinct
FROM pg_stats
WHERE tablename = 'customers' AND attname = 'country';

-- ======================================
-- セクション4: JOIN最適化
-- ======================================

\echo '\n\n--- セクション4: JOIN アルゴリズム ---'

-- Nested Loop Join
SET enable_hashjoin = off;
SET enable_mergejoin = off;

\echo '\n--- Nested Loop Join ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, COUNT(o.id)
FROM customers c
JOIN orders o ON c.id = o.customer_id
WHERE c.country = 'Japan'
GROUP BY c.id, c.name
LIMIT 10;

\echo '\n💡 Nested Loop:'
\echo '  - 小さいテーブル × 大きいテーブル'
\echo '  - インデックスがある場合に効率的'

-- Hash Join
SET enable_hashjoin = on;
SET enable_mergejoin = off;
SET enable_nestloop = off;

\echo '\n--- Hash Join ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, COUNT(o.id)
FROM customers c
JOIN orders o ON c.id = o.customer_id
WHERE c.country = 'Japan'
GROUP BY c.id, c.name
LIMIT 10;

\echo '\n💡 Hash Join:'
\echo '  - 小さいテーブルでハッシュテーブル構築'
\echo '  - 大きいテーブルをスキャン'
\echo '  - work_memに収まる必要あり'

-- Merge Join
SET enable_hashjoin = off;
SET enable_mergejoin = on;
SET enable_nestloop = off;

CREATE INDEX idx_customers_id ON customers(id);
CREATE INDEX idx_orders_customer_id ON orders(customer_id);

\echo '\n--- Merge Join ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, COUNT(o.id)
FROM customers c
JOIN orders o ON c.id = o.customer_id
WHERE c.country = 'Japan'
GROUP BY c.id, c.name
LIMIT 10;

\echo '\n💡 Merge Join:'
\echo '  - 両テーブルがソート済み'
\echo '  - インデックススキャンで効率的'

-- 設定をリセット
RESET enable_hashjoin;
RESET enable_mergejoin;
RESET enable_nestloop;

-- ======================================
-- セクション5: サブクエリ最適化
-- ======================================

\echo '\n\n--- セクション5: サブクエリ vs JOIN ---'

-- 相関サブクエリ（非効率）
\echo '\n--- 相関サブクエリ（遅い） ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name,
    (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.id) as order_count
FROM customers c
WHERE c.country = 'Japan'
LIMIT 100;

-- JOIN に書き換え（効率的）
\echo '\n--- JOIN に書き換え（速い） ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, COUNT(o.id) as order_count
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
WHERE c.country = 'Japan'
GROUP BY c.id, c.name
LIMIT 100;

\echo '\n💡 最適化:'
\echo '  - 相関サブクエリは各行で実行される'
\echo '  - JOINは1回のスキャンで済む'

-- ======================================
-- セクション6: CTE（WITH句）の最適化
-- ======================================

\echo '\n\n--- セクション6: CTE の最適化 ---'

-- PostgreSQL 12以降: CTEのインライン化
\echo '\n--- CTE (自動インライン化) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH japan_customers AS (
    SELECT id, name FROM customers WHERE country = 'Japan'
)
SELECT jc.name, COUNT(o.id)
FROM japan_customers jc
LEFT JOIN orders o ON jc.id = o.customer_id
GROUP BY jc.name
LIMIT 10;

-- 強制的にマテリアライズ
\echo '\n--- CTE (MATERIALIZED) ---'
EXPLAIN (ANALYZE, BUFFERS)
WITH japan_customers AS MATERIALIZED (
    SELECT id, name FROM customers WHERE country = 'Japan'
)
SELECT jc.name, COUNT(o.id)
FROM japan_customers jc
LEFT JOIN orders o ON jc.id = o.customer_id
GROUP BY jc.name
LIMIT 10;

\echo '\n💡 CTE最適化:'
\echo '  - デフォルト: プランナーがインライン化判断'
\echo '  - MATERIALIZED: 強制的に実体化'
\echo '  - NOT MATERIALIZED: 強制的にインライン化'

-- ======================================
-- セクション7: インデックス戦略
-- ======================================

\echo '\n\n--- セクション7: インデックス最適化 ---'

-- 複合インデックスの効果
CREATE INDEX idx_orders_status_date ON orders(status, order_date);

\echo '\n--- 複合インデックス使用 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE status = 'delivered'
  AND order_date > NOW() - INTERVAL '30 days';

-- INCLUDE インデックス
DROP INDEX IF EXISTS idx_orders_status_date;
CREATE INDEX idx_orders_status_date_inc
ON orders(status, order_date) INCLUDE (customer_id);

\echo '\n--- Index Only Scan (INCLUDE使用) ---'
VACUUM orders;  -- Visibility Map更新

EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id FROM orders
WHERE status = 'delivered'
  AND order_date > NOW() - INTERVAL '30 days';

\echo '\n💡 INCLUDE:'
\echo '  - 検索に使わないカラムも含める'
\echo '  - Index Only Scanが可能に'
\echo '  - ヒープアクセス不要'

-- ======================================
-- セクション8: パーティション枝刈り
-- ======================================

\echo '\n\n--- セクション8: パーティション Pruning ---'

-- パーティションテーブル作成
DROP TABLE IF EXISTS orders_partitioned CASCADE;

CREATE TABLE orders_partitioned (
    id SERIAL,
    customer_id INTEGER,
    order_date DATE,
    status VARCHAR(20)
) PARTITION BY RANGE (order_date);

CREATE TABLE orders_2023 PARTITION OF orders_partitioned
FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');

CREATE TABLE orders_2024 PARTITION OF orders_partitioned
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

CREATE TABLE orders_2025 PARTITION OF orders_partitioned
FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

-- データ挿入
INSERT INTO orders_partitioned
SELECT id, customer_id, order_date::DATE, status
FROM orders;

\echo '\n--- Partition Pruning (枝刈り) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders_partitioned
WHERE order_date >= '2024-01-01'
  AND order_date < '2024-02-01';

\echo '\n💡 Partition Pruning:'
\echo '  - WHERE句からアクセス不要なパーティションを除外'
\echo '  - スキャン範囲が大幅に削減'

-- ======================================
-- セクション9: work_mem チューニング
-- ======================================

\echo '\n\n--- セクション9: work_mem の影響 ---'

-- work_mem 小さい（ディスクソート）
SET work_mem = '64kB';

\echo '\n--- work_mem = 64kB (ディスクソート) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, SUM(quantity * unit_price) as total
FROM order_items
GROUP BY customer_id
ORDER BY total DESC
LIMIT 100;

-- work_mem 大きい（メモリソート）
SET work_mem = '64MB';

\echo '\n--- work_mem = 64MB (メモリソート) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, SUM(quantity * unit_price) as total
FROM order_items
GROUP BY customer_id
ORDER BY total DESC
LIMIT 100;

RESET work_mem;

\echo '\n💡 work_mem:'
\echo '  - ソート・ハッシュ用のメモリ'
\echo '  - 小さいとディスクI/O発生（遅い）'
\echo '  - 大きすぎるとメモリ不足のリスク'

-- ======================================
-- セクション10: 統計情報とコスト見積もり
-- ======================================

\echo '\n\n--- セクション10: コストモデル ---'

-- コストパラメータ確認
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'seq_page_cost',
    'random_page_cost',
    'cpu_tuple_cost',
    'cpu_index_tuple_cost',
    'cpu_operator_cost',
    'effective_cache_size'
);

-- random_page_cost の影響
\echo '\n--- random_page_cost = 4.0 (HDD想定) ---'
SET random_page_cost = 4.0;
EXPLAIN SELECT * FROM orders WHERE customer_id = 100;

\echo '\n--- random_page_cost = 1.1 (SSD想定) ---'
SET random_page_cost = 1.1;
EXPLAIN SELECT * FROM orders WHERE customer_id = 100;

RESET random_page_cost;

\echo '\n💡 random_page_cost:'
\echo '  - ランダムI/Oのコスト'
\echo '  - HDD: 4.0, SSD: 1.1-1.5'
\echo '  - インデックス選択に影響'

-- ======================================
-- セクション11: LIMIT の最適化
-- ======================================

\echo '\n\n--- セクション11: LIMIT プッシュダウン ---'

\echo '\n--- LIMIT あり（早期終了） ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, o.order_date
FROM customers c
JOIN orders o ON c.id = o.customer_id
ORDER BY o.order_date DESC
LIMIT 10;

\echo '\n--- LIMIT なし（全件処理） ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, o.order_date
FROM customers c
JOIN orders o ON c.id = o.customer_id
ORDER BY o.order_date DESC;

\echo '\n💡 LIMIT最適化:'
\echo '  - Top-N ヒープソート'
\echo '  - 必要最小限のタプルのみ処理'
\echo '  - INDEX使用で早期終了可能'

-- ======================================
-- セクション12: まとめと実践課題
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ EXPLAIN ANALYZE: 実行計画と実測値の確認'
\echo '✓ 統計情報: プランナーの判断材料'
\echo '✓ JOIN: Nested Loop / Hash / Merge'
\echo '✓ サブクエリ: JOINへの書き換え'
\echo '✓ CTE: インライン化 vs マテリアライズ'
\echo '✓ インデックス: 複合、INCLUDE、部分'
\echo '✓ work_mem: メモリ vs ディスクソート'
\echo '✓ Partition Pruning: 枝刈り最適化'
\echo ''
\echo '最適化チェックリスト:'
\echo '  1. EXPLAIN ANALYZEで実測'
\echo '  2. 統計情報が最新か確認（ANALYZE）'
\echo '  3. 適切なインデックス作成'
\echo '  4. サブクエリをJOINに書き換え'
\echo '  5. work_memチューニング'
\echo '  6. パーティショニング検討'
\echo ''
\echo '📝 実践課題:'
\echo '  1. 遅いクエリを見つける（pg_stat_statements）'
\echo '  2. EXPLAIN ANALYZEで分析'
\echo '  3. インデックス追加またはクエリ書き換え'
\echo '  4. 改善効果を測定'
\echo '========================================'

-- クリーンアップ
-- DROP TABLE IF EXISTS customers, orders, order_items, products, orders_partitioned CASCADE;
