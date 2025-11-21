-- ======================================================================
-- ハンズオン10: モニタリングと診断
-- ======================================================================
-- 目的: PostgreSQLのモニタリングツールと診断手法を習得する
-- 所要時間: 35分
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン10: モニタリングと診断'
\echo '========================================'

-- ======================================
-- セクション1: データベース全体の状態
-- ======================================

\echo '\n--- セクション1: データベース概要 ---'

-- データベースサイズ
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) as size,
    numbackends as connections,
    xact_commit as commits,
    xact_rollback as rollbacks,
    blks_read as disk_blocks_read,
    blks_hit as cache_blocks_hit,
    round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) as cache_hit_ratio,
    tup_returned as rows_returned,
    tup_fetched as rows_fetched,
    tup_inserted as rows_inserted,
    tup_updated as rows_updated,
    tup_deleted as rows_deleted
FROM pg_stat_database
WHERE datname = current_database();

\echo '\n💡 重要指標:'
\echo '  - cache_hit_ratio: 95%以上が理想'
\echo '  - rollbacks: 多いとアプリケーション問題の可能性'

-- ======================================
-- セクション2: テーブル統計
-- ======================================

\echo '\n\n--- セクション2: テーブル統計 ---'

-- テーブルサイズとアクセス統計
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
    seq_scan as sequential_scans,
    seq_tup_read as seq_rows_read,
    idx_scan as index_scans,
    idx_tup_fetch as index_rows_fetched,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    n_live_tup as live_rows,
    n_dead_tup as dead_rows,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;

\echo '\n💡 注目ポイント:'
\echo '  - seq_scan が多い → インデックス不足の可能性'
\echo '  - dead_pct > 20% → VACUUM必要'
\echo '  - last_vacuum が古い → autovacuum調整必要'

-- テーブルブロート検出
SELECT
    schemaname,
    tablename,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    CASE
        WHEN n_dead_tup > n_live_tup * 0.2 THEN '⚠️ HIGH'
        WHEN n_dead_tup > n_live_tup * 0.1 THEN '⚡ MEDIUM'
        ELSE '✓ OK'
    END as bloat_status
FROM pg_stat_user_tables
WHERE n_live_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 10;

-- ======================================
-- セクション3: インデックス統計
-- ======================================

\echo '\n\n--- セクション3: インデックス統計 ---'

-- インデックス使用状況
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC
LIMIT 20;

-- 未使用インデックス検出
\echo '\n--- 未使用インデックス（削除候補） ---'
SELECT
    schemaname || '.' || tablename as table,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size,
    idx_scan as scans
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND indexrelname NOT LIKE '%pkey'  -- PRIMARY KEY除外
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '\n💡 未使用インデックス:'
\echo '  - idx_scan = 0 なら削除検討'
\echo '  - ただし、PRIMARY KEYは除外'
\echo '  - 夜間バッチで使う可能性も考慮'

-- 重複インデックス検出
\echo '\n--- 重複インデックス ---'
SELECT
    pg_size_pretty(SUM(pg_relation_size(idx))::BIGINT) as total_size,
    (array_agg(idx))[1] as idx1,
    (array_agg(idx))[2] as idx2
FROM (
    SELECT
        indexrelid::regclass as idx,
        (indrelid::text ||E'\n'|| indclass::text ||E'\n'|| indkey::text ||E'\n'||
         COALESCE(indexprs::text,'')||E'\n'||COALESCE(indpred::text,'')) as key
    FROM pg_index
) sub
GROUP BY key
HAVING COUNT(*) > 1
ORDER BY SUM(pg_relation_size(idx)) DESC;

-- ======================================
-- セクション4: アクティビティ監視
-- ======================================

\echo '\n\n--- セクション4: アクティブセッション ---'

-- 現在実行中のクエリ
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    query_start,
    NOW() - query_start as duration,
    LEFT(query, 100) as query_preview
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY query_start;

\echo '\n💡 状態の意味:'
\echo '  - active: 実行中'
\echo '  - idle in transaction: トランザクション内で待機（要注意）'
\echo '  - wait_event: 待機理由（Lock, IO等）'

-- 長時間実行クエリ
\echo '\n--- 長時間実行クエリ（1分以上） ---'
SELECT
    pid,
    usename,
    NOW() - query_start as duration,
    state,
    LEFT(query, 150) as query
FROM pg_stat_activity
WHERE state = 'active'
  AND NOW() - query_start > INTERVAL '1 minute'
  AND pid != pg_backend_pid()
ORDER BY query_start;

-- アイドルトランザクション
\echo '\n--- アイドルトランザクション（要注意） ---'
SELECT
    pid,
    usename,
    NOW() - xact_start as transaction_duration,
    NOW() - state_change as idle_duration,
    LEFT(query, 100) as last_query
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%'
  AND NOW() - state_change > INTERVAL '5 minutes'
ORDER BY xact_start;

\echo '\n💡 アイドルトランザクション:'
\echo '  - ロックを保持し続ける'
\echo '  - VACUUMをブロック'
\echo '  - idle_in_transaction_session_timeout で自動切断可能'

-- ======================================
-- セクション5: ロック監視
-- ======================================

\echo '\n\n--- セクション5: ロック状況 ---'

-- ロック待ちクエリ
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocking.pid AS blocking_pid,
    blocking.usename AS blocking_user,
    blocked.query AS blocked_query,
    blocking.query AS blocking_query,
    blocking.wait_event_type || ':' || blocking.wait_event AS blocking_wait
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.pid != pg_backend_pid();

\echo '\n💡 ロック待ち:'
\echo '  - blocked_pid: 待たされているプロセス'
\echo '  - blocking_pid: ブロックしているプロセス'
\echo '  - 長時間ブロックは調査必要'

-- テーブルロック一覧
SELECT
    locktype,
    relation::regclass,
    mode,
    granted,
    pid
FROM pg_locks
WHERE relation IS NOT NULL
ORDER BY relation, mode;

-- ======================================
-- セクション6: クエリ統計 (pg_stat_statements)
-- ======================================

\echo '\n\n--- セクション6: クエリ統計 ---'

-- pg_stat_statementsがなければ作成
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 統計リセット（学習用）
SELECT pg_stat_statements_reset();

-- サンプルクエリ実行
DROP TABLE IF EXISTS test_monitoring;
CREATE TABLE test_monitoring AS
SELECT i, md5(random()::TEXT) as data
FROM generate_series(1, 10000) i;

SELECT COUNT(*) FROM test_monitoring WHERE i < 5000;
SELECT AVG(i) FROM test_monitoring;

-- 実行時間Top10
\echo '\n--- 実行時間が長いクエリ Top 10 ---'
SELECT
    LEFT(query, 100) as query_preview,
    calls,
    round(total_exec_time::NUMERIC, 2) as total_time_ms,
    round(mean_exec_time::NUMERIC, 2) as avg_time_ms,
    round(min_exec_time::NUMERIC, 2) as min_time_ms,
    round(max_exec_time::NUMERIC, 2) as max_time_ms,
    round(stddev_exec_time::NUMERIC, 2) as stddev_ms,
    rows
FROM pg_stat_statements
WHERE userid = (SELECT usesysid FROM pg_user WHERE usename = current_user)
ORDER BY total_exec_time DESC
LIMIT 10;

-- I/Oが多いクエリ
\echo '\n--- I/Oが多いクエリ ---'
SELECT
    LEFT(query, 100) as query_preview,
    calls,
    shared_blks_read + shared_blks_written as total_io_blocks,
    shared_blks_hit as cache_hits,
    round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 2) as cache_hit_pct
FROM pg_stat_statements
WHERE userid = (SELECT usesysid FROM pg_user WHERE usename = current_user)
  AND (shared_blks_read + shared_blks_written) > 0
ORDER BY (shared_blks_read + shared_blks_written) DESC
LIMIT 10;

-- ======================================
-- セクション7: I/O統計
-- ======================================

\echo '\n\n--- セクション7: I/O統計 ---'

-- テーブルI/O統計
SELECT
    schemaname,
    tablename,
    heap_blks_read as heap_disk_reads,
    heap_blks_hit as heap_cache_hits,
    round(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) as heap_hit_pct,
    idx_blks_read as index_disk_reads,
    idx_blks_hit as index_cache_hits,
    round(100.0 * idx_blks_hit / NULLIF(idx_blks_hit + idx_blks_read, 0), 2) as index_hit_pct
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 0
ORDER BY heap_blks_read + heap_blks_hit DESC
LIMIT 10;

-- WAL I/O統計
SELECT
    wal_records,
    wal_fpi as full_page_images,
    pg_size_pretty(wal_bytes) as wal_size,
    wal_buffers_full,
    wal_write,
    wal_sync,
    round(wal_write_time::NUMERIC, 2) as wal_write_time_ms,
    round(wal_sync_time::NUMERIC, 2) as wal_sync_time_ms
FROM pg_stat_wal;

-- ======================================
-- セクション8: バックグラウンドプロセス統計
-- ======================================

\echo '\n\n--- セクション8: BGWriter & Checkpointer ---'

SELECT
    checkpoints_timed as scheduled_checkpoints,
    checkpoints_req as requested_checkpoints,
    round(checkpoint_write_time::NUMERIC, 2) as checkpoint_write_ms,
    round(checkpoint_sync_time::NUMERIC, 2) as checkpoint_sync_ms,
    buffers_checkpoint,
    buffers_clean as bgwriter_buffers,
    buffers_backend as backend_writes,
    buffers_backend_fsync as backend_fsync,
    buffers_alloc as allocated_buffers,
    maxwritten_clean as bgwriter_stops
FROM pg_stat_bgwriter;

\echo '\n💡 BGWriter統計:'
\echo '  - checkpoints_req が多い → max_wal_size 増加検討'
\echo '  - buffers_backend_fsync > 0 → shared_buffers 不足'
\echo '  - maxwritten_clean が多い → bgwriter_lru_maxpages 増加'

-- ======================================
-- セクション9: Autovacuum統計
-- ======================================

\echo '\n\n--- セクション9: Autovacuum 活動 ---'

-- Autovacuum実行履歴（PostgreSQL 16+）
SELECT
    relid::regclass as table,
    last_autovacuum,
    autovacuum_count,
    last_autoanalyze,
    autoanalyze_count
FROM pg_stat_user_tables
WHERE last_autovacuum IS NOT NULL
   OR last_autoanalyze IS NOT NULL
ORDER BY last_autovacuum DESC NULLS LAST
LIMIT 10;

-- VACUUMが必要なテーブル
\echo '\n--- VACUUM推奨テーブル ---'
SELECT
    schemaname || '.' || tablename as table,
    n_live_tup as live,
    n_dead_tup as dead,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup, 0), 2) as dead_pct,
    last_autovacuum,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
  AND n_dead_tup::FLOAT / NULLIF(n_live_tup, 0) > 0.1
ORDER BY n_dead_tup DESC;

-- ======================================
-- セクション10: レプリケーション統計
-- ======================================

\echo '\n\n--- セクション10: レプリケーション状態 ---'

-- レプリケーションスロット
SELECT
    slot_name,
    slot_type,
    database,
    active,
    restart_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) as replication_lag_size
FROM pg_replication_slots;

-- WAL送信状態
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    sync_state,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)
    ) as send_lag,
    pg_size_pretty(
        pg_wal_lsn_diff(sent_lsn, flush_lsn)
    ) as flush_lag,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- ======================================
-- セクション11: システムリソース
-- ======================================

\echo '\n\n--- セクション11: システムリソース ---'

-- 接続数
SELECT
    COUNT(*) as total_connections,
    COUNT(*) FILTER (WHERE state = 'active') as active,
    COUNT(*) FILTER (WHERE state = 'idle') as idle,
    COUNT(*) FILTER (WHERE state LIKE 'idle in transaction%') as idle_in_txn,
    (SELECT setting::INTEGER FROM pg_settings WHERE name = 'max_connections') as max_connections
FROM pg_stat_activity;

-- メモリ設定
SELECT
    name,
    setting,
    unit,
    CASE
        WHEN unit = '8kB' THEN pg_size_pretty((setting::BIGINT * 8 * 1024)::BIGINT)
        WHEN unit = 'kB' THEN pg_size_pretty((setting::BIGINT * 1024)::BIGINT)
        ELSE setting || ' ' || COALESCE(unit, '')
    END as readable_value
FROM pg_settings
WHERE name IN (
    'shared_buffers',
    'effective_cache_size',
    'work_mem',
    'maintenance_work_mem',
    'wal_buffers',
    'max_wal_size'
)
ORDER BY name;

-- ======================================
-- セクション12: まとめと監視ベストプラクティス
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ 定期監視項目:'
\echo '  1. cache_hit_ratio: 95%以上維持'
\echo '  2. dead tuple 比率: 20%未満'
\echo '  3. 未使用インデックス: 定期削除'
\echo '  4. 長時間クエリ: 最適化'
\echo '  5. アイドルトランザクション: 調査・切断'
\echo '  6. ロック競合: ボトルネック解消'
\echo ''
\echo '✓ 重要な統計ビュー:'
\echo '  - pg_stat_database: DB全体統計'
\echo '  - pg_stat_user_tables: テーブル統計'
\echo '  - pg_stat_user_indexes: インデックス統計'
\echo '  - pg_stat_activity: アクティブセッション'
\echo '  - pg_stat_statements: クエリ統計'
\echo '  - pg_stat_bgwriter: バックグラウンド処理'
\echo ''
\echo '✓ アラート設定推奨:'
\echo '  - cache_hit_ratio < 90%'
\echo '  - replication_lag > 10MB'
\echo '  - connections > max_connections * 0.8'
\echo '  - long_running_query > 5 minutes'
\echo '  - idle_in_transaction > 10 minutes'
\echo ''
\echo '📝 実践課題:'
\echo '  1. 定期監視スクリプト作成'
\echo '  2. 未使用インデックス検出・削除'
\echo '  3. 遅いクエリをpg_stat_statementsから特定'
\echo '  4. VACUUM推奨テーブルをチェック'
\echo '========================================'

\echo '\n\n✅ 全てのハンズオン完了おめでとうございます！'
\echo 'PostgreSQLの内部動作を理解し、実践的なスキルを習得しました。'

-- クリーンアップ
-- DROP TABLE IF EXISTS test_monitoring CASCADE;
