-- Read-only diagnostics. wal_status='lost' / invalidation_reason require recovery.
SELECT slot_name, database, plugin, active, restart_lsn, confirmed_flush_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint AS retained_wal_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)::bigint AS unconfirmed_bytes,
       wal_status, safe_wal_size
FROM pg_replication_slots WHERE slot_name = 'core_catalog_outbox';
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate
FROM pg_publication WHERE pubname = 'core_catalog_outbox';
SELECT schemaname, tablename FROM pg_publication_tables
WHERE pubname = 'core_catalog_outbox';
SELECT count(*) AS catalog_rows, min(created_at) AS oldest_catalog_row,
       max(created_at) AS newest_catalog_row,
       count(*) FILTER (WHERE published_at IS NULL) AS relay_unmarked_rows
FROM public.event_outbox WHERE topic = 'commerce.catalog.snapshots.v1';
