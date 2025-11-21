# PostgreSQL 内部アーキテクチャ徹底解説

PostgreSQLデータベースサーバーとクライアントの内部動作を、低レベルの技術実装から高レベルの機能まで包括的に解説します。

## 目次

1. [PostgreSQLの全体アーキテクチャ](#1-postgresqlの全体アーキテクチャ)
2. [プロセスアーキテクチャ](#2-プロセスアーキテクチャ)
3. [メモリアーキテクチャ](#3-メモリアーキテクチャ)
4. [ストレージアーキテクチャ](#4-ストレージアーキテクチャ)
5. [クエリ処理パイプライン](#5-クエリ処理パイプライン)
6. [インデックス技術](#6-インデックス技術)
7. [ビューとマテリアルビュー](#7-ビューとマテリアルビュー)
8. [トランザクション管理とMVCC](#8-トランザクション管理とmvcc)
9. [ネットワークプロトコル](#9-ネットワークプロトコル)
10. [PostgreSQL 18の最新機能](#10-postgresql-18の最新機能)
11. [pgクライアントの内部実装](#11-pgクライアントの内部実装)

---

## 1. PostgreSQLの全体アーキテクチャ

### 1.1 アーキテクチャの概要

PostgreSQLは**マルチプロセスアーキテクチャ**を採用しています。これはスレッドベースではなく、個別のOSプロセスを使用する設計です。

```
┌─────────────────────────────────────────────────────────┐
│                    クライアント層                        │
│  (psql, pgAdmin, libpq, JDBC, ODBC, その他ドライバ)     │
└─────────────────────────────────────────────────────────┘
                          ↓ TCP/IP or Unix Socket
┌─────────────────────────────────────────────────────────┐
│              Postmaster (親プロセス)                     │
│  - 接続受付 (Port 5432)                                 │
│  - プロセス管理                                          │
│  - バックグラウンドプロセスの起動・監視                  │
└─────────────────────────────────────────────────────────┘
         ↓                    ↓                    ↓
┌──────────────┐  ┌──────────────────┐  ┌─────────────────┐
│ Backend      │  │ Background       │  │ Auxiliary       │
│ Processes    │  │ Workers          │  │ Processes       │
│ (各接続ごと) │  │ - WAL Writer     │  │ - Checkpointer  │
│              │  │ - Autovacuum     │  │ - Stats         │
│              │  │ - Logical Worker │  │ - Logger        │
└──────────────┘  └──────────────────┘  └─────────────────┘
         ↓                    ↓                    ↓
┌─────────────────────────────────────────────────────────┐
│              共有メモリ (Shared Memory)                  │
│  - Shared Buffers                                       │
│  - WAL Buffers                                          │
│  - Lock Tables                                          │
│  - Transaction State                                    │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│                   ストレージ層                           │
│  - データファイル (pg_data)                             │
│  - WAL (Write-Ahead Log)                                │
│  - インデックスファイル                                  │
│  - システムカタログ                                      │
└─────────────────────────────────────────────────────────┘
```

### 1.2 なぜマルチプロセス?

**利点:**
- **安定性**: 1つのクライアント接続がクラッシュしても他の接続に影響しない
- **移植性**: OSのプロセス管理機能を利用できる
- **セキュリティ**: プロセス間の強力な分離
- **メモリリーク対策**: 接続終了時にOSがリソースを完全に回収

**欠点:**
- プロセス作成のオーバーヘッド (→ 接続プーリングで軽減)
- コンテキストスイッチのコスト
- 共有メモリ経由でのデータ共有が必要

---

## 2. プロセスアーキテクチャ

### 2.1 Postmaster (postgres プロセス)

**役割:**
- データベースサーバーの**親プロセス**
- クライアント接続の**リスニング**と受付
- 全バックグラウンドプロセスの**起動と監視**
- シグナルハンドリング (SIGTERM, SIGHUP等)

**起動シーケンス:**
```c
// src/backend/postmaster/postmaster.c の簡略化されたフロー

1. pg_ctl start
   ↓
2. Postmasterプロセス起動
   ↓
3. 共有メモリセグメントの作成・初期化
   ↓
4. バックグラウンドプロセスの起動:
   - Startup Process (WALリカバリ)
   - Checkpointer
   - WAL Writer
   - Autovacuum Launcher
   - Stats Collector
   - Background Writer
   - Logical Replication Launcher
   ↓
5. ソケットバインド (Port 5432)
   ↓
6. accept() ループで接続待機
```

### 2.2 Backend Processes (バックエンドプロセス)

各クライアント接続ごとに**fork()**で作成される専用プロセス。

**ライフサイクル:**
```
1. クライアント接続要求
   ↓
2. Postmasterがaccept()
   ↓
3. fork()で新しいバックエンドプロセス生成
   ↓
4. 認証処理 (pg_hba.conf)
   ↓
5. クエリ実行ループ:
   while (クライアント接続中) {
       - メッセージ受信 (libpqプロトコル)
       - SQL解析・最適化・実行
       - 結果返送
   }
   ↓
6. 接続終了、プロセス終了
```

**メモリレイアウト:**
```
┌─────────────────────┐
│ プロセス固有メモリ   │
│ - work_mem          │  ← ソート、ハッシュ用
│ - maintenance_work  │  ← VACUUM, INDEX用
│ - temp_buffers      │  ← 一時テーブル用
└─────────────────────┘
        ↓ アクセス
┌─────────────────────┐
│ 共有メモリ          │
│ (全プロセスで共有)  │
└─────────────────────┘
```

### 2.3 バックグラウンドプロセス

#### 2.3.1 Checkpointer
- **役割**: ダーティページをディスクに書き込む
- **トリガー**: `checkpoint_timeout` または WAL容量
- **CPU使用**: I/O集約的、fsync()システムコール多用
- **実装**: `src/backend/postmaster/checkpointer.c`

```c
// チェックポイントの疑似コード
Checkpoint() {
    1. 全ダーティバッファをスキャン
    2. ソート (ファイル・ページ番号順)
    3. write()でディスクに書き込み
    4. fsync()で確実に永続化
    5. pg_control更新 (チェックポイント位置記録)
}
```

#### 2.3.2 WAL Writer
- **役割**: WALバッファを定期的にディスクにフラッシュ
- **周期**: `wal_writer_delay` (デフォルト200ms)
- **I/O**: シーケンシャルライト (高性能)
- **実装**: `src/backend/postmaster/walwriter.c`

#### 2.3.3 Background Writer
- **役割**: ダーティバッファを少しずつディスクに書き出す
- **目的**: チェックポイント時のI/Oバースト軽減
- **戦略**: LRU (Least Recently Used) ベース

#### 2.3.4 Autovacuum Launcher & Workers
- **役割**: 不要なタプル削除、統計情報更新
- **スケジューリング**: テーブルごとの更新頻度に基づく
- **並列度**: `autovacuum_max_workers` で制御

#### 2.3.5 Stats Collector
- **役割**: データベース統計情報の収集
- **データ**: テーブルスキャン数、インデックスヒット率等
- **通信**: UDPで統計データ受信 (低オーバーヘッド)

#### 2.3.6 Logical Replication Launcher & Workers
- **役割**: 論理レプリケーションのワーカー管理
- **実装**: WAL Senderと連携

---

## 3. メモリアーキテクチャ

### 3.1 共有メモリ (Shared Memory)

PostgreSQLは起動時に大きな共有メモリセグメントを確保します。

#### 3.1.1 Shared Buffers

**最も重要なメモリ領域**で、データページのキャッシュです。

**構造:**
```c
// src/include/storage/buf_internals.h

typedef struct BufferDesc {
    BufferTag   tag;        // ファイル・ページ識別子
    int         buf_id;     // バッファID
    uint32      flags;      // ダーティ、ピン状態等
    uint16      usage_count;// クロックスイープ用カウンタ
    LWLock      content_lock; // ページ内容保護
} BufferDesc;
```

**サイズ**: `shared_buffers` パラメータ (推奨: システムRAMの25%)

**アルゴリズム: Clock Sweep**
```
Buffer管理:
1. ページが必要
2. Shared Buffersを探す
   - ヒット → usage_count++, 使用
   - ミス → Clock Sweep で退避候補探し
3. 退避候補:
   - usage_count == 0 → 選択
   - usage_count > 0  → デクリメント、次候補へ
4. ダーティページなら書き込み
5. 新ページ読み込み
```

**メモリマッピング:**
```
共有メモリセグメント:
┌────────────────────────┐ ← 開始アドレス
│ Buffer Descriptors     │ (メタデータ配列)
├────────────────────────┤
│ Buffer Pool            │ (実データ: 8KB × N個)
├────────────────────────┤
│ Lock Tables            │
├────────────────────────┤
│ ...                    │
└────────────────────────┘
```

#### 3.1.2 WAL Buffers

**役割**: WALレコードの一時バッファ

**サイズ**: `wal_buffers` (デフォルト: shared_buffersの1/32)

**フロー:**
```
Transaction Commit:
1. WALレコード生成 (INSERT/UPDATE/DELETE内容)
2. WAL Bufferに書き込み
3. XLogInsert() → メモリコピー
4. Commit時: write() + fsync() でディスクへ
5. 成功後にクライアントへACK返送
```

#### 3.1.3 Lock Tables

**役割**: テーブル・行レベルロックの管理

**実装**: ハッシュテーブル (動的サイズ)

**ロックモード** (8種類):
```
1. AccessShareLock      - SELECT
2. RowShareLock         - SELECT FOR UPDATE
3. RowExclusiveLock     - INSERT/UPDATE/DELETE
4. ShareUpdateExclusiveLock - VACUUM
5. ShareLock            - CREATE INDEX
6. ShareRowExclusiveLock
7. ExclusiveLock        - LOCK TABLE
8. AccessExclusiveLock  - DROP TABLE, ALTER TABLE
```

#### 3.1.4 Lightweight Locks (LWLocks)

**目的**: 共有メモリ構造の保護

**種類**:
- BufMappingLocks: バッファマッピング保護
- WALInsertLocks: WAL挿入の並列化
- LockMgrLocks: ロックマネージャ保護

**実装**: スピンロック + セマフォ (競合時)

### 3.2 プロセスローカルメモリ

各バックエンドプロセスが個別に持つメモリ。

#### 3.2.1 work_mem
- **用途**: ソート、ハッシュ結合、集約操作
- **重要**: クエリ内で**複数回**使われる可能性
- **計算例**:
  ```
  総メモリ使用 = work_mem × 並列度 × 同時接続数
  ```

#### 3.2.2 maintenance_work_mem
- **用途**: VACUUM, CREATE INDEX, ALTER TABLE
- **推奨**: work_memより大きく設定 (例: 1GB)

#### 3.2.3 temp_buffers
- **用途**: セッション内の一時テーブル
- **デフォルト**: 8MB

---

## 4. ストレージアーキテクチャ

### 4.1 データディレクトリ構造

```
$PGDATA/
├── base/                     # データベースファイル
│   └── <oid>/               # データベースごと
│       ├── <oid>            # テーブルファイル
│       ├── <oid>_fsm        # Free Space Map
│       ├── <oid>_vm         # Visibility Map
│       └── <oid>.<seq>      # 1GBで分割ファイル
├── global/                  # 共有システムカタログ
├── pg_wal/                  # Write-Ahead Log
│   └── 000000010000000000000001
├── pg_xact/                 # トランザクション状態
├── pg_multixact/            # マルチトランザクション
├── pg_logical/              # 論理デコーディング
├── pg_stat/                 # 統計情報
├── pg_tblspc/               # テーブルスペースリンク
└── postgresql.conf          # 設定ファイル
```

### 4.2 ページ構造 (8KB固定)

PostgreSQLの基本I/O単位は**8KB**です。

```
┌─────────────────────────────────┐ 0
│ PageHeaderData (24 bytes)       │
│  - pd_lsn: LSN (WAL位置)        │
│  - pd_checksum: チェックサム    │
│  - pd_flags, pd_lower, pd_upper │
├─────────────────────────────────┤ 24
│ ItemIdData[] (Line Pointers)    │
│  - 4 bytes × N個                │
│  - (offset, length, flags)      │
├─────────────────────────────────┤ pd_lower
│ Free Space                      │
├─────────────────────────────────┤ pd_upper
│ Tuples (下から上へ成長)        │
│  - HeapTupleHeader + データ     │
├─────────────────────────────────┤
│ Special Space (インデックス用)  │
└─────────────────────────────────┘ 8192
```

**Line Pointer間接参照の理由:**
- タプル更新時に物理位置が変わってもポインタは不変
- ページ内の断片化整理が容易

### 4.3 HeapTuple構造

```c
// src/include/access/htup_details.h

typedef struct HeapTupleHeaderData {
    union {
        HeapTupleFields t_heap;
        DatumTupleFields t_datum;
    } t_choice;

    ItemPointerData t_ctid;  // 次バージョンへのポインタ (MVCC)

    uint16 t_infomask2;      // フラグ (列数等)
    uint16 t_infomask;       // フラグ (XMIN/XMAX有効等)
    uint8  t_hoff;           // データ開始オフセット

    bits8  t_bits[FLEXIBLE_ARRAY_MEMBER]; // NULLビットマップ

    // 以降、実際のカラムデータ
} HeapTupleHeaderData;
```

**MVCC情報:**
- `t_xmin`: このタプルを挿入したトランザクションID
- `t_xmax`: このタプルを削除したトランザクションID
- `t_cid`: コマンドID (トランザクション内のSQL順序)

### 4.4 TOAST (The Oversized-Attribute Storage Technique)

大きなデータ (通常 > 2KB) の格納メカニズム。

**戦略:**
1. **PLAIN**: TOAST不使用 (小さな型)
2. **EXTENDED**: 圧縮 → それでも大きければ外部保存
3. **EXTERNAL**: 圧縮なし外部保存
4. **MAIN**: 圧縮のみ、外部保存は最後の手段

**実装:**
```
元のテーブル:
┌──────┬────────────┬────────┐
│ id   │ large_text │ ...    │
├──────┼────────────┼────────┤
│ 1    │ <TOAST Ptr>│        │ ← TOAST参照
└──────┴────────────┴────────┘
        ↓
TOASTテーブル (pg_toast.<oid>):
┌─────────┬──────┬──────┐
│ chunk_id│ seq  │ data │
├─────────┼──────┼──────┤
│ 1       │ 0    │ ...  │ ← 2KBチャンク
│ 1       │ 1    │ ...  │
│ 1       │ 2    │ ...  │
└─────────┴──────┴──────┘
```

### 4.5 Free Space Map (FSM)

各ページの空き容量を追跡するB-tree構造。

**目的**: INSERT時に空きのあるページを高速検索

**ファイル**: `<relfilenode>_fsm`

**構造**: 3層B-tree (最大32TB対応)

### 4.6 Visibility Map (VM)

各ページの可視性情報を管理するビットマップ。

**ビット:**
- **all-visible**: 全タプルが全トランザクションに可視
- **all-frozen**: 全タプルがfrozen (VACUUM不要)

**活用:**
- Index-Only Scanの効率化
- VACUUMのスキップ

**ファイル**: `<relfilenode>_vm`

---

## 5. クエリ処理パイプライン

### 5.1 全体フロー

```
1. クライアント → SQL文送信
   ↓
2. Parser (構文解析)
   - Raw Parse Tree生成
   - src/backend/parser/gram.y (Bison文法)
   ↓
3. Analyzer (意味解析)
   - システムカタログ参照
   - 型チェック、名前解決
   - Query Tree生成
   ↓
4. Rewriter (書き換え)
   - ビュー展開
   - ルール適用
   ↓
5. Planner (最適化)
   - 実行計画生成
   - コスト見積もり
   - 最適プラン選択
   ↓
6. Executor (実行)
   - イテレータモデル
   - ボルケーノ方式
   ↓
7. 結果返送 → クライアント
```

### 5.2 Parser (パーサー)

**技術:**
- **Bison** (LALR(1) パーサジェネレータ)
- **Flex** (字句解析器)

**入力:** `SELECT * FROM users WHERE id = 1;`

**出力 (簡略化):**
```c
SelectStmt {
    targetList: [ResTarget(name="*")]
    fromClause: [RangeVar(relname="users")]
    whereClause: A_Expr(
        kind=AEXPR_OP,
        left=ColumnRef(fields=["id"]),
        op="=",
        right=A_Const(val=1)
    )
}
```

### 5.3 Analyzer (アナライザ)

**処理:**
1. システムカタログ(`pg_class`, `pg_attribute`等)検索
2. 列名解決: `id` → テーブル`users`の`int`型カラム
3. 型変換挿入: 必要に応じて暗黙的キャスト
4. 権限チェック

**出力:** Query Tree (意味情報付き)

### 5.4 Rewriter (リライタ)

**ビュー展開例:**
```sql
CREATE VIEW active_users AS
  SELECT * FROM users WHERE status = 'active';

-- クエリ:
SELECT * FROM active_users WHERE age > 20;

-- 書き換え後:
SELECT * FROM users
WHERE status = 'active' AND age > 20;
```

**ルールシステム:**
- `CREATE RULE` で定義されたルールを適用
- 複雑なクエリ変換が可能

### 5.5 Planner (プランナー)

PostgreSQLの**最も複雑な**コンポーネント。

#### 5.5.1 コストモデル

**基本コスト単位:**
```c
// src/include/optimizer/cost.h

seq_page_cost = 1.0     // シーケンシャルページ読み込み
random_page_cost = 4.0  // ランダムページ読み込み (SSDなら1.1)
cpu_tuple_cost = 0.01   // タプル処理
cpu_index_tuple_cost = 0.005  // インデックスタプル処理
cpu_operator_cost = 0.0025    // 演算子評価
```

**総コスト計算例 (Seq Scan):**
```
total_cost = seq_page_cost × pages
           + cpu_tuple_cost × tuples
           + cpu_operator_cost × tuples × filter_complexity
```

#### 5.5.2 実行計画生成

**プラン種類:**

1. **Scan Plans:**
   - Seq Scan: 全行スキャン
   - Index Scan: インデックス経由
   - Index Only Scan: インデックスのみ
   - Bitmap Scan: 複数インデックス併用
   - TID Scan: 物理位置直接アクセス

2. **Join Plans:**
   - Nested Loop Join: 小さいテーブル向け
   - Hash Join: 大きいテーブル向け
   - Merge Join: ソート済みデータ向け

3. **Aggregate Plans:**
   - Plain Aggregate: GROUP BYなし
   - Group Aggregate: ソート済みデータ
   - Hash Aggregate: ハッシュテーブル使用

**動的計画法 (Dynamic Programming):**
```
小さなサブプラン生成:
  - 単一テーブルスキャン
    ↓
中規模プラン:
  - 2テーブルJoin (全組み合わせ評価)
    ↓
大規模プラン:
  - 3テーブル以上 (最良プラン継承)
    ↓
最終プラン選択 (最小コスト)
```

**GEQO (Genetic Query Optimizer):**
- テーブル数が多い場合 (`geqo_threshold` = 12)
- 遺伝的アルゴリズムで近似解

#### 5.5.3 統計情報活用

**pg_statistic:**
- **most_common_vals**: 頻出値
- **most_common_freqs**: その頻度
- **histogram_bounds**: 値の分布ヒストグラム
- **n_distinct**: ユニーク値数推定
- **correlation**: 物理順序と論理順序の相関

**選択率計算:**
```sql
-- WHERE age = 25
selectivity = frequency(25) または 1.0 / n_distinct

-- WHERE age > 25
selectivity = (max - 25) / (max - min)  -- ヒストグラム利用
```

### 5.6 Executor (エグゼキュータ)

**イテレータモデル (Volcano Model):**

各ノードが同じインターフェースを実装:
```c
ExecInitNode()  // 初期化
ExecProcNode()  // 次のタプル取得
ExecEndNode()   // 終了処理
```

**実行例:**
```
QUERY PLAN
──────────────────────────────────────
Aggregate  (cost=... rows=1)
  -> Seq Scan on users (cost=... rows=1000)
      Filter: (age > 25)

実行フロー:
1. Aggregate.ExecProcNode() 呼び出し
   ↓
2. SeqScan.ExecProcNode() 繰り返し呼び出し
   ↓
3. SeqScanがタプルを1つずつ返す
   - ページ読み込み (Shared Buffers経由)
   - Filter評価
   - 合格タプルを上位に返す
   ↓
4. Aggregateが集約処理
   ↓
5. 最終結果返却
```

**パイプライン実行:**
- メモリ効率的 (全データを保持しない)
- ストリーム処理

**Materialize:**
- 一部のケースでバッファリング必要
- 例: Merge Join の内側テーブル

---

## 6. インデックス技術

### 6.1 B-Tree インデックス

PostgreSQLの**デフォルト**インデックス。

#### 6.1.1 構造

```
                  Root Page
                 [50 | 100]
                /     |     \
              /       |       \
         [10|30]   [60|80]   [110|130]
         /  |  \    /  |  \    /   |   \
      Leaf Leaf Leaf Leaf Leaf ... (データへのポインタ)
```

**特性:**
- **バランス木**: 全リーフが同じ深さ
- **ファンアウト**: 通常100-200 (8KBページ内)
- **高さ**: log<sub>100</sub>(N) → 100万行で3段、1億行で4段

#### 6.1.2 実装詳細

**ページタイプ:**
1. **Meta Page**: B-treeのルート情報
2. **Internal Pages**: キー + 子ページポインタ
3. **Leaf Pages**: キー + TID (タプルID)

**Tuple Identifier (TID):**
```c
typedef struct ItemPointerData {
    BlockNumber ip_blkid;  // ページ番号 (4 bytes)
    OffsetNumber ip_posid; // ページ内オフセット (2 bytes)
} ItemPointerData;  // 合計6 bytes
```

**挿入処理:**
```
1. ルートから検索 (バイナリサーチ)
2. リーフページ到達
3. 挿入位置特定
4. ページに空きあり → 挿入
5. ページ満杯 → ページ分割:
   - 新ページ確保
   - エントリを半分ずつ分配
   - 親ページに新キー追加 (再帰的)
```

**並行制御:**
- **ページレベルロック**: リーフページは読み取りロック軽量
- **リンクポインタ**: リーフページが双方向リスト (スキャン効率化)

#### 6.1.3 インデックススキャン戦略

**Index Scan:**
```
1. インデックスB-tree検索 (WHERE条件)
2. TID取得
3. ヒープテーブルからタプル取得 (ランダムI/O)
4. 可視性チェック (MVCC)
5. 結果返却
```

**Index Only Scan:**
```
前提: インデックスに必要なカラム全て含まれる

1. インデックスB-tree検索
2. Visibility Map チェック
3. all-visibleなら → ヒープアクセス不要
4. そうでなければ → ヒープで可視性確認
```

**Bitmap Index Scan:**
```
複数インデックス併用:

1. Index1をスキャン → TID Set A
2. Index2をスキャン → TID Set B
3. ビットマップ演算: A ∩ B (AND) または A ∪ B (OR)
4. TID Set をソート (ページ番号順)
5. ヒープをシーケンシャル的にアクセス → I/O効率化
```

### 6.2 Hash インデックス

#### 6.2.1 概要

**用途**: 等値検索 (`=`) のみ

**構造**: 動的ハッシュテーブル

**PostgreSQL 10以降:**
- WALログ対応 (クラッシュセーフ)
- それ以前は非推奨だった

#### 6.2.2 実装

**ハッシュ関数:**
```c
uint32 hash = hash_any((unsigned char *)key, keylen);
bucket = hash % num_buckets;
```

**バケットチェイン:**
```
Hash Table
├─ Bucket 0 → Overflow Page → Overflow Page → ...
├─ Bucket 1 → Overflow Page
├─ Bucket 2
...
```

**分割 (Bucket Split):**
- バケットが満杯になると動的に分割
- 線形ハッシング方式

### 6.3 GiST (Generalized Search Tree)

#### 6.3.1 概要

**汎用インデックスフレームワーク**:
- 幾何データ (PostGIS)
- 全文検索 (tsvector)
- 範囲型 (int4range)
- カスタムデータ型

#### 6.3.2 実装原理

**Key Methods (演算子クラス定義):**
```c
1. consistent: 検索条件マッチ判定
2. union: 複数キーの統合
3. compress: キー圧縮
4. decompress: キー展開
5. penalty: 挿入ペナルティ計算
6. picksplit: ページ分割戦略
7. same: キー同一性判定
```

**例: 2次元点インデックス**
```
        Root [全体Bounding Box]
       /                       \
  [左半分BBox]              [右半分BBox]
    /      \                   /      \
 [...] [実点群]           [...] [実点群]
```

**検索:**
```
1. ルートから下降
2. consistent()で各子ノードをチェック
3. マッチしたノードへ再帰
4. リーフで実データ取得
```

### 6.4 SP-GiST (Space-Partitioned GiST)

#### 6.4.1 概要

**空間分割木**:
- Quad-tree
- k-d tree
- Radix tree (テキスト)

**適用:**
- 非均衡データ分布
- 電話番号、IPアドレス等

#### 6.4.2 構造例 (Quad-tree)

```
       ┌─────────┬─────────┐
       │   NW    │   NE    │
       ├─────────┼─────────┤
       │   SW    │   SE    │
       └─────────┴─────────┘
            ↓
       各象限を再帰的に分割
```

### 6.5 GIN (Generalized Inverted Index)

#### 6.5.1 概要

**転置インデックス**:
- 配列要素
- 全文検索トークン
- JSONB キー

**特性:**
- 複数値を持つカラムに最適
- 高速検索、挿入は遅い

#### 6.5.2 構造

```
B-tree (キー)
├─ "apple" → Posting List: [TID1, TID5, TID9, ...]
├─ "banana" → Posting List: [TID2, TID7, ...]
├─ "orange" → Posting List: [TID3, TID5, TID8, ...]
...
```

**Posting List圧縮:**
- varbyte エンコーディング
- デルタ圧縮

**挿入最適化:**
- **Pending List**: 挿入を一時的にバッファリング
- バックグラウンドでB-treeにマージ

#### 6.5.3 全文検索例

```sql
CREATE INDEX idx_fts ON documents USING GIN (to_tsvector('english', body));

SELECT * FROM documents
WHERE to_tsvector('english', body) @@ to_tsquery('postgresql & performance');
```

**内部処理:**
```
1. クエリ解析: 'postgresql' AND 'performance'
2. GINからPosting List取得:
   - 'postgresql' → [1, 5, 8, 12, ...]
   - 'performance' → [3, 5, 9, 12, ...]
3. ビットマップAND: [5, 12, ...]
4. ヒープからタプル取得
```

### 6.6 BRIN (Block Range Index)

#### 6.6.1 概要

**ブロック範囲インデックス**:
- 物理的に連続したブロック群の**要約情報**を格納
- 超大規模テーブル向け (TB級)
- インデックスサイズが極小

#### 6.6.2 構造

```
Table Pages:
[0-127]    [128-255]  [256-383]  ...
  ↓           ↓          ↓
BRIN Index:
[min=10,   [min=130,  [min=240,
 max=120]   max=250]   max=380]
```

**128ページ = 1MB単位**で要約 (`pages_per_range`)

#### 6.6.3 検索

```sql
SELECT * FROM logs WHERE timestamp > '2024-01-01';

1. BRIN Index スキャン
2. max >= '2024-01-01' のブロック範囲を特定
3. 該当ブロック範囲のみシーケンシャルスキャン
```

**効果的な場合:**
- 時系列データ (挿入順にソート済み)
- 物理順序と論理順序が高相関

**インデックスサイズ比較:**
- B-tree: 数GB
- BRIN: 数MB (1000分の1)

---

## 7. ビューとマテリアルビュー

### 7.1 通常ビュー

#### 7.1.1 概念

**ビューは保存されたクエリ**:
- データは保存されない
- クエリ実行時に動的に計算

#### 7.1.2 実装

**システムカタログ:**
```sql
-- pg_class: ビューのメタデータ
-- pg_rewrite: ビュー定義 (Query Tree)
```

**クエリ書き換え:**
```sql
CREATE VIEW high_salary AS
  SELECT * FROM employees WHERE salary > 100000;

-- 実行:
SELECT name FROM high_salary WHERE dept = 'Engineering';

-- 書き換え後:
SELECT name FROM employees
WHERE salary > 100000 AND dept = 'Engineering';
```

**最適化の恩恵:**
- プランナーは展開後のクエリ全体を最適化
- 不要な計算は削除される

#### 7.1.3 更新可能ビュー

**自動更新可能条件:**
- 単一テーブル参照
- 集約・DISTINCT・LIMIT等なし
- WHEREは更新可能

**INSTEAD OF トリガー:**
```sql
CREATE TRIGGER view_insert
INSTEAD OF INSERT ON complex_view
FOR EACH ROW EXECUTE FUNCTION handle_insert();
```

### 7.2 マテリアルビュー (Materialized View)

#### 7.2.1 概念

**物理的にデータを保存**:
- クエリ結果をテーブルとして格納
- 定期的にリフレッシュ必要

#### 7.2.2 実装

**ストレージ:**
- 通常のテーブルと同じヒープ構造
- インデックス作成可能

**作成:**
```sql
CREATE MATERIALIZED VIEW sales_summary AS
  SELECT product_id, SUM(amount) as total
  FROM sales
  GROUP BY product_id;

CREATE INDEX ON sales_summary (product_id);
```

**内部処理:**
1. クエリ実行
2. 一時テーブルに結果格納
3. トランザクションコミット時に実体化
4. システムカタログ登録

#### 7.2.3 リフレッシュ

**REFRESH MATERIALIZED VIEW:**
```sql
-- ロックあり (読み取り不可)
REFRESH MATERIALIZED VIEW sales_summary;

-- CONCURRENT (読み取り可能)
REFRESH MATERIALIZED VIEW CONCURRENTLY sales_summary;
```

**CONCURRENT実装:**
1. 新しいクエリ結果を一時テーブルに生成
2. 既存データとDIFF計算
3. 差分を適用 (INSERT/DELETE)
4. 要件: **UNIQUE INDEXが必須**

**トレードオフ:**
```
通常ビュー:
  + 常に最新データ
  - クエリごとに計算コスト

マテリアルビュー:
  + 高速クエリ (事前計算済み)
  - データ古い可能性
  - リフレッシュコスト
  - ストレージ消費
```

---

## 8. トランザクション管理とMVCC

### 8.1 MVCC (Multi-Version Concurrency Control)

#### 8.1.1 基本原理

**各トランザクションはスナップショットを見る:**
- 読み取りは書き込みをブロックしない
- 書き込みは読み取りをブロックしない

**実装:**
```c
typedef struct HeapTupleFields {
    TransactionId t_xmin;  // 作成トランザクションID
    TransactionId t_xmax;  // 削除トランザクションID
    union {
        CommandId t_cid;
        TransactionId t_xvac;
    } t_field3;
} HeapTupleFields;
```

#### 8.1.2 可視性判定

**Snapshot:**
```c
typedef struct SnapshotData {
    TransactionId xmin;  // 最小アクティブXID
    TransactionId xmax;  // 次のXID
    TransactionId *xip;  // アクティブXID配列
    uint32 xcnt;         // アクティブXID数
} SnapshotData;
```

**可視性ルール:**
```
Tuple可視 ⇔
  1. t_xmin がコミット済み
  AND
  2. t_xmin < snapshot.xmin
     OR (t_xmin がスナップショット内で非アクティブ)
  AND
  3. t_xmax が未設定 または アボート済み
     OR t_xmax >= snapshot.xmax
     OR (t_xmax がスナップショット内でアクティブ)
```

**例:**
```
Transaction T1 (XID=100):
  BEGIN;
  INSERT INTO users VALUES (1, 'Alice');  -- t_xmin=100
  COMMIT;

Transaction T2 (XID=101, 開始時点でT1実行中):
  BEGIN;  -- Snapshot: xmin=100, xip=[100]
  SELECT * FROM users;  -- Alice見えない (100はアクティブ)

Transaction T3 (XID=102, T1コミット後開始):
  BEGIN;  -- Snapshot: xmin=102, xip=[]
  SELECT * FROM users;  -- Alice見える (100 < 102, コミット済み)
```

#### 8.1.3 トランザクションID管理

**XID構造:**
- 32bit整数 (約42億)
- 循環的に使用 (ラップアラウンド)

**Frozen XID:**
- 古いタプルのXIDを特殊値`FrozenTransactionId (2)`に変換
- VACUUMが定期的に実行
- ラップアラウンド防止

**pg_xact (Transaction Status):**
```
$PGDATA/pg_xact/0000
               /0001
               ...

各XIDに2bit割り当て:
  00: IN_PROGRESS
  01: COMMITTED
  10: ABORTED
  11: SUB_COMMITTED
```

### 8.2 WAL (Write-Ahead Logging)

#### 8.2.1 原理

**変更は必ずWALに先に記録**:
```
1. データ変更 (メモリ内)
2. WALレコード生成・書き込み
3. WALディスクフラッシュ (fsync)
4. クライアントへCOMMIT応答
5. (後で) ダーティページをディスクに書き込み
```

**クラッシュリカバリ:**
```
1. 最後のチェックポイント位置をpg_controlから取得
2. チェックポイント以降のWALを再生
3. COMMITされたトランザクション → REDO
4. ABORTまたは未完了 → UNDO不要 (MVCC)
```

#### 8.2.2 WAL構造

**WALファイル:**
- 16MB固定サイズ
- 名前形式: `000000010000000000000001`
  - Timeline ID: 8桁
  - Logical Log ID: 8桁
  - Segment Number: 8桁

**WALレコード:**
```c
typedef struct XLogRecord {
    uint32 xl_tot_len;     // レコード長
    TransactionId xl_xid;  // トランザクションID
    XLogRecPtr xl_prev;    // 前レコードへのポインタ
    uint8 xl_info;         // 操作種別
    RmgrId xl_rmid;        // リソースマネージャID
    uint32 xl_crc;         // CRC32Cチェックサム
    // データブロック情報
    // 実際の変更データ
} XLogRecord;
```

**リソースマネージャ:**
- RM_HEAP: ヒープ操作 (INSERT/UPDATE/DELETE)
- RM_BTREE: B-treeインデックス
- RM_HASH: ハッシュインデックス
- RM_GIN: GINインデックス
- RM_XACT: トランザクション制御
- ...

**Full Page Writes:**
- チェックポイント後の初回変更は**ページ全体**をWALに記録
- 部分書き込み (torn page) 対策
- `full_page_writes = on` (デフォルト)

#### 8.2.3 WALレベル

```
minimal:  クラッシュリカバリのみ
replica:  レプリケーション対応 (デフォルト)
logical:  論理レプリケーション対応
```

### 8.3 チェックポイント

**目的:**
1. リカバリ時間短縮
2. WALファイル削除可能化

**処理:**
```
1. 全ダーティバッファリスト作成
2. ファイル・ページ番号でソート
3. write()でディスクへ書き込み
   - checkpoint_completion_target で速度調整
4. fsync()で永続化保証
5. pg_control更新 (新チェックポイント位置)
```

**トリガー:**
- `checkpoint_timeout` (デフォルト5分)
- `max_wal_size` 到達 (デフォルト1GB)
- 管理者が`CHECKPOINT`コマンド実行
- シャットダウン時

---

## 9. ネットワークプロトコル

### 9.1 PostgreSQLプロトコル概要

**特性:**
- **バイナリプロトコル** (効率的)
- **非同期対応** (パイプライン可能)
- **拡張可能** (カスタムメッセージ型)

**通信方式:**
- TCP/IP (デフォルトポート5432)
- Unixドメインソケット (ローカル接続)
- SSL/TLS対応

### 9.2 接続シーケンス

```
Client                          Server
  |                               |
  |--- SSLRequest --------------->|  (オプション)
  |<-- 'S' or 'N' ----------------|
  |                               |
  |--- StartupMessage ----------->|
  |    (user, database, params)   |
  |                               |
  |<-- Authentication Request ----|
  |    (AuthenticationMD5Password |
  |     or AuthenticationOk)      |
  |                               |
  |--- PasswordMessage ---------->|  (必要時)
  |                               |
  |<-- AuthenticationOk ----------|
  |<-- ParameterStatus ------------|  (複数)
  |<-- BackendKeyData -------------|  (キャンセル用)
  |<-- ReadyForQuery --------------|  (接続完了)
  |                               |
```

### 9.3 メッセージフォーマット

**一般構造:**
```
┌─────────┬──────────────┬─────────────┐
│ Type(1) │ Length(4)    │ Payload     │
│ byte    │ int32        │ (Length-4)  │
└─────────┴──────────────┴─────────────┘
```

**主要メッセージタイプ:**

**クライアント → サーバー:**
- `Q`: Simple Query
- `P`: Parse (プリペアドステートメント)
- `B`: Bind (パラメータバインド)
- `E`: Execute
- `D`: Describe
- `S`: Sync
- `X`: Terminate

**サーバー → クライアント:**
- `R`: Authentication
- `S`: ParameterStatus
- `K`: BackendKeyData
- `Z`: ReadyForQuery
- `T`: RowDescription
- `D`: DataRow
- `C`: CommandComplete
- `E`: ErrorResponse

### 9.4 Simple Query Protocol

```
Client                          Server
  |                               |
  |--- 'Q' + SQL ---------------->|
  |                               |
  |<-- RowDescription ------------|
  |<-- DataRow -------------------|  (複数行)
  |<-- DataRow -------------------|
  |<-- CommandComplete -----------|
  |<-- ReadyForQuery -------------|
  |                               |
```

**バイナリ例 (SELECT 1):**
```
Client sends:
  51                    // 'Q'
  00 00 00 0D           // Length = 13
  53 45 4C 45 43 54 20 31 3B 00  // "SELECT 1;" + null terminator

Server responds:
  54 ...                // 'T' RowDescription
  44 ...                // 'D' DataRow (value=1)
  43 ...                // 'C' CommandComplete ("SELECT 1")
  5A ...                // 'Z' ReadyForQuery
```

### 9.5 Extended Query Protocol

**利点:**
- プリペアドステートメント (SQLインジェクション防止)
- バイナリフォーマット転送 (高効率)
- ポータル (カーソル相当)

**フロー:**
```
Client                          Server
  |                               |
  |--- Parse -------------------->|  (SQL構文解析)
  |<-- ParseComplete -------------|
  |                               |
  |--- Bind --------------------->|  (パラメータバインド)
  |<-- BindComplete --------------|
  |                               |
  |--- Execute ------------------>|  (実行)
  |<-- DataRow -------------------|
  |<-- CommandComplete -----------|
  |                               |
  |--- Sync --------------------->|
  |<-- ReadyForQuery -------------|
  |                               |
```

**再利用:**
```
1. Parse → 1回だけ
2. Bind → パラメータ変えて複数回
3. Execute → 複数回
```

### 9.6 パイプライニング

**複数メッセージを一度に送信:**
```
Client sends:
  Parse + Bind + Execute + Sync (一括送信)

Server processes:
  キューイング → 順次処理 → 結果一括返送

効果:
  - ラウンドトリップ削減
  - レイテンシ削減
```

### 9.7 COPY Protocol

**バルクデータ転送**用の高速プロトコル。

```
Client                          Server
  |                               |
  |--- COPY FROM STDIN ---------->|
  |<-- CopyInResponse ------------|
  |                               |
  |--- CopyData ----------------->|  (複数チャンク)
  |--- CopyData ----------------->|
  |--- CopyDone ----------------->|
  |                               |
  |<-- CommandComplete -----------|
  |<-- ReadyForQuery -------------|
  |                               |
```

**フォーマット:**
- TEXT: CSV風 (人間可読)
- BINARY: ネイティブ形式 (最高速)

### 9.8 SSL/TLS暗号化

**接続:**
```
1. SSLRequest送信 (特殊8バイトメッセージ)
2. サーバー応答:
   - 'S': SSL対応、TLSハンドシェイク開始
   - 'N': SSL非対応、平文接続続行
3. TLS handshake (OpenSSL)
4. 暗号化通信開始
```

**証明書検証:**
- `sslmode=require`: 暗号化必須
- `sslmode=verify-ca`: CA検証
- `sslmode=verify-full`: ホスト名検証

---

## 10. PostgreSQL 18の最新機能

### 10.1 リリース概要

**PostgreSQL 18** (2025年リリース予定) の主要機能:

### 10.2 インクリメンタル BACKUP & RESTORE

**概要:**
- ベースバックアップからの**差分バックアップ**をネイティブサポート
- 従来: 完全バックアップのみ
- 効果: バックアップ時間・容量削減

**技術実装:**
```
1. ベースバックアップ:
   pg_basebackup --incremental=yes --target=/backup/base
   → WAL Summary Files生成

2. 差分バックアップ:
   pg_basebackup --incremental=/backup/base --target=/backup/incr1
   → 変更ブロックのみコピー

3. リストア:
   pg_combinebackup --base=/backup/base --increment=/backup/incr1 --output=/pgdata
   → 完全なデータディレクトリ再構築
```

**WAL Summary Files:**
- チェックポイント間の変更ブロックリストを記録
- `pg_wal/summaries/` ディレクトリ

### 10.3 I/O 並列性の向上

**Parallel Sequential Scan改善:**
- ワーカー間のページ割り当て最適化
- プリフェッチ強化

**Parallel B-tree Index Builds:**
- `CREATE INDEX` の並列度向上
- ソートフェーズとページ構築の並列化

### 10.4 JSON機能強化

**JSON_TABLE拡張:**
```sql
-- JSON配列を行に展開
SELECT * FROM JSON_TABLE(
    '[{"name":"Alice","age":30}, {"name":"Bob","age":25}]',
    '$[*]' COLUMNS(
        name TEXT PATH '$.name',
        age INT PATH '$.age'
    )
);
```

**JSON Schema Validation:**
```sql
-- JSONカラムにスキーマ制約
ALTER TABLE users ADD CONSTRAINT profile_schema
  CHECK (profile IS JSON VALIDATE USING '{
    "type": "object",
    "properties": {
      "age": {"type": "number"},
      "email": {"type": "string", "format": "email"}
    },
    "required": ["email"]
  }');
```

### 10.5 Logical Replication改善

**Parallel Apply Workers:**
- 複数ワーカーでトランザクション並列適用
- スループット向上

**Initial Table Sync改善:**
- `COPY`の高速化
- 大規模テーブルの初期同期が高速化

### 10.6 パーティショニング機能強化

**MERGE INTO with Partitioning:**
```sql
-- パーティションテーブルへのMERGE文サポート
MERGE INTO sales_partitioned AS target
USING new_sales AS source
ON target.id = source.id
WHEN MATCHED THEN UPDATE SET amount = source.amount
WHEN NOT MATCHED THEN INSERT VALUES (source.id, source.amount, source.date);
```

**パーティション自動作成 (拡張):**
- より柔軟なパーティション管理

### 10.7 VACUUM性能改善

**Index Cleanup Optimization:**
- インデックスVACUUMの並列度向上
- デッドタプルの検出効率化

**Frozen Tuple Tracking:**
- Visibility Map拡張
- VACUUM Freezeの最適化

### 10.8 ANALYZE統計情報強化

**Extended Statistics:**
- 多次元統計の精度向上
- 相関関係の推定改善

**Sampling改善:**
- 大規模テーブルのサンプリング高速化

### 10.9 接続管理改善

**Connection Pooling Hooks:**
- 内蔵接続プーリング機能の基盤
- 外部ツール (pgBouncer等) との統合強化

### 10.10 セキュリティ強化

**Row-Level Security (RLS) 性能改善:**
- RLSポリシーの最適化
- オーバーヘッド削減

**Audit Logging拡張:**
- より詳細な監査ログ

### 10.11 モニタリング機能

**pg_stat_io拡張:**
- I/O統計の詳細化
- キャッシュヒット率の可視化

**Wait Event拡張:**
- 新しい待機イベント追加
- ボトルネック特定の容易化

---

## 11. pgクライアントの内部実装

### 11.1 libpq (PostgreSQL C Client Library)

#### 11.1.1 概要

**PostgreSQLの公式Cライブラリ**:
- 他言語ドライバの基盤
- 同期・非同期API提供

**ヘッダ:** `libpq-fe.h`

#### 11.1.2 接続管理

**接続文字列:**
```c
PGconn *conn = PQconnectdb(
    "host=localhost port=5432 dbname=mydb user=postgres password=secret"
);

if (PQstatus(conn) != CONNECTION_OK) {
    fprintf(stderr, "Connection failed: %s\n", PQerrorMessage(conn));
    PQfinish(conn);
    exit(1);
}
```

**内部フロー:**
```
1. PQconnectdb()
   ↓
2. 接続文字列パース
   ↓
3. DNS解決 (getaddrinfo)
   ↓
4. socket() + connect()
   ↓
5. SSL交渉 (オプション)
   ↓
6. StartupMessage送信
   ↓
7. 認証処理
   ↓
8. ParameterStatus受信・保存
   ↓
9. ReadyForQuery受信
   ↓
10. PGconn構造体返却
```

**PGconn構造体:**
```c
struct pg_conn {
    PGConnectionState status;  // 接続状態
    int sock;                  // ソケットFD
    char *pghost;              // ホスト名
    char *pgport;              // ポート
    PGAsyncStatusType asyncStatus; // 非同期状態
    PGresult *result;          // 最後のクエリ結果
    PQExpBuffer inBuffer;      // 受信バッファ
    PQExpBuffer outBuffer;     // 送信バッファ
    // ... 多数のフィールド
};
```

#### 11.1.3 クエリ実行 (同期)

**Simple Query:**
```c
PGresult *res = PQexec(conn, "SELECT * FROM users");

if (PQresultStatus(res) != PGRES_TUPLES_OK) {
    fprintf(stderr, "Query failed: %s\n", PQerrorMessage(conn));
    PQclear(res);
    PQfinish(conn);
    exit(1);
}

int nrows = PQntuples(res);
int ncols = PQnfields(res);

for (int i = 0; i < nrows; i++) {
    for (int j = 0; j < ncols; j++) {
        printf("%s\t", PQgetvalue(res, i, j));
    }
    printf("\n");
}

PQclear(res);
```

**内部処理:**
```
1. PQexec()
   ↓
2. 'Q' メッセージ構築・送信
   ↓
3. ブロッキング受信ループ:
   while (true) {
       recv(sock, buffer, size)
       メッセージパース
       switch (message_type) {
           case 'T': RowDescription保存
           case 'D': DataRow蓄積
           case 'C': CommandComplete
           case 'Z': ReadyForQuery → break
       }
   }
   ↓
4. PGresult構造体構築・返却
```

**PGresult構造体:**
```c
struct pg_result {
    ExecStatusType resultStatus;  // PGRES_TUPLES_OK等
    int ntups;                    // 行数
    int numAttributes;            // 列数
    PGresAttDesc *attDescs;       // 列記述子
    PGresAttValue **tuples;       // データ配列
    char *errMsg;                 // エラーメッセージ
    // ...
};
```

#### 11.1.4 プリペアドステートメント

**準備:**
```c
PGresult *res = PQprepare(conn,
    "get_user",                          // ステートメント名
    "SELECT * FROM users WHERE id = $1", // SQL
    1,                                   // パラメータ数
    NULL                                 // パラメータ型 (自動推論)
);
```

**実行:**
```c
const char *paramValues[] = {"42"};
PGresult *res = PQexecPrepared(conn,
    "get_user",     // ステートメント名
    1,              // パラメータ数
    paramValues,    // パラメータ値
    NULL,           // パラメータ長 (TEXT形式)
    NULL,           // パラメータ形式 (TEXT)
    0               // 結果形式 (TEXT)
);
```

**バイナリフォーマット:**
```c
// INT型をバイナリで送信
int value = htonl(42);  // ネットワークバイトオーダー
const char *paramValues[] = {(char *)&value};
int paramLengths[] = {sizeof(int)};
int paramFormats[] = {1};  // 1=BINARY

PGresult *res = PQexecParams(conn,
    "SELECT * FROM users WHERE id = $1",
    1,
    NULL,
    paramValues,
    paramLengths,
    paramFormats,
    1  // 結果もBINARY
);

// INT型をバイナリで取得
int result_value = ntohl(*(int *)PQgetvalue(res, 0, 0));
```

#### 11.1.5 非同期API

**非同期接続:**
```c
PGconn *conn = PQconnectStart("host=localhost dbname=mydb");

while (true) {
    PostgresPollingStatusType status = PQconnectPoll(conn);

    if (status == PGRES_POLLING_OK)
        break;  // 接続完了

    if (status == PGRES_POLLING_FAILED) {
        fprintf(stderr, "Connection failed\n");
        exit(1);
    }

    // PGRES_POLLING_READING or PGRES_POLLING_WRITING
    int sock = PQsocket(conn);
    // select() / poll() / epoll() でイベント待機
}
```

**非同期クエリ:**
```c
// クエリ送信 (ノンブロッキング)
if (!PQsendQuery(conn, "SELECT * FROM large_table")) {
    fprintf(stderr, "Send failed\n");
}

// 結果受信 (ノンブロッキング)
while (true) {
    if (!PQconsumeInput(conn)) {
        fprintf(stderr, "Receive failed\n");
        break;
    }

    if (PQisBusy(conn)) {
        // まだデータ来てない → select()等で待機
        continue;
    }

    PGresult *res = PQgetResult(conn);
    if (res == NULL)
        break;  // 全結果受信完了

    // 結果処理
    PQclear(res);
}
```

#### 11.1.6 COPY操作

**COPY TO (エクスポート):**
```c
PGresult *res = PQexec(conn, "COPY users TO STDOUT");

if (PQresultStatus(res) == PGRES_COPY_OUT) {
    char *buffer;
    int ret;

    while ((ret = PQgetCopyData(conn, &buffer, 0)) > 0) {
        fwrite(buffer, 1, ret, stdout);
        PQfreemem(buffer);
    }
}

PQclear(res);
```

**COPY FROM (インポート):**
```c
PGresult *res = PQexec(conn, "COPY users FROM STDIN");

if (PQresultStatus(res) == PGRES_COPY_IN) {
    while (/* データがある */) {
        char *line = "1\tAlice\t30\n";
        if (PQputCopyData(conn, line, strlen(line)) != 1) {
            fprintf(stderr, "COPY failed\n");
            break;
        }
    }

    PQputCopyEnd(conn, NULL);  // 終了
}

PQclear(res);
```

### 11.2 psql (対話型クライアント)

#### 11.2.1 アーキテクチャ

```
┌────────────────────────────────┐
│ psql                           │
│  ├─ Readline (入力・履歴)    │
│  ├─ Command Processor         │
│  │   ├─ SQL Commands          │
│  │   └─ Meta Commands (\d等) │
│  ├─ libpq (通信)             │
│  └─ Output Formatter          │
└────────────────────────────────┘
```

#### 11.2.2 メタコマンド

**実装:**
- `\d`: システムカタログクエリ生成
- `\timing`: クライアントサイドタイマー
- `\copy`: クライアントサイドCOPY

**例: \d テーブル名**
```sql
-- psqlが内部で実行するクエリ (簡略版)
SELECT
    c.relname AS "Table",
    a.attname AS "Column",
    t.typname AS "Type"
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid
JOIN pg_type t ON t.oid = a.atttypid
WHERE c.relname = 'users'
  AND a.attnum > 0
ORDER BY a.attnum;
```

#### 11.2.3 出力フォーマット

**フォーマット種類:**
- `aligned`: デフォルト表形式
- `unaligned`: タブ区切り
- `html`: HTMLテーブル
- `json`: JSON配列
- `csv`: CSV形式

**設定:**
```sql
\pset format unaligned
\pset fieldsep ','
```

### 11.3 他言語ドライバ

#### 11.3.1 JDBC (Java)

**実装:** postgresql.jar

**接続:**
```java
Class.forName("org.postgresql.Driver");
Connection conn = DriverManager.getConnection(
    "jdbc:postgresql://localhost:5432/mydb",
    "postgres",
    "password"
);
```

**内部:**
- libpqプロトコルをJavaで再実装
- NIOベース (java.nio.channels)
- 接続プーリング対応

#### 11.3.2 psycopg2 (Python)

**C拡張モジュール**:
- libpqのPythonラッパー
- Cレベルで高速

```python
import psycopg2

conn = psycopg2.connect(
    host="localhost",
    database="mydb",
    user="postgres",
    password="password"
)

cur = conn.cursor()
cur.execute("SELECT * FROM users WHERE id = %s", (42,))
rows = cur.fetchall()
```

**非同期版 (psycopg3):**
```python
import asyncio
import psycopg

async def main():
    async with await psycopg.AsyncConnection.connect(
        "host=localhost dbname=mydb"
    ) as conn:
        async with conn.cursor() as cur:
            await cur.execute("SELECT * FROM users")
            async for row in cur:
                print(row)

asyncio.run(main())
```

#### 11.3.3 pgx (Go)

**Pure Go実装**:
- libpq不要
- goroutineフレンドリー

```go
package main

import (
    "context"
    "github.com/jackc/pgx/v5"
)

func main() {
    conn, _ := pgx.Connect(context.Background(),
        "postgres://postgres:password@localhost:5432/mydb")
    defer conn.Close(context.Background())

    var name string
    var age int
    conn.QueryRow(context.Background(),
        "SELECT name, age FROM users WHERE id = $1", 42).
        Scan(&name, &age)
}
```

**接続プール:**
```go
pool, _ := pgxpool.New(context.Background(),
    "postgres://localhost/mydb?pool_max_conns=10")
```

---

## 12. CPU・メモリ・ストレージの相互作用

### 12.1 CPU使用パターン

**ボトルネック分析:**

```
1. I/O待ち支配型:
   - Sequential Scan (大テーブル)
   - CPU使用率: 低い (< 30%)
   - 対策: インデックス、パーティション

2. CPU支配型:
   - 複雑な集約 (GROUP BY, DISTINCT)
   - 文字列操作、正規表現
   - CPU使用率: 高い (> 80%)
   - 対策: 並列クエリ、マテリアルビュー

3. ロック競合:
   - 高並行UPDATE
   - CPU使用率: 中程度、wait time高い
   - 対策: パーティション、行レベルロック
```

**SIMD最適化:**
- PostgreSQL 14+でAVX-512対応
- ビット演算、文字列比較の高速化

### 12.2 メモリ階層

```
┌─────────────────────┬──────────┬────────────┐
│ レベル              │ サイズ   │ レイテンシ │
├─────────────────────┼──────────┼────────────┤
│ L1キャッシュ        │ 32KB     │ 1ns        │
│ L2キャッシュ        │ 256KB    │ 3ns        │
│ L3キャッシュ        │ 8MB      │ 10ns       │
│ メインメモリ(RAM)   │ 64GB     │ 100ns      │
│ SSD                 │ 1TB      │ 100μs      │
│ HDD                 │ 10TB     │ 10ms       │
└─────────────────────┴──────────┴────────────┘

速度差: メモリ vs SSD = 1000倍
        メモリ vs HDD = 100,000倍
```

**最適化:**
- **Shared Buffers**: ホットデータをRAMに
- **OS Page Cache**: ファイルシステムキャッシュ活用
- **work_mem**: ソート・ハッシュをメモリ内で

### 12.3 ストレージI/O

**I/Oパターン:**

```
Sequential I/O:
  - Seq Scan, Index Build
  - HDD: 100-200 MB/s
  - SSD: 500-3000 MB/s

Random I/O:
  - Index Scan
  - HDD: 100-200 IOPS (深刻なボトルネック)
  - SSD: 10,000-100,000 IOPS
```

**I/Oスケジューリング:**
- Linux: `mq-deadline`, `none` (NVMe)
- `effective_io_concurrency`: SSD並列度

**Direct I/O (PostgreSQL 16+):**
- OSページキャッシュバイパス
- 大規模データベース向け

---

## 13. パフォーマンスチューニング実践

### 13.1 設定パラメータ

**メモリ:**
```conf
shared_buffers = 8GB              # システムRAMの25%
effective_cache_size = 24GB       # OSキャッシュ含む見積もり
work_mem = 64MB                   # ソート用 (接続数考慮)
maintenance_work_mem = 2GB        # VACUUM, INDEX用
```

**WAL:**
```conf
wal_buffers = 16MB                # -1で自動
wal_compression = on              # WAL圧縮
checkpoint_timeout = 15min        # チェックポイント間隔
checkpoint_completion_target = 0.9 # I/O分散
```

**クエリプランニング:**
```conf
random_page_cost = 1.1            # SSDなら低く
effective_io_concurrency = 200    # SSD並列度
default_statistics_target = 100   # 統計精度
```

**並列化:**
```conf
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_worker_processes = 8
```

### 13.2 インデックス戦略

**基本原則:**
```sql
-- 1. WHERE句の列
CREATE INDEX ON orders (customer_id);

-- 2. JOIN列
CREATE INDEX ON order_items (order_id);

-- 3. 複合インデックス (選択率順)
CREATE INDEX ON users (status, created_at);  -- status高選択率

-- 4. カバリングインデックス
CREATE INDEX ON users (email) INCLUDE (name, created_at);
```

**避けるべき:**
```sql
-- 関数適用 (インデックス使えない)
SELECT * FROM users WHERE LOWER(email) = 'test@example.com';

-- 改善: 関数インデックス
CREATE INDEX ON users (LOWER(email));

-- または: Generated Column (PostgreSQL 12+)
ALTER TABLE users ADD COLUMN email_lower TEXT GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX ON users (email_lower);
```

### 13.3 クエリ最適化

**EXPLAIN ANALYZE:**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING)
SELECT * FROM orders WHERE customer_id = 123;

-- 注目ポイント:
-- 1. Actual time vs Estimated rows (精度)
-- 2. Shared Hit vs Read (キャッシュ効率)
-- 3. Filter rows removed (無駄なフィルタ)
```

**Common Table Expression (CTE) 最適化:**
```sql
-- PostgreSQL 12+: CTE inline化
WITH recent_orders AS MATERIALIZED (  -- 強制materialize
    SELECT * FROM orders WHERE created_at > NOW() - INTERVAL '1 day'
)
SELECT * FROM recent_orders WHERE status = 'pending';
```

### 13.4 VACUUM戦略

**定期的なVACUUM:**
```sql
-- 手動実行
VACUUM (VERBOSE, ANALYZE) users;

-- パラレルVACUUM (PostgreSQL 13+)
VACUUM (PARALLEL 4) large_table;
```

**Autovacuum調整:**
```conf
autovacuum_max_workers = 4
autovacuum_naptime = 30s                    # スキャン頻度
autovacuum_vacuum_scale_factor = 0.1        # 更新10%でVACUUM
autovacuum_analyze_scale_factor = 0.05      # 更新5%でANALYZE
```

**テーブル単位設定:**
```sql
ALTER TABLE high_update_table SET (
    autovacuum_vacuum_scale_factor = 0.02,  -- より頻繁に
    autovacuum_analyze_scale_factor = 0.01
);
```

---

## 14. まとめ

PostgreSQLは以下の技術原理により高性能・高信頼性を実現しています:

1. **プロセスアーキテクチャ**: 安定性とセキュリティ
2. **MVCC**: 高並行性トランザクション
3. **WAL**: クラッシュリカバリと高性能書き込み
4. **多様なインデックス**: 用途別最適化
5. **高度なプランナー**: コストベース最適化
6. **拡張性**: カスタムデータ型・インデックス・関数

**低レベル技術:**
- CPU: SIMD、並列処理
- メモリ: 多層キャッシュ、共有メモリ
- ストレージ: ページ管理、I/O最適化
- ネットワーク: 効率的なバイナリプロトコル

**最新機能 (v18):**
- インクリメンタルバックアップ
- I/O並列性向上
- JSON強化
- 論理レプリケーション改善

これらの技術が統合され、エンタープライズグレードのRDBMSとして機能しています。

---

## 参考資料

- PostgreSQL公式ドキュメント: https://www.postgresql.org/docs/
- ソースコード: https://git.postgresql.org/gitweb/?p=postgresql.git
- 『The Internals of PostgreSQL』: https://www.interdb.jp/pg/
- PGCon, PostgresConf等の技術カンファレンス資料

---

**作成日**: 2025年
**対象バージョン**: PostgreSQL 18 (Beta/RC)
