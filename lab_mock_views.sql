-- LAB MOCK DATA FOR VIEWS AND SUBQUERIES
-- Small table created for demonstration in class/lab

DROP VIEW IF EXISTS v_student_admission;
DROP VIEW IF EXISTS v_student_overview;
DROP TABLE IF EXISTS admission_records;
DROP TABLE IF EXISTS students;

CREATE TABLE students (
    student_id   INTEGER PRIMARY KEY,
    student_name TEXT NOT NULL,
    department   TEXT NOT NULL,
    marks        INTEGER NOT NULL CHECK (marks BETWEEN 0 AND 100),
    fee_paid     INTEGER NOT NULL DEFAULT 0,
    status       TEXT NOT NULL DEFAULT 'ACTIVE'
);

CREATE TABLE admission_records (
    admission_id   INTEGER PRIMARY KEY,
    student_id     INTEGER UNIQUE,
    course         TEXT NOT NULL,
    seat_status    TEXT NOT NULL,
    FOREIGN KEY (student_id) REFERENCES students(student_id)
);

INSERT INTO students (student_id, student_name, department, marks, fee_paid, status) VALUES
(1, 'Aarav', 'CSE', 90, 25000, 'ACTIVE'),
(2, 'Ishita', 'ECE', 82, 22000, 'ACTIVE'),
(3, 'Rohan', 'MECH', 68, 18000, 'PENDING'),
(4, 'Meera', 'CSE', 95, 30000, 'ACTIVE'),
(5, 'Karan', 'IT', 74, 20000, 'ACTIVE'),
(6, 'Sana', 'ECE', 86, 24000, 'ACTIVE');

INSERT INTO admission_records (admission_id, student_id, course, seat_status) VALUES
(101, 1, 'B.Tech CSE', 'CONFIRMED'),
(102, 2, 'B.Tech ECE', 'CONFIRMED'),
(103, 4, 'B.Tech CSE', 'WAITLISTED'),
(104, 6, 'B.Tech ECE', 'CONFIRMED');

-- 1) Create view from a single table
CREATE VIEW v_student_overview AS
SELECT student_id, student_name, department, marks, fee_paid, status
FROM students;

CREATE TRIGGER trg_v_student_overview_ins
INSTEAD OF INSERT ON v_student_overview
BEGIN
    INSERT INTO students (student_id, student_name, department, marks, fee_paid, status)
    VALUES (NEW.student_id, NEW.student_name, NEW.department, NEW.marks, COALESCE(NEW.fee_paid, 0), COALESCE(NEW.status, 'ACTIVE'));
END;

CREATE TRIGGER trg_v_student_overview_upd
INSTEAD OF UPDATE ON v_student_overview
BEGIN
    UPDATE students
    SET student_name = NEW.student_name,
        department = NEW.department,
        marks = NEW.marks,
        fee_paid = COALESCE(NEW.fee_paid, fee_paid),
        status = COALESCE(NEW.status, status)
    WHERE student_id = OLD.student_id;
END;

CREATE TRIGGER trg_v_student_overview_del
INSTEAD OF DELETE ON v_student_overview
BEGIN
    DELETE FROM students
    WHERE student_id = OLD.student_id;
END;

-- 2) Create view from multiple tables
CREATE VIEW v_student_admission AS
SELECT s.student_id,
       s.student_name,
       s.department,
       a.course,
       a.seat_status
FROM students s
LEFT JOIN admission_records a
    ON s.student_id = a.student_id;

-- 3) Display rows from single-table view
SELECT *
FROM v_student_overview;

-- 4) Display rows from multi-table view
SELECT *
FROM v_student_admission;

-- 5) Insert values into the view
INSERT INTO v_student_overview (student_id, student_name, department, marks, status)
VALUES (7, 'Riya', 'CSE', 88, 'ACTIVE');

-- 6) Update values in the view
UPDATE v_student_overview
SET marks = 92
WHERE student_id = 2;

-- 7) Delete values from the view
DELETE FROM v_student_overview
WHERE student_id = 7;

-- 8) Show the result after insert/update/delete
SELECT *
FROM v_student_overview
ORDER BY student_id;

-- ==========================================================
-- 5 EXAMPLES OF SINGLE-ROW SUBQUERIES
-- ==========================================================
SELECT student_name, marks
FROM students
WHERE marks = (SELECT MAX(marks) FROM students);

SELECT student_name, fee_paid
FROM students
WHERE fee_paid = (SELECT MAX(fee_paid) FROM students);

SELECT student_name, department
FROM students
WHERE student_id = (SELECT MIN(student_id) FROM students);

SELECT student_name, marks
FROM students
WHERE marks > (SELECT AVG(marks) FROM students);

SELECT student_name, department
FROM students
WHERE fee_paid = (SELECT MIN(fee_paid) FROM students WHERE status = 'ACTIVE');

-- ==========================================================
-- 5 EXAMPLES OF MULTI-ROW SUBQUERIES
-- ==========================================================
SELECT student_name, department
FROM students
WHERE student_id IN (SELECT student_id FROM admission_records);

SELECT student_name, department
FROM students
WHERE department IN (
    SELECT department
    FROM students
    WHERE marks >= 85
);

SELECT student_name, status
FROM students
WHERE student_id NOT IN (SELECT student_id FROM admission_records);

SELECT student_name, department
FROM students
WHERE student_id IN (
    SELECT student_id
    FROM students
    WHERE status = 'ACTIVE'
    ORDER BY marks DESC
    LIMIT 3
);

SELECT student_name, marks
FROM students
WHERE department IN (
    SELECT department
    FROM students
    GROUP BY department
    HAVING COUNT(*) >= 2
);

-- ==========================================================
-- 5 EXAMPLES OF CORRELATED SUBQUERIES
-- ==========================================================
SELECT s.student_name, s.marks
FROM students s
WHERE s.marks > (
    SELECT AVG(marks)
    FROM students
    WHERE department = s.department
);

SELECT s.student_name, s.fee_paid
FROM students s
WHERE s.fee_paid > (
    SELECT AVG(fee_paid)
    FROM students
    WHERE department = s.department
);

SELECT s.student_name, s.marks
FROM students s
WHERE s.marks = (
    SELECT MAX(marks)
    FROM students
    WHERE department = s.department
);

SELECT s.student_name
FROM students s
WHERE EXISTS (
    SELECT 1
    FROM admission_records a
    WHERE a.student_id = s.student_id
);

SELECT s.student_name, s.fee_paid
FROM students s
WHERE s.fee_paid = (
    SELECT MAX(fee_paid)
    FROM students
    WHERE department = s.department
);

-- DROP the views at end of demo if needed
DROP VIEW v_student_admission;
DROP VIEW v_student_overview;
