-- Establish nonempty GTID history before each captured file family begins.
USE moonbinlog_fixture;
BEGIN;
INSERT INTO sample VALUES (50, '"history seed"');
COMMIT;
