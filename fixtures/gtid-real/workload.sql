USE moonbinlog_fixture;
SET SESSION binlog_row_value_options='';
BEGIN;
INSERT INTO sample VALUES
  (1, '{"u":18446744073709551615,"i":-9223372036854775808,"f":1.5,"s":"中文","n":null,"a":[true,false,{"z":"x"}]}'),
  (2, NULL),
  (3, 'null');
COMMIT;
BEGIN;
UPDATE sample SET text_value='["更新",null,18446744073709551615,-9223372036854775808,1.25]' WHERE id=1;
COMMIT;
BEGIN;
INSERT INTO sample VALUES (99, 'false');
ROLLBACK;
BEGIN;
DELETE FROM sample WHERE id IN (1, 3);
COMMIT;
