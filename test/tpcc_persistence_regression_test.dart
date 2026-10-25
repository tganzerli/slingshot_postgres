/// Regression guard for a pipeline-exit rollback bug — the native PG pipeline primitive
/// must NOT force-rollback a *healthy* open transaction (`PQTRANS_INTRANS`)
/// on pipeline exit; only an *aborted* one (`PQTRANS_INERROR`) is rolled
/// back (native pool worker).
///
/// Before that fix the primitive rolled back on `INTRANS || INERROR`, so an
/// `executePipeline` batch running inside an external `withTransaction` had
/// its writes silently discarded (the outer COMMIT hit an already-clean
/// connection). That is exactly the shape the TPC-C benchmark consumer
/// uses, and the bug went
/// unnoticed for weeks: TPC-C ran "green" while `orders`/`new_order`/
/// `order_line` stayed empty. If the condition ever reverts to
/// `INTRANS || INERROR`, every PG test in this file goes RED with zero
/// persisted rows.
///
/// Coverage vs. `pipeline_test.dart`: that file pins the primitive with a
/// trivial 2-row INSERT read back on the *same* pooled connection. This
/// file adds (1) the real TPC-C write-set (NewOrder + Payment + Delivery,
/// mixed INSERT/UPDATE/DELETE with FKs) and (2) the multi-batch shape
/// (several `executePipeline` calls inside one transaction — the Delivery
/// pattern) — both asserted on a *brand-new* connection.
///
/// MySQL/SQLite N/A: their `executeBatch` workers
/// (`native/c/src/mysql_pool_worker.c:73`, `sqlite_pool_worker.c:172`)
/// contain no transaction-control statements, so this regression class
/// cannot occur there. Positive composition is covered by
/// `mysql_batch_test.dart:72` and `sqlite/sqlite_driver_test.dart`.
///
/// No CI exists in this repo, so this guard is enforced only by a local
/// `dart test` with a reachable Postgres. A silent skip (native lib not
/// built / Postgres down) means the guard is inactive — same limitation as
/// every other PG integration test here.
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

import 'dart:ffi' as ffi;

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

PostgresBinding _binding() {
  final b = PostgresBinding(loadNativeDb());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);
  return b;
}

Future<PostgresConnectionPool> _freshPool(PostgresBinding b) async {
  final pool = PostgresConnectionPool.withBinding(
    b,
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
  );
  await pool.start();
  return pool;
}

/// Reads [sql] (which must return a single int column aliased `n`) on a
/// BRAND-NEW pool — a connection opened AFTER the writes committed. A
/// same-session read could mask a discarded commit; opening a fresh pool
/// makes the guard honest about post-COMMIT durability.
Future<int> _countOnFreshConnection(PostgresBinding b, String sql) async {
  final pool = await _freshPool(b);
  try {
    return await withTransaction(pool, (exec) async {
      final rs = await exec.execute(sql);
      final v = rs.row(0).getInt('n')!;
      rs.release();
      return v;
    });
  } finally {
    await pool.close();
  }
}

/// Runs [statements] one at a time via the plain Simple-query path (never
/// the pipeline primitive under test) inside a single transaction.
Future<void> _runAll(
    PostgresConnectionPool pool, List<String> statements) async {
  await withTransaction(pool, (exec) async {
    for (final s in statements) {
      (await exec.execute(s)).release();
    }
  });
}

/// Reduced TPC-C DDL (mirrors the benchmark fixture schema, minus
/// the indexes) created inside a dedicated `tpcc_guard` schema so the test
/// never touches the benchmark seed in `public`. Unqualified names resolve
/// via `search_path`, keeping the SQL identical in shape to the real
/// consumer.
const _ddl = <String>[
  'CREATE TABLE warehouse ('
      'w_id int4 PRIMARY KEY, w_name varchar(10) NOT NULL, '
      'w_street varchar(40) NOT NULL, w_city varchar(20) NOT NULL, '
      'w_state char(2) NOT NULL, w_zip char(9) NOT NULL, '
      'w_tax numeric(4,4) NOT NULL, w_ytd numeric(12,2) NOT NULL)',
  'CREATE TABLE district ('
      'd_w_id int4 NOT NULL, d_id int4 NOT NULL, d_name varchar(10) NOT NULL, '
      'd_street varchar(40) NOT NULL, d_city varchar(20) NOT NULL, '
      'd_state char(2) NOT NULL, d_zip char(9) NOT NULL, '
      'd_tax numeric(4,4) NOT NULL, d_ytd numeric(12,2) NOT NULL, '
      'd_next_o_id int4 NOT NULL, PRIMARY KEY (d_w_id, d_id), '
      'FOREIGN KEY (d_w_id) REFERENCES warehouse(w_id))',
  'CREATE TABLE customer ('
      'c_w_id int4 NOT NULL, c_d_id int4 NOT NULL, c_id int4 NOT NULL, '
      'c_first varchar(16) NOT NULL, c_middle char(2) NOT NULL, '
      'c_last varchar(16) NOT NULL, c_street varchar(40) NOT NULL, '
      'c_city varchar(20) NOT NULL, c_state char(2) NOT NULL, '
      'c_zip char(9) NOT NULL, c_since timestamptz NOT NULL, '
      'c_credit char(2) NOT NULL, c_credit_lim numeric(12,2) NOT NULL, '
      'c_discount numeric(4,4) NOT NULL, c_balance numeric(12,2) NOT NULL, '
      'c_ytd_payment numeric(12,2) NOT NULL, c_payment_cnt int4 NOT NULL, '
      'c_delivery_cnt int4 NOT NULL, PRIMARY KEY (c_w_id, c_d_id, c_id), '
      'FOREIGN KEY (c_w_id, c_d_id) REFERENCES district(d_w_id, d_id))',
  'CREATE TABLE history ('
      'h_c_id int4 NOT NULL, h_c_d_id int4 NOT NULL, h_c_w_id int4 NOT NULL, '
      'h_d_id int4 NOT NULL, h_w_id int4 NOT NULL, h_date timestamptz NOT NULL, '
      'h_amount numeric(6,2) NOT NULL, h_data varchar(24) NOT NULL)',
  'CREATE TABLE orders ('
      'o_w_id int4 NOT NULL, o_d_id int4 NOT NULL, o_id int4 NOT NULL, '
      'o_c_id int4 NOT NULL, o_entry_d timestamptz NOT NULL, '
      'o_carrier_id int4, o_ol_cnt int4 NOT NULL, o_all_local int4 NOT NULL, '
      'PRIMARY KEY (o_w_id, o_d_id, o_id), '
      'FOREIGN KEY (o_w_id, o_d_id, o_c_id) '
      'REFERENCES customer(c_w_id, c_d_id, c_id))',
  'CREATE TABLE new_order ('
      'no_w_id int4 NOT NULL, no_d_id int4 NOT NULL, no_o_id int4 NOT NULL, '
      'PRIMARY KEY (no_w_id, no_d_id, no_o_id), '
      'FOREIGN KEY (no_w_id, no_d_id, no_o_id) '
      'REFERENCES orders(o_w_id, o_d_id, o_id))',
  'CREATE TABLE order_line ('
      'ol_w_id int4 NOT NULL, ol_d_id int4 NOT NULL, ol_o_id int4 NOT NULL, '
      'ol_number int4 NOT NULL, ol_i_id int4 NOT NULL, '
      'ol_supply_w_id int4 NOT NULL, ol_delivery_d timestamptz, '
      'ol_quantity int4 NOT NULL, ol_amount numeric(6,2) NOT NULL, '
      'ol_dist_info char(24) NOT NULL, '
      'PRIMARY KEY (ol_w_id, ol_d_id, ol_o_id, ol_number), '
      'FOREIGN KEY (ol_w_id, ol_d_id, ol_o_id) '
      'REFERENCES orders(o_w_id, o_d_id, o_id))',
  'CREATE TABLE item ('
      'i_id int4 PRIMARY KEY, i_im_id int4 NOT NULL, i_name varchar(24) NOT NULL, '
      'i_price numeric(5,2) NOT NULL, i_data varchar(50) NOT NULL)',
  'CREATE TABLE stock ('
      's_w_id int4 NOT NULL, s_i_id int4 NOT NULL, s_quantity int4 NOT NULL, '
      's_dist_info char(24) NOT NULL, s_ytd numeric(8,0) NOT NULL, '
      's_order_cnt int4 NOT NULL, s_remote_cnt int4 NOT NULL, '
      'PRIMARY KEY (s_w_id, s_i_id), '
      'FOREIGN KEY (s_w_id) REFERENCES warehouse(w_id), '
      'FOREIGN KEY (s_i_id) REFERENCES item(i_id))',
];

/// Minimal FK-consistent seed (explicit column lists for robustness):
/// 1 warehouse, 1 district (next order id = 3001), 1 customer, 2 items,
/// 2 stocks. NEW_ORDER/ORDERS/ORDER_LINE/HISTORY start empty, as in the
/// real seed.
const _seed = <String>[
  'INSERT INTO warehouse (w_id,w_name,w_street,w_city,w_state,w_zip,w_tax,w_ytd) '
      "VALUES (1,'W1','St','City','SP','000000000',0.1000,0.00)",
  'INSERT INTO district '
      '(d_w_id,d_id,d_name,d_street,d_city,d_state,d_zip,d_tax,d_ytd,d_next_o_id) '
      "VALUES (1,1,'D1','St','City','SP','000000000',0.0500,0.00,3001)",
  'INSERT INTO customer '
      '(c_w_id,c_d_id,c_id,c_first,c_middle,c_last,c_street,c_city,c_state,'
      'c_zip,c_since,c_credit,c_credit_lim,c_discount,c_balance,c_ytd_payment,'
      'c_payment_cnt,c_delivery_cnt) '
      "VALUES (1,1,1,'First','OE','LAST','St','City','SP','000000000',NOW(),"
      "'GC',50000.00,0.1000,0.00,0.00,0,0)",
  'INSERT INTO item (i_id,i_im_id,i_name,i_price,i_data) '
      "VALUES (1,1,'item-1',9.99,'data')",
  'INSERT INTO item (i_id,i_im_id,i_name,i_price,i_data) '
      "VALUES (2,2,'item-2',4.50,'data')",
  'INSERT INTO stock '
      '(s_w_id,s_i_id,s_quantity,s_dist_info,s_ytd,s_order_cnt,s_remote_cnt) '
      "VALUES (1,1,50,'dist-info',0,0,0)",
  'INSERT INTO stock '
      '(s_w_id,s_i_id,s_quantity,s_dist_info,s_ytd,s_order_cnt,s_remote_cnt) '
      "VALUES (1,2,50,'dist-info',0,0,0)",
];

Future<void> _setupTpccGuardSchema(PostgresConnectionPool pool) async {
  await _runAll(pool, [
    'DROP SCHEMA IF EXISTS tpcc_guard CASCADE',
    'CREATE SCHEMA tpcc_guard',
    'SET LOCAL search_path TO tpcc_guard',
    ..._ddl,
    ..._seed,
  ]);
}

Future<void> _dropTpccGuardSchema(PostgresConnectionPool pool) async {
  await _runAll(pool, ['DROP SCHEMA IF EXISTS tpcc_guard CASCADE']);
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('TPC-C persistence regression guard', () {
    test(
        'real TPC-C write-set (NewOrder+Payment+Delivery) persists across '
        'fresh connections', () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _setupTpccGuardSchema(pool);

        // ── NewOrder (shape of transactions_native.dart:81-173) ──
        await withTransaction(pool, (exec) async {
          (await exec.execute('SET LOCAL search_path TO tpcc_guard')).release();
          final dRs = await exec.execute('SELECT d_next_o_id FROM district '
              'WHERE d_w_id=1 AND d_id=1 FOR UPDATE');
          final oId = dRs.row(0).getInt('d_next_o_id')!;
          dRs.release();

          await (exec as PostgresQueryExecutor).executePipeline([
            'UPDATE district SET d_next_o_id = d_next_o_id + 1 '
                'WHERE d_w_id=1 AND d_id=1',
            'INSERT INTO orders (o_w_id,o_d_id,o_id,o_c_id,o_entry_d,'
                'o_carrier_id,o_ol_cnt,o_all_local) '
                'VALUES (1,1,$oId,1,NOW(),NULL,2,1)',
            'INSERT INTO new_order (no_w_id,no_d_id,no_o_id) '
                'VALUES (1,1,$oId)',
            'UPDATE stock SET s_quantity=45, s_ytd=5, s_order_cnt=1, '
                's_remote_cnt=0 WHERE s_w_id=1 AND s_i_id=1',
            'INSERT INTO order_line (ol_w_id,ol_d_id,ol_o_id,ol_number,'
                'ol_i_id,ol_supply_w_id,ol_delivery_d,ol_quantity,ol_amount,'
                "ol_dist_info) VALUES (1,1,$oId,1,1,1,NULL,5,49.95,'dist-info')",
            'UPDATE stock SET s_quantity=47, s_ytd=3, s_order_cnt=1, '
                's_remote_cnt=0 WHERE s_w_id=1 AND s_i_id=2',
            'INSERT INTO order_line (ol_w_id,ol_d_id,ol_o_id,ol_number,'
                'ol_i_id,ol_supply_w_id,ol_delivery_d,ol_quantity,ol_amount,'
                "ol_dist_info) VALUES (1,1,$oId,2,2,1,NULL,3,13.50,'dist-info')",
          ]);
        });

        // Assert on a BRAND-NEW connection — the heart of criterion #1.
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM tpcc_guard.orders'),
            1,
            reason: 'NewOrder writes silently discarded — the pipeline exit '
                'rolled back a healthy transaction');
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM tpcc_guard.new_order'),
            1);
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM tpcc_guard.order_line'),
            2);
        expect(
            await _countOnFreshConnection(
                b,
                'SELECT d_next_o_id AS n FROM tpcc_guard.district '
                'WHERE d_w_id=1 AND d_id=1'),
            3002);

        // ── Payment (shape of transactions_native.dart:203-213) ──
        await withTransaction(pool, (exec) async {
          (await exec.execute('SET LOCAL search_path TO tpcc_guard')).release();
          await (exec as PostgresQueryExecutor).executePipeline([
            'UPDATE warehouse SET w_ytd = w_ytd + 100.00 WHERE w_id=1',
            'UPDATE district SET d_ytd = d_ytd + 100.00 '
                'WHERE d_w_id=1 AND d_id=1',
            'UPDATE customer SET c_balance = c_balance - 100.00, '
                'c_ytd_payment = c_ytd_payment + 100.00, '
                'c_payment_cnt = c_payment_cnt + 1 '
                'WHERE c_w_id=1 AND c_d_id=1 AND c_id=1',
            'INSERT INTO history (h_c_id,h_c_d_id,h_c_w_id,h_d_id,h_w_id,'
                "h_date,h_amount,h_data) VALUES (1,1,1,1,1,NOW(),100.00,'GUARD')",
          ]);
        });
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM tpcc_guard.history'),
            1);
        expect(
            await _countOnFreshConnection(
                b,
                'SELECT c_payment_cnt AS n FROM tpcc_guard.customer '
                'WHERE c_w_id=1 AND c_d_id=1 AND c_id=1'),
            1);

        // ── Delivery (shape of transactions_native.dart:247-297):
        //    read + executePipeline inside the SAME withTransaction ──
        await withTransaction(pool, (exec) async {
          (await exec.execute('SET LOCAL search_path TO tpcc_guard')).release();
          final noRs = await exec
              .execute('SELECT MIN(no_o_id) AS no_o_id FROM new_order '
                  'WHERE no_w_id=1 AND no_d_id=1');
          final oId = noRs.row(0).getInt('no_o_id')!;
          noRs.release();
          await (exec as PostgresQueryExecutor).executePipeline([
            'DELETE FROM new_order '
                'WHERE no_w_id=1 AND no_d_id=1 AND no_o_id=$oId',
            'UPDATE orders SET o_carrier_id=7 '
                'WHERE o_w_id=1 AND o_d_id=1 AND o_id=$oId',
            'UPDATE order_line SET ol_delivery_d=NOW() '
                'WHERE ol_w_id=1 AND ol_d_id=1 AND ol_o_id=$oId',
            'UPDATE customer SET c_balance = c_balance + 63.45, '
                'c_delivery_cnt = c_delivery_cnt + 1 '
                'WHERE c_w_id=1 AND c_d_id=1 AND c_id=1',
          ]);
        });
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM tpcc_guard.new_order'),
            0,
            reason: 'Delivery DELETE was rolled back');
        expect(
            await _countOnFreshConnection(
                b,
                'SELECT COUNT(*) AS n FROM tpcc_guard.orders '
                'WHERE o_carrier_id IS NOT NULL'),
            1);
        expect(
            await _countOnFreshConnection(
                b,
                'SELECT COUNT(*) AS n FROM tpcc_guard.order_line '
                'WHERE ol_delivery_d IS NOT NULL'),
            2);
      } finally {
        await _dropTpccGuardSchema(pool);
        await pool.close();
      }
    });

    test(
        'multiple executePipeline batches inside ONE withTransaction '
        '(Delivery-style) all persist', () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _runAll(pool, [
          'DROP TABLE IF EXISTS mbatch_guard',
          'CREATE TABLE mbatch_guard '
              '(id int4 PRIMARY KEY, v int4 NOT NULL, tag text)',
        ]);

        await withTransaction(pool, (exec) async {
          final p = exec as PostgresQueryExecutor;
          // Batch 1: INSERTs. If the regression rolls this back, batches
          // 2-3 run in autocommit over an empty table.
          await p.executePipeline([
            "INSERT INTO mbatch_guard VALUES (1, 10, 'a')",
            "INSERT INTO mbatch_guard VALUES (2, 20, 'b')",
            "INSERT INTO mbatch_guard VALUES (3, 30, 'c')",
          ]);
          // Batch 2: UPDATEs that depend on batch 1's rows.
          await p.executePipeline([
            'UPDATE mbatch_guard SET v = v + 1 WHERE id IN (1, 2)',
            "UPDATE mbatch_guard SET tag = 'delivered' WHERE id = 3",
          ]);
          // Batch 3: DELETE + INSERT.
          await p.executePipeline([
            'DELETE FROM mbatch_guard WHERE id = 2',
            "INSERT INTO mbatch_guard VALUES (4, 40, 'd')",
          ]);
        });

        // Assert final state on a BRAND-NEW connection.
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM mbatch_guard'),
            3);
        expect(
            await _countOnFreshConnection(
                b, 'SELECT v AS n FROM mbatch_guard WHERE id = 1'),
            11,
            reason: 'batch-2 UPDATE must see batch-1 rows within the same txn '
                'and survive the outer COMMIT');
        expect(
            await _countOnFreshConnection(
                b, 'SELECT COUNT(*) AS n FROM mbatch_guard WHERE id = 2'),
            0);
        expect(
            await _countOnFreshConnection(b,
                "SELECT COUNT(*) AS n FROM mbatch_guard WHERE tag = 'delivered'"),
            1);
      } finally {
        await _runAll(pool, ['DROP TABLE IF EXISTS mbatch_guard']);
        await pool.close();
      }
    });
  });
}
