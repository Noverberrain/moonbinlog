-- Only for the disposable instance created by capture_mysql_fixtures.py.
CREATE DATABASE moonbinlog_fixture CHARACTER SET utf8mb4;
USE moonbinlog_fixture;
CREATE TABLE sample (
  id INT NOT NULL PRIMARY KEY,
  text_value JSON NULL
) ENGINE=InnoDB;
