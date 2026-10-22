-- Copyright 2026 Noverberrain.
-- SPDX-License-Identifier: Apache-2.0
USE moonbinlog_fixture;
SET time_zone='+00:00';
BEGIN;
INSERT INTO sample VALUES
  (1,-128,32767,-8388608,18446744073709551615,'月兔',X'00FF0100',
   -12345678901234.123456,'2024-02-29',2024,'2024-02-29 12:34:56.123456',
   '-25:02:03.456789','2024-01-01 00:00:00.654321',1.5,-2.25,b'100000001',
   'green','a,c',X'0000FF','abc');
INSERT INTO sample(id) VALUES(2);
UPDATE sample SET text_value='更新',decimal_value=0.000001,bit_value=b'000000011' WHERE id=1;
DELETE FROM sample WHERE id=1;
COMMIT;
BEGIN;
INSERT INTO sample(id,text_value) VALUES(99,'rolled back');
ROLLBACK;
