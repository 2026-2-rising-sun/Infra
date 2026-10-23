-- Runs only when this Compose project's new PostgreSQL volume is initialized.
-- Existing local/docker-compose.yml and its databases are not mounted or modified.
CREATE DATABASE member;
CREATE DATABASE shopping;
CREATE DATABASE commerce;
CREATE DATABASE live;
