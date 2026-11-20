-- Run as the application table owner AFTER Backend Flyway migrations.
-- psql reads the password from the environment, not a checked-in credential.
\set ON_ERROR_STOP on
\getenv cdc_password CDC_DATABASE_PASSWORD
SELECT 'CREATE ROLE catalog_cdc LOGIN REPLICATION'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'catalog_cdc') \gexec
ALTER ROLE catalog_cdc LOGIN REPLICATION PASSWORD :'cdc_password';
SELECT format('GRANT CONNECT ON DATABASE %I TO catalog_cdc', current_database()) \gexec
GRANT USAGE ON SCHEMA public TO catalog_cdc;
GRANT SELECT ON public.event_outbox TO catalog_cdc;
-- Restrict at publication AND connector levels. Never publish all tables.
SELECT 'CREATE PUBLICATION core_catalog_outbox FOR TABLE public.event_outbox WITH (publish = ''insert'')'
WHERE NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'core_catalog_outbox') \gexec
ALTER PUBLICATION core_catalog_outbox SET TABLE public.event_outbox;
ALTER PUBLICATION core_catalog_outbox SET (publish = 'insert');
