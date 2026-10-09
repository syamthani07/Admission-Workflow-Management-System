
-- ============================================================
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- Script 5 of 5: TRIGGERS, CURSORS AND PROCEDURES
-- Run review.sql first; this script works on the database it builds.
-- Safe to re-run: every object is dropped before it is created, and
-- every demo that changes data runs inside a transaction that is
-- rolled back. (Rolled-back inserts still use up AUTO_INCREMENT
-- values, so the next real id may skip a few numbers.)
--
-- Triggers
--   Trigger 1    trg_app_clean_input          BEFORE INSERT  trim names, lower-case e-mail
--   Trigger 2    trg_app_check_age            BEFORE INSERT  reject applicants under 16
--   Trigger 3    trg_app_log_new              AFTER INSERT   log first status + "received" e-mail
--   Trigger 4    trg_refund_cap               BEFORE INSERT  refund cannot exceed amount paid
--   Trigger 5    trg_course_seat_guard        BEFORE UPDATE  seats cannot drop below allocations
-- Cursors
--   Cursor 1     sp_cursor_accepted_names     LOOP ... LEAVE    names of accepted applicants
--   Cursor 2     sp_cursor_outstanding_fees   REPEAT ... UNTIL  students owing fees and total
--   Cursor 3     sp_cursor_course_report      WHILE             seat report per course
--   Cursor 4     sp_cursor_fee_reminders      cursor + DML      queue SMS fee reminders
--   Cursor 5     sp_cursor_department_roster  nested cursors    enrolled students per department
-- Procedures
--   Procedure 1  sp_applicants_by_category    IN parameter
--   Procedure 2  sp_admission_counts          OUT parameters
--   Procedure 3  sp_apply_discount            INOUT parameter
--   Procedure 4  sp_record_payment            validation + UPDATE
--   Procedure 5  sp_add_course                error handlers
-- ============================================================

USE admission_workflow_db;

-- Workbench's Safe Updates mode blocks UPDATEs without a key in WHERE
SET SQL_SAFE_UPDATES = 0;


-- ============================================================
-- TRIGGERS
-- ============================================================

DROP TRIGGER IF EXISTS trg_app_clean_input;
DROP TRIGGER IF EXISTS trg_app_check_age;
DROP TRIGGER IF EXISTS trg_app_log_new;
DROP TRIGGER IF EXISTS trg_refund_cap;
DROP TRIGGER IF EXISTS trg_course_seat_guard;

DELIMITER $$

-- Trigger 1: BEFORE INSERT -- tidy up names and e-mail before they are stored
CREATE TRIGGER trg_app_clean_input
BEFORE INSERT ON Application_Master
FOR EACH ROW
BEGIN
    SET NEW.first_name = TRIM(NEW.first_name);
    SET NEW.last_name  = TRIM(NEW.last_name);
    SET NEW.email      = LOWER(TRIM(NEW.email));
END$$

-- Trigger 2: BEFORE INSERT -- reject applicants younger than 16 (runs after Trigger 1)
CREATE TRIGGER trg_app_check_age
BEFORE INSERT ON Application_Master
FOR EACH ROW
FOLLOWS trg_app_clean_input
BEGIN
    IF TIMESTAMPDIFF(YEAR, NEW.dob, CURDATE()) < 16 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Applicant must be at least 16 years old';
    END IF;
END$$

-- Trigger 3: AFTER INSERT -- log the first status and send the "received" e-mail
CREATE TRIGGER trg_app_log_new
AFTER INSERT ON Application_Master
FOR EACH ROW
BEGIN
    INSERT INTO Application_Status_History (application_id, old_status, new_status)
    VALUES (NEW.application_id, NULL, NEW.status);

    INSERT INTO Communication_Log (application_id, channel, message_summary)
    VALUES (NEW.application_id, 'EMAIL', 'Application received - under review');
END$$

-- Trigger 4: BEFORE INSERT -- a refund can never exceed what was paid
CREATE TRIGGER trg_refund_cap
BEFORE INSERT ON Refund_Table
FOR EACH ROW
BEGIN
    DECLARE v_paid DECIMAL(10,2);

    SELECT amount_paid INTO v_paid
    FROM Fee_Payment_Table WHERE payment_id = NEW.payment_id;

    IF NEW.amount_refunded > v_paid THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Refund cannot exceed the amount paid';
    END IF;
END$$

-- Trigger 5: BEFORE UPDATE -- a course cannot shrink below the seats already allocated
CREATE TRIGGER trg_course_seat_guard
BEFORE UPDATE ON Course_Master
FOR EACH ROW
BEGIN
    DECLARE v_allocated INT;

    SELECT COUNT(*) INTO v_allocated
    FROM Course_Eligibility_Table
    WHERE course_id = NEW.course_id AND allocation_status = 'ALLOCATED';

    IF NEW.total_seats < v_allocated THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot cut seats below the number already allocated';
    END IF;
END$$

DELIMITER ;

-- Triggers 1 + 3 in action: insert a messy applicant, then undo it
START TRANSACTION;

INSERT INTO Application_Master
(first_name, last_name, dob, email, jee_score, high_school_pct, category, docs_submitted)
VALUES ('  Kiran ', ' Rao  ', '2006-05-05', '  Kiran.Rao@Example.COM ', 81.00, 85.00, 'GENERAL', TRUE);

-- Trigger 1: spaces trimmed (brackets show the edges) and e-mail lower-cased
SELECT application_id,
       CONCAT('[', first_name, ']') AS first_name,
       CONCAT('[', last_name, ']')  AS last_name,
       email
FROM Application_Master WHERE email = 'kiran.rao@example.com';

-- Trigger 3: first status and the welcome e-mail were logged automatically
SELECT h.old_status, h.new_status, h.changed_at
FROM Application_Status_History h
JOIN Application_Master am ON am.application_id = h.application_id
WHERE am.email = 'kiran.rao@example.com';

SELECT cl.channel, cl.message_summary, cl.sent_at
FROM Communication_Log cl
JOIN Application_Master am ON am.application_id = cl.application_id
WHERE am.email = 'kiran.rao@example.com';

ROLLBACK;

-- Triggers 2, 4, 5 in action: each statement breaks a rule. Running them
-- through a procedure catches each error, so the script keeps going.
DROP PROCEDURE IF EXISTS sp_trigger_tests;
DELIMITER $$
CREATE PROCEDURE sp_trigger_tests()
BEGIN
    DECLARE v_msg VARCHAR(255);

    DROP TEMPORARY TABLE IF EXISTS tmp_trigger_tests;
    CREATE TEMPORARY TABLE tmp_trigger_tests (
        trigger_name VARCHAR(40),
        attempted    VARCHAR(80),
        result       VARCHAR(255)
    );

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_msg = '!! NOT BLOCKED';
        INSERT INTO Application_Master (first_name, last_name, dob, email, jee_score, high_school_pct)
        VALUES ('Test', 'Child', DATE_SUB(CURDATE(), INTERVAL 10 YEAR), 'test.child@example.com', 80.00, 80.00);
        INSERT INTO tmp_trigger_tests VALUES ('trg_app_check_age', 'Add an applicant aged 10', v_msg);
    END;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_msg = '!! NOT BLOCKED';
        INSERT INTO Refund_Table (payment_id, amount_refunded)
        SELECT fp.payment_id, fp.amount_paid + 1000
        FROM Fee_Payment_Table fp
        JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
        JOIN Application_Master am ON am.application_id = acc.application_id
        WHERE am.email = 'priya.iyer@example.com';
        INSERT INTO tmp_trigger_tests VALUES ('trg_refund_cap', 'Refund Priya Rs 1000 more than she paid', v_msg);
    END;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_msg = '!! NOT BLOCKED';
        UPDATE Course_Master SET total_seats = 1
        WHERE course_name = 'B.Tech Artificial Intelligence';
        INSERT INTO tmp_trigger_tests VALUES ('trg_course_seat_guard', 'Cut AI seats to 1 (4 already allocated)', v_msg);
    END;

    SELECT * FROM tmp_trigger_tests;
END$$
DELIMITER ;

START TRANSACTION;
CALL sp_trigger_tests();   -- every row should show the trigger's error message
ROLLBACK;


-- ============================================================
-- CURSORS
-- ============================================================

-- Cursor 1: LOOP ... LEAVE -- names of all accepted applicants, highest score first
DROP PROCEDURE IF EXISTS sp_cursor_accepted_names;
DELIMITER $$
CREATE PROCEDURE sp_cursor_accepted_names(OUT p_names TEXT)
BEGIN
    DECLARE v_name VARCHAR(101);
    DECLARE v_done BOOLEAN DEFAULT FALSE;
    DECLARE cur_accepted CURSOR FOR
        SELECT CONCAT(first_name, ' ', last_name)
        FROM Application_Master
        WHERE status = 'ACCEPTED'
        ORDER BY jee_score DESC;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    SET p_names = '';
    OPEN cur_accepted;
    read_loop: LOOP
        FETCH cur_accepted INTO v_name;
        IF v_done THEN
            LEAVE read_loop;
        END IF;
        SET p_names = IF(p_names = '', v_name, CONCAT(p_names, ', ', v_name));
    END LOOP;
    CLOSE cur_accepted;
END$$
DELIMITER ;

CALL sp_cursor_accepted_names(@names);
SELECT @names AS accepted_students_by_score;

-- Cursor 2: REPEAT ... UNTIL -- how many students owe fees, and how much in total
DROP PROCEDURE IF EXISTS sp_cursor_outstanding_fees;
DELIMITER $$
CREATE PROCEDURE sp_cursor_outstanding_fees(OUT p_students INT, OUT p_total DECIMAL(12,2))
BEGIN
    DECLARE v_balance DECIMAL(10,2);
    DECLARE v_done BOOLEAN DEFAULT FALSE;
    DECLARE cur_fees CURSOR FOR
        SELECT amount_due - amount_paid
        FROM Fee_Payment_Table
        WHERE amount_paid < amount_due;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    SET p_students = 0;
    SET p_total = 0;
    OPEN cur_fees;
    REPEAT
        FETCH cur_fees INTO v_balance;
        IF NOT v_done THEN
            SET p_students = p_students + 1;
            SET p_total = p_total + v_balance;
        END IF;
    UNTIL v_done END REPEAT;
    CLOSE cur_fees;
END$$
DELIMITER ;

CALL sp_cursor_outstanding_fees(@students, @total);
SELECT @students AS students_owing, @total AS total_outstanding;

-- Cursor 3: WHILE -- seat report per course, built row by row into a temporary table
DROP PROCEDURE IF EXISTS sp_cursor_course_report;
DELIMITER $$
CREATE PROCEDURE sp_cursor_course_report()
BEGIN
    DECLARE v_course_id INT;
    DECLARE v_course    VARCHAR(100);
    DECLARE v_seats     INT;
    DECLARE v_allocated INT;
    DECLARE v_done BOOLEAN DEFAULT FALSE;
    DECLARE cur_courses CURSOR FOR
        SELECT course_id, course_name, total_seats
        FROM Course_Master
        ORDER BY course_name;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    DROP TEMPORARY TABLE IF EXISTS tmp_course_report;
    CREATE TEMPORARY TABLE tmp_course_report (
        course_name VARCHAR(100),
        total_seats INT,
        allocated   INT,
        seats_left  INT,
        fill_pct    DECIMAL(5,1)
    );

    OPEN cur_courses;
    FETCH cur_courses INTO v_course_id, v_course, v_seats;
    WHILE NOT v_done DO
        SELECT COUNT(*) INTO v_allocated
        FROM Course_Eligibility_Table
        WHERE course_id = v_course_id AND allocation_status = 'ALLOCATED';

        INSERT INTO tmp_course_report
        VALUES (v_course, v_seats, v_allocated, v_seats - v_allocated, v_allocated * 100 / v_seats);

        FETCH cur_courses INTO v_course_id, v_course, v_seats;
    END WHILE;
    CLOSE cur_courses;

    SELECT * FROM tmp_course_report ORDER BY fill_pct DESC;
END$$
DELIMITER ;

CALL sp_cursor_course_report();

-- Cursor 4: Cursor with a parameter that writes data -- queue an SMS reminder
--           for every student who still owes at least p_min_balance
DROP PROCEDURE IF EXISTS sp_cursor_fee_reminders;
DELIMITER $$
CREATE PROCEDURE sp_cursor_fee_reminders(IN p_min_balance DECIMAL(10,2), OUT p_sent INT)
BEGIN
    DECLARE v_app_id  INT;
    DECLARE v_balance DECIMAL(10,2);
    DECLARE v_done BOOLEAN DEFAULT FALSE;
    DECLARE cur_due CURSOR FOR
        SELECT acc.application_id, fp.amount_due - fp.amount_paid
        FROM Fee_Payment_Table fp
        JOIN Acceptance_Table acc ON acc.acceptance_id = fp.acceptance_id
        WHERE acc.student_decision <> 'DECLINED'
          AND fp.amount_due - fp.amount_paid >= p_min_balance;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    SET p_sent = 0;
    OPEN cur_due;
    reminder_loop: LOOP
        FETCH cur_due INTO v_app_id, v_balance;
        IF v_done THEN
            LEAVE reminder_loop;
        END IF;
        INSERT INTO Communication_Log (application_id, channel, message_summary)
        VALUES (v_app_id, 'SMS', CONCAT('Fee reminder: Rs ', v_balance, ' still due'));
        SET p_sent = p_sent + 1;
    END LOOP;
    CLOSE cur_due;
END$$
DELIMITER ;

START TRANSACTION;
CALL sp_cursor_fee_reminders(50000, @sent);
SELECT @sent AS reminders_queued;
SELECT am.first_name, am.last_name, cl.channel, cl.message_summary
FROM Communication_Log cl
JOIN Application_Master am ON am.application_id = cl.application_id
WHERE cl.message_summary LIKE 'Fee reminder%';
ROLLBACK;

-- Cursor 5: Nested cursors -- the outer cursor walks departments, the inner
--           one walks the students enrolled in each department
DROP PROCEDURE IF EXISTS sp_cursor_department_roster;
DELIMITER $$
CREATE PROCEDURE sp_cursor_department_roster()
BEGIN
    DECLARE v_dept VARCHAR(100);
    DECLARE v_dept_done BOOLEAN DEFAULT FALSE;
    DECLARE cur_dept CURSOR FOR
        SELECT DISTINCT department FROM Course_Master ORDER BY department;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_dept_done = TRUE;

    DROP TEMPORARY TABLE IF EXISTS tmp_department_roster;
    CREATE TEMPORARY TABLE tmp_department_roster (
        department VARCHAR(100),
        students   INT,
        roster     TEXT
    );

    OPEN cur_dept;
    dept_loop: LOOP
        FETCH cur_dept INTO v_dept;
        IF v_dept_done THEN
            LEAVE dept_loop;
        END IF;

        BEGIN
            DECLARE v_roll   VARCHAR(20);
            DECLARE v_name   VARCHAR(101);
            DECLARE v_count  INT  DEFAULT 0;
            DECLARE v_roster TEXT DEFAULT NULL;
            DECLARE v_student_done BOOLEAN DEFAULT FALSE;
            DECLARE cur_student CURSOR FOR
                SELECT es.roll_number, CONCAT(am.first_name, ' ', am.last_name)
                FROM Enrolled_Students es
                JOIN Course_Master cm      ON cm.course_id      = es.course_id
                JOIN Acceptance_Table acc  ON acc.acceptance_id = es.acceptance_id
                JOIN Application_Master am ON am.application_id = acc.application_id
                WHERE cm.department = v_dept
                ORDER BY es.roll_number;
            DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_student_done = TRUE;

            OPEN cur_student;
            student_loop: LOOP
                FETCH cur_student INTO v_roll, v_name;
                IF v_student_done THEN
                    LEAVE student_loop;
                END IF;
                SET v_count  = v_count + 1;
                SET v_roster = CONCAT_WS(', ', v_roster, CONCAT(v_roll, ' ', v_name));
            END LOOP;
            CLOSE cur_student;

            INSERT INTO tmp_department_roster VALUES (v_dept, v_count, v_roster);
        END;
    END LOOP;
    CLOSE cur_dept;

    SELECT * FROM tmp_department_roster;
END$$
DELIMITER ;

CALL sp_cursor_department_roster();


-- ============================================================
-- PROCEDURES
-- ============================================================

-- Procedure 1: IN parameter -- list the applicants in one category
DROP PROCEDURE IF EXISTS sp_applicants_by_category;
DELIMITER $$
CREATE PROCEDURE sp_applicants_by_category(IN p_category VARCHAR(10))
BEGIN
    SELECT application_id, first_name, last_name, jee_score, status
    FROM Application_Master
    WHERE category = p_category
    ORDER BY jee_score DESC;
END$$
DELIMITER ;

CALL sp_applicants_by_category('OBC');

-- Procedure 2: OUT parameters -- application counts by outcome
DROP PROCEDURE IF EXISTS sp_admission_counts;
DELIMITER $$
CREATE PROCEDURE sp_admission_counts(
    OUT p_total      INT,
    OUT p_accepted   INT,
    OUT p_rejected   INT,
    OUT p_incomplete INT
)
BEGIN
    SELECT COUNT(*),
           SUM(status = 'ACCEPTED'),
           SUM(status = 'REJECTED'),
           SUM(status = 'INCOMPLETE')
    INTO p_total, p_accepted, p_rejected, p_incomplete
    FROM Application_Master;
END$$
DELIMITER ;

CALL sp_admission_counts(@total_apps, @accepted, @rejected, @incomplete);
SELECT @total_apps AS total, @accepted AS accepted, @rejected AS rejected, @incomplete AS incomplete;

-- Procedure 3: INOUT parameter -- apply a percentage discount to an amount in place
DROP PROCEDURE IF EXISTS sp_apply_discount;
DELIMITER $$
CREATE PROCEDURE sp_apply_discount(INOUT p_amount DECIMAL(10,2), IN p_percent DECIMAL(5,2))
BEGIN
    SET p_amount = ROUND(p_amount * (100 - p_percent) / 100, 2);
END$$
DELIMITER ;

SET @fee = 150000.00;
CALL sp_apply_discount(@fee, 20);      -- 150000 -> 120000
SET @after_first = @fee;
CALL sp_apply_discount(@fee, 10);      -- 120000 -> 108000
SELECT 150000.00 AS original_fee, @after_first AS after_20_pct, @fee AS after_another_10_pct;

-- Procedure 4: Validation + DML -- record a fee payment, refusing bad amounts.
--              payment_status is updated by trg_fee_status_upd from review.sql.
DROP PROCEDURE IF EXISTS sp_record_payment;
DELIMITER $$
CREATE PROCEDURE sp_record_payment(
    IN  p_email   VARCHAR(100),
    IN  p_amount  DECIMAL(10,2),
    OUT p_message VARCHAR(255)
)
BEGIN
    DECLARE v_payment_id INT;
    DECLARE v_balance    DECIMAL(10,2);
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_payment_id = NULL;

    SELECT fp.payment_id, fp.amount_due - fp.amount_paid
    INTO v_payment_id, v_balance
    FROM Fee_Payment_Table fp
    JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
    JOIN Application_Master am ON am.application_id = acc.application_id
    WHERE am.email = p_email;

    IF v_payment_id IS NULL THEN
        SET p_message = CONCAT('Refused: no fee record for ', p_email);
    ELSEIF p_amount <= 0 THEN
        SET p_message = 'Refused: amount must be positive';
    ELSEIF p_amount > v_balance THEN
        SET p_message = CONCAT('Refused: Rs ', p_amount, ' is more than the balance of Rs ', v_balance);
    ELSE
        UPDATE Fee_Payment_Table
        SET amount_paid = amount_paid + p_amount
        WHERE payment_id = v_payment_id;
        SET p_message = CONCAT('Recorded Rs ', p_amount, '; balance now Rs ', v_balance - p_amount);
    END IF;
END$$
DELIMITER ;

START TRANSACTION;
CALL sp_record_payment('priya.iyer@example.com',  20000.00, @pay_ok);
CALL sp_record_payment('priya.iyer@example.com', 500000.00, @pay_too_much);
CALL sp_record_payment('kabir.menon@example.com',  1000.00, @pay_no_record);
SELECT @pay_ok AS valid_payment, @pay_too_much AS over_balance, @pay_no_record AS rejected_applicant;
SELECT fp.amount_due, fp.amount_paid, fp.amount_due - fp.amount_paid AS balance, fp.payment_status
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE am.email = 'priya.iyer@example.com';
ROLLBACK;

-- Procedure 5: Error handling -- add a course, turning database errors into messages
DROP PROCEDURE IF EXISTS sp_add_course;
DELIMITER $$
CREATE PROCEDURE sp_add_course(
    IN  p_name       VARCHAR(100),
    IN  p_department VARCHAR(100),
    IN  p_seats      INT,
    OUT p_message    VARCHAR(255)
)
BEGIN
    DECLARE EXIT HANDLER FOR 1062   -- duplicate key: course_name is UNIQUE
        SET p_message = CONCAT('Not added: ', p_name, ' already exists');
    DECLARE EXIT HANDLER FOR 3819   -- CHECK constraint chk_seats failed
        SET p_message = 'Not added: total seats must be greater than 0';

    INSERT INTO Course_Master (course_name, department, total_seats)
    VALUES (p_name, p_department, p_seats);

    SET p_message = CONCAT('Added ', p_name, ' (course_id ', LAST_INSERT_ID(), ')');
END$$
DELIMITER ;

START TRANSACTION;
CALL sp_add_course('B.Tech Robotics',             'MECH', 40, @course_new);
CALL sp_add_course('B.Tech Computer Science',     'CSE',  60, @course_dup);
CALL sp_add_course('B.Tech Chemical Engineering', 'CHEM',  0, @course_zero);
SELECT @course_new AS new_course, @course_dup AS duplicate_name, @course_zero AS zero_seats;
ROLLBACK;


-- Back to Workbench's default
SET SQL_SAFE_UPDATES = 1;
