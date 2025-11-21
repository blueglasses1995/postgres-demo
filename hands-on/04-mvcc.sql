-- ======================================================================
-- ハンズオン04: MVCC とトランザクション分離
-- ======================================================================
-- 目的: PostgreSQLのMVCC実装とトランザクション分離レベルを理解する
-- 所要時間: 40分
-- 注意: 一部の実験では2つのセッションが必要です
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン04: MVCC とトランザクション'
\echo '========================================'

-- ======================================
-- セクション1: データ準備
-- ======================================

\echo '\n--- セクション1: サンプルデータ作成 ---'

DROP TABLE IF EXISTS accounts CASCADE;
CREATE TABLE accounts (
    id SERIAL PRIMARY KEY,
    account_number VARCHAR(20) UNIQUE NOT NULL,
    balance DECIMAL(15, 2) NOT NULL,
    last_updated TIMESTAMP DEFAULT NOW()
);

INSERT INTO accounts (account_number, balance) VALUES
    ('ACC001', 1000.00),
    ('ACC002', 2000.00),
    ('ACC003', 1500.00);

\echo '✓ アカウントテーブル作成完了'

-- ======================================
-- セクション2: タプルの内部構造確認
-- ======================================

\echo '\n\n--- セクション2: タプルの内部構造 ---'

-- pageinspect拡張を使用
CREATE EXTENSION IF NOT EXISTS pageinspect;

\echo '\n--- ヒープページの構造 ---'

-- ページ番号0の内容確認
SELECT
    lp as line_pointer,
    lp_off as offset,
    lp_len as length,
    t_xmin,
    t_xmax,
    t_field3 as t_cid,
    t_ctid
FROM heap_page_items(get_raw_page('accounts', 0));

\echo '\n💡 注目ポイント:'
\echo '  - t_xmin: このタプルを作成したトランザクションID'
\echo '  - t_xmax: このタプルを削除/更新したトランザクションID (0なら未削除)'
\echo '  - t_ctid: このタプルの物理位置 (page, offset)'
\echo '  - 更新時は新バージョンへのポインタになる'

-- 現在のトランザクションID確認
SELECT txid_current() as current_xid;

-- ======================================
-- セクション3: UPDATEによるタプルバージョン
-- ======================================

\echo '\n\n--- セクション3: UPDATE とタプルバージョン ---'

-- 更新前のタプル状態
\echo '\n--- 更新前 ---'
SELECT * FROM accounts WHERE id = 1;

SELECT
    lp,
    t_xmin,
    t_xmax,
    t_ctid,
    t_data
FROM heap_page_items(get_raw_page('accounts', 0))
WHERE lp = 1;

-- トランザクション開始
BEGIN;
SELECT txid_current() as xid_before_update;

-- 更新実行
UPDATE accounts SET balance = balance + 100 WHERE id = 1;

SELECT txid_current() as xid_after_update;

\echo '\n--- 更新後（同一トランザクション内） ---'
SELECT * FROM accounts WHERE id = 1;

-- ページ内容確認
SELECT
    lp,
    t_xmin,
    t_xmax,
    t_ctid,
    SUBSTRING(t_data::TEXT, 1, 50) as data_preview
FROM heap_page_items(get_raw_page('accounts', 0))
ORDER BY lp;

\echo '\n💡 注目ポイント:'
\echo '  - 古いタプル: t_xmax が現在のXIDに設定される'
\echo '  - 新しいタプル: 別のline pointerに作成される'
\echo '  - 古いタプルの t_ctid が新タプルを指す'

COMMIT;

-- コミット後の状態
\echo '\n--- COMMIT後 ---'
SELECT
    lp,
    t_xmin,
    t_xmax,
    t_ctid
FROM heap_page_items(get_raw_page('accounts', 0))
ORDER BY lp;

-- ======================================
-- セクション4: トランザクション分離レベル
-- ======================================

\echo '\n\n--- セクション4: トランザクション分離レベル ---'

\echo '\n現在のデフォルト分離レベル:'
SHOW default_transaction_isolation;

\echo '\n--- READ COMMITTED (デフォルト) ---'
\echo '
【2セッション実験】
この実験には2つのpsqlセッションが必要です。

ターミナル1:
  docker exec -it postgres-demo psql -U postgres -d demo

ターミナル2:
  docker exec -it postgres-demo psql -U postgres -d demo

--- ターミナル1 ---
BEGIN;
SELECT balance FROM accounts WHERE id = 1;
-- ここで待機

--- ターミナル2 ---
BEGIN;
UPDATE accounts SET balance = 5000 WHERE id = 1;
COMMIT;

--- ターミナル1に戻る ---
SELECT balance FROM accounts WHERE id = 1;  -- 新しい値が見える（Non-Repeatable Read）
COMMIT;
'

-- ======================================
-- セクション5: REPEATABLE READ 分離レベル
-- ======================================

\echo '\n--- REPEATABLE READ 分離レベル ---'

\echo '
【2セッション実験】

--- ターミナル1 ---
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT txid_current_snapshot();  -- スナップショット確認
SELECT balance FROM accounts WHERE id = 1;
-- ここで待機

--- ターミナル2 ---
BEGIN;
UPDATE accounts SET balance = 6000 WHERE id = 1;
COMMIT;

--- ターミナル1に戻る ---
SELECT balance FROM accounts WHERE id = 1;  -- 古い値のまま（スナップショット分離）
SELECT txid_current_snapshot();  -- スナップショットは変わらない
COMMIT;

-- 確認
SELECT balance FROM accounts WHERE id = 1;  -- 新しい値が見える
'

-- スナップショットの仕組み
\echo '\n--- スナップショットの理解 ---'

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- スナップショット情報取得
SELECT
    txid_current() as my_xid,
    txid_current_snapshot() as snapshot;

\echo '\n💡 スナップショット形式: xmin:xmax:xip_list'
\echo '  - xmin: 最小アクティブXID（これより小さいXIDは完了済み）'
\echo '  - xmax: 次に割り当てられるXID'
\echo '  - xip_list: 実行中のXIDリスト'

COMMIT;

-- ======================================
-- セクション6: トランザクション状態の確認
-- ======================================

\echo '\n\n--- セクション6: トランザクション状態 (pg_xact) ---'

-- アクティブなトランザクション確認
SELECT
    pid,
    usename,
    datname,
    state,
    backend_xid,
    backend_xmin,
    query_start,
    LEFT(query, 60) as query
FROM pg_stat_activity
WHERE backend_xid IS NOT NULL OR backend_xmin IS NOT NULL;

-- ======================================
-- セクション7: ロックの仕組み
-- ======================================

\echo '\n\n--- セクション7: 行レベルロック ---'

DROP TABLE IF EXISTS lock_test;
CREATE TABLE lock_test (
    id SERIAL PRIMARY KEY,
    value INTEGER
);

INSERT INTO lock_test (value) VALUES (1), (2), (3);

\echo '
【2セッション実験: 行レベルロック】

--- ターミナル1 ---
BEGIN;
SELECT * FROM lock_test WHERE id = 1 FOR UPDATE;  -- 行ロック取得
-- ここで待機（COMMITしない）

--- ターミナル2 ---
BEGIN;
SELECT * FROM lock_test WHERE id = 1 FOR UPDATE;  -- ブロックされる
-- ターミナル1がCOMMITするまで待機

SELECT * FROM lock_test WHERE id = 2 FOR UPDATE;  -- 別の行はOK

--- ロック状況確認（別ターミナル） ---
SELECT
    locktype,
    relation::regclass,
    mode,
    granted,
    pid
FROM pg_locks
WHERE relation = '\''lock_test'\''::regclass;
'

-- ======================================
-- セクション8: デッドロック
-- ======================================

\echo '\n\n--- セクション8: デッドロック検出 ---'

\echo '
【2セッション実験: デッドロック】

--- ターミナル1 ---
BEGIN;
UPDATE lock_test SET value = 10 WHERE id = 1;  -- 行1ロック
-- 少し待機
UPDATE lock_test SET value = 20 WHERE id = 2;  -- 行2をロック要求

--- ターミナル2 ---
BEGIN;
UPDATE lock_test SET value = 30 WHERE id = 2;  -- 行2ロック
-- 少し待機
UPDATE lock_test SET value = 40 WHERE id = 1;  -- 行1をロック要求 → デッドロック検出

結果: PostgreSQLがデッドロックを自動検出し、片方をアボート
'

-- デッドロック設定確認
SHOW deadlock_timeout;

-- ======================================
-- セクション9: Phantom Read と SERIALIZABLE
-- ======================================

\echo '\n\n--- セクション9: SERIALIZABLE 分離レベル ---'

DROP TABLE IF EXISTS items;
CREATE TABLE items (
    id SERIAL PRIMARY KEY,
    category VARCHAR(50),
    price DECIMAL(10, 2)
);

INSERT INTO items (category, price) VALUES
    ('A', 100),
    ('A', 200),
    ('B', 150);

\echo '
【2セッション実験: Phantom Read】

REPEATABLE READでのPhantom Read:

--- ターミナル1 ---
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT SUM(price) FROM items WHERE category = '\''A'\'';  -- 300

--- ターミナル2 ---
INSERT INTO items (category, price) VALUES ('\''A'\'', 50);

--- ターミナル1 ---
SELECT SUM(price) FROM items WHERE category = '\''A'\'';  -- まだ300 (新しい行は見えない)
COMMIT;

--------------------------------------------------

SERIALIZABLEでの直列化異常検出:

--- ターミナル1 ---
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT SUM(price) FROM items WHERE category = '\''A'\'';
-- 他の処理...
UPDATE items SET price = 500 WHERE category = '\''B'\'';

--- ターミナル2 ---
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
INSERT INTO items (category, price) VALUES ('\''A'\'', 75);
COMMIT;

--- ターミナル1 ---
COMMIT;  -- 直列化エラー発生の可能性

エラー: could not serialize access due to read/write dependencies
→ アプリケーションでリトライが必要
'

-- ======================================
-- セクション10: 可視性ルールの実験
-- ======================================

\echo '\n\n--- セクション10: タプル可視性ルール ---'

DROP TABLE IF EXISTS visibility_test;
CREATE TABLE visibility_test (
    id INTEGER PRIMARY KEY,
    value TEXT
);

-- トランザクション1: 挿入
BEGIN;
SELECT txid_current() as xid1;
INSERT INTO visibility_test VALUES (1, 'T1');
-- まだCOMMITしない

\echo '
--- 別セッションで確認 ---
SELECT * FROM visibility_test;  -- 見えない（T1未コミット）

SELECT
    t_xmin,
    t_xmax,
    txid_current() as current_xid,
    CASE
        WHEN t_xmin < txid_current() THEN '\''xmin < current'\'
        WHEN t_xmin = txid_current() THEN '\''xmin = current'\'
        ELSE '\''xmin > current'\'
    END as visibility_rule
FROM heap_page_items(get_raw_page('\''visibility_test'\'', 0));
'

COMMIT;

\echo '\n--- COMMIT後 ---'
SELECT * FROM visibility_test;  -- 見える

SELECT
    lp,
    t_xmin,
    t_xmax,
    t_infomask::BIT(16) as infomask
FROM heap_page_items(get_raw_page('visibility_test', 0));

\echo '\n💡 t_infomask ビットフラグ:'
\echo '  - HEAP_XMIN_COMMITTED: xminがコミット済み'
\echo '  - HEAP_XMAX_INVALID: xmaxが無効（削除されていない）'

-- ======================================
-- セクション11: VACUUM とデッドタプル
-- ======================================

\echo '\n\n--- セクション11: デッドタプルの発生と回収 ---'

-- 大量更新でデッドタプル生成
BEGIN;
UPDATE accounts SET balance = balance + 1;
UPDATE accounts SET balance = balance + 1;
UPDATE accounts SET balance = balance + 1;
COMMIT;

-- デッドタプル確認
SELECT
    schemaname,
    tablename,
    n_live_tup as live,
    n_dead_tup as dead,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE tablename = 'accounts';

-- ページ内のタプル状態
SELECT
    COUNT(*) as total_tuples,
    COUNT(*) FILTER (WHERE t_xmax = 0) as live_tuples,
    COUNT(*) FILTER (WHERE t_xmax != 0) as dead_tuples
FROM heap_page_items(get_raw_page('accounts', 0));

-- VACUUMによる回収
VACUUM VERBOSE accounts;

-- VACUUM後の状態
SELECT
    n_live_tup as live,
    n_dead_tup as dead
FROM pg_stat_user_tables
WHERE tablename = 'accounts';

-- ======================================
-- セクション12: トランザクションID枯渇対策
-- ======================================

\echo '\n\n--- セクション12: Transaction ID Wraparound ---'

-- 現在のトランザクションID状況
SELECT
    datname,
    age(datfrozenxid) as xid_age,
    2^31 - 1000000 as wraparound_threshold,
    CASE
        WHEN age(datfrozenxid) > 2^31 - 1000000 THEN '⚠️ WARNING'
        ELSE '✓ OK'
    END as status
FROM pg_database
WHERE datname = current_database();

\echo '\n💡 XID Wraparound対策:'
\echo '  - VACUUMがt_xminをFrozenTransactionId(2)に変換'
\echo '  - autovacuum_freeze_max_age: デフォルト2億'
\echo '  - 定期的なVACUUM FREEZEが必須'

-- テーブルごとのフリーズ状態
SELECT
    schemaname,
    tablename,
    age(relfrozenxid) as xid_age,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_stat_user_tables
ORDER BY age(relfrozenxid) DESC;

-- ======================================
-- セクション13: まとめ
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ MVCC: 各トランザクションはスナップショットを見る'
\echo '✓ タプルバージョン: UPDATE = DELETE + INSERT'
\echo '✓ t_xmin/t_xmax: タプルの可視性判定に使用'
\echo '✓ 分離レベル:'
\echo '    - READ COMMITTED: ステートメント単位のスナップショット'
\echo '    - REPEATABLE READ: トランザクション単位のスナップショット'
\echo '    - SERIALIZABLE: 直列化異常検出'
\echo '✓ デッドタプル: VACUUMで回収'
\echo '✓ XID Wraparound: VACUUM FREEZEで対策'
\echo ''
\echo '📝 課題:'
\echo '  1. 2セッションでREPEATABLE READ実験を実施'
\echo '  2. デッドロックを意図的に発生させる'
\echo '  3. t_xmin/t_xmaxの変化を観察'
\echo '  4. VACUUMによるデッドタプル回収を確認'
\echo '========================================'

-- クリーンアップ
-- DROP TABLE IF EXISTS accounts, lock_test, items, visibility_test CASCADE;
