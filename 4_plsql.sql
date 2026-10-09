
-- ============================================================
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- Script 4 of 5: PL/SQL
-- Run review.sql first; this script works on the database it builds.
-- Safe to re-run: every function is dropped before it is created.
--
-- PL/SQL is Oracle's language; MySQL's equivalent is a stored program,
-- so each item is a stored function built around one PL/SQL construct.
--
--   PL/SQL 1  fn_score_grade          IF / ELSEIF        letter grade for a score
--   PL/SQL 2  fn_category_concession  CASE statement     fee concession by category
--   PL/SQL 3  fn_working_days_left    WHILE loop         working days before a deadline
--   PL/SQL 4  fn_fee_balance          exception handler  fee balance, NULL if no record
--   PL/SQL 5  fn_merit_score          variables          70/30 merit score
-- ============================================================

USE admission_workflow_db;


-- PL/SQL 1: IF / ELSEIF -- letter grade for a score
DROP FUNCTION IF EXISTS fn_score_grade;
DELIMITER $$
CREATE FUNCTION fn_score_grade(p_score DECIMAL(6,2))
RETURNS VARCHAR(2)
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_grade VARCHAR(2);

    IF p_score >= 90 THEN
        SET v_grade = 'A+';
    ELSEIF p_score >= 80 THEN
        SET v_grade = 'A';
    ELSEIF p_score >= 70 THEN
        SET v_grade = 'B';
    ELSEIF p_score >= 60 THEN
        SET v_grade = 'C';
    ELSE
        SET v_grade = 'F';
    END IF;

    RETURN v_grade;
END$$
DELIMITER ;

SELECT first_name, last_name, jee_score, fn_score_grade(jee_score) AS grade
FROM Application_Master
ORDER BY jee_score DESC;


-- PL/SQL 2: CASE statement -- fee concession (%) by reservation category
DROP FUNCTION IF EXISTS fn_category_concession;
DELIMITER $$
CREATE FUNCTION fn_category_concession(p_category VARCHAR(10))
RETURNS INT
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_pct INT;

    CASE p_category
        WHEN 'SC'  THEN SET v_pct = 50;
        WHEN 'ST'  THEN SET v_pct = 50;
        WHEN 'OBC' THEN SET v_pct = 25;
        WHEN 'EWS' THEN SET v_pct = 20;
        ELSE            SET v_pct = 0;
    END CASE;

    RETURN v_pct;
END$$
DELIMITER ;

SELECT category,
       fn_category_concession(category) AS concession_pct,
       COUNT(*) AS applicants
FROM Application_Master
GROUP BY category
ORDER BY concession_pct DESC;


-- PL/SQL 3: WHILE loop -- working days (Mon-Fri) left before a deadline
DROP FUNCTION IF EXISTS fn_working_days_left;
DELIMITER $$
CREATE FUNCTION fn_working_days_left(p_deadline DATE)
RETURNS INT
NOT DETERMINISTIC NO SQL
BEGIN
    DECLARE v_day   DATE DEFAULT CURDATE();
    DECLARE v_count INT  DEFAULT 0;

    WHILE v_day < p_deadline DO
        SET v_day = v_day + INTERVAL 1 DAY;
        IF DAYOFWEEK(v_day) NOT IN (1, 7) THEN   -- 1 = Sunday, 7 = Saturday
            SET v_count = v_count + 1;
        END IF;
    END WHILE;

    RETURN v_count;
END$$
DELIMITER ;

SELECT am.first_name, am.last_name, acc.response_deadline,
       fn_working_days_left(acc.response_deadline) AS working_days_left
FROM Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE acc.student_decision = 'PENDING';


-- PL/SQL 4: Exception handling -- fee balance by e-mail, NULL instead of
--           an error when the applicant has no fee record
DROP FUNCTION IF EXISTS fn_fee_balance;
DELIMITER $$
CREATE FUNCTION fn_fee_balance(p_email VARCHAR(100))
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_balance DECIMAL(10,2);
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_balance = NULL;

    SELECT fp.amount_due - fp.amount_paid INTO v_balance
    FROM Fee_Payment_Table fp
    JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
    JOIN Application_Master am ON am.application_id = acc.application_id
    WHERE am.email = p_email;

    RETURN v_balance;
END$$
DELIMITER ;

SELECT first_name, last_name, status, fn_fee_balance(email) AS fee_balance
FROM Application_Master
ORDER BY fee_balance DESC;


-- PL/SQL 5: Variables and arithmetic -- 70/30 merit score from JEE and school marks
DROP FUNCTION IF EXISTS fn_merit_score;
DELIMITER $$
CREATE FUNCTION fn_merit_score(p_jee DECIMAL(6,2), p_school_pct DECIMAL(5,2))
RETURNS DECIMAL(6,2)
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_jee_weight    DECIMAL(3,2) DEFAULT 0.70;
    DECLARE v_school_weight DECIMAL(3,2) DEFAULT 0.30;

    RETURN ROUND(p_jee * v_jee_weight + p_school_pct * v_school_weight, 2);
END$$
DELIMITER ;

SELECT first_name, last_name, jee_score, high_school_pct,
       fn_merit_score(jee_score, high_school_pct)                 AS merit_score,
       fn_score_grade(fn_merit_score(jee_score, high_school_pct)) AS merit_grade
FROM Application_Master
ORDER BY merit_score DESC;
