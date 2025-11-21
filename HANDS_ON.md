# PostgreSQL 内部アーキテクチャ ハンズオン教材

実際にPostgreSQLを動かしながら内部動作を理解するための実践的な教材です。

## 🚀 環境構築

### 必要なもの
- Docker & Docker Compose
- 最低4GB RAM（8GB推奨）
- 10GB ディスクスペース

### セットアップ手順

```bash
# 1. リポジトリのクローン（既にクローン済みの場合はスキップ）
git clone <repository-url>
cd postgres-demo

# 2. Docker環境の起動
docker-compose up -d

# 3. PostgreSQLの起動確認
docker-compose ps

# 4. PostgreSQLに接続
docker exec -it postgres-demo psql -U postgres -d demo

# 5. pgAdmin (GUI) にアクセス（オプション）
# ブラウザで http://localhost:8080 を開く
# Email: admin@example.com
# Password: admin
```

### 接続情報

- **データベース**: localhost:5432
- **ユーザー**: postgres
- **パスワード**: postgres
- **データベース名**: demo
- **pgAdmin**: http://localhost:8080

## 📚 ハンズオン構成

### レベル1: 基礎編

| # | テーマ | 所要時間 | ファイル |
|---|--------|----------|----------|
| 1 | インデックス技術の理解 | 30分 | `hands-on/01-indexes.sql` |
| 2 | EXPLAIN ANALYZEの読み方 | 20分 | `hands-on/02-explain.sql` |
| 3 | ビューとマテリアルビュー | 25分 | `hands-on/03-views.sql` |

### レベル2: 中級編

| # | テーマ | 所要時間 | ファイル |
|---|--------|----------|----------|
| 4 | MVCCとトランザクション分離 | 40分 | `hands-on/04-mvcc.sql` |
| 5 | WALとチェックポイント | 35分 | `hands-on/05-wal.sql` |
| 6 | VACUUMとブロート管理 | 30分 | `hands-on/06-vacuum.sql` |

### レベル3: 上級編

| # | テーマ | 所要時間 | ファイル |
|---|--------|----------|----------|
| 7 | クエリ最適化とプランニング | 45分 | `hands-on/07-optimization.sql` |
| 8 | 並列クエリ | 30分 | `hands-on/08-parallel.sql` |
| 9 | パーティショニング | 40分 | `hands-on/09-partitioning.sql` |
| 10 | モニタリングと診断 | 35分 | `hands-on/10-monitoring.sql` |

## 🎯 学習の進め方

### 1. ハンズオンスクリプトの実行方法

```bash
# 方法1: psqlで直接実行
docker exec -it postgres-demo psql -U postgres -d demo -f /hands-on/01-indexes.sql

# 方法2: コンテナ内でインタラクティブに実行
docker exec -it postgres-demo psql -U postgres -d demo
demo=# \i /hands-on/01-indexes.sql

# 方法3: ホストから実行（psqlがインストール済みの場合）
psql -h localhost -U postgres -d demo -f hands-on/01-indexes.sql
```

### 2. 各ハンズオンの構成

各SQLファイルは以下の構成になっています:

```sql
-- ======================================
-- セクション1: 概要説明
-- ======================================

-- ======================================
-- セクション2: データ準備
-- ======================================

-- ======================================
-- セクション3: 実験と観察
-- ======================================

-- ======================================
-- セクション4: 内部動作の確認
-- ======================================

-- ======================================
-- セクション5: まとめと課題
-- ======================================
```

### 3. 推奨学習パス

#### 初心者向け
1. 01-indexes.sql（インデックス基礎）
2. 02-explain.sql（実行計画の読み方）
3. 03-views.sql（ビューの理解）
4. 10-monitoring.sql（基本的な監視）

#### 中級者向け
1. 04-mvcc.sql（トランザクション理解）
2. 06-vacuum.sql（メンテナンス）
3. 07-optimization.sql（最適化）
4. 09-partitioning.sql（大規模データ処理）

#### 上級者向け
1. 05-wal.sql（WAL詳細）
2. 08-parallel.sql（並列処理）
3. 全てのハンズオンを通しで実施

## 🔧 便利なコマンド集

### データベース情報確認

```sql
-- 現在のデータベースサイズ
SELECT pg_size_pretty(pg_database_size('demo'));

-- テーブル一覧とサイズ
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- インデックス一覧
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;

-- アクティブな接続確認
SELECT * FROM current_activity;

-- バッファキャッシュ統計
SELECT * FROM buffer_cache_stats;

-- インデックス使用統計
SELECT * FROM index_usage_stats;

-- テーブルブロート統計
SELECT * FROM table_bloat_stats;
```

### システムカタログ活用

```sql
-- テーブル定義確認
\d+ テーブル名

-- インデックス詳細
\di+ インデックス名

-- ビュー定義
\d+ ビュー名

-- 関数一覧
\df

-- 拡張機能一覧
\dx
```

### パフォーマンス分析

```sql
-- 遅いクエリTop 10 (pg_stat_statements)
SELECT
    substring(query, 1, 100) as query_preview,
    calls,
    round(total_exec_time::numeric, 2) as total_time_ms,
    round(mean_exec_time::numeric, 2) as avg_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) as percent
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- キャッシュヒット率
SELECT
    sum(heap_blks_read) as heap_read,
    sum(heap_blks_hit) as heap_hit,
    round(100.0 * sum(heap_blks_hit) / NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) as cache_hit_ratio
FROM pg_statio_user_tables;

-- インデックスヒット率
SELECT
    sum(idx_blks_read) as idx_read,
    sum(idx_blks_hit) as idx_hit,
    round(100.0 * sum(idx_blks_hit) / NULLIF(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2) as idx_hit_ratio
FROM pg_statio_user_indexes;
```

## 🧹 環境のリセット

```bash
# 全データをクリア（初期状態に戻す）
docker-compose down -v

# 再起動
docker-compose up -d

# 特定のデータベースだけリセット
docker exec -it postgres-demo psql -U postgres -c "DROP DATABASE IF EXISTS demo;"
docker exec -it postgres-demo psql -U postgres -c "CREATE DATABASE demo;"
docker exec -it postgres-demo psql -U postgres -d demo -f /docker-entrypoint-initdb.d/01-init.sql
```

## 📖 各ハンズオンの詳細

### 01. インデックス技術

**学習内容:**
- B-Tree, Hash, GiST, GIN, BRIN, SP-GiSTの特性
- インデックスの作成と使用状況確認
- Index Scan vs Sequential Scan
- Index Only Scan の条件
- Covering Index (INCLUDE句)
- 部分インデックス
- 式インデックス

**確認できる内部動作:**
- インデックスのページ構造
- バッファキャッシュの動作
- 統計情報の影響

### 02. EXPLAIN ANALYZE

**学習内容:**
- 実行計画の読み方
- コスト見積もりの仕組み
- 実測値と推定値の比較
- BUFFERS, TIMINGオプション
- ノードタイプの理解
- ボトルネックの特定方法

**確認できる内部動作:**
- プランナーの最適化過程
- 統計情報の利用
- コストモデル

### 03. ビューとマテリアルビュー

**学習内容:**
- ビューの書き換え（Rewrite）
- 更新可能ビュー
- マテリアルビューの実体化
- REFRESHの動作
- CONCURRENTLY オプション

**確認できる内部動作:**
- クエリ書き換えプロセス
- ストレージ使用量
- リフレッシュのロック動作

### 04. MVCC とトランザクション

**学習内容:**
- トランザクション分離レベル
- スナップショットの概念
- タプルの可視性判定
- デッドタプルの発生
- トランザクションID

**確認できる内部動作:**
- xmin/xmax の変化
- pg_xact の状態
- スナップショット情報
- ロック競合

### 05. WAL とチェックポイント

**学習内容:**
- WALの役割と構造
- チェックポイントの動作
- クラッシュリカバリ
- WALレベルの違い
- フルページライト

**確認できる内部動作:**
- WALファイルの生成
- チェックポイントのタイミング
- ダーティバッファのフラッシュ
- LSNの進行

### 06. VACUUM

**学習内容:**
- VACUUMの役割
- デッドタプルの回収
- テーブルブロート
- Freezing
- Autovacuum の動作

**確認できる内部動作:**
- FSM (Free Space Map)
- Visibility Map
- 統計情報の更新
- インデックスクリーニング

### 07. クエリ最適化

**学習内容:**
- 統計情報の重要性
- JOINアルゴリズムの選択
- サブクエリの最適化
- CTEの扱い
- パラメータチューニング

**確認できる内部動作:**
- プランナーの統計利用
- コスト計算
- プラン選択ロジック

### 08. 並列クエリ

**学習内容:**
- 並列スキャン
- 並列JOIN
- 並列集約
- Gather ノード
- ワーカープロセス

**確認できる内部動作:**
- プロセスの生成
- 並列度の決定
- データ分配

### 09. パーティショニング

**学習内容:**
- レンジパーティション
- リストパーティション
- ハッシュパーティション
- Partition Pruning
- パーティション間のデータ移動

**確認できる内部動作:**
- プランニング時の枝刈り
- パーティションルーティング
- インデックスの管理

### 10. モニタリング

**学習内容:**
- pg_stat_* ビュー群
- 待機イベント
- I/O統計
- ロック監視
- クエリ統計

**確認できる内部動作:**
- 統計コレクター
- アクティビティ追跡
- リソース使用状況

## 🎓 学習のヒント

1. **手を動かす**: 各SQLを実際に実行して結果を確認
2. **数値を観察**: EXPLAIN ANALYZEの数値変化に注目
3. **比較する**: インデックスあり/なしなど条件を変えて比較
4. **システムカタログを見る**: pg_class, pg_attribute等も確認
5. **ログを確認**: Docker logs で内部動作を追跡
   ```bash
   docker logs postgres-demo -f
   ```

## 🐛 トラブルシューティング

### コンテナが起動しない

```bash
# ログ確認
docker-compose logs postgres

# ポート競合確認
lsof -i :5432

# 完全クリーンアップ
docker-compose down -v
docker system prune -a
```

### ディスク容量不足

```bash
# 使用量確認
docker system df

# 不要なリソース削除
docker system prune -a --volumes
```

### 接続できない

```bash
# PostgreSQL起動確認
docker exec -it postgres-demo pg_isready

# ネットワーク確認
docker network ls
docker network inspect postgres-demo_postgres-network
```

## 📚 参考資料

- [PostgreSQL公式ドキュメント](https://www.postgresql.org/docs/)
- [The Internals of PostgreSQL](https://www.interdb.jp/pg/)
- このリポジトリの `README.md`（理論編）

## 🤝 フィードバック

質問や改善提案があれば、GitHubのIssueまでお願いします。

---

**Happy Learning! 🎉**
