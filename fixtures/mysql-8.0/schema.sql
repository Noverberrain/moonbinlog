-- Copyright 2026 Noverberrain.
-- SPDX-License-Identifier: Apache-2.0
CREATE DATABASE moonbinlog_fixture CHARACTER SET utf8mb4;
CREATE TABLE moonbinlog_fixture.sample (
  id INT PRIMARY KEY,
  tiny_value TINYINT,
  small_value SMALLINT,
  medium_value MEDIUMINT,
  big_value BIGINT UNSIGNED,
  text_value VARCHAR(100),
  blob_value BLOB,
  decimal_value DECIMAL(20,6),
  date_value DATE,
  year_value YEAR,
  datetime_value DATETIME(6),
  time_value TIME(6),
  timestamp_value TIMESTAMP(6) NULL,
  float_value FLOAT,
  double_value DOUBLE,
  bit_value BIT(9),
  enum_value ENUM('red','green','blue'),
  set_value SET('a','b','c'),
  binary_value VARBINARY(16),
  char_value CHAR(8)
) ENGINE=InnoDB;
