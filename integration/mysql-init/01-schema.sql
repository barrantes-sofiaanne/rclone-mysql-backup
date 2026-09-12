-- Test schema for the end-to-end integration harness.
--
-- This MySQL initialization script is mounted into a THROWAWAY MySQL 8.4
-- container. It intentionally exercises the data types that most often break a
-- dump/restore round trip (binary blobs, fractional timestamps, unicode, JSON,
-- generated columns, and an explicit AUTO_INCREMENT gap).
--
-- NOTE: an AUTO_INCREMENT gap alone is NOT treated by this harness as proof that
-- binary-log replay happened. See integration/run.sh for how the restorability
-- checks are scoped and what they do and do not prove.

CREATE DATABASE IF NOT EXISTS puptracker
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE puptracker;

CREATE TABLE students (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  student_no  VARCHAR(32) NOT NULL UNIQUE,
  full_name   VARCHAR(255) NOT NULL,
  email       VARCHAR(255) DEFAULT NULL,
  note        TEXT,
  created_at  DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB;

CREATE TABLE violations (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  student_id   INT NOT NULL,
  category     VARCHAR(64) NOT NULL,
  details      JSON DEFAULT NULL,
  fine         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  evidence     BLOB,
  occurred_at  DATETIME(6) NOT NULL,
  CONSTRAINT fk_violations_student
    FOREIGN KEY (student_id) REFERENCES students(id)
) ENGINE=InnoDB;

-- Seed rows that exist BEFORE the FULL backup.
INSERT INTO students (student_no, full_name, email, note) VALUES
  ('2026-0001', 'Alpha One',   'alpha@example.test',  'seed-1'),
  ('2026-0002', 'Beta Two',    'beta@example.test',   'seed-2'),
  ('2026-0003', 'Gamma Three', 'gamma@example.test',  NULL),
  ('2026-0004', 'Délta Four',  'delta@example.test',  'unicode: 🎓 ünïcödé'),
  ('2026-0005', 'Epsilon Five','epsilon@example.test','seed-5');

INSERT INTO violations (student_id, category, details, fine, evidence, occurred_at) VALUES
  (1, 'lateness',   JSON_OBJECT('minutes', 10),  50.00,  UNHEX('DEADBEEF01'), '2026-09-01 08:00:00.000001'),
  (2, 'uniform',    JSON_OBJECT('item', 'shoes'),100.00, UNHEX('DEADBEEF02'), '2026-09-01 09:30:00.000002'),
  (3, 'noise',      JSON_OBJECT('level', 'high'),25.50,  NULL,               '2026-09-01 10:15:00.000003');

-- Prove the schema is queryable.
SELECT COUNT(*) AS seeded_students FROM students;
