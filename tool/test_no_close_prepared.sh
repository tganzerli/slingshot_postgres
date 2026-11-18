#!/usr/bin/env bash
# Runs the statement cache and batch suites against a build with
# SLINGSHOT_NO_CLOSE_PREPARED: the DEALLOCATE fallback that a libpq older than
# 17 (no PQsendClosePrepared) takes. The default build on a libpq >= 17 host
# never exercises it. Needs the dev Postgres, like the suite itself.
#
#   packages/slingshot_postgres/tool/test_no_close_prepared.sh [dart test args]
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
cmake -S native -B "$out" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS=-DSLINGSHOT_NO_CLOSE_PREPARED >/dev/null
cmake --build "$out" >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
lib="$out/libnative_db.so"
[ -f "$lib" ] || lib="$out/libnative_db.dylib"
# Capture first, filter after: under pipefail a failing `nm -D` (macOS) or a
# SIGPIPE from an early `grep -q` exit would hide the match.
syms="$({ nm -u "$lib"; nm -D -u "$lib"; } 2>/dev/null || true)"
if grep -q PQsendClosePrepared <<<"$syms"; then
  echo "fallback build still calls PQsendClosePrepared" >&2
  exit 1
fi
DART_DB_CONNECTOR_NATIVE_LIB_PATH="$lib" dart test test/prepared_statement_cache_test.dart \
  test/batch_test.dart "$@"
