-- ======================================================================
-- ハンズオン01: インデックス技術の理解
-- ======================================================================
-- 目的: PostgreSQLの各種インデックスの特性と内部動作を理解する
-- 所要時間: 30分
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン01: インデックス技術'
\echo '========================================'

-- ======================================
-- セクション1: データ準備
-- ======================================

\echo '\n--- セクション1: サンプルデータ作成 ---'

-- テーブル作成
DROP TABLE IF EXISTS users CASCADE;
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    username VARCHAR(100) NOT NULL,
    age INTEGER,
    created_at TIMESTAMP DEFAULT NOW(),
    status VARCHAR(20),
    tags TEXT[],
    profile JSONB,
    location POINT
);

-- 100万件のサンプルデータ挿入
INSERT INTO users (email, username, age, status, tags, profile, location)
SELECT
    'user' || i || '@example.com',
    'user_' || i,
    20 + (random() * 60)::INTEGER,
    CASE (random() * 3)::INTEGER
        WHEN 0 THEN 'active'
        WHEN 1 THEN 'inactive'
        ELSE 'pending'
    END,
    ARRAY['tag' || ((random() * 10)::INTEGER), 'tag' || ((random() * 10)::INTEGER)],
    jsonb_build_object(
        'level', (random() * 100)::INTEGER,
        'verified', random() > 0.5,
        'bio', 'User biography ' || i
    ),
    point(random() * 180 - 90, random() * 360 - 180)
FROM generate_series(1, 1000000) i;

\echo '✓ 100万件のデータ作成完了'

-- 統計情報更新
ANALYZE users;

-- テーブルサイズ確認
SELECT
    pg_size_pretty(pg_total_relation_size('users')) as total_size,
    pg_size_pretty(pg_relation_size('users')) as table_size,
    pg_size_pretty(pg_indexes_size('users')) as indexes_size;

\echo '\n--- 初期状態のクエリ性能 ---'

-- ベースライン計測: インデックスなしのクエリ
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM users WHERE email = 'user50000@example.com';

\echo '\n💡 注目ポイント:'
\echo '  - Seq Scan (Sequential Scan): 全行スキャン'
\echo '  - Buffers read: ディスクI/O回数'
\echo '  - Execution Time: 実行時間'

-- ======================================
-- セクション2: B-Tree インデックス
-- ======================================

\echo '\n\n--- セクション2: B-Tree インデックス ---'

-- emailカラムにB-Treeインデックス作成
\timing on
CREATE INDEX idx_users_email ON users(email);
\timing off

\echo '\n✓ B-Treeインデックス作成完了'

-- インデックスサイズ確認
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched
FROM pg_stat_user_indexes
WHERE indexname = 'idx_users_email';

-- インデックスを使ったクエリ
\echo '\n--- Index Scanの動作確認 ---'
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM users WHERE email = 'user50000@example.com';

\echo '\n💡 注目ポイント:'
\echo '  - Index Scan: B-Treeインデックスを使用'
\echo '  - Buffers read: 大幅に減少'
\echo '  - Heap Fetches: インデックスからヒープへのアクセス数'

-- 範囲検索でのB-Tree効率性
\echo '\n--- B-Treeの範囲検索 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users
WHERE email >= 'user100000@example.com'
  AND email < 'user100100@example.com';

-- ======================================
-- セクション3: Index Only Scan
-- ======================================

\echo '\n\n--- セクション3: Index Only Scan ---'

-- Covering Index (INCLUDE句)
CREATE INDEX idx_users_email_covering ON users(email) INCLUDE (username);

\echo '\n--- Index Only Scan vs Index Scan 比較 ---'

-- Index Scan (ヒープアクセス必要)
\echo '\nパターン1: email のみ取得 (Index Only Scan期待)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT email FROM users WHERE email LIKE 'user5000%';

-- ヒープアクセス最小化のためVACUUM実行
VACUUM users;

\echo '\nVACUUM後に再実行:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT email FROM users WHERE email LIKE 'user5000%';

\echo '\n💡 注目ポイント:'
\echo '  - Heap Fetches: 0 = ヒープアクセス不要'
\echo '  - Visibility Mapでall-visibleページを確認'

-- INCLUDE句の効果
\echo '\nパターン2: email + username 取得 (INCLUDE活用)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT email, username FROM users WHERE email LIKE 'user5000%';

-- ======================================
-- セクション4: 複合インデックス
-- ======================================

\echo '\n\n--- セクション4: 複合インデックス ---'

-- 複合インデックス作成
CREATE INDEX idx_users_status_age ON users(status, age);

\echo '\n--- 複合インデックスの使用パターン ---'

-- パターン1: 両方のカラムを使用（最適）
\echo '\nパターン1: status + age 両方条件指定'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE status = 'active' AND age > 30;

-- パターン2: 先頭カラムのみ（使用可能）
\echo '\nパターン2: status のみ（先頭カラム）'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE status = 'active';

-- パターン3: 2番目のカラムのみ（使用不可）
\echo '\nパターン3: age のみ（2番目カラム）'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE age > 30;

\echo '\n💡 注目ポイント:'
\echo '  - 複合インデックスは左端からの一致が必要'
\echo '  - (status, age) → status単独でも使用可能'
\echo '  - age単独では使用されない'

-- ======================================
-- セクション5: 部分インデックス
-- ======================================

\echo '\n\n--- セクション5: 部分インデックス (Partial Index) ---'

-- activeユーザーのみのインデックス
CREATE INDEX idx_users_active_age ON users(age) WHERE status = 'active';

\echo '\n--- 部分インデックスの効果 ---'

-- インデックスサイズ比較
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE tablename = 'users'
ORDER BY pg_relation_size(indexrelid) DESC;

-- 部分インデックスの使用
\echo '\n条件がマッチする場合:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE status = 'active' AND age > 50;

\echo '\n条件がマッチしない場合:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE status = 'inactive' AND age > 50;

\echo '\n💡 注目ポイント:'
\echo '  - WHERE句が部分インデックス条件と一致すると使用される'
\echo '  - インデックスサイズを大幅に削減可能'

-- ======================================
-- セクション6: 式インデックス (Expression Index)
-- ======================================

\echo '\n\n--- セクション6: 式インデックス ---'

-- LOWER関数を使った式インデックス
CREATE INDEX idx_users_email_lower ON users(LOWER(email));

\echo '\n--- 式インデックスの使用 ---'

-- 式インデックスなしでの検索（インデックス使用不可）
\echo '\n式インデックスなし:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE LOWER(email) = 'user60000@example.com';

\echo '\n💡 関数適用するとB-Treeインデックスは使えない'
\echo '   → 式インデックスで解決'

-- ======================================
-- セクション7: GIN インデックス (配列・JSONB)
-- ======================================

\echo '\n\n--- セクション7: GIN インデックス ---'

-- 配列カラムへのGINインデックス
CREATE INDEX idx_users_tags ON users USING GIN(tags);

\echo '\n--- GINインデックス: 配列検索 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE tags @> ARRAY['tag5'];

\echo '\n💡 注目ポイント:'
\echo '  - Bitmap Index Scan: 複数ヒット時に使用'
\echo '  - @> 演算子: 配列包含検索'

-- JSONBへのGINインデックス
CREATE INDEX idx_users_profile ON users USING GIN(profile);

\echo '\n--- GINインデックス: JSONB検索 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE profile @> '{"verified": true}';

-- JSON内の特定キーへのインデックス
CREATE INDEX idx_users_profile_level ON users USING BTREE ((profile->>'level')::INTEGER);

\echo '\n--- JSONB内の特定値へのB-Tree ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE (profile->>'level')::INTEGER > 90;

-- ======================================
-- セクション8: BRIN インデックス (大規模テーブル)
-- ======================================

\echo '\n\n--- セクション8: BRIN インデックス ---'

-- created_atにBRINインデックス作成
CREATE INDEX idx_users_created_brin ON users USING BRIN(created_at);

-- サイズ比較
\echo '\n--- BRINインデックスのサイズ効率 ---'
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size,
    (SELECT pg_size_pretty(pg_relation_size('users'))) as table_size
FROM pg_stat_user_indexes
WHERE indexname LIKE '%created%' OR indexname LIKE '%brin%';

-- B-Treeとの比較用
CREATE INDEX idx_users_created_btree ON users USING BTREE(created_at);

SELECT
    'BRIN' as index_type,
    pg_size_pretty(pg_relation_size('idx_users_created_brin')) as size
UNION ALL
SELECT
    'B-Tree' as index_type,
    pg_size_pretty(pg_relation_size('idx_users_created_btree')) as size;

\echo '\n💡 注目ポイント:'
\echo '  - BRINは超小サイズ（ブロック範囲の要約のみ）'
\echo '  - 時系列など物理順序と論理順序が一致するデータに有効'

-- ======================================
-- セクション9: GiST インデックス (幾何データ)
-- ======================================

\echo '\n\n--- セクション9: GiST インデックス ---'

-- 座標データへのGiSTインデックス
CREATE INDEX idx_users_location ON users USING GIST(location);

\echo '\n--- GiSTインデックス: 範囲検索 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users
WHERE location <@ box '((0,0),(10,10))';

\echo '\n💡 注目ポイント:'
\echo '  - GiSTは幾何データ、範囲型などに使用'
\echo '  - <@ 演算子: ボックス内包含判定'

-- ======================================
-- セクション10: Hash インデックス
-- ======================================

\echo '\n\n--- セクション10: Hash インデックス ---'

-- Hashインデックス作成
CREATE INDEX idx_users_username_hash ON users USING HASH(username);

\echo '\n--- Hashインデックス: 等値検索のみ ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE username = 'user_50000';

\echo '\n--- 範囲検索では使用されない ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE username > 'user_5';

\echo '\n💡 注目ポイント:'
\echo '  - Hashは等値検索のみ（=）'
\echo '  - 範囲検索、ソートには使用不可'
\echo '  - PostgreSQL 10+でWAL対応により実用的に'

-- ======================================
-- セクション11: インデックスの内部構造確認
-- ======================================

\echo '\n\n--- セクション11: インデックス内部構造 ---'

-- pgstattuple拡張でB-Tree構造確認
SELECT
    'Table' as type,
    tuple_count,
    tuple_percent,
    dead_tuple_count,
    dead_tuple_percent,
    pg_size_pretty(table_len) as size
FROM pgstattuple('users')
UNION ALL
SELECT
    'Index: ' || 'idx_users_email',
    tuple_count,
    tuple_percent,
    dead_tuple_count,
    dead_tuple_percent,
    pg_size_pretty(table_len)
FROM pgstattuple('idx_users_email');

-- B-Treeメタページ情報
SELECT
    'idx_users_email' as index_name,
    version,
    level as tree_depth,
    fastroot as root_block,
    numblocks as total_blocks
FROM bt_metap('idx_users_email');

-- B-Treeページ統計
SELECT
    itemoffset,
    ctid,
    itemlen,
    left(data, 50) as data_preview
FROM bt_page_items('idx_users_email', 1)
LIMIT 10;

\echo '\n💡 B-Tree構造:'
\echo '  - level: ツリーの深さ'
\echo '  - root_block: ルートページのブロック番号'
\echo '  - 100万行でもツリー深さは3-4程度'

-- ======================================
-- セクション12: インデックス使用統計
-- ======================================

\echo '\n\n--- セクション12: インデックス使用統計 ---'

SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as index_scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE tablename = 'users'
ORDER BY idx_scan DESC;

\echo '\n💡 注目ポイント:'
\echo '  - idx_scan: インデックスがスキャンされた回数'
\echo '  - idx_scan = 0 なら不要なインデックスの可能性'

-- 未使用インデックスの検出
SELECT
    schemaname || '.' || tablename as table,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelname NOT LIKE 'pg_toast%'
ORDER BY pg_relation_size(indexrelid) DESC;

-- ======================================
-- セクション13: まとめと課題
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ B-Tree: デフォルト、範囲検索・ソート対応'
\echo '✓ Hash: 等値検索のみ、シンプル'
\echo '✓ GIN: 配列・JSONB・全文検索'
\echo '✓ GiST: 幾何・範囲型・カスタムデータ'
\echo '✓ BRIN: 超大規模テーブル、小サイズ'
\echo '✓ 複合・部分・式インデックス: 特定用途最適化'
\echo ''
\echo '💡 インデックス選択の指針:'
\echo '  1. 等値検索: B-Tree (または Hash)'
\echo '  2. 範囲検索: B-Tree'
\echo '  3. 配列包含: GIN'
\echo '  4. JSONB検索: GIN'
\echo '  5. 幾何データ: GiST'
\echo '  6. 超大規模時系列: BRIN'
\echo ''
\echo '📝 課題:'
\echo '  1. ageカラムに適切なインデックスを作成'
\echo '  2. "active かつ age > 30" 専用の部分インデックス作成'
\echo '  3. それぞれのインデックスサイズを比較'
\echo '  4. EXPLAIN ANALYZEで効果を確認'
\echo '========================================'

-- クリーンアップ用コマンド（コメントアウト）
-- DROP TABLE IF EXISTS users CASCADE;
