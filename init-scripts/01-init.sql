-- PostgreSQL ハンズオン用初期化スクリプト

-- 拡張機能のインストール
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 統計情報表示用の便利ビュー作成
CREATE OR REPLACE VIEW current_activity AS
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    query_start,
    state_change,
    LEFT(query, 100) as query_preview
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
ORDER BY query_start DESC;

-- バッファキャッシュ統計用ビュー
CREATE OR REPLACE VIEW buffer_cache_stats AS
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
    round(100.0 * pg_total_relation_size(schemaname||'.'||tablename) /
          pg_database_size(current_database()), 2) as percent_of_db
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- インデックス使用統計用ビュー
CREATE OR REPLACE VIEW index_usage_stats AS
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as index_scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
ORDER BY idx_scan DESC;

-- テーブルサイズとデッドタプル統計
CREATE OR REPLACE VIEW table_bloat_stats AS
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_tuple_percent,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

\echo '==================================='
\echo 'PostgreSQL ハンズオン環境 初期化完了'
\echo '==================================='
\echo '拡張機能:'
\echo '  - pg_stat_statements'
\echo '  - pgstattuple'
\echo '  - pg_trgm'
\echo '  - btree_gin'
\echo '  - btree_gist'
\echo ''
\echo '便利ビュー:'
\echo '  - current_activity'
\echo '  - buffer_cache_stats'
\echo '  - index_usage_stats'
\echo '  - table_bloat_stats'
\echo '==================================='
