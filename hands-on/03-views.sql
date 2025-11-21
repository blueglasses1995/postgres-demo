-- ======================================================================
-- ハンズオン03: ビューとマテリアルビュー
-- ======================================================================
-- 目的: ビューの書き換えとマテリアルビューの実体化を理解する
-- 所要時間: 25分
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン03: ビューとマテリアルビュー'
\echo '========================================'

-- ======================================
-- セクション1: データ準備
-- ======================================

\echo '\n--- セクション1: サンプルデータ作成 ---'

DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS products CASCADE;

CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(255),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    price DECIMAL(10, 2),
    category VARCHAR(50)
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    product_id INTEGER REFERENCES products(id),
    quantity INTEGER,
    order_date TIMESTAMP DEFAULT NOW()
);

-- サンプルデータ挿入
INSERT INTO customers (name, email)
SELECT
    'Customer ' || i,
    'customer' || i || '@example.com'
FROM generate_series(1, 1000) i;

INSERT INTO products (name, price, category)
SELECT
    'Product ' || i,
    (random() * 1000)::DECIMAL(10, 2),
    CASE (random() * 3)::INTEGER
        WHEN 0 THEN 'Electronics'
        WHEN 1 THEN 'Books'
        ELSE 'Clothing'
    END
FROM generate_series(1, 100) i;

INSERT INTO orders (customer_id, product_id, quantity, order_date)
SELECT
    (random() * 999 + 1)::INTEGER,
    (random() * 99 + 1)::INTEGER,
    (random() * 10 + 1)::INTEGER,
    NOW() - (random() * 365 || ' days')::INTERVAL
FROM generate_series(1, 100000) i;

ANALYZE customers, products, orders;

\echo '✓ サンプルデータ作成完了'

-- ======================================
-- セクション2: 通常ビューの作成と書き換え
-- ======================================

\echo '\n\n--- セクション2: 通常ビュー ---'

-- ビュー作成
CREATE VIEW order_summary AS
SELECT
    c.name as customer_name,
    p.name as product_name,
    p.category,
    o.quantity,
    p.price * o.quantity as total_price,
    o.order_date
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN products p ON o.product_id = p.id;

\echo '✓ ビュー作成完了'

-- ビュー定義確認
\d+ order_summary

-- ビューのクエリ
\echo '\n--- ビューからSELECT ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_name, SUM(total_price) as total
FROM order_summary
WHERE category = 'Electronics'
GROUP BY customer_name
ORDER BY total DESC
LIMIT 10;

\echo '\n💡 注目ポイント:'
\echo '  - ビューは実行時にクエリ書き換え'
\echo '  - データは保存されていない（仮想テーブル）'
\echo '  - プランナーが全体を最適化'

-- 書き換え後のクエリ確認
\echo '\n--- 実際に実行されるクエリ（書き換え後） ---'
EXPLAIN (VERBOSE)
SELECT customer_name, SUM(total_price)
FROM order_summary
WHERE category = 'Electronics'
GROUP BY customer_name
LIMIT 10;

-- ======================================
-- セクション3: マテリアルビューの作成
-- ======================================

\echo '\n\n--- セクション3: マテリアルビュー ---'

-- マテリアルビュー作成
\timing on
CREATE MATERIALIZED VIEW order_summary_mv AS
SELECT
    c.id as customer_id,
    c.name as customer_name,
    p.category,
    SUM(o.quantity) as total_quantity,
    SUM(p.price * o.quantity) as total_amount,
    COUNT(*) as order_count
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN products p ON o.product_id = p.id
GROUP BY c.id, c.name, p.category;
\timing off

\echo '✓ マテリアルビュー作成完了'

-- サイズ確認
SELECT
    'order_summary (view)' as object,
    pg_size_pretty(0::BIGINT) as size
UNION ALL
SELECT
    'order_summary_mv (materialized)',
    pg_size_pretty(pg_total_relation_size('order_summary_mv'));

-- データ確認
SELECT COUNT(*) as row_count FROM order_summary_mv;

-- ======================================
-- セクション4: パフォーマンス比較
-- ======================================

\echo '\n\n--- セクション4: ビュー vs マテリアルビュー ---'

\echo '\n通常ビュー（毎回計算）:'
\timing on
SELECT customer_name, SUM(total_price) as total
FROM order_summary
WHERE category = 'Electronics'
GROUP BY customer_name
ORDER BY total DESC
LIMIT 10;
\timing off

\echo '\nマテリアルビュー（事前計算済み）:'
\timing on
SELECT customer_name, SUM(total_amount) as total
FROM order_summary_mv
WHERE category = 'Electronics'
GROUP BY customer_name
ORDER BY total DESC
LIMIT 10;
\timing off

\echo '\n💡 注目ポイント:'
\echo '  - マテリアルビューは事前集約済みで高速'
\echo '  - ただしデータは作成時点の内容'

-- ======================================
-- セクション5: マテリアルビューのリフレッシュ
-- ======================================

\echo '\n\n--- セクション5: REFRESH MATERIALIZED VIEW ---'

-- データ変更
INSERT INTO orders (customer_id, product_id, quantity)
VALUES (1, 1, 100);

\echo '\n--- リフレッシュ前 ---'
SELECT * FROM order_summary_mv WHERE customer_id = 1 AND category = 'Electronics';

-- リフレッシュ（ロックあり）
\echo '\n--- REFRESH実行 ---'
\timing on
REFRESH MATERIALIZED VIEW order_summary_mv;
\timing off

\echo '\n--- リフレッシュ後 ---'
SELECT * FROM order_summary_mv WHERE customer_id = 1 AND category = 'Electronics';

\echo '\n💡 通常のREFRESH:'
\echo '  - ACCESS EXCLUSIVE LOCKを取得'
\echo '  - リフレッシュ中は読み取り不可'
\echo '  - 全データを再計算'

-- ======================================
-- セクション6: REFRESH CONCURRENTLY
-- ======================================

\echo '\n\n--- セクション6: REFRESH CONCURRENTLY ---'

-- UNIQUEインデックス作成（CONCURRENTLY の要件）
CREATE UNIQUE INDEX ON order_summary_mv (customer_id, category);

\echo '\n--- REFRESH CONCURRENTLY実行 ---'
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY order_summary_mv;
\timing off

\echo '\n💡 REFRESH CONCURRENTLY:'
\echo '  - 読み取りアクセス可能'
\echo '  - UNIQUE INDEXが必須'
\echo '  - 差分を計算して適用'
\echo '  - 通常のREFRESHより時間がかかる場合あり'

-- ロック状況確認
SELECT
    locktype,
    mode,
    granted
FROM pg_locks
WHERE relation = 'order_summary_mv'::regclass;

-- ======================================
-- セクション7: マテリアルビューへのインデックス
-- ======================================

\echo '\n\n--- セクション7: インデックス追加 ---'

-- インデックス作成
CREATE INDEX idx_mv_category ON order_summary_mv(category);
CREATE INDEX idx_mv_amount ON order_summary_mv(total_amount);

-- インデックス使用確認
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_summary_mv
WHERE category = 'Electronics'
ORDER BY total_amount DESC
LIMIT 10;

\echo '\n💡 マテリアルビューの利点:'
\echo '  - インデックス作成可能'
\echo '  - 複雑な集計を事前計算'
\echo '  - 読み取り専用の分析クエリに最適'

-- ======================================
-- セクション8: 更新可能ビュー
-- ======================================

\echo '\n\n--- セクション8: 更新可能ビュー ---'

-- シンプルなビュー作成
CREATE VIEW active_customers AS
SELECT id, name, email
FROM customers
WHERE created_at > NOW() - INTERVAL '30 days';

\echo '\n--- ビュー経由でINSERT ---'
INSERT INTO active_customers (name, email)
VALUES ('New Customer', 'new@example.com')
RETURNING *;

\echo '\n--- ビュー経由でUPDATE ---'
UPDATE active_customers
SET email = 'updated@example.com'
WHERE name = 'New Customer'
RETURNING *;

\echo '\n💡 自動更新可能ビューの条件:'
\echo '  - 単一テーブル参照'
\echo '  - JOIN, 集約, DISTINCT等なし'
\echo '  - FROM句に複数テーブルがない'

-- ======================================
-- セクション9: INSTEAD OF トリガー
-- ======================================

\echo '\n\n--- セクション9: INSTEAD OF トリガー ---'

-- 複雑なビュー（更新不可）
CREATE VIEW customer_orders AS
SELECT
    c.id as customer_id,
    c.name,
    COUNT(o.id) as order_count
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
GROUP BY c.id, c.name;

-- INSTEAD OF トリガー関数
CREATE OR REPLACE FUNCTION update_customer_orders()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE customers
    SET name = NEW.name
    WHERE id = NEW.customer_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- INSTEAD OF トリガー作成
CREATE TRIGGER instead_of_update_customer_orders
INSTEAD OF UPDATE ON customer_orders
FOR EACH ROW
EXECUTE FUNCTION update_customer_orders();

\echo '\n--- トリガー経由でUPDATE ---'
UPDATE customer_orders
SET name = 'Updated via Trigger'
WHERE customer_id = 1;

SELECT * FROM customers WHERE id = 1;

\echo '\n💡 INSTEAD OF トリガー:'
\echo '  - 複雑なビューでも更新可能に'
\echo '  - INSERT/UPDATE/DELETE を実装可能'

-- ======================================
-- セクション10: マテリアルビューの内部構造
-- ======================================

\echo '\n\n--- セクション10: 内部構造 ---'

-- システムカタログ確認
SELECT
    schemaname,
    matviewname,
    matviewowner,
    tablespace,
    hasindexes,
    ispopulated,
    definition
FROM pg_matviews
WHERE matviewname = 'order_summary_mv';

-- ストレージ情報
SELECT
    pg_size_pretty(pg_total_relation_size('order_summary_mv')) as total_size,
    pg_size_pretty(pg_relation_size('order_summary_mv')) as table_size,
    pg_size_pretty(pg_indexes_size('order_summary_mv')) as indexes_size;

-- タプル統計
SELECT
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'order_summary_mv';

\echo '\n💡 マテリアルビューは物理テーブル:'
\echo '  - 通常のテーブルと同じストレージ'
\echo '  - VACUUMが必要'
\echo '  - 統計情報も収集される'

-- ======================================
-- セクション11: リフレッシュ戦略
-- ======================================

\echo '\n\n--- セクション11: リフレッシュ戦略 ---'

\echo '
リフレッシュ戦略の選択:

1. 定期的なREFRESH:
   - cron や pg_cron で定時実行
   - 夜間バッチ等でREFRESH

2. REFRESH CONCURRENTLY:
   - 営業時間中のリフレッシュ
   - 大きなMVで推奨

3. トリガーベース:
   - 元テーブルのINSERT/UPDATEトリガーで更新
   - リアルタイム性が必要な場合

4. 増分更新:
   - 差分だけを手動でUPDATE
   - タイムスタンプ等で判定

例: pg_cron による定期リフレッシュ
CREATE EXTENSION pg_cron;
SELECT cron.schedule('\''refresh-mv'\'', '\''0 2 * * *'\'',
    '\''REFRESH MATERIALIZED VIEW CONCURRENTLY order_summary_mv'\'');
'

-- ======================================
-- セクション12: まとめ
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ ビュー: クエリの保存、実行時に書き換え'
\echo '✓ マテリアルビュー: 結果を物理的に保存'
\echo '✓ REFRESH: データを再計算'
\echo '✓ REFRESH CONCURRENTLY: 読み取り可能なまま更新'
\echo '✓ 更新可能ビュー: 単純なビューは自動更新可能'
\echo '✓ INSTEAD OF トリガー: 複雑なビューの更新'
\echo ''
\echo '使い分け:'
\echo '  - リアルタイムデータ → 通常ビュー'
\echo '  - 重い集計クエリ → マテリアルビュー'
\echo '  - 頻繁な読み取り、少ない更新 → マテリアルビュー'
\echo ''
\echo '📝 課題:'
\echo '  1. カテゴリ別売上集計のマテリアルビュー作成'
\echo '  2. 適切なインデックスを追加'
\echo '  3. REFRESH CONCURRENTLY実行'
\echo '  4. パフォーマンスを通常ビューと比較'
\echo '========================================'

-- クリーンアップ
-- DROP MATERIALIZED VIEW IF EXISTS order_summary_mv CASCADE;
-- DROP VIEW IF EXISTS order_summary, active_customers, customer_orders CASCADE;
-- DROP TABLE IF EXISTS orders, customers, products CASCADE;
