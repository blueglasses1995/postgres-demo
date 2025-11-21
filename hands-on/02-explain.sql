-- ======================================================================
-- ハンズオン02: EXPLAIN ANALYZE の読み方
-- ======================================================================
-- 目的: EXPLAIN ANALYZEの出力を正しく読み、ボトルネックを特定する
-- 所要時間: 20分
-- ======================================================================

\echo '========================================'
\echo 'ハンズオン02: EXPLAIN ANALYZE'
\echo '========================================'

-- ======================================
-- セクション1: データ準備
-- ======================================

\echo '\n--- セクション1: サンプルデータ作成 ---'

DROP TABLE IF EXISTS employees CASCADE;
CREATE TABLE employees (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    department VARCHAR(50),
    salary INTEGER,
    hire_date DATE
);

INSERT INTO employees (name, department, salary, hire_date)
SELECT
    'Employee ' || i,
    (ARRAY['Sales', 'Engineering', 'Marketing', 'HR'])[1 + floor(random() * 4)::INTEGER],
    30000 + (random() * 70000)::INTEGER,
    DATE '2020-01-01' + (random() * 1000)::INTEGER
FROM generate_series(1, 100000) i;

ANALYZE employees;

\echo '✓ 10万件のデータ作成完了'

-- ======================================
-- セクション2: EXPLAIN の基本
-- ======================================

\echo '\n\n--- セクション2: EXPLAIN の基本 ---'

\echo '\n1. EXPLAIN のみ（推定値のみ）:'
EXPLAIN
SELECT * FROM employees WHERE department = 'Engineering';

\echo '\n💡 読み方:'
\echo '  - cost=0.00..X.XX'
\echo '    開始コスト..終了コスト（相対値）'
\echo '  - rows=XXXX'
\echo '    プランナーの推定行数'
\echo '  - width=XXX'
\echo '    1行あたりの平均バイト数'

-- ======================================
-- セクション3: EXPLAIN ANALYZE
-- ======================================

\echo '\n\n--- セクション3: EXPLAIN ANALYZE ---'

\echo '\n2. EXPLAIN ANALYZE（実測値付き）:'
EXPLAIN (ANALYZE, TIMING)
SELECT * FROM employees WHERE department = 'Engineering';

\echo '\n💡 実測値:'
\echo '  - actual time=X.XXX..Y.YYY'
\echo '    実際の開始時間..終了時間（ミリ秒）'
\echo '  - rows=XXXX'
\echo '    実際の行数'
\echo '  - loops=N'
\echo '    このノードが何回実行されたか'

-- ======================================
-- セクション4: BUFFERS オプション
-- ======================================

\echo '\n\n--- セクション4: BUFFERS オプション ---'

\echo '\n3. BUFFERS付き（I/O情報）:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees WHERE department = 'Engineering';

\echo '\n💡 バッファ情報:'
\echo '  - Buffers: shared hit=X read=Y'
\echo '    hit: キャッシュヒット'
\echo '    read: ディスクからの読み込み'
\echo '  - 理想: read=0（全てキャッシュヒット）'

-- もう一度実行（キャッシュされるはず）
\echo '\n4. 2回目の実行（キャッシュ効果）:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees WHERE department = 'Engineering';

-- ======================================
-- セクション5: ノードタイプの理解
-- ======================================

\echo '\n\n--- セクション5: 主要なノードタイプ ---'

-- Seq Scan
\echo '\n【Seq Scan】全テーブルスキャン:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT AVG(salary) FROM employees;

-- Index Scan
CREATE INDEX idx_employees_dept ON employees(department);

\echo '\n【Index Scan】インデックススキャン:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees WHERE department = 'Engineering';

-- Bitmap Scan
\echo '\n【Bitmap Scan】ビットマップスキャン:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees WHERE department IN ('Engineering', 'Sales');

-- Aggregate
\echo '\n【Aggregate】集約:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT department, COUNT(*), AVG(salary)
FROM employees
GROUP BY department;

-- Sort
\echo '\n【Sort】ソート:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM employees
ORDER BY salary DESC
LIMIT 10;

-- Nested Loop
DROP TABLE IF EXISTS projects;
CREATE TABLE projects (
    id SERIAL PRIMARY KEY,
    employee_id INTEGER REFERENCES employees(id),
    project_name VARCHAR(100)
);

INSERT INTO projects (employee_id, project_name)
SELECT
    (random() * 99999 + 1)::INTEGER,
    'Project ' || i
FROM generate_series(1, 1000) i;

\echo '\n【Nested Loop】ネステッドループ結合:'
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.name, p.project_name
FROM employees e
JOIN projects p ON e.id = p.employee_id
WHERE e.department = 'Engineering'
LIMIT 100;

-- ======================================
-- セクション6: VERBOSE オプション
-- ======================================

\echo '\n\n--- セクション6: VERBOSE オプション ---'

EXPLAIN (ANALYZE, VERBOSE, BUFFERS)
SELECT department, AVG(salary) as avg_salary
FROM employees
WHERE hire_date > '2022-01-01'
GROUP BY department
HAVING AVG(salary) > 50000;

\echo '\n💡 VERBOSE:'
\echo '  - Output: 各ノードの出力カラム'
\echo '  - Filter: フィルタ条件'
\echo '  - より詳細な情報'

-- ======================================
-- セクション7: 実測値 vs 推定値の比較
-- ======================================

\echo '\n\n--- セクション7: 推定精度の確認 ---'

\echo '\nケース1: 推定が正確:'
EXPLAIN (ANALYZE)
SELECT * FROM employees WHERE department = 'Engineering';

\echo '\nケース2: 統計情報が古い場合:'
-- 大量データ追加
INSERT INTO employees (name, department, salary, hire_date)
SELECT
    'New Employee ' || i,
    'Engineering',
    60000,
    DATE '2024-01-01'
FROM generate_series(1, 50000) i;

\echo '\n統計情報更新前（推定が外れる）:'
EXPLAIN (ANALYZE)
SELECT * FROM employees WHERE department = 'Engineering';

\echo '\n統計情報更新後:'
ANALYZE employees;
EXPLAIN (ANALYZE)
SELECT * FROM employees WHERE department = 'Engineering';

\echo '\n💡 推定値と実測値の乖離:'
\echo '  - 大きく外れている → ANALYZE実行'
\echo '  - statistics_target 調整も検討'

-- ======================================
-- セクション8: ボトルネックの特定
-- ======================================

\echo '\n\n--- セクション8: ボトルネック特定 ---'

-- 複雑なクエリ
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    e.department,
    COUNT(DISTINCT e.id) as employee_count,
    COUNT(p.id) as project_count,
    AVG(e.salary) as avg_salary
FROM employees e
LEFT JOIN projects p ON e.id = p.employee_id
WHERE e.hire_date > '2020-01-01'
GROUP BY e.department
HAVING COUNT(p.id) > 5
ORDER BY avg_salary DESC;

\echo '\n💡 ボトルネック特定のポイント:'
\echo '  1. 実行時間が長いノードを探す'
\echo '  2. rows推定と実測の乖離を確認'
\echo '  3. Buffers read（ディスクI/O）が多いか'
\echo '  4. Seq Scanが不要に使われていないか'
\echo '  5. ソート/ハッシュでメモリ不足していないか'

-- ======================================
-- セクション9: FORMAT オプション
-- ======================================

\echo '\n\n--- セクション9: 出力フォーマット ---'

\echo '\nJSON形式:'
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT department, AVG(salary)
FROM employees
GROUP BY department
LIMIT 3;

\echo '\nYAML形式:'
EXPLAIN (ANALYZE, FORMAT YAML)
SELECT department, AVG(salary)
FROM employees
GROUP BY department
LIMIT 3;

\echo '\n💡 JSON/YAML形式:'
\echo '  - プログラムで解析しやすい'
\echo '  - 監視ツールとの連携'

-- ======================================
-- セクション10: auto_explain拡張
-- ======================================

\echo '\n\n--- セクション10: auto_explain ---'

\echo '
auto_explain拡張:
- 自動的に遅いクエリのEXPLAINをログ出力
- postgresql.confに設定:

shared_preload_libraries = '\''auto_explain'\''
auto_explain.log_min_duration = 1000  # 1秒以上のクエリ
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_timing = on
auto_explain.log_nested_statements = on

- PostgreSQL再起動後に有効
- ログファイルに自動記録
'

-- ======================================
-- セクション11: まとめ
-- ======================================

\echo '\n\n========================================'
\echo 'まとめ'
\echo '========================================'
\echo '✓ EXPLAIN: 推定値のみ'
\echo '✓ EXPLAIN ANALYZE: 実測値付き（必ず使う）'
\echo '✓ BUFFERS: I/O統計（重要）'
\echo '✓ VERBOSE: 詳細情報'
\echo '✓ TIMING: 各ノードの実行時間'
\echo ''
\echo 'チェックポイント:'
\echo '  1. 実測rows vs 推定rows の乖離'
\echo '  2. Buffers read の数（多い=遅い）'
\echo '  3. Seq Scan vs Index Scan'
\echo '  4. ソート/ハッシュのメモリ使用'
\echo '  5. 最も時間がかかっているノード'
\echo ''
\echo '最適化の流れ:'
\echo '  1. EXPLAIN ANALYZEで分析'
\echo '  2. ボトルネック特定'
\echo '  3. インデックス追加またはクエリ書き換え'
\echo '  4. 再度EXPLAIN ANALYZEで効果確認'
\echo ''
\echo '📝 課題:'
\echo '  1. 遅いクエリを見つける'
\echo '  2. EXPLAIN ANALYZEで分析'
\echo '  3. インデックスを追加'
\echo '  4. 改善前後を比較'
\echo '========================================'

-- クリーンアップ
-- DROP TABLE IF EXISTS employees, projects CASCADE;
