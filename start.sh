#!/bin/bash

# PostgreSQL ハンズオン環境 起動スクリプト

echo "=========================================="
echo "PostgreSQL ハンズオン環境を起動します"
echo "=========================================="

# Docker Composeで起動
docker-compose up -d

echo ""
echo "起動中..."
sleep 3

# ヘルスチェック
echo ""
echo "PostgreSQL接続確認中..."
for i in {1..30}; do
    if docker exec postgres-demo pg_isready -U postgres > /dev/null 2>&1; then
        echo "✓ PostgreSQLが起動しました"
        break
    fi
    echo -n "."
    sleep 1
done

echo ""
echo "=========================================="
echo "環境情報"
echo "=========================================="
echo "PostgreSQL: localhost:5432"
echo "  ユーザー: postgres"
echo "  パスワード: postgres"
echo "  データベース: demo"
echo ""
echo "pgAdmin: http://localhost:8080"
echo "  Email: admin@example.com"
echo "  Password: admin"
echo ""
echo "=========================================="
echo "接続方法"
echo "=========================================="
echo "1. psqlで接続:"
echo "   docker exec -it postgres-demo psql -U postgres -d demo"
echo ""
echo "2. ハンズオン実行:"
echo "   docker exec -it postgres-demo psql -U postgres -d demo -f /hands-on/01-indexes.sql"
echo ""
echo "3. ログ確認:"
echo "   docker logs postgres-demo -f"
echo ""
echo "=========================================="
echo "✅ 準備完了！ハンズオンを開始できます"
echo "=========================================="
