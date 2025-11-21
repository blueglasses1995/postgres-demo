-- ======================================================================
-- ハンズオン05: WAL (Write-Ahead Log) とチェックポイント
-- ======================================================================
-- 目的: PostgreSQLのWAL機構とクラッシュリカバリの仕組みを理解する
-- 所要時間: 35分
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン05: WAL とチェックポイント'
\echo '========================================'

-- ======================================
-- セクション1: WAL設定の確認
-- ======================================

\echo '\n--- セクション1: WAL設定 ---'

SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN (
    'wal_level',
    'fsync',
    'synchronous_commit',
    'wal_buffers',
    'wal_writer_delay',
    'checkpoint_timeout',
    'checkpoint_completion_target',
    'max_wal_size',
    'min_wal_size',
    'wal_compression',
    'full_page_writes'
)
ORDER BY name;

\echo '\n💡 重要パラメータ:'
\echo '  - wal_level: WAL詳細度 (minimal/replica/logical)'
\echo '  - fsync: ディスク同期 (必ずON)'
\echo '  - synchronous_commit: コミット時のWAL同期'
\echo '  - full_page_writes: ページ全体の書き込み（torn page対策）'

-- ======================================
-- セクション2: 現在のWAL状態
-- ======================================

\echo '\n\n--- セクション2: WAL状態の確認 ---'

-- 現在のWAL位置
SELECT
    pg_current_wal_lsn() as current_lsn,
    pg_walfile_name(pg_current_wal_lsn()) as current_wal_file;

\echo '\n💡 LSN (Log Sequence Number):'
\echo '  - WAL内の位置を示す64bitの値'
\echo '  - 形式: XXX/YYYYYYYY (ファイル番号/オフセット)'

-- WAL統計情報
SELECT
    wal_records,
    wal_fpi as full_page_images,
    wal_bytes,
    pg_size_pretty(wal_bytes) as wal_size,
    wal_buffers_full,
    stats_reset
FROM pg_stat_wal;

\echo '\n💡 WAL統計:'
\echo '  - wal_records: 書き込まれたWALレコード数'
\echo '  - full_page_images: フルページイメージ数'
\echo '  - wal_buffers_full: WALバッファが満杯になった回数'

-- ======================================
-- セクション3: WALレコードの生成観察
-- ======================================

\echo '\n\n--- セクション3: WAL生成の観察 ---'

-- 初期LSN記録
SELECT pg_current_wal_lsn() as lsn_before
\gset

-- テストテーブル作成
DROP TABLE IF EXISTS wal_test;
CREATE TABLE wal_test (
    id SERIAL PRIMARY KEY,
    data TEXT
);

-- 大量データ挿入
INSERT INTO wal_test (data)
SELECT 'test data ' || i
FROM generate_series(1, 10000) i;

-- 終了LSN記録
SELECT pg_current_wal_lsn() as lsn_after
\gset

-- 生成されたWAL量計算
SELECT
    :'lsn_before' as before_lsn,
    :'lsn_after' as after_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(:'lsn_after', :'lsn_before')
    ) as wal_generated;

\echo '\n💡 注目ポイント:'
\echo '  - INSERTでWALレコードが生成される'
\echo '  - pg_wal_lsn_diff()でLSN間のバイト数を計算'

-- ======================================
-- セクション4: WALファイルの確認
-- ======================================

\echo '\n\n--- セクション4: WALファイル ---'

\echo '
--- コンテナ内でWALディレクトリ確認 ---
$ docker exec -it postgres-demo ls -lh /var/lib/postgresql/data/pg_wal/

WALファイル命名規則:
  000000010000000000000001
  ^^^^^^^^ ^^^^^^^^ ^^^^^^^^
  Timeline LogFile  Segment
  ID       ID       Number

各WALファイルは16MB固定サイズ
'

-- pg_ls_waldir()でWALファイル一覧
SELECT
    name,
    size,
    pg_size_pretty(size) as size_pretty,
    modification
FROM pg_ls_waldir()
ORDER BY name DESC
LIMIT 10;

\echo '\n現在のWALファイル数:'
SELECT COUNT(*) as wal_file_count FROM pg_ls_waldir();

-- ======================================
-- セクション5: チェックポイントの仕組み
-- ======================================

\echo '\n\n--- セクション5: チェックポイント ---'

-- 最後のチェックポイント情報
SELECT
    checkpoint_lsn,
    redo_lsn,
    timeline_id,
    checkpoint_time
FROM pg_control_checkpoint();

\echo '\n💡 チェックポイント情報:'
\echo '  - checkpoint_lsn: チェックポイントのWAL位置'
\echo '  - redo_lsn: リカバリ開始位置'
\echo '  - checkpoint_time: 最後のチェックポイント時刻'

-- BGWriterとCheckpointer統計
SELECT
    checkpoints_timed as scheduled_checkpoints,
    checkpoints_req as requested_checkpoints,
    checkpoint_write_time as write_time_ms,
    checkpoint_sync_time as sync_time_ms,
    buffers_checkpoint,
    buffers_clean,
    buffers_backend,
    buffers_alloc,
    stats_reset
FROM pg_stat_bgwriter;

\echo '\n💡 チェックポイント統計:'
\echo '  - checkpoints_timed: スケジュール（時間）によるCP'
\echo '  - checkpoints_req: 要求（max_wal_size到達等）によるCP'
\echo '  - buffers_checkpoint: CPで書き込まれたバッファ数'

-- 手動チェックポイント実行
\echo '\n--- 手動チェックポイント実行 ---'
\timing on
CHECKPOINT;
\timing off

\echo '✓ チェックポイント完了'

-- チェックポイント後の状態
SELECT
    checkpoint_lsn,
    checkpoint_time
FROM pg_control_checkpoint();

-- ======================================
-- セクション6: ダーティバッファの確認
-- ======================================

\echo '\n\n--- セクション6: ダーティバッファ ---'

-- 大量更新でダーティバッファ生成
UPDATE wal_test SET data = 'updated ' || id WHERE id <= 5000;

-- バッファ統計
SELECT
    buffers_clean as bgwriter_cleaned,
    buffers_backend as backend_writes,
    buffers_backend_fsync as backend_fsync,
    maxwritten_clean as bgwriter_stopped
FROM pg_stat_bgwriter;

\echo '\n💡 バッファ統計:'
\echo '  - buffers_clean: Background Writerが書き込んだバッファ'
\echo '  - buffers_backend: バックエンドが直接書き込んだバッファ'
\echo '  - maxwritten_clean: BGWriterが制限により停止した回数'

-- ======================================
-- セクション7: Full Page Writes
-- ======================================

\echo '\n\n--- セクション7: Full Page Writes ---'

-- チェックポイント実行
CHECKPOINT;

-- チェックポイント直後のWAL統計
SELECT wal_fpi as full_page_images_before
FROM pg_stat_wal
\gset

-- 更新実行（チェックポイント後の初回更新）
UPDATE wal_test SET data = 'fpw test' WHERE id = 1;

-- FPI増加確認
SELECT
    :full_page_images_before as fpi_before,
    wal_fpi as fpi_after,
    wal_fpi - :full_page_images_before as fpi_increase
FROM pg_stat_wal;

\echo '\n💡 Full Page Writes:'
\echo '  - チェックポイント後の初回ページ変更'
\echo '  - ページ全体（8KB）をWALに記録'
\echo '  - torn page問題への対策'
\echo '  - full_page_writes = off で無効化可能（非推奨）'

-- ======================================
-- セクション8: WALアーカイビング設定
-- ======================================

\echo '\n\n--- セクション8: WALアーカイビング ---'

-- アーカイブ設定確認
SELECT name, setting
FROM pg_settings
WHERE name IN (
    'archive_mode',
    'archive_command',
    'archive_timeout'
);

-- アーカイブ統計
SELECT
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time
FROM pg_stat_archiver;

\echo '\n💡 WALアーカイビング:'
\echo '  - PITR (Point-In-Time Recovery) に必要'
\echo '  - archive_command でWALファイルを外部保存'
\echo '  - ストリーミングレプリケーションでも使用'

-- ======================================
-- セクション9: WALレベルと論理レプリケーション
-- ======================================

\echo '\n\n--- セクション9: WALレベルの違い ---'

SHOW wal_level;

\echo '\nWALレベル:'
\echo '  - minimal: クラッシュリカバリのみ'
\echo '  - replica: 物理レプリケーション対応（デフォルト）'
\echo '  - logical: 論理レプリケーション対応'

-- 論理デコーディングスロット（wal_level=logicalの場合）
SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    restart_lsn,
    confirmed_flush_lsn
FROM pg_replication_slots;

-- ======================================
-- セクション10: WAL送信統計（レプリケーション）
-- ======================================

\echo '\n\n--- セクション10: WALレプリケーション状態 ---'

SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sync_state
FROM pg_stat_replication;

\echo '\n💡 レプリケーション状態:'
\echo '  - sent_lsn: プライマリから送信済み'
\echo '  - write_lsn: スタンバイに書き込み済み'
\echo '  - flush_lsn: スタンバイでディスク同期済み'
\echo '  - replay_lsn: スタンバイで適用済み'

-- ======================================
-- セクション11: クラッシュリカバリのシミュレーション
-- ======================================

\echo '\n\n--- セクション11: クラッシュリカバリ ---'

\echo '
【クラッシュリカバリ実験】
※注意: この実験はPostgreSQLを強制終了します

1. 現在のLSN記録:
'
SELECT pg_current_wal_lsn() as lsn_before_crash;

\echo '
2. 大量データ挿入:
'
DROP TABLE IF EXISTS crash_test;
CREATE TABLE crash_test (id SERIAL, data TEXT);
INSERT INTO crash_test (data) SELECT md5(random()::TEXT) FROM generate_series(1, 100000);

\echo '
3. コンテナ強制再起動:
$ docker restart postgres-demo

4. 再接続後、リカバリログ確認:
$ docker logs postgres-demo | grep -A 10 "database system was interrupted"

5. データ確認（リカバリされているはず）:
SELECT COUNT(*) FROM crash_test;

💡 リカバリプロセス:
  1. pg_controlから最後のチェックポイント位置取得
  2. チェックポイント以降のWALレコードを再生（REDO）
  3. コミット済みトランザクションを復元
  4. 未完了トランザクションは破棄（UNDO不要）
'

-- ======================================
-- セクション12: WAL書き込み性能の測定
-- ======================================

\echo '\n\n--- セクション12: WAL書き込み性能 ---'

-- synchronous_commit の影響測定
\echo '\n--- synchronous_commit = ON ---'
SET synchronous_commit = on;
SELECT pg_current_wal_lsn() \gset lsn1

\timing on
INSERT INTO wal_test (data) SELECT 'sync on' FROM generate_series(1, 1000);
\timing off

SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'lsn1')) as wal_size;

\echo '\n--- synchronous_commit = OFF ---'
SET synchronous_commit = off;
SELECT pg_current_wal_lsn() \gset lsn2

\timing on
INSERT INTO wal_test (data) SELECT 'sync off' FROM generate_series(1, 1000);
\timing off

SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), :'lsn2')) as wal_size;

\echo '\n💡 synchronous_commit = off:'
\echo '  - コミット時にWALディスク同期を待たない'
\echo '  - 大幅な性能向上'
\echo '  - クラッシュ時に最大数秒のデータ損失リスク'
\echo '  - トランザクション持続性は保証される'

-- デフォルトに戻す
SET synchronous_commit = on;

-- ======================================
-- セクション13: WALファイルのローテーション
-- ======================================

\echo '\n\n--- セクション13: WALローテーション ---'

-- 現在のWALファイル数
SELECT COUNT(*) as wal_file_count FROM pg_ls_waldir();

-- チェックポイントでWALファイルリサイクル
CHECKPOINT;

-- チェックポイント後のWALファイル数
SELECT COUNT(*) as wal_file_count_after FROM pg_ls_waldir();

\echo '\n💡 WALファイル管理:'
\echo '  - max_wal_size到達でチェックポイント'
\echo '  - 古いWALファイルはリサイクル（削除ではなく再利用）'
\echo '  - min_wal_size分は保持'
\echo '  - アーカイブ有効時は archive_command 成功後に削除'

-- WAL使用量サマリ
SELECT
    pg_size_pretty(SUM(size)) as total_wal_size,
    COUNT(*) as file_count,
    pg_size_pretty(AVG(size)) as avg_file_size
FROM pg_ls_waldir();

-- ======================================
-- セクション14: まとめ
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ WAL: 変更を先にログに記録（Write-Ahead）'
\echo '✓ クラッシュリカバリ: WAL再生で復旧'
\echo '✓ LSN: WAL内の位置を示す64bit値'
\echo '✓ チェックポイント:'
\echo '    - ダーティバッファをディスクに書き込み'
\echo '    - リカバリ開始位置を更新'
\echo '    - 古いWALファイルをリサイクル'
\echo '✓ Full Page Writes: torn page対策'
\echo '✓ WALレベル: minimal/replica/logical'
\echo '✓ synchronous_commit: 性能とデータ損失リスクのトレードオフ'
\echo ''
\echo '📝 課題:'
\echo '  1. 大量UPDATE前後のLSNを比較'
\echo '  2. チェックポイント前後のWALファイル数を確認'
\echo '  3. synchronous_commitのON/OFFで性能を比較'
\echo '  4. pg_stat_bgwriterで最適化の余地を確認'
\echo '========================================'

-- クリーンアップ
-- DROP TABLE IF EXISTS wal_test, crash_test CASCADE;
