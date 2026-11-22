#!/usr/bin/env bash
# Создать итоговый архив только после успешного восстановления и проверки.
set -euo pipefail

FOOD_CHECKS_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOOD_PROJECT_DIR="$(cd -- "$FOOD_CHECKS_DIR/../.." && pwd)"
cd -- "$FOOD_PROJECT_DIR"
FOOD_PG_ROOT="$(brew --prefix postgresql@18)"
FOOD_SOURCE_DB=foodexpress_3nf_check
FOOD_RESTORE_DB=foodexpress_final_restore_check

test -s db/foodexpress_lisanov.backup
shasum -a 256 -c db/SHA256SUMS

# Уже существующая целевая база останавливает сценарий, удаления здесь нет.
"$FOOD_PG_ROOT/bin/createdb" \
  -h localhost -p 5432 -U aleksandr --template=template0 "$FOOD_RESTORE_DB"

FOOD_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/foodexpress-verify.XXXXXX")"
FOOD_NEW_BACKUP=""
trap 'if [ -n "$FOOD_NEW_BACKUP" ]; then rm -f -- "$FOOD_NEW_BACKUP"; fi; rm -rf -- "$FOOD_WORK_DIR"' EXIT
FOOD_NEW_BACKUP="$(mktemp "$FOOD_PROJECT_DIR/db/foodexpress-checked.XXXXXX")"

"$FOOD_PG_ROOT/bin/psql" -X -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_SOURCE_DB" \
  -f db/checks/assert_normalized.sql

"$FOOD_PG_ROOT/bin/psql" -X -qAt -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_SOURCE_DB" \
  -f db/checks/data_fingerprints.sql > "$FOOD_WORK_DIR/source.txt"

"$FOOD_PG_ROOT/bin/pg_dump" \
  -h localhost -p 5432 -U inspector -W -d "$FOOD_SOURCE_DB" \
  -Fc -n lisanov_food --no-acl -f "$FOOD_NEW_BACKUP"

"$FOOD_PG_ROOT/bin/psql" -X -qAt -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_SOURCE_DB" \
  -f db/checks/data_fingerprints.sql > "$FOOD_WORK_DIR/source-after-dump.txt"
diff -u "$FOOD_WORK_DIR/source.txt" "$FOOD_WORK_DIR/source-after-dump.txt"

"$FOOD_PG_ROOT/bin/psql" -X -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_RESTORE_DB" \
  -c 'CREATE SCHEMA exts; CREATE EXTENSION "uuid-ossp" WITH SCHEMA exts;'

"$FOOD_PG_ROOT/bin/pg_restore" \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_RESTORE_DB" \
  --no-owner --no-acl --exit-on-error --single-transaction "$FOOD_NEW_BACKUP"

# Временная копия использует существующего inspector, его пароль не меняется.
"$FOOD_PG_ROOT/bin/psql" -X -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_RESTORE_DB" \
  -f db/checks/grants_restore_check.sql -f db/checks/assert_normalized.sql

"$FOOD_PG_ROOT/bin/psql" -X -qAt -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_RESTORE_DB" \
  -f db/checks/data_fingerprints.sql > "$FOOD_WORK_DIR/restored.txt"
diff -u "$FOOD_WORK_DIR/source.txt" "$FOOD_WORK_DIR/restored.txt"

"$FOOD_PG_ROOT/bin/psql" -X -v ON_ERROR_STOP=1 -P pager=off \
  -h localhost -p 5432 -U inspector -W -d "$FOOD_RESTORE_DB" \
  -f db/checks/verify_restore.sql | tee "$FOOD_WORK_DIR/inspector-check.txt"

"$FOOD_PG_ROOT/bin/psql" -X -qAt -v ON_ERROR_STOP=1 \
  -h localhost -p 5432 -U aleksandr -d "$FOOD_RESTORE_DB" \
  -f db/checks/data_fingerprints.sql > "$FOOD_WORK_DIR/after-check.txt"
diff -u "$FOOD_WORK_DIR/restored.txt" "$FOOD_WORK_DIR/after-check.txt"

# Старый архив сохраняется вне репозитория до замены файла для сдачи.
FOOD_HISTORY_DIR="$(mktemp -d "$HOME/Downloads/foodexpress-backup-before-3nf.XXXXXX")"
cp -p db/foodexpress_lisanov.backup "$FOOD_HISTORY_DIR/foodexpress_lisanov.backup"
mv -f -- "$FOOD_NEW_BACKUP" db/foodexpress_lisanov.backup
FOOD_NEW_BACKUP=""

{
  date '+Проверено: %Y-%m-%d %H:%M:%S %z'
  "$FOOD_PG_ROOT/bin/pg_dump" --version
  printf 'Исходная база: %s\nВосстановленная база: %s\n' "$FOOD_SOURCE_DB" "$FOOD_RESTORE_DB"
  printf 'Структура после нормализации: OK\n'
  printf 'Отпечатки всех таблиц: источник = восстановление = после ROLLBACK\n'
  shasum -a 256 db/foodexpress_lisanov.backup
  cat "$FOOD_WORK_DIR/restored.txt"
  cat "$FOOD_WORK_DIR/inspector-check.txt"
} > db/checks/last_backup_verification.txt

printf '\nИтоговый архив проверен: db/foodexpress_lisanov.backup\n'
printf 'Восстановление и проверка inspector: OK\n'
printf 'Отпечатки данных всех таблиц до/после проверки: совпадают\n'
printf 'Прежний архив сохранён: %s/foodexpress_lisanov.backup\n' "$FOOD_HISTORY_DIR"
shasum -a 256 db/foodexpress_lisanov.backup
