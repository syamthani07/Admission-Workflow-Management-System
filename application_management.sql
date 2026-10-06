-- ============================================================
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM  (upgraded edition)
-- MySQL 8.0.16+ / MySQL Workbench compatible script
--
-- Contents
--   1  Tables ............ 16 core + 4 supporting (audit / archive / reports)
--   2  Triggers .......... 15 triggers (BEFORE / AFTER, INSERT / UPDATE / DELETE)
--   3  Functions ......... 5 stored functions (the "PL/SQL function" equivalent)
--   4  Stored procedures . 7 procedures (transactions, error handling, OUT params)
--   5  Cursors ........... 4 cursor procedures: explicit (LOOP, REPEAT, nested WHILE)
--                          and implicit-cursor behaviour
--   6  Views ............. 9 views (simple, aggregated, nested, updatable, restricted)
--   7  Sample data
--   8  DML ............... INSERT / UPDATE / DELETE / UPSERT / multi-table
--   9  DQL core queries
--  10  JOINs ............. INNER, LEFT, RIGHT, FULL (emulated), CROSS, SELF,
--                          NATURAL, USING, non-equi, anti-join
--  11  Subqueries ........ scalar, multi-row, ANY/ALL, EXISTS, correlated,
--                          nested (3 levels), derived tables, row subqueries
--  12  CTEs, window functions, set operations, ROLLUP
--  13  Running the functions / procedures / cursors / views
--  14  TCL ............... COMMIT, ROLLBACK, SAVEPOINT
--  15  Event scheduler
--  16  Business-rule tests (an 8th procedure; proves triggers + constraints work)
--  17  DCL (optional, commented out)
--
-- A note on "PL/SQL": PL/SQL is Oracle's language. MySQL's equivalent is
-- its stored-program language (SQL/PSM): stored procedures, functions,
-- triggers, events, cursors, handlers and SIGNAL. Everything below is the
-- MySQL counterpart of the PL/SQL feature of the same name.
-- ============================================================


DROP DATABASE IF EXISTS admission_workflow_db;
CREATE DATABASE admission_workflow_db;
USE admission_workflow_db;

-- MySQL Workbench turns "Safe Updates" on by default, which refuses any
-- UPDATE/DELETE whose WHERE clause does not use a key column. This script
-- has several by design, so switch it off for this session.
SET SQL_SAFE_UPDATES = 0;


-- ============================================================
-- RELATIONSHIP MAP (every FK in the schema)
--
-- Application_Master  <-- THE MASTER TABLE. Every applicant,
--   |                     without exception, gets exactly one
--   |                     row here first. Nothing downstream
--   |                     can exist without it.
--   |
--   +-- Acceptance_Table            (1:1, if qualifies)
--   |     +-- Course_Eligibility_Table --> Course_Master
--   |     +-- Scholarship_Table        --> Scholarship_Master
--   |     +-- Fee_Payment_Table (1:1)
--   |     |     +-- Refund_Table
--   |     +-- Hostel_Accommodation_Table (1:1)
--   |     +-- Enrolled_Students (1:1)   --> Course_Master
--   |
--   +-- Rejection_Table            (1:1, if below cutoff)
--   |     +-- Appeal_Table
--   |
--   +-- Incomplete_Table           (1:1, if docs missing)
--   |     +-- Document_Checklist
--   |
--   +-- Application_Status_History (1:N audit trail)
--   +-- Communication_Log          (1:N notifications)
--   +-- Merit_Rank_List            (1:1, produced by a cursor procedure)
--
-- Course_Master and Scholarship_Master are the two lookup
-- (reference) tables; they are not owned by any applicant.
--
-- Deliberately detached (no FK, so they survive deletes):
--   Fee_Audit_Log, Deleted_Applications_Archive
-- Report table filled by a nested-cursor procedure:
--   Course_Roster_Report --> Course_Master
-- ============================================================



-- SECTION 1: TABLE CREATION (16 core tables + 4 supporting tables)


-- Level 0: Entry point -- THE MASTER TABLE
CREATE TABLE Application_Master (
    application_id      INT AUTO_INCREMENT PRIMARY KEY,
    first_name           VARCHAR(50)  NOT NULL,
    last_name            VARCHAR(50)  NOT NULL,
    dob                  DATE         NOT NULL,
    email                VARCHAR(100) NOT NULL UNIQUE,
    jee_score            DECIMAL(6,2) NOT NULL,
    high_school_pct      DECIMAL(5,2) NOT NULL,
    category             ENUM('GENERAL','OBC','SC','ST','EWS') NOT NULL DEFAULT 'GENERAL',
    docs_submitted       BOOLEAN      NOT NULL DEFAULT FALSE,
    status               ENUM('SUBMITTED','UNDER_REVIEW','ACCEPTED','REJECTED','INCOMPLETE') NOT NULL DEFAULT 'SUBMITTED',
    created_at           TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_jee_score  CHECK (jee_score       BETWEEN 0 AND 100),
    CONSTRAINT chk_school_pct CHECK (high_school_pct BETWEEN 0 AND 100)
);

-- Lookup / reference tables (not owned by any single applicant)
CREATE TABLE Course_Master (
    course_id                INT AUTO_INCREMENT PRIMARY KEY,
    course_name                VARCHAR(100) NOT NULL UNIQUE,
    department                  VARCHAR(100) NOT NULL,
    total_seats                  INT NOT NULL,
    CONSTRAINT chk_seats CHECK (total_seats > 0)
);

CREATE TABLE Scholarship_Master (
    scholarship_code           VARCHAR(20) PRIMARY KEY,
    scholarship_name            VARCHAR(100) NOT NULL UNIQUE,
    max_amount                   DECIMAL(10,2) NOT NULL,
    CONSTRAINT chk_max_amount CHECK (max_amount > 0)
);

-- Level 1: Outcome tables
CREATE TABLE Acceptance_Table (
    acceptance_id        INT AUTO_INCREMENT PRIMARY KEY,
    application_id        INT NOT NULL UNIQUE,
    offer_date            DATE NOT NULL,
    response_deadline     DATE NOT NULL,
    student_decision      ENUM('PENDING','ACCEPTED','DECLINED') NOT NULL DEFAULT 'PENDING',
    CONSTRAINT fk_acc_app FOREIGN KEY (application_id)
        REFERENCES Application_Master(application_id) ON DELETE CASCADE,
    CONSTRAINT chk_deadline CHECK (response_deadline >= offer_date)
);

CREATE TABLE Rejection_Table (
    rejection_id          INT AUTO_INCREMENT PRIMARY KEY,
    application_id         INT NOT NULL UNIQUE,
    rejection_reason       VARCHAR(255) NOT NULL,
    appeal_eligible         BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT fk_rej_app FOREIGN KEY (application_id)
        REFERENCES Application_Master(application_id) ON DELETE CASCADE
);

CREATE TABLE Incomplete_Table (
    incomplete_id          INT AUTO_INCREMENT PRIMARY KEY,
    application_id          INT NOT NULL UNIQUE,
    grace_period_end        DATE NOT NULL,
    CONSTRAINT fk_inc_app FOREIGN KEY (application_id)
        REFERENCES Application_Master(application_id) ON DELETE CASCADE
);

-- Level 2: Children of outcome tables
CREATE TABLE Document_Checklist (
    doc_id                 INT AUTO_INCREMENT PRIMARY KEY,
    incomplete_id            INT NOT NULL,
    document_type            VARCHAR(100) NOT NULL,
    status                    ENUM('PENDING','RECEIVED','VERIFIED','REJECTED') NOT NULL DEFAULT 'PENDING',
    CONSTRAINT fk_doc_inc FOREIGN KEY (incomplete_id)
        REFERENCES Incomplete_Table(incomplete_id) ON DELETE CASCADE,
    -- the same document can only be listed once per application
    CONSTRAINT uq_inc_doctype UNIQUE (incomplete_id, document_type)
);

CREATE TABLE Appeal_Table (
    appeal_id               INT AUTO_INCREMENT PRIMARY KEY,
    rejection_id              INT NOT NULL,
    appeal_date                DATE NOT NULL,
    revised_score               DECIMAL(6,2),
    appeal_status                ENUM('FILED','UNDER_REVIEW','APPROVED','DENIED') NOT NULL DEFAULT 'FILED',
    CONSTRAINT fk_appeal_rej FOREIGN KEY (rejection_id)
        REFERENCES Rejection_Table(rejection_id) ON DELETE CASCADE
);

CREATE TABLE Course_Eligibility_Table (
    eligibility_id            INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                INT NOT NULL,
    course_id                     INT NOT NULL,
    priority_preference             INT NOT NULL,
    allocation_status                ENUM('APPLIED','ALLOCATED','WAITLISTED','REJECTED') NOT NULL DEFAULT 'APPLIED',
    CONSTRAINT fk_cet_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE,
    CONSTRAINT fk_cet_course FOREIGN KEY (course_id)
        REFERENCES Course_Master(course_id) ON DELETE RESTRICT,
    -- one course per priority slot, and no listing the same course twice
    CONSTRAINT uq_acc_priority UNIQUE (acceptance_id, priority_preference),
    CONSTRAINT uq_acc_course   UNIQUE (acceptance_id, course_id),
    CONSTRAINT chk_priority CHECK (priority_preference > 0)
);

CREATE TABLE Scholarship_Table (
    scholarship_id             INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                 INT NOT NULL,
    scholarship_code                 VARCHAR(20) NOT NULL,
    amount_awarded                    DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_sch_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE,
    CONSTRAINT fk_sch_master FOREIGN KEY (scholarship_code)
        REFERENCES Scholarship_Master(scholarship_code) ON DELETE RESTRICT,
    -- a student cannot be awarded the same scholarship twice
    CONSTRAINT uq_acc_scholarship UNIQUE (acceptance_id, scholarship_code),
    CONSTRAINT chk_award CHECK (amount_awarded > 0)
);

CREATE TABLE Fee_Payment_Table (
    payment_id                  INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                  INT NOT NULL UNIQUE,
    amount_due                       DECIMAL(10,2) NOT NULL,
    amount_paid                        DECIMAL(10,2) NOT NULL DEFAULT 0,
    payment_status                       ENUM('PENDING','PARTIAL','PAID') NOT NULL DEFAULT 'PENDING',
    CONSTRAINT fk_fee_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE,
    CONSTRAINT chk_amounts CHECK (amount_due >= 0 AND amount_paid >= 0)
);

CREATE TABLE Hostel_Accommodation_Table (
    hostel_req_id                 INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                     INT NOT NULL UNIQUE,
    room_type_preference                 VARCHAR(50),
    allotted_room_number                    VARCHAR(20) UNIQUE,
    CONSTRAINT fk_hostel_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE
);

-- Level 3: Grandchildren
CREATE TABLE Refund_Table (
    refund_id                       INT AUTO_INCREMENT PRIMARY KEY,
    payment_id                          INT NOT NULL,
    amount_refunded                        DECIMAL(10,2) NOT NULL,
    refund_status                            ENUM('REQUESTED','PROCESSING','COMPLETED','DENIED') NOT NULL DEFAULT 'REQUESTED',
    CONSTRAINT fk_refund_pay FOREIGN KEY (payment_id)
        REFERENCES Fee_Payment_Table(payment_id) ON DELETE CASCADE,
    CONSTRAINT chk_refund CHECK (amount_refunded > 0)
);

CREATE TABLE Enrolled_Students (
    enrollment_id                     INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                        INT NOT NULL UNIQUE,
    course_id                              INT NOT NULL,
    enrollment_date                          DATE NOT NULL,
    roll_number                                VARCHAR(20) NOT NULL UNIQUE,
    CONSTRAINT fk_enroll_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE,
    -- an enrolled student is enrolled INTO a course; without this FK
    -- the final node had no link back to Course_Master at all
    CONSTRAINT fk_enroll_course FOREIGN KEY (course_id)
        REFERENCES Course_Master(course_id) ON DELETE RESTRICT
);

-- Supporting / cross-cutting tables
CREATE TABLE Application_Status_History (
    history_id                          INT AUTO_INCREMENT PRIMARY KEY,
    application_id                          INT NOT NULL,
    old_status                                VARCHAR(30),
    new_status                                  VARCHAR(30) NOT NULL,
    changed_at                                    DATETIME DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_hist_app FOREIGN KEY (application_id)
        REFERENCES Application_Master(application_id) ON DELETE CASCADE
);

CREATE TABLE Communication_Log (
    log_id                                  INT AUTO_INCREMENT PRIMARY KEY,
    application_id                              INT NOT NULL,
    channel                                       ENUM('EMAIL','SMS','PORTAL') NOT NULL,
    message_summary                                 VARCHAR(255),
    sent_at                                           DATETIME DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_comm_app FOREIGN KEY (application_id)
        REFERENCES Application_Master(application_id) ON DELETE CASCADE
);

-- Helpful indexes for common lookups/joins.
-- (MySQL auto-indexes FK columns, so only non-FK filters need these.)
CREATE INDEX idx_app_status ON Application_Master(status);
CREATE INDEX idx_app_score  ON Application_Master(jee_score);
CREATE INDEX idx_cet_alloc  ON Course_Eligibility_Table(allocation_status);
CREATE INDEX idx_fee_status ON Fee_Payment_Table(payment_status);



-- ------------------------------------------------------------
-- Supporting tables (added in the upgrade)
-- ------------------------------------------------------------

-- Written by trg_fee_audit. Detached on purpose: an audit trail must
-- outlive the rows it describes, so there is no FK and no cascade.
CREATE TABLE Fee_Audit_Log (
    audit_id        INT AUTO_INCREMENT PRIMARY KEY,
    payment_id      INT NOT NULL,
    old_due         DECIMAL(10,2),
    new_due         DECIMAL(10,2),
    old_paid        DECIMAL(10,2),
    new_paid        DECIMAL(10,2),
    old_status      VARCHAR(10),
    new_status      VARCHAR(10),
    changed_by      VARCHAR(100),
    changed_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Written by trg_app_archive_delete. Also detached: the parent row is gone.
CREATE TABLE Deleted_Applications_Archive (
    archive_id      INT AUTO_INCREMENT PRIMARY KEY,
    application_id  INT NOT NULL,
    full_name       VARCHAR(101) NOT NULL,
    email           VARCHAR(100) NOT NULL,
    jee_score       DECIMAL(6,2),
    last_status     VARCHAR(20),
    deleted_by      VARCHAR(100),
    deleted_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Filled by the explicit-cursor procedure sp_build_merit_rank_list.
CREATE TABLE Merit_Rank_List (
    rank_id          INT AUTO_INCREMENT PRIMARY KEY,
    application_id   INT NOT NULL UNIQUE,
    composite_score  DECIMAL(6,2) NOT NULL,
    merit_rank       INT NOT NULL,
    generated_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_merit_app FOREIGN KEY (application_id)
        REFERENCES Application_Master(application_id) ON DELETE CASCADE
);

-- Filled by the nested-cursor procedure sp_course_roster_report.
CREATE TABLE Course_Roster_Report (
    course_id        INT PRIMARY KEY,
    course_name      VARCHAR(100) NOT NULL,
    enrolled_count   INT NOT NULL,
    roster           TEXT,
    generated_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_roster_course FOREIGN KEY (course_id)
        REFERENCES Course_Master(course_id) ON DELETE CASCADE
);



-- ============================================================
-- SECTION 2: TRIGGERS (15)
--   Application_Master : 5  (BEFORE INS, AFTER INS, BEFORE UPD, AFTER UPD, AFTER DEL)
--   Fee / Scholarship  : 6
--   Course allocation  : 2
--   Enrollment, Refund : 2
-- ============================================================

DELIMITER $$

-- ---- Application_Master ------------------------------------

-- 2a. BEFORE INSERT: clean the data and reject impossible applicants.
CREATE TRIGGER trg_app_before_insert
BEFORE INSERT ON Application_Master
FOR EACH ROW
BEGIN
    SET NEW.first_name = TRIM(NEW.first_name);
    SET NEW.last_name  = TRIM(NEW.last_name);
    SET NEW.email      = LOWER(TRIM(NEW.email));

    IF NEW.email NOT LIKE '%_@_%.__%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid e-mail address';
    END IF;
    IF TIMESTAMPDIFF(YEAR, NEW.dob, CURDATE()) < 16 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Applicant must be at least 16 years old';
    END IF;
END$$

-- 2b. AFTER INSERT: the audit trail now starts at birth (NULL -> SUBMITTED).
CREATE TRIGGER trg_app_after_insert
AFTER INSERT ON Application_Master
FOR EACH ROW
BEGIN
    INSERT INTO Application_Status_History (application_id, old_status, new_status)
    VALUES (NEW.application_id, NULL, NEW.status);
END$$

-- 2c. BEFORE UPDATE: a decided application cannot silently go back to
--     "under review", and its score is frozen once decided.
CREATE TRIGGER trg_app_guard_update
BEFORE UPDATE ON Application_Master
FOR EACH ROW
BEGIN
    IF OLD.status IN ('ACCEPTED','REJECTED')
       AND NEW.status IN ('SUBMITTED','UNDER_REVIEW') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A decided application cannot be reopened as SUBMITTED / UNDER_REVIEW';
    END IF;
    IF OLD.status IN ('ACCEPTED','REJECTED') AND NEW.jee_score <> OLD.jee_score THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The score of a decided application is frozen';
    END IF;
END$$

-- 2d. AFTER UPDATE: auto-log every status change.
CREATE TRIGGER trg_log_status_change
AFTER UPDATE ON Application_Master
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO Application_Status_History (application_id, old_status, new_status)
        VALUES (NEW.application_id, OLD.status, NEW.status);
    END IF;
END$$

-- 2e. AFTER DELETE: keep a tombstone of every deleted application.
CREATE TRIGGER trg_app_archive_delete
AFTER DELETE ON Application_Master
FOR EACH ROW
BEGIN
    INSERT INTO Deleted_Applications_Archive
        (application_id, full_name, email, jee_score, last_status, deleted_by)
    VALUES
        (OLD.application_id, CONCAT(OLD.first_name, ' ', OLD.last_name),
         OLD.email, OLD.jee_score, OLD.status, CURRENT_USER());
END$$

-- ---- Fees and scholarships ---------------------------------

-- 2f. Every acceptance gets a fee record, automatically. This is what makes
--     the Acceptance -> Fee_Payment 1:1 relationship actually hold: an
--     applicant accepted later (via an appeal, say) cannot end up with no
--     fee row just because the bulk data load already ran.
CREATE TRIGGER trg_fee_row_on_accept
AFTER INSERT ON Acceptance_Table
FOR EACH ROW
BEGIN
    -- flat base tuition; scholarships are deducted by trg_fee_discount below
    INSERT INTO Fee_Payment_Table (acceptance_id, amount_due, amount_paid)
    VALUES (NEW.acceptance_id, 150000.00, 0.00);
END$$

-- 2g. Awarding a scholarship reduces what the student owes, whenever it
--     is awarded -- so Fee_Payment stays derived from Scholarship_Table.
CREATE TRIGGER trg_fee_discount_on_scholarship
AFTER INSERT ON Scholarship_Table
FOR EACH ROW
BEGIN
    UPDATE Fee_Payment_Table
    SET amount_due = GREATEST(0, amount_due - NEW.amount_awarded)
    WHERE acceptance_id = NEW.acceptance_id;
END$$

-- 2h. Keep payment_status derived from the amounts, so it can never
--     drift out of sync with amount_paid / amount_due.
CREATE TRIGGER trg_fee_status_ins
BEFORE INSERT ON Fee_Payment_Table
FOR EACH ROW
BEGIN
    SET NEW.payment_status = CASE
        WHEN NEW.amount_paid >= NEW.amount_due THEN 'PAID'
        WHEN NEW.amount_paid > 0              THEN 'PARTIAL'
        ELSE 'PENDING'
    END;
END$$

CREATE TRIGGER trg_fee_status_upd
BEFORE UPDATE ON Fee_Payment_Table
FOR EACH ROW
BEGIN
    SET NEW.payment_status = CASE
        WHEN NEW.amount_paid >= NEW.amount_due THEN 'PAID'
        WHEN NEW.amount_paid > 0              THEN 'PARTIAL'
        ELSE 'PENDING'
    END;
END$$

-- 2i. A scholarship award may not exceed the cap in Scholarship_Master.
CREATE TRIGGER trg_scholarship_cap
BEFORE INSERT ON Scholarship_Table
FOR EACH ROW
BEGIN
    DECLARE v_max DECIMAL(10,2);
    SELECT max_amount INTO v_max
    FROM Scholarship_Master WHERE scholarship_code = NEW.scholarship_code;
    IF NEW.amount_awarded > v_max THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Award exceeds the maximum for this scholarship';
    END IF;
END$$

-- 2j. AFTER UPDATE audit: every change to money fields is recorded with
--     the old value, the new value and who did it.
CREATE TRIGGER trg_fee_audit
AFTER UPDATE ON Fee_Payment_Table
FOR EACH ROW
BEGIN
    IF OLD.amount_paid <> NEW.amount_paid OR OLD.amount_due <> NEW.amount_due THEN
        INSERT INTO Fee_Audit_Log
            (payment_id, old_due, new_due, old_paid, new_paid,
             old_status, new_status, changed_by)
        VALUES
            (NEW.payment_id, OLD.amount_due, NEW.amount_due, OLD.amount_paid, NEW.amount_paid,
             OLD.payment_status, NEW.payment_status, CURRENT_USER());
    END IF;
END$$

-- ---- Course allocation -------------------------------------

-- 2k/2l. Seat capacity and "one ALLOCATED course per applicant" are now
--        enforced in the database (both were listed as extensions before).
CREATE TRIGGER trg_cet_alloc_ins
BEFORE INSERT ON Course_Eligibility_Table
FOR EACH ROW
BEGIN
    DECLARE v_seats INT;
    DECLARE v_used  INT;

    IF NEW.allocation_status = 'ALLOCATED' THEN
        SELECT total_seats INTO v_seats
        FROM Course_Master WHERE course_id = NEW.course_id;

        SELECT COUNT(*) INTO v_used
        FROM Course_Eligibility_Table
        WHERE course_id = NEW.course_id AND allocation_status = 'ALLOCATED';

        IF v_used >= v_seats THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Course is full: no seat left to allocate';
        END IF;

        IF EXISTS (SELECT 1 FROM Course_Eligibility_Table
                   WHERE acceptance_id = NEW.acceptance_id
                     AND allocation_status = 'ALLOCATED') THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Applicant already has an allocated course';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_cet_alloc_upd
BEFORE UPDATE ON Course_Eligibility_Table
FOR EACH ROW
BEGIN
    DECLARE v_seats INT;
    DECLARE v_used  INT;

    IF NEW.allocation_status = 'ALLOCATED'
       AND (OLD.allocation_status <> 'ALLOCATED' OR OLD.course_id <> NEW.course_id) THEN

        SELECT total_seats INTO v_seats
        FROM Course_Master WHERE course_id = NEW.course_id;

        SELECT COUNT(*) INTO v_used
        FROM Course_Eligibility_Table
        WHERE course_id = NEW.course_id AND allocation_status = 'ALLOCATED';

        IF v_used >= v_seats THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Course is full: no seat left to allocate';
        END IF;

        IF EXISTS (SELECT 1 FROM Course_Eligibility_Table
                   WHERE acceptance_id = NEW.acceptance_id
                     AND allocation_status = 'ALLOCATED'
                     AND eligibility_id <> NEW.eligibility_id) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Applicant already has an allocated course';
        END IF;
    END IF;
END$$

-- ---- Enrollment and refunds --------------------------------

-- 2m. The three enrollment gates, enforced at the table: offer accepted,
--     fees fully paid, and the course really is the allocated one.
CREATE TRIGGER trg_enroll_gate
BEFORE INSERT ON Enrolled_Students
FOR EACH ROW
BEGIN
    DECLARE v_decision VARCHAR(10);
    DECLARE v_pay      VARCHAR(10);

    SELECT student_decision INTO v_decision
    FROM Acceptance_Table WHERE acceptance_id = NEW.acceptance_id;

    SELECT payment_status INTO v_pay
    FROM Fee_Payment_Table WHERE acceptance_id = NEW.acceptance_id;

    IF v_decision IS NULL OR v_decision <> 'ACCEPTED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot enroll: the offer has not been accepted';
    END IF;
    IF v_pay IS NULL OR v_pay <> 'PAID' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot enroll: fees are not fully paid';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Course_Eligibility_Table
                   WHERE acceptance_id = NEW.acceptance_id
                     AND course_id = NEW.course_id
                     AND allocation_status = 'ALLOCATED') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot enroll: course is not the allocated course';
    END IF;
END$$

-- 2n. A refund can never exceed what was actually paid (denied refunds
--     do not count against the limit).
CREATE TRIGGER trg_refund_cap
BEFORE INSERT ON Refund_Table
FOR EACH ROW
BEGIN
    DECLARE v_paid    DECIMAL(10,2);
    DECLARE v_already DECIMAL(10,2);

    SELECT amount_paid INTO v_paid
    FROM Fee_Payment_Table WHERE payment_id = NEW.payment_id;

    SELECT COALESCE(SUM(amount_refunded), 0) INTO v_already
    FROM Refund_Table
    WHERE payment_id = NEW.payment_id AND refund_status <> 'DENIED';

    IF NEW.amount_refunded + v_already > COALESCE(v_paid, 0) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Refund exceeds the amount actually paid';
    END IF;
END$$

DELIMITER ;


-- ============================================================
-- SECTION 3: STORED FUNCTIONS (5)
-- Functions return one value and can be used inside any SELECT.
-- ============================================================

DELIMITER $$

-- 3a. Age in whole years.
CREATE FUNCTION fn_applicant_age(p_dob DATE)
RETURNS INT
NOT DETERMINISTIC NO SQL
BEGIN
    RETURN TIMESTAMPDIFF(YEAR, p_dob, CURDATE());
END$$

-- 3b. Label a JEE score.
CREATE FUNCTION fn_score_band(p_score DECIMAL(6,2))
RETURNS VARCHAR(20)
DETERMINISTIC NO SQL
BEGIN
    RETURN CASE
        WHEN p_score >= 90 THEN 'Elite (90+)'
        WHEN p_score >= 80 THEN 'Excellent (80-89)'
        WHEN p_score >= 70 THEN 'Good (70-79)'
        WHEN p_score >= 60 THEN 'Average (60-69)'
        ELSE 'Below 60'
    END;
END$$

-- 3c. Merit formula: 70% entrance score + 30% school percentage.
CREATE FUNCTION fn_composite_score(p_jee DECIMAL(6,2), p_school DECIMAL(5,2))
RETURNS DECIMAL(6,2)
DETERMINISTIC NO SQL
BEGIN
    RETURN ROUND(0.7 * p_jee + 0.3 * p_school, 2);
END$$

-- 3d. Outstanding fee for one acceptance (NULL if there is no fee row).
CREATE FUNCTION fn_fee_balance(p_acceptance_id INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_balance DECIMAL(10,2);
    SELECT amount_due - amount_paid INTO v_balance
    FROM Fee_Payment_Table WHERE acceptance_id = p_acceptance_id;
    RETURN v_balance;
END$$

-- 3e. Seats still free in a course.
CREATE FUNCTION fn_seats_left(p_course_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_total INT;
    DECLARE v_used  INT;
    SELECT total_seats INTO v_total FROM Course_Master WHERE course_id = p_course_id;
    SELECT COUNT(*) INTO v_used
    FROM Course_Eligibility_Table
    WHERE course_id = p_course_id AND allocation_status = 'ALLOCATED';
    RETURN v_total - v_used;
END$$

DELIMITER ;



-- ============================================================
-- SECTION 4: STORED PROCEDURES (7 here + 1 test procedure in section 16)
-- All multi-step procedures use a transaction and an EXIT HANDLER, so
-- they either complete fully or leave nothing behind.
-- ============================================================

DELIMITER $$

-- 4a. Route an application to Accepted / Rejected / Incomplete.
--     Upgrades over the first version: validates its inputs, refuses to
--     re-decide an application that is already ACCEPTED/REJECTED, can
--     safely re-decide an INCOMPLETE one, and is atomic.
CREATE PROCEDURE sp_decide_application(
    IN p_application_id INT,
    IN p_cutoff_score DECIMAL(6,2)
)
BEGIN
    DECLARE v_score  DECIMAL(6,2);
    DECLARE v_docs   BOOLEAN;
    DECLARE v_status VARCHAR(20);
    DECLARE v_found  TINYINT DEFAULT 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_cutoff_score IS NULL OR p_cutoff_score < 0 OR p_cutoff_score > 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cutoff must be between 0 and 100';
    END IF;

    SELECT jee_score, docs_submitted, status
      INTO v_score, v_docs, v_status
    FROM Application_Master WHERE application_id = p_application_id;

    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Application not found';
    END IF;
    IF v_status IN ('ACCEPTED','REJECTED') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Application already decided - use the appeal procedures';
    END IF;

    START TRANSACTION;

    -- documents now complete: the old "incomplete" record (and its checklist,
    -- by cascade) is obsolete
    IF v_docs = TRUE THEN
        DELETE FROM Incomplete_Table WHERE application_id = p_application_id;
    END IF;

    IF v_docs = FALSE THEN
        UPDATE Application_Master SET status = 'INCOMPLETE' WHERE application_id = p_application_id;
        INSERT INTO Incomplete_Table (application_id, grace_period_end)
        VALUES (p_application_id, DATE_ADD(CURDATE(), INTERVAL 14 DAY))
        ON DUPLICATE KEY UPDATE grace_period_end = VALUES(grace_period_end);

    ELSEIF v_score >= p_cutoff_score THEN
        UPDATE Application_Master SET status = 'ACCEPTED' WHERE application_id = p_application_id;
        INSERT INTO Acceptance_Table (application_id, offer_date, response_deadline)
        VALUES (p_application_id, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 21 DAY));

    ELSE
        UPDATE Application_Master SET status = 'REJECTED' WHERE application_id = p_application_id;
        INSERT INTO Rejection_Table (application_id, rejection_reason, appeal_eligible)
        VALUES (p_application_id, 'Score below cutoff', TRUE);
    END IF;

    COMMIT;
END$$

-- 4b. Approve an appeal.
--     Flipping Application_Master.status to ACCEPTED by hand leaves the
--     applicant with no Acceptance_Table row -- an orphan that every
--     downstream join silently drops. This keeps the two in step, and
--     refuses to touch an appeal that has already been closed.
CREATE PROCEDURE sp_approve_appeal(IN p_appeal_id INT)
BEGIN
    DECLARE v_application_id INT;
    DECLARE v_appeal_status  VARCHAR(20);
    DECLARE v_found          TINYINT DEFAULT 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT rt.application_id, ap.appeal_status
      INTO v_application_id, v_appeal_status
    FROM Appeal_Table ap
    JOIN Rejection_Table rt ON rt.rejection_id = ap.rejection_id
    WHERE ap.appeal_id = p_appeal_id;

    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No such appeal';
    END IF;
    IF v_appeal_status IN ('APPROVED','DENIED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appeal is already closed';
    END IF;

    START TRANSACTION;

    UPDATE Appeal_Table SET appeal_status = 'APPROVED' WHERE appeal_id = p_appeal_id;
    UPDATE Application_Master SET status = 'ACCEPTED' WHERE application_id = v_application_id;

    INSERT INTO Acceptance_Table (application_id, offer_date, response_deadline)
    SELECT v_application_id, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 21 DAY)
    WHERE NOT EXISTS (
        SELECT 1 FROM Acceptance_Table WHERE application_id = v_application_id
    );

    COMMIT;
END$$

-- 4c. Deny an appeal (the missing half of 4b).
CREATE PROCEDURE sp_deny_appeal(IN p_appeal_id INT)
BEGIN
    DECLARE v_rejection_id  INT;
    DECLARE v_appeal_status VARCHAR(20);
    DECLARE v_found         TINYINT DEFAULT 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT rejection_id, appeal_status INTO v_rejection_id, v_appeal_status
    FROM Appeal_Table WHERE appeal_id = p_appeal_id;

    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No such appeal';
    END IF;
    IF v_appeal_status IN ('APPROVED','DENIED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appeal is already closed';
    END IF;

    START TRANSACTION;
    UPDATE Appeal_Table SET appeal_status = 'DENIED' WHERE appeal_id = p_appeal_id;
    -- one appeal per rejection: the door closes
    UPDATE Rejection_Table SET appeal_eligible = FALSE WHERE rejection_id = v_rejection_id;
    COMMIT;
END$$

-- 4d. Record a fee payment. Rejects non-positive amounts and over-payment;
--     trg_fee_status_upd then recomputes payment_status by itself.
--     (No transaction of its own, so a caller can wrap it in theirs.)
CREATE PROCEDURE sp_record_payment(
    IN p_acceptance_id INT,
    IN p_amount DECIMAL(10,2)
)
BEGIN
    DECLARE v_due   DECIMAL(10,2);
    DECLARE v_paid  DECIMAL(10,2);
    DECLARE v_found TINYINT DEFAULT 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment must be a positive amount';
    END IF;

    SELECT amount_due, amount_paid INTO v_due, v_paid
    FROM Fee_Payment_Table WHERE acceptance_id = p_acceptance_id;

    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No fee record for this acceptance';
    END IF;
    IF v_paid + p_amount > v_due THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds the amount due';
    END IF;

    UPDATE Fee_Payment_Table
    SET amount_paid = amount_paid + p_amount
    WHERE acceptance_id = p_acceptance_id;

    INSERT INTO Communication_Log (application_id, channel, message_summary)
    SELECT application_id, 'PORTAL', CONCAT('Payment received: Rs ', FORMAT(p_amount, 2))
    FROM Acceptance_Table WHERE acceptance_id = p_acceptance_id;
END$$

-- 4e. Enroll one student (for late cases the bulk INSERT...SELECT missed).
--     Generates the next roll number for the department. The three gates
--     are enforced by trg_enroll_gate, not repeated here.
CREATE PROCEDURE sp_enroll_student(IN p_acceptance_id INT)
BEGIN
    DECLARE v_course INT;
    DECLARE v_dept   VARCHAR(100);
    DECLARE v_seq    INT;
    DECLARE v_found  TINYINT DEFAULT 1;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;

    SELECT cet.course_id, cm.department INTO v_course, v_dept
    FROM Course_Eligibility_Table cet
    JOIN Course_Master cm ON cm.course_id = cet.course_id
    WHERE cet.acceptance_id = p_acceptance_id
      AND cet.allocation_status = 'ALLOCATED';

    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No allocated course for this acceptance';
    END IF;

    -- roll format: <DEPT>2027<3-digit running number>
    SELECT COALESCE(MAX(CAST(SUBSTRING(es.roll_number, CHAR_LENGTH(v_dept) + 5) AS UNSIGNED)), 0) + 1
      INTO v_seq
    FROM Enrolled_Students es
    JOIN Course_Master cm ON cm.course_id = es.course_id
    WHERE cm.department = v_dept;

    INSERT INTO Enrolled_Students (acceptance_id, course_id, enrollment_date, roll_number)
    VALUES (p_acceptance_id, v_course, CURDATE(), CONCAT(v_dept, '2027', LPAD(v_seq, 3, '0')));
END$$

-- 4f. Expire incomplete applications whose grace period has passed.
--     Rejects them, closes their incomplete record, and reports how many
--     rows were touched through an OUT parameter (ROW_COUNT() is the MySQL
--     counterpart of Oracle's implicit-cursor attribute SQL%ROWCOUNT).
--     Called daily by the event in section 15.
CREATE PROCEDURE sp_expire_incomplete_applications(OUT p_expired INT)
BEGIN
    -- 1. rejection record (skip anyone who somehow already has one)
    INSERT INTO Rejection_Table (application_id, rejection_reason, appeal_eligible)
    SELECT am.application_id, 'Documents not received within grace period', TRUE
    FROM Incomplete_Table it
    JOIN Application_Master am ON am.application_id = it.application_id
    WHERE it.grace_period_end < CURDATE()
      AND am.status = 'INCOMPLETE'
      AND NOT EXISTS (SELECT 1 FROM Rejection_Table r WHERE r.application_id = am.application_id);

    -- 2. flip the status (trg_log_status_change records it)
    UPDATE Application_Master am
    JOIN Incomplete_Table it ON it.application_id = am.application_id
    SET am.status = 'REJECTED'
    WHERE it.grace_period_end < CURDATE() AND am.status = 'INCOMPLETE';
    SET p_expired = ROW_COUNT();

    -- 3. the incomplete record and its checklist are no longer needed
    DELETE it FROM Incomplete_Table it
    JOIN Application_Master am ON am.application_id = it.application_id
    WHERE am.status = 'REJECTED' AND it.grace_period_end < CURDATE();
END$$

-- 4g. Add seats to every course in a department. Demonstrates ROW_COUNT()
--     (SQL%ROWCOUNT) and its use as SQL%NOTFOUND.
CREATE PROCEDURE sp_expand_department_seats(
    IN  p_department VARCHAR(100),
    IN  p_extra_seats INT,
    OUT p_rows_changed INT
)
BEGIN
    IF p_extra_seats IS NULL OR p_extra_seats <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Extra seats must be positive';
    END IF;

    UPDATE Course_Master
    SET total_seats = total_seats + p_extra_seats
    WHERE department = p_department;

    SET p_rows_changed = ROW_COUNT();

    IF p_rows_changed = 0 THEN                       -- SQL%NOTFOUND
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No course found in that department';
    END IF;
END$$

DELIMITER ;


-- ============================================================
-- SECTION 5: CURSORS
--
-- EXPLICIT cursor  : DECLARE ... CURSOR FOR, OPEN, FETCH, CLOSE, and a
--                    NOT FOUND handler to detect the end of the result set.
--                    Three loop styles are shown: LOOP/LEAVE, REPEAT/UNTIL,
--                    WHILE. 5c nests one cursor inside another.
-- IMPLICIT cursor  : MySQL has no cursor object you do not declare, but it
--                    has the same behaviour: SELECT ... INTO (one-row fetch),
--                    ROW_COUNT() (SQL%ROWCOUNT), and handlers for
--                    NO_DATA_FOUND (NOT FOUND) and TOO_MANY_ROWS (1172).
-- ============================================================

DELIMITER $$

-- 5a. EXPLICIT CURSOR, LOOP / LEAVE style.
--     Walks every unpaid, non-declined fee record with a balance of at least
--     p_min_balance (largest first) and queues an e-mail reminder for each.
CREATE PROCEDURE sp_send_fee_reminders(
    IN  p_min_balance DECIMAL(10,2),
    OUT p_reminders_sent INT
)
BEGIN
    DECLARE v_done    TINYINT DEFAULT 0;
    DECLARE v_app_id  INT;
    DECLARE v_balance DECIMAL(10,2);

    DECLARE cur_dues CURSOR FOR
        SELECT am.application_id, fp.amount_due - fp.amount_paid
        FROM Fee_Payment_Table fp
        JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
        JOIN Application_Master am ON am.application_id = acc.application_id
        WHERE fp.payment_status <> 'PAID'
          AND acc.student_decision <> 'DECLINED'
          AND fp.amount_due - fp.amount_paid >= p_min_balance
        ORDER BY fp.amount_due - fp.amount_paid DESC, am.application_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    SET p_reminders_sent = 0;

    OPEN cur_dues;
    read_loop: LOOP
        FETCH cur_dues INTO v_app_id, v_balance;
        IF v_done = 1 THEN
            LEAVE read_loop;
        END IF;

        INSERT INTO Communication_Log (application_id, channel, message_summary)
        VALUES (v_app_id, 'EMAIL',
                CONCAT('Fee reminder: Rs ', FORMAT(v_balance, 2), ' still outstanding'));

        SET p_reminders_sent = p_reminders_sent + 1;
    END LOOP read_loop;
    CLOSE cur_dues;
END$$

-- 5b. EXPLICIT CURSOR, REPEAT / UNTIL style.
--     Builds the merit rank list from accepted applicants. Equal composite
--     scores share a rank (1,2,2,4 ...), which is the tie logic that is
--     awkward to express in one SQL statement. p_top_n NULL = everyone.
CREATE PROCEDURE sp_build_merit_rank_list(IN p_top_n INT)
BEGIN
    DECLARE v_done   TINYINT DEFAULT 0;
    DECLARE v_app_id INT;
    DECLARE v_comp   DECIMAL(6,2);
    DECLARE v_prev   DECIMAL(6,2) DEFAULT NULL;
    DECLARE v_pos    INT DEFAULT 0;
    DECLARE v_rank   INT DEFAULT 0;

    DECLARE cur_merit CURSOR FOR
        SELECT application_id, fn_composite_score(jee_score, high_school_pct)
        FROM Application_Master
        WHERE status = 'ACCEPTED'
        ORDER BY fn_composite_score(jee_score, high_school_pct) DESC, application_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DELETE FROM Merit_Rank_List;
    SET v_done = 0;          -- defensive: no earlier statement may pre-set the end-of-data flag

    OPEN cur_merit;
    REPEAT
        FETCH cur_merit INTO v_app_id, v_comp;
        IF v_done = 0 THEN
            SET v_pos = v_pos + 1;
            IF v_prev IS NULL OR v_comp <> v_prev THEN
                SET v_rank = v_pos;                  -- new score -> new rank
            END IF;
            SET v_prev = v_comp;

            IF p_top_n IS NULL OR v_pos <= p_top_n THEN
                INSERT INTO Merit_Rank_List (application_id, composite_score, merit_rank)
                VALUES (v_app_id, v_comp, v_rank);
            ELSE
                SET v_done = 1;                      -- list is full, stop early
            END IF;
        END IF;
    UNTIL v_done = 1 END REPEAT;
    CLOSE cur_merit;

    SELECT mr.merit_rank, am.first_name, am.last_name, am.category,
           am.jee_score, am.high_school_pct, mr.composite_score
    FROM Merit_Rank_List mr
    JOIN Application_Master am ON am.application_id = mr.application_id
    ORDER BY mr.merit_rank, am.application_id;
END$$

-- 5c. NESTED EXPLICIT CURSORS, WHILE style for the inner loop.
--     Outer cursor: every course. Inner cursor: that course's enrolled
--     students. Writes one summary row per course. The inner cursor lives
--     in its own BEGIN...END block, with its own NOT FOUND handler, so
--     exhausting the inner cursor does not end the outer loop.
CREATE PROCEDURE sp_course_roster_report()
BEGIN
    DECLARE v_done_outer TINYINT DEFAULT 0;
    DECLARE v_course_id  INT;
    DECLARE v_course     VARCHAR(100);

    DECLARE cur_courses CURSOR FOR
        SELECT course_id, course_name FROM Course_Master ORDER BY course_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done_outer = 1;

    DELETE FROM Course_Roster_Report;
    SET v_done_outer = 0;    -- defensive: no earlier statement may pre-set the end-of-data flag

    OPEN cur_courses;
    course_loop: LOOP
        FETCH cur_courses INTO v_course_id, v_course;
        IF v_done_outer = 1 THEN
            LEAVE course_loop;
        END IF;

        -- ---- inner block: its own variables, cursor and handler ----
        BEGIN
            DECLARE v_done_inner TINYINT DEFAULT 0;
            DECLARE v_roll       VARCHAR(20);
            DECLARE v_student    VARCHAR(101);
            DECLARE v_count      INT DEFAULT 0;
            DECLARE v_roster     TEXT DEFAULT '';

            DECLARE cur_students CURSOR FOR
                SELECT es.roll_number, CONCAT(am.first_name, ' ', am.last_name)
                FROM Enrolled_Students es
                JOIN Acceptance_Table acc  ON acc.acceptance_id = es.acceptance_id
                JOIN Application_Master am ON am.application_id = acc.application_id
                WHERE es.course_id = v_course_id
                ORDER BY es.roll_number;

            DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done_inner = 1;

            OPEN cur_students;
            FETCH cur_students INTO v_roll, v_student;
            WHILE v_done_inner = 0 DO
                SET v_count  = v_count + 1;
                SET v_roster = CONCAT(v_roster, IF(v_count > 1, '; ', ''), v_roll, ' ', v_student);
                FETCH cur_students INTO v_roll, v_student;
            END WHILE;
            CLOSE cur_students;

            INSERT INTO Course_Roster_Report (course_id, course_name, enrolled_count, roster)
            VALUES (v_course_id, v_course, v_count, NULLIF(v_roster, ''));
        END;
    END LOOP course_loop;
    CLOSE cur_courses;

    SELECT course_id, course_name, enrolled_count, roster
    FROM Course_Roster_Report ORDER BY course_id;
END$$

-- 5d. IMPLICIT-CURSOR behaviour. No cursor is declared: SELECT ... INTO
--     fetches exactly one row, and the handlers play the role of
--     Oracle's NO_DATA_FOUND and TOO_MANY_ROWS exceptions.
CREATE PROCEDURE sp_implicit_cursor_demo(IN p_email VARCHAR(100))
BEGIN
    DECLARE v_app_id    INT;
    DECLARE v_other_id  INT;
    DECLARE v_name      VARCHAR(101);
    DECLARE v_score     DECIMAL(6,2);
    DECLARE v_total     INT;
    DECLARE v_found     TINYINT DEFAULT 1;     -- ~ SQL%FOUND
    DECLARE v_too_many  TINYINT DEFAULT 0;     -- ~ TOO_MANY_ROWS

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = 0;   -- ~ NO_DATA_FOUND
    DECLARE CONTINUE HANDLER FOR 1172 SET v_too_many = 1;     -- "result consisted of more than one row"

    -- (1) one-row implicit fetch
    SELECT application_id, CONCAT(first_name, ' ', last_name), jee_score
      INTO v_app_id, v_name, v_score
    FROM Application_Master WHERE email = p_email;

    -- (2) aggregate implicit fetch: always exactly one row
    SELECT COUNT(*) INTO v_total FROM Application_Master WHERE category = 'GENERAL';

    -- (3) implicit fetch that matches many rows -> TOO_MANY_ROWS
    SELECT application_id INTO v_other_id FROM Application_Master WHERE category = 'GENERAL';

    SELECT p_email                                      AS looked_up_email,
           IF(v_found = 1, 'yes', 'no (NO_DATA_FOUND)') AS row_found,
           v_name                                       AS applicant_name,
           v_score                                      AS jee_score,
           v_total                                      AS general_category_count,
           IF(v_too_many = 1, 'yes (TOO_MANY_ROWS)', 'no') AS too_many_rows_raised;
END$$

DELIMITER ;


-- ============================================================
-- SECTION 6: VIEWS (9)
-- ============================================================

-- 6a. Funnel counts, now with each status as a share of the whole.
CREATE VIEW vw_admission_funnel AS
SELECT
    status,
    COUNT(*) AS total_applications,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM Application_Master
GROUP BY status;

-- 6b. One row per applicant, walking the whole chain from the master table
--     down to enrollment. LEFT JOINs, because most applicants stop partway.
CREATE VIEW vw_applicant_360 AS
SELECT
    am.application_id,
    CONCAT(am.first_name, ' ', am.last_name) AS applicant_name,
    am.category,
    am.jee_score,
    am.status,
    cm.course_name          AS allocated_course,
    fp.amount_due,
    fp.amount_paid,
    fp.payment_status,
    ht.allotted_room_number AS hostel_room,
    es.roll_number,
    fn_score_band(am.jee_score)                            AS score_band,
    fn_composite_score(am.jee_score, am.high_school_pct)   AS composite_score
FROM Application_Master am
LEFT JOIN Acceptance_Table acc            ON acc.application_id = am.application_id
LEFT JOIN Course_Eligibility_Table cet    ON cet.acceptance_id  = acc.acceptance_id
                                          AND cet.allocation_status = 'ALLOCATED'
LEFT JOIN Course_Master cm                ON cm.course_id       = cet.course_id
LEFT JOIN Fee_Payment_Table fp            ON fp.acceptance_id   = acc.acceptance_id
LEFT JOIN Hostel_Accommodation_Table ht   ON ht.acceptance_id   = acc.acceptance_id
LEFT JOIN Enrolled_Students es            ON es.acceptance_id   = acc.acceptance_id;

-- 6c. FINANCE team: who still owes money (offers not declined).
CREATE VIEW vw_fee_defaulters AS
SELECT
    am.application_id,
    CONCAT(am.first_name, ' ', am.last_name) AS applicant_name,
    am.email,
    acc.student_decision,
    acc.response_deadline,
    fp.amount_due,
    fp.amount_paid,
    fp.amount_due - fp.amount_paid AS balance_due,
    fp.payment_status
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE fp.payment_status <> 'PAID'
  AND acc.student_decision <> 'DECLINED';

-- 6d. ADMISSIONS office: seat position per course (aggregated outer join).
CREATE VIEW vw_course_seat_status AS
SELECT
    cm.course_id,
    cm.course_name,
    cm.department,
    cm.total_seats,
    COALESCE(SUM(cet.allocation_status = 'ALLOCATED'),  0) AS allocated,
    COALESCE(SUM(cet.allocation_status = 'WAITLISTED'), 0) AS waitlisted,
    cm.total_seats - COALESCE(SUM(cet.allocation_status = 'ALLOCATED'), 0) AS seats_left,
    ROUND(100 * COALESCE(SUM(cet.allocation_status = 'ALLOCATED'), 0) / cm.total_seats, 1) AS fill_pct
FROM Course_Master cm
LEFT JOIN Course_Eligibility_Table cet ON cet.course_id = cm.course_id
GROUP BY cm.course_id, cm.course_name, cm.department, cm.total_seats;

-- 6e. Document chase list: what each incomplete applicant is still missing.
CREATE VIEW vw_pending_documents AS
SELECT
    am.application_id,
    CONCAT(am.first_name, ' ', am.last_name) AS applicant_name,
    it.grace_period_end,
    DATEDIFF(it.grace_period_end, CURDATE())  AS days_left,
    COUNT(*)                                  AS docs_outstanding,
    GROUP_CONCAT(dc.document_type ORDER BY dc.document_type SEPARATOR ', ') AS missing_documents
FROM Incomplete_Table it
JOIN Application_Master am ON am.application_id = it.application_id
JOIN Document_Checklist dc ON dc.incomplete_id  = it.incomplete_id
WHERE dc.status <> 'VERIFIED'
GROUP BY am.application_id, am.first_name, am.last_name, it.grace_period_end;

-- 6f. Scholarship scheme summary.
CREATE VIEW vw_scholarship_summary AS
SELECT
    sm.scholarship_code,
    sm.scholarship_name,
    sm.max_amount,
    COUNT(st.scholarship_id)                    AS awards,
    COALESCE(SUM(st.amount_awarded), 0)         AS total_awarded,
    ROUND(COALESCE(AVG(st.amount_awarded), 0), 2) AS avg_award
FROM Scholarship_Master sm
LEFT JOIN Scholarship_Table st ON st.scholarship_code = sm.scholarship_code
GROUP BY sm.scholarship_code, sm.scholarship_name, sm.max_amount;

-- 6g. Restricted view for the front desk: no date of birth, no e-mail,
--     no scores -- only what is needed to answer "where is my application?".
CREATE VIEW vw_public_applicant AS
SELECT
    application_id,
    CONCAT(first_name, ' ', LEFT(last_name, 1), '.') AS display_name,
    category,
    status
FROM Application_Master;

-- 6h. UPDATABLE view with WITH CHECK OPTION: staff can edit open applications
--     through it, but cannot push a row out of the view (e.g. set it to
--     ACCEPTED) because the check option re-tests the WHERE clause.
CREATE VIEW vw_open_applications AS
SELECT application_id, first_name, last_name, jee_score, docs_submitted, status
FROM Application_Master
WHERE status IN ('SUBMITTED', 'UNDER_REVIEW')
WITH CHECK OPTION;

-- 6i. NESTED view (a view built on a view): top two scorers per category,
--     ranked with a window function over vw_applicant_360.
CREATE VIEW vw_category_toppers AS
SELECT t.*
FROM (
    SELECT application_id, applicant_name, category, jee_score, status,
           RANK() OVER (PARTITION BY category ORDER BY jee_score DESC) AS category_rank
    FROM vw_applicant_360
) t
WHERE t.category_rank <= 2;



-- ============================================================
-- SECTION 7: SAMPLE DATA
-- ============================================================

-- 7.1 Courses (lookup)
INSERT INTO Course_Master (course_name, department, total_seats) VALUES
('B.Tech Artificial Intelligence',     'CSE',   120),
('B.Tech Computer Science',            'CSE',   180),
('B.Tech Electronics & Communication', 'ECE',   100),
('B.Tech Mechanical Engineering',      'MECH',   90),
('B.Tech Civil Engineering',           'CIVIL',  60),
('B.Tech Data Science',                'CSE',    90),
('B.Tech Electrical Engineering',      'EEE',    80),
('B.Tech Biotechnology',               'BT',     45);

-- 7.2 Scholarships (lookup)
INSERT INTO Scholarship_Master (scholarship_code, scholarship_name, max_amount) VALUES
('MERIT',    'Merit Scholarship',          50000.00),
('CATEGORY', 'Category Fee Waiver',        35000.00),
('SPORTS',   'Sports Excellence Award',    25000.00),
('DIVERSITY','Girl Child Education Grant', 30000.00),
('NEED',     'Need-Based Financial Aid',   40000.00);

-- 7.3 Applicants -- 25 rows, every one of them entering through the master table
INSERT INTO Application_Master
(first_name, last_name, dob, email, jee_score, high_school_pct, category, docs_submitted) VALUES
('Aarav','Sharma',      '2006-03-14','aarav.sharma@example.com',      92.50, 88.20, 'GENERAL', TRUE ),
('Priya','Iyer',        '2006-07-22','priya.iyer@example.com',        78.30, 91.00, 'OBC',     TRUE ),
('Kabir','Menon',       '2005-11-02','kabir.menon@example.com',       55.00, 76.40, 'GENERAL', TRUE ),
('Ananya','Das',        '2006-01-19','ananya.das@example.com',        88.10, 85.00, 'EWS',     FALSE),
('Rohan','Verma',       '2006-05-30','rohan.verma@example.com',       65.75, 70.30, 'SC',      TRUE ),
('Ishaan','Reddy',      '2006-02-11','ishaan.reddy@example.com',      95.20, 94.10, 'GENERAL', TRUE ),
('Meera','Nair',        '2006-09-05','meera.nair@example.com',        84.60, 89.70, 'GENERAL', TRUE ),
('Vivaan','Gupta',      '2005-12-18','vivaan.gupta@example.com',      71.00, 74.50, 'OBC',     TRUE ),
('Diya','Kulkarni',     '2006-04-27','diya.kulkarni@example.com',     69.90, 81.20, 'GENERAL', TRUE ),
('Arjun','Patel',       '2006-06-08','arjun.patel@example.com',       90.10, 87.60, 'GENERAL', FALSE),
('Saanvi','Joshi',      '2006-08-16','saanvi.joshi@example.com',      76.85, 83.90, 'EWS',     TRUE ),
('Aditya','Rao',        '2005-10-24','aditya.rao@example.com',        48.20, 65.80, 'GENERAL', TRUE ),
('Navya','Bose',        '2006-03-03','navya.bose@example.com',        82.40, 90.50, 'OBC',     TRUE ),
('Reyansh','Chauhan',   '2006-11-12','reyansh.chauhan@example.com',   70.00, 72.10, 'GENERAL', TRUE ),
('Anika','Mehta',       '2006-07-07','anika.mehta@example.com',       61.30, 79.40, 'ST',      TRUE ),
('Krishna','Pillai',    '2005-09-29','krishna.pillai@example.com',    87.75, 86.30, 'GENERAL', TRUE ),
('Tara','Sinha',        '2006-05-15','tara.sinha@example.com',        93.40, 92.80, 'GENERAL', FALSE),
('Dhruv','Malhotra',    '2006-01-31','dhruv.malhotra@example.com',    58.90, 68.70, 'OBC',     TRUE ),
('Ira','Banerjee',      '2006-10-09','ira.banerjee@example.com',      79.60, 88.90, 'GENERAL', TRUE ),
('Vihaan','Shetty',     '2006-04-02','vihaan.shetty@example.com',     66.20, 73.30, 'SC',      TRUE ),
('Myra','Kapoor',       '2006-12-21','myra.kapoor@example.com',       91.80, 93.40, 'GENERAL', TRUE ),
('Advait','Deshmukh',   '2006-06-26','advait.deshmukh@example.com',   73.15, 80.60, 'OBC',     TRUE ),
('Zara','Khan',         '2006-02-14','zara.khan@example.com',         85.30, 87.10, 'GENERAL', TRUE ),
('Nikhil','Chandra',    '2005-08-19','nikhil.chandra@example.com',    52.75, 66.90, 'ST',      TRUE ),
('Riya','Agarwal',      '2006-09-23','riya.agarwal@example.com',      74.40, 84.20, 'EWS',     FALSE);

-- 7.4 Route every applicant through the decision procedure (cutoff = 70.00)
CALL sp_decide_application( 1, 70.00);  -- Aarav    -> ACCEPTED
CALL sp_decide_application( 2, 70.00);  -- Priya    -> ACCEPTED
CALL sp_decide_application( 3, 70.00);  -- Kabir    -> REJECTED
CALL sp_decide_application( 4, 70.00);  -- Ananya   -> INCOMPLETE (docs missing)
CALL sp_decide_application( 5, 70.00);  -- Rohan    -> REJECTED   (appeals later, wins)
CALL sp_decide_application( 6, 70.00);  -- Ishaan   -> ACCEPTED
CALL sp_decide_application( 7, 70.00);  -- Meera    -> ACCEPTED
CALL sp_decide_application( 8, 70.00);  -- Vivaan   -> ACCEPTED
CALL sp_decide_application( 9, 70.00);  -- Diya     -> REJECTED   (0.10 below cutoff)
CALL sp_decide_application(10, 70.00);  -- Arjun    -> INCOMPLETE (high score, no docs)
CALL sp_decide_application(11, 70.00);  -- Saanvi   -> ACCEPTED
CALL sp_decide_application(12, 70.00);  -- Aditya   -> REJECTED
CALL sp_decide_application(13, 70.00);  -- Navya    -> ACCEPTED
CALL sp_decide_application(14, 70.00);  -- Reyansh  -> ACCEPTED   (exactly on the cutoff)
CALL sp_decide_application(15, 70.00);  -- Anika    -> REJECTED
CALL sp_decide_application(16, 70.00);  -- Krishna  -> ACCEPTED
CALL sp_decide_application(17, 70.00);  -- Tara     -> INCOMPLETE
CALL sp_decide_application(18, 70.00);  -- Dhruv    -> REJECTED
CALL sp_decide_application(19, 70.00);  -- Ira      -> ACCEPTED
CALL sp_decide_application(20, 70.00);  -- Vihaan   -> REJECTED   (appeals, denied)
CALL sp_decide_application(21, 70.00);  -- Myra     -> ACCEPTED
CALL sp_decide_application(22, 70.00);  -- Advait   -> ACCEPTED
CALL sp_decide_application(23, 70.00);  -- Zara     -> ACCEPTED
CALL sp_decide_application(24, 70.00);  -- Nikhil   -> REJECTED
CALL sp_decide_application(25, 70.00);  -- Riya     -> INCOMPLETE

-- ------------------------------------------------------------
-- Everything below keys off email rather than hard-coded ids.
-- The ids are deterministic (the script drops and recreates the
-- database), but "which student is this row about" should be
-- readable without counting AUTO_INCREMENT values by hand.
-- ------------------------------------------------------------

-- 7.5 Standard document checklist for every incomplete application
INSERT INTO Document_Checklist (incomplete_id, document_type)
SELECT it.incomplete_id, d.document_type
FROM Incomplete_Table it
CROSS JOIN (
    SELECT '10th Marksheet'       AS document_type
    UNION ALL SELECT '12th Marksheet'
    UNION ALL SELECT 'JEE Scorecard'
    UNION ALL SELECT 'Category Certificate'
    UNION ALL SELECT 'Transfer Certificate'
) d;

-- Some documents have already come in
UPDATE Document_Checklist dc
JOIN Incomplete_Table it ON it.incomplete_id = dc.incomplete_id
JOIN Application_Master am ON am.application_id = it.application_id
SET dc.status = 'VERIFIED'
WHERE am.email IN ('ananya.das@example.com','arjun.patel@example.com')
  AND dc.document_type IN ('10th Marksheet','12th Marksheet');

UPDATE Document_Checklist dc
JOIN Incomplete_Table it ON it.incomplete_id = dc.incomplete_id
JOIN Application_Master am ON am.application_id = it.application_id
SET dc.status = 'RECEIVED'
WHERE am.email = 'tara.sinha@example.com'
  AND dc.document_type = 'JEE Scorecard';

UPDATE Document_Checklist dc
JOIN Incomplete_Table it ON it.incomplete_id = dc.incomplete_id
JOIN Application_Master am ON am.application_id = it.application_id
SET dc.status = 'REJECTED'
WHERE am.email = 'riya.agarwal@example.com'
  AND dc.document_type = 'Category Certificate';

-- 7.6 Appeals filed by rejected applicants
INSERT INTO Appeal_Table (rejection_id, appeal_date, revised_score, appeal_status)
SELECT rt.rejection_id, a.appeal_date, a.revised_score, a.appeal_status
FROM (
    SELECT 'rohan.verma@example.com'   AS em, DATE_SUB(CURDATE(), INTERVAL 5 DAY) AS appeal_date, 71.00 AS revised_score, 'UNDER_REVIEW' AS appeal_status
    UNION ALL SELECT 'vihaan.shetty@example.com', DATE_SUB(CURDATE(), INTERVAL 4 DAY), 67.10, 'UNDER_REVIEW'
    UNION ALL SELECT 'diya.kulkarni@example.com', DATE_SUB(CURDATE(), INTERVAL 3 DAY), 70.40, 'UNDER_REVIEW'
    UNION ALL SELECT 'anika.mehta@example.com',   DATE_SUB(CURDATE(), INTERVAL 2 DAY), NULL,  'FILED'
) a
JOIN Application_Master am ON am.email = a.em
JOIN Rejection_Table rt    ON rt.application_id = am.application_id;

-- Rohan's appeal succeeds: the procedure flips the status AND creates the
-- Acceptance_Table row, so he isn't left ACCEPTED with nothing to join to.
CALL sp_approve_appeal((
    SELECT ap.appeal_id FROM Appeal_Table ap
    JOIN Rejection_Table rt   ON rt.rejection_id = ap.rejection_id
    JOIN Application_Master am ON am.application_id = rt.application_id
    WHERE am.email = 'rohan.verma@example.com'
));

-- Vihaan's appeal is denied: sp_deny_appeal closes the appeal AND clears
-- appeal_eligible on his rejection, so he cannot appeal twice.
CALL sp_deny_appeal((
    SELECT ap.appeal_id FROM Appeal_Table ap
    JOIN Rejection_Table rt   ON rt.rejection_id = ap.rejection_id
    JOIN Application_Master am ON am.application_id = rt.application_id
    WHERE am.email = 'vihaan.shetty@example.com'
));

-- 7.7 Course preferences for every accepted applicant
INSERT INTO Course_Eligibility_Table (acceptance_id, course_id, priority_preference, allocation_status)
SELECT acc.acceptance_id, cm.course_id, p.priority_preference, p.allocation_status
FROM (
    SELECT 'aarav.sharma@example.com'    AS em, 'B.Tech Artificial Intelligence'     AS course, 1 AS priority_preference, 'ALLOCATED'  AS allocation_status
    UNION ALL SELECT 'aarav.sharma@example.com',    'B.Tech Computer Science',            2, 'APPLIED'
    UNION ALL SELECT 'priya.iyer@example.com',      'B.Tech Computer Science',            1, 'ALLOCATED'
    UNION ALL SELECT 'priya.iyer@example.com',      'B.Tech Data Science',                2, 'APPLIED'
    UNION ALL SELECT 'ishaan.reddy@example.com',    'B.Tech Artificial Intelligence',     1, 'ALLOCATED'
    UNION ALL SELECT 'ishaan.reddy@example.com',    'B.Tech Data Science',                2, 'APPLIED'
    UNION ALL SELECT 'ishaan.reddy@example.com',    'B.Tech Computer Science',            3, 'APPLIED'
    UNION ALL SELECT 'meera.nair@example.com',      'B.Tech Data Science',                1, 'ALLOCATED'
    UNION ALL SELECT 'meera.nair@example.com',      'B.Tech Computer Science',            2, 'WAITLISTED'
    UNION ALL SELECT 'vivaan.gupta@example.com',    'B.Tech Electronics & Communication', 1, 'ALLOCATED'
    UNION ALL SELECT 'vivaan.gupta@example.com',    'B.Tech Electrical Engineering',      2, 'APPLIED'
    UNION ALL SELECT 'saanvi.joshi@example.com',    'B.Tech Computer Science',            1, 'ALLOCATED'
    UNION ALL SELECT 'saanvi.joshi@example.com',    'B.Tech Artificial Intelligence',     2, 'REJECTED'
    UNION ALL SELECT 'navya.bose@example.com',      'B.Tech Artificial Intelligence',     1, 'ALLOCATED'
    UNION ALL SELECT 'navya.bose@example.com',      'B.Tech Data Science',                2, 'WAITLISTED'
    UNION ALL SELECT 'reyansh.chauhan@example.com', 'B.Tech Mechanical Engineering',      1, 'ALLOCATED'
    UNION ALL SELECT 'reyansh.chauhan@example.com', 'B.Tech Civil Engineering',           2, 'APPLIED'
    UNION ALL SELECT 'krishna.pillai@example.com',  'B.Tech Computer Science',            1, 'ALLOCATED'
    UNION ALL SELECT 'krishna.pillai@example.com',  'B.Tech Electronics & Communication', 2, 'APPLIED'
    UNION ALL SELECT 'ira.banerjee@example.com',    'B.Tech Biotechnology',               1, 'ALLOCATED'
    UNION ALL SELECT 'ira.banerjee@example.com',    'B.Tech Civil Engineering',           2, 'APPLIED'
    UNION ALL SELECT 'myra.kapoor@example.com',     'B.Tech Artificial Intelligence',     1, 'ALLOCATED'
    UNION ALL SELECT 'myra.kapoor@example.com',     'B.Tech Computer Science',            2, 'APPLIED'
    UNION ALL SELECT 'advait.deshmukh@example.com', 'B.Tech Electrical Engineering',      1, 'ALLOCATED'
    UNION ALL SELECT 'advait.deshmukh@example.com', 'B.Tech Electronics & Communication', 2, 'WAITLISTED'
    UNION ALL SELECT 'zara.khan@example.com',       'B.Tech Data Science',                1, 'ALLOCATED'
    UNION ALL SELECT 'zara.khan@example.com',       'B.Tech Artificial Intelligence',     2, 'WAITLISTED'
    UNION ALL SELECT 'rohan.verma@example.com',     'B.Tech Civil Engineering',           1, 'ALLOCATED'
    UNION ALL SELECT 'rohan.verma@example.com',     'B.Tech Mechanical Engineering',      2, 'APPLIED'
) p
JOIN Application_Master am ON am.email = p.em
JOIN Acceptance_Table acc  ON acc.application_id = am.application_id
JOIN Course_Master cm      ON cm.course_name = p.course;

-- 7.8 Scholarship awards
INSERT INTO Scholarship_Table (acceptance_id, scholarship_code, amount_awarded)
SELECT acc.acceptance_id, s.code, s.amt
FROM (
    SELECT 'aarav.sharma@example.com'    AS em, 'MERIT'     AS code, 50000.00 AS amt
    UNION ALL SELECT 'ishaan.reddy@example.com',    'MERIT',     50000.00
    UNION ALL SELECT 'ishaan.reddy@example.com',    'SPORTS',    25000.00
    UNION ALL SELECT 'myra.kapoor@example.com',     'MERIT',     50000.00
    UNION ALL SELECT 'priya.iyer@example.com',      'CATEGORY',  35000.00
    UNION ALL SELECT 'rohan.verma@example.com',     'CATEGORY',  35000.00
    UNION ALL SELECT 'saanvi.joshi@example.com',    'CATEGORY',  30000.00
    UNION ALL SELECT 'meera.nair@example.com',      'DIVERSITY', 30000.00
    UNION ALL SELECT 'navya.bose@example.com',      'DIVERSITY', 30000.00
    UNION ALL SELECT 'ira.banerjee@example.com',    'DIVERSITY', 30000.00
    UNION ALL SELECT 'zara.khan@example.com',       'NEED',      40000.00
    UNION ALL SELECT 'krishna.pillai@example.com',  'NEED',      35000.00
    UNION ALL SELECT 'advait.deshmukh@example.com', 'SPORTS',    20000.00
) s
JOIN Application_Master am ON am.email = s.em
JOIN Acceptance_Table acc  ON acc.application_id = am.application_id;

-- 7.9 No INSERT needed here: trg_fee_row_on_accept already created a fee
--     row for every acceptance, and trg_fee_discount_on_scholarship already
--     deducted the awards inserted in 5.8.

-- 7.10 Payments received (payment_status is set by trg_fee_status_upd)
UPDATE Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
SET fp.amount_paid = fp.amount_due
WHERE am.email IN (
    'aarav.sharma@example.com','ishaan.reddy@example.com','meera.nair@example.com',
    'vivaan.gupta@example.com','navya.bose@example.com','krishna.pillai@example.com',
    'myra.kapoor@example.com','zara.khan@example.com','rohan.verma@example.com'
);

-- Part payments
UPDATE Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
JOIN (
    SELECT 'priya.iyer@example.com'      AS em, 50000.00 AS paid
    UNION ALL SELECT 'saanvi.joshi@example.com',    40000.00
    UNION ALL SELECT 'advait.deshmukh@example.com', 50000.00
    UNION ALL SELECT 'ira.banerjee@example.com',    60000.00
) p ON p.em = am.email
SET fp.amount_paid = p.paid;
-- Reyansh has paid nothing, so his row stays on PENDING.

-- 7.11 Hostel requests
INSERT INTO Hostel_Accommodation_Table (acceptance_id, room_type_preference, allotted_room_number)
SELECT acc.acceptance_id, h.room_type, h.room_no
FROM (
    SELECT 'aarav.sharma@example.com'   AS em, 'Single' AS room_type, 'H1-204' AS room_no
    UNION ALL SELECT 'priya.iyer@example.com',     'Shared', 'H2-118'
    UNION ALL SELECT 'ishaan.reddy@example.com',   'Single', 'H1-205'
    UNION ALL SELECT 'meera.nair@example.com',     'Shared', 'H2-119'
    UNION ALL SELECT 'vivaan.gupta@example.com',   'Shared', 'H1-310'
    UNION ALL SELECT 'navya.bose@example.com',     'Shared', 'H2-120'
    UNION ALL SELECT 'krishna.pillai@example.com', 'Single', 'H1-206'
    UNION ALL SELECT 'myra.kapoor@example.com',    'Single', 'H2-201'
    UNION ALL SELECT 'zara.khan@example.com',      'Shared', 'H2-121'
    UNION ALL SELECT 'rohan.verma@example.com',    'Shared', 'H1-311'
    UNION ALL SELECT 'ira.banerjee@example.com',   'Single', NULL
    UNION ALL SELECT 'advait.deshmukh@example.com','Shared', NULL
) h
JOIN Application_Master am ON am.email = h.em
JOIN Acceptance_Table acc  ON acc.application_id = am.application_id;

-- 7.12 Students respond to their offers
UPDATE Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
SET acc.student_decision = 'ACCEPTED'
WHERE am.email IN (
    'aarav.sharma@example.com','priya.iyer@example.com','ishaan.reddy@example.com',
    'meera.nair@example.com','vivaan.gupta@example.com','saanvi.joshi@example.com',
    'navya.bose@example.com','krishna.pillai@example.com','myra.kapoor@example.com',
    'zara.khan@example.com','rohan.verma@example.com'
);

UPDATE Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
SET acc.student_decision = 'DECLINED'
WHERE am.email IN ('reyansh.chauhan@example.com','ira.banerjee@example.com');
-- Advait is left on PENDING -- he hasn't replied yet.

-- 7.13 Enrollment: derived, not typed in. A student enrolls only when all
--      three conditions hold -- offer accepted, fees paid, course allocated.
--      Roll numbers are generated per department.
INSERT INTO Enrolled_Students (acceptance_id, course_id, enrollment_date, roll_number)
SELECT acc.acceptance_id,
       cet.course_id,
       CURDATE(),
       CONCAT(cm.department, '2027',
              LPAD(ROW_NUMBER() OVER (PARTITION BY cm.department ORDER BY acc.acceptance_id), 3, '0'))
FROM Acceptance_Table acc
JOIN Fee_Payment_Table fp          ON fp.acceptance_id = acc.acceptance_id
JOIN Course_Eligibility_Table cet  ON cet.acceptance_id = acc.acceptance_id
JOIN Course_Master cm              ON cm.course_id = cet.course_id
WHERE acc.student_decision   = 'ACCEPTED'
  AND fp.payment_status      = 'PAID'
  AND cet.allocation_status  = 'ALLOCATED';

-- 7.14 Refunds against fee payments
INSERT INTO Refund_Table (payment_id, amount_refunded, refund_status)
SELECT fp.payment_id, r.amt, r.st
FROM (
    SELECT 'ira.banerjee@example.com' AS em, 60000.00 AS amt, 'REQUESTED'  AS st
    UNION ALL SELECT 'aarav.sharma@example.com', 20000.00, 'PROCESSING'
    UNION ALL SELECT 'priya.iyer@example.com',    5000.00, 'DENIED'
) r
JOIN Application_Master am ON am.email = r.em
JOIN Acceptance_Table acc  ON acc.application_id = am.application_id
JOIN Fee_Payment_Table fp  ON fp.acceptance_id = acc.acceptance_id;

-- 7.15 Communication log, generated from each applicant's outcome
INSERT INTO Communication_Log (application_id, channel, message_summary)
SELECT application_id, 'EMAIL', 'Application received - under review'
FROM Application_Master;

INSERT INTO Communication_Log (application_id, channel, message_summary)
SELECT application_id, 'EMAIL', 'Admission offer letter sent'
FROM Application_Master WHERE status = 'ACCEPTED';

INSERT INTO Communication_Log (application_id, channel, message_summary)
SELECT application_id, 'EMAIL', 'Rejection notice sent'
FROM Application_Master WHERE status = 'REJECTED';

INSERT INTO Communication_Log (application_id, channel, message_summary)
SELECT application_id, 'SMS', 'Document reminder - grace period ends soon'
FROM Application_Master WHERE status = 'INCOMPLETE';

INSERT INTO Communication_Log (application_id, channel, message_summary)
SELECT acc.application_id, 'PORTAL', 'Fee payment confirmed'
FROM Acceptance_Table acc
JOIN Fee_Payment_Table fp ON fp.acceptance_id = acc.acceptance_id
WHERE fp.payment_status = 'PAID';

INSERT INTO Communication_Log (application_id, channel, message_summary)
SELECT acc.application_id, 'PORTAL', CONCAT('Hostel room allotted: ', ht.allotted_room_number)
FROM Acceptance_Table acc
JOIN Hostel_Accommodation_Table ht ON ht.acceptance_id = acc.acceptance_id
WHERE ht.allotted_room_number IS NOT NULL;



-- ============================================================
-- SECTION 8: DML EXAMPLES (INSERT / UPDATE / DELETE / UPSERT)
-- ============================================================

-- 8a. Advait finally replies and accepts his offer
UPDATE Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
SET acc.student_decision = 'ACCEPTED'
WHERE am.email = 'advait.deshmukh@example.com';

-- 8b. Ananya submits her missing documents, so she is re-decided.
--     sp_decide_application now removes her obsolete Incomplete_Table row
--     (cascading to the checklist) by itself, and trg_log_status_change
--     records INCOMPLETE -> ACCEPTED automatically.
UPDATE Application_Master SET docs_submitted = TRUE
WHERE email = 'ananya.das@example.com';

CALL sp_decide_application(
    (SELECT application_id FROM Application_Master WHERE email = 'ananya.das@example.com'),
    70.00
);

-- 8c. Diya's appeal is approved on review -- procedure keeps master + acceptance in step
CALL sp_approve_appeal((
    SELECT ap.appeal_id FROM Appeal_Table ap
    JOIN Rejection_Table rt    ON rt.rejection_id = ap.rejection_id
    JOIN Application_Master am ON am.application_id = rt.application_id
    WHERE am.email = 'diya.kulkarni@example.com'
));

-- 8d. Ira's refund completes
UPDATE Refund_Table r
JOIN Fee_Payment_Table fp  ON fp.payment_id = r.payment_id
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
SET r.refund_status = 'COMPLETED'
WHERE am.email = 'ira.banerjee@example.com';

-- 8e. Drop stale document reminders for applications that are no longer incomplete
--     (multi-table DELETE)
DELETE cl FROM Communication_Log cl
JOIN Application_Master am ON am.application_id = cl.application_id
WHERE cl.channel = 'SMS' AND am.status <> 'INCOMPLETE';

-- 8f. Free a hostel room for a student who declined
UPDATE Hostel_Accommodation_Table ht
JOIN Acceptance_Table acc ON acc.acceptance_id = ht.acceptance_id
SET ht.allotted_room_number = NULL
WHERE acc.student_decision = 'DECLINED';

-- 8g. UPSERT: add a new scheme, or refresh its cap if it already exists.
--     Running this statement twice is harmless.
INSERT INTO Scholarship_Master (scholarship_code, scholarship_name, max_amount)
VALUES ('RURAL', 'Rural Student Grant', 20000.00)
ON DUPLICATE KEY UPDATE max_amount = VALUES(max_amount);

-- 8h. UPDATE with CASE: students who have not answered get another week;
--     everyone else keeps the original deadline.
UPDATE Acceptance_Table
SET response_deadline = DATE_ADD(response_deadline,
        INTERVAL CASE WHEN student_decision = 'PENDING' THEN 7 ELSE 0 END DAY);

-- 8i. UPDATE driven by a correlated subquery: every course that has a
--     waiting list gets 5 extra seats.
UPDATE Course_Master cm
SET cm.total_seats = cm.total_seats + 5
WHERE (SELECT COUNT(*)
       FROM Course_Eligibility_Table cet
       WHERE cet.course_id = cm.course_id
         AND cet.allocation_status = 'WAITLISTED') > 0;

-- 8j. INSERT a walk-in applicant. Padding and capital letters in the input are
--     cleaned by trg_app_before_insert; trg_app_after_insert logs the first status.
INSERT INTO Application_Master
    (first_name, last_name, dob, email, jee_score, high_school_pct, category, docs_submitted)
VALUES
    ('  Test ', 'Withdrawn ', '2006-01-01', '  TEST.WITHDRAWN@Example.com ', 60.00, 60.00, 'GENERAL', TRUE);

SELECT application_id, CONCAT('[', first_name, ']') AS first_name, last_name, email, status
FROM Application_Master WHERE last_name = 'Withdrawn';       -- shows the cleaned values

-- 8k. UPDATE through the updatable view. The row is still SUBMITTED, so it is
--     visible in vw_open_applications and can be edited there.
UPDATE vw_open_applications SET jee_score = 61.50
WHERE first_name = 'Test' AND last_name = 'Withdrawn';

--     WITH CHECK OPTION would REJECT this one, because the new status ACCEPTED
--     takes the row out of the view (left commented: it would raise an error):
-- UPDATE vw_open_applications SET status = 'ACCEPTED' WHERE first_name = 'Test';

-- 8l. DELETE the withdrawn applicant; trg_app_archive_delete keeps a tombstone.
DELETE FROM Application_Master WHERE last_name = 'Withdrawn';

SELECT application_id, full_name, email, jee_score, last_status, deleted_by
FROM Deleted_Applications_Archive;

-- 8m. DELETE driven by a subquery: a document that was REJECTED and whose
--     grace period has lapsed is purged. (Matches nothing today; it is the
--     statement the nightly clean-up would run.)
DELETE FROM Document_Checklist
WHERE status = 'REJECTED'
  AND incomplete_id IN (SELECT incomplete_id FROM Incomplete_Table
                        WHERE grace_period_end < CURDATE());



-- ============================================================
-- SECTION 9: DQL -- CORE QUERIES (the original 15, unchanged in meaning)
-- ============================================================

-- 9a. Full applicant list with current status
SELECT application_id, first_name, last_name, category, jee_score, status
FROM Application_Master
ORDER BY jee_score DESC;

-- 9b. Accepted students with their allocated course
SELECT am.first_name, am.last_name, cm.course_name, cm.department, cet.allocation_status
FROM Application_Master am
JOIN Acceptance_Table acc         ON acc.application_id = am.application_id
JOIN Course_Eligibility_Table cet ON cet.acceptance_id  = acc.acceptance_id
JOIN Course_Master cm             ON cm.course_id       = cet.course_id
WHERE cet.allocation_status = 'ALLOCATED'
ORDER BY cm.department, am.last_name;

-- 9c. Fee balance per accepted student
SELECT am.first_name, am.last_name,
       fp.amount_due, fp.amount_paid,
       (fp.amount_due - fp.amount_paid) AS balance_due,
       fp.payment_status
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
JOIN Application_Master am ON am.application_id  = acc.application_id
ORDER BY balance_due DESC;

-- 9d. Rejected applicants still eligible to appeal but who haven't yet
SELECT am.first_name, am.last_name, am.jee_score, rt.rejection_reason
FROM Rejection_Table rt
JOIN Application_Master am ON am.application_id = rt.application_id
WHERE rt.appeal_eligible = TRUE
  AND rt.rejection_id NOT IN (SELECT rejection_id FROM Appeal_Table);

-- 9e. Full audit trail for one applicant (Rohan: rejected, appealed, accepted)
SELECT am.first_name, h.old_status, h.new_status, h.changed_at
FROM Application_Status_History h
JOIN Application_Master am ON am.application_id = h.application_id
WHERE am.email = 'rohan.verma@example.com'
ORDER BY h.changed_at, h.history_id;

-- 9f. Funnel counts via the view
SELECT * FROM vw_admission_funnel;

-- 9g. Seat demand per course
SELECT cm.course_name, cm.department, cm.total_seats,
       COUNT(cet.eligibility_id) AS applicants,
       SUM(cet.allocation_status = 'ALLOCATED') AS allocated,
       cm.total_seats - SUM(cet.allocation_status = 'ALLOCATED') AS seats_left
FROM Course_Master cm
LEFT JOIN Course_Eligibility_Table cet ON cet.course_id = cm.course_id
GROUP BY cm.course_id, cm.course_name, cm.department, cm.total_seats
ORDER BY applicants DESC;

-- 9h. Applicants who still need document reminders
SELECT am.first_name, am.last_name, it.grace_period_end,
       COUNT(*) AS documents_outstanding
FROM Incomplete_Table it
JOIN Application_Master am  ON am.application_id = it.application_id
JOIN Document_Checklist dc  ON dc.incomplete_id  = it.incomplete_id
WHERE dc.status <> 'VERIFIED' AND it.grace_period_end >= CURDATE()
GROUP BY am.application_id, am.first_name, am.last_name, it.grace_period_end;

-- 9i. Scholarship spend by scheme
SELECT sm.scholarship_name, sm.max_amount,
       COUNT(st.scholarship_id) AS awards,
       COALESCE(SUM(st.amount_awarded), 0) AS total_awarded
FROM Scholarship_Master sm
LEFT JOIN Scholarship_Table st ON st.scholarship_code = sm.scholarship_code
GROUP BY sm.scholarship_code, sm.scholarship_name, sm.max_amount
ORDER BY total_awarded DESC;

-- 9j. Category-wise outcome breakdown
SELECT category,
       COUNT(*) AS applied,
       SUM(status = 'ACCEPTED')   AS accepted,
       SUM(status = 'REJECTED')   AS rejected,
       SUM(status = 'INCOMPLETE') AS incomplete,
       ROUND(AVG(jee_score), 2)   AS avg_score
FROM Application_Master
GROUP BY category
ORDER BY applied DESC;

-- 9k. Enrolled students with course and hostel room
SELECT es.roll_number, am.first_name, am.last_name,
       cm.course_name, ht.allotted_room_number, es.enrollment_date
FROM Enrolled_Students es
JOIN Acceptance_Table acc  ON acc.acceptance_id = es.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
JOIN Course_Master cm      ON cm.course_id = es.course_id
LEFT JOIN Hostel_Accommodation_Table ht ON ht.acceptance_id = acc.acceptance_id
ORDER BY es.roll_number;

-- 9l. Accepted offers that have not converted into enrollment, and why
SELECT am.first_name, am.last_name,
       acc.student_decision,
       fp.payment_status,
       COALESCE(MAX(cet.allocation_status = 'ALLOCATED'), 0) AS has_course
FROM Acceptance_Table acc
JOIN Application_Master am        ON am.application_id = acc.application_id
LEFT JOIN Fee_Payment_Table fp    ON fp.acceptance_id  = acc.acceptance_id
LEFT JOIN Course_Eligibility_Table cet ON cet.acceptance_id = acc.acceptance_id
LEFT JOIN Enrolled_Students es    ON es.acceptance_id  = acc.acceptance_id
WHERE es.enrollment_id IS NULL
GROUP BY am.application_id, am.first_name, am.last_name, acc.student_decision, fp.payment_status;

-- 9m. Appeal outcomes with the score that triggered them
SELECT am.first_name, am.last_name, am.jee_score AS original_score,
       ap.revised_score, ap.appeal_status, am.status AS current_status
FROM Appeal_Table ap
JOIN Rejection_Table rt    ON rt.rejection_id = ap.rejection_id
JOIN Application_Master am ON am.application_id = rt.application_id
ORDER BY ap.appeal_date;

-- 9n. The 360-degree view, one row per applicant
SELECT * FROM vw_applicant_360 ORDER BY application_id;

-- 9o. Integrity check: nobody marked ACCEPTED without an Acceptance_Table row
SELECT am.application_id, am.first_name, am.last_name
FROM Application_Master am
LEFT JOIN Acceptance_Table acc ON acc.application_id = am.application_id
WHERE am.status = 'ACCEPTED' AND acc.acceptance_id IS NULL;



-- ============================================================
-- SECTION 10: JOINS -- every type
-- ============================================================

-- 10a. INNER JOIN (three tables): only applicants who have an offer AND a fee record
SELECT am.first_name, am.last_name, acc.student_decision, fp.amount_due, fp.payment_status
FROM Application_Master am
INNER JOIN Acceptance_Table acc  ON acc.application_id = am.application_id
INNER JOIN Fee_Payment_Table fp  ON fp.acceptance_id   = acc.acceptance_id
ORDER BY am.last_name;

-- 10b. LEFT OUTER JOIN: EVERY applicant, with offer details where they exist
--      (NULLs for rejected / incomplete applicants)
SELECT am.application_id, am.first_name, am.status,
       acc.acceptance_id, acc.student_decision
FROM Application_Master am
LEFT JOIN Acceptance_Table acc ON acc.application_id = am.application_id
ORDER BY am.application_id;

-- 10c. RIGHT OUTER JOIN: EVERY course, even those nobody has enrolled in yet
SELECT cm.course_name, cm.department, COUNT(es.enrollment_id) AS enrolled
FROM Enrolled_Students es
RIGHT JOIN Course_Master cm ON cm.course_id = es.course_id
GROUP BY cm.course_id, cm.course_name, cm.department
ORDER BY enrolled, cm.course_name;

-- 10d. FULL OUTER JOIN. MySQL has no FULL JOIN keyword, so it is built as
--      LEFT JOIN  UNION  RIGHT JOIN. Question answered: who has a scholarship,
--      who has a hostel request, who has both, and who has only one of the two.
WITH sch AS (
    SELECT acceptance_id, SUM(amount_awarded) AS total_awarded
    FROM Scholarship_Table
    GROUP BY acceptance_id
),
full_outer AS (
    SELECT COALESCE(s.acceptance_id, h.acceptance_id) AS acceptance_id,
           s.total_awarded, h.room_type_preference
    FROM sch s
    LEFT JOIN Hostel_Accommodation_Table h ON h.acceptance_id = s.acceptance_id
    UNION
    SELECT COALESCE(s.acceptance_id, h.acceptance_id),
           s.total_awarded, h.room_type_preference
    FROM sch s
    RIGHT JOIN Hostel_Accommodation_Table h ON h.acceptance_id = s.acceptance_id
)
SELECT am.first_name, am.last_name, fo.total_awarded, fo.room_type_preference,
       CASE WHEN fo.total_awarded IS NOT NULL AND fo.room_type_preference IS NOT NULL THEN 'Both'
            WHEN fo.total_awarded IS NOT NULL THEN 'Scholarship only'
            ELSE 'Hostel only' END AS coverage
FROM full_outer fo
JOIN Acceptance_Table acc  ON acc.acceptance_id  = fo.acceptance_id
JOIN Application_Master am ON am.application_id  = acc.application_id
ORDER BY coverage, am.last_name;

-- 10e. CROSS JOIN (Cartesian product): a complete category x status grid,
--      so combinations that never occur still appear with a zero.
SELECT c.category, s.status, COUNT(am.application_id) AS applicants
FROM (SELECT DISTINCT category FROM Application_Master) c
CROSS JOIN (SELECT DISTINCT status FROM Application_Master) s
LEFT JOIN Application_Master am ON am.category = c.category AND am.status = s.status
GROUP BY c.category, s.status
ORDER BY c.category, s.status;

-- 10f. SELF JOIN: pairs of applicants in the same category whose scores are
--      within 2 points of each other. (a.id < b.id lists each pair once.)
SELECT a.first_name AS applicant_1, b.first_name AS applicant_2, a.category,
       a.jee_score AS score_1, b.jee_score AS score_2,
       ABS(a.jee_score - b.jee_score) AS gap
FROM Application_Master a
JOIN Application_Master b
  ON  a.category = b.category
  AND a.application_id < b.application_id
  AND ABS(a.jee_score - b.jee_score) <= 2
ORDER BY gap, a.category;

-- 10g. NON-EQUI JOIN (range join): bucket every applicant into a score band.
SELECT bands.band_label, COUNT(am.application_id) AS applicants
FROM (SELECT   0 AS lo,  60 AS hi, 'Below 60'   AS band_label
      UNION ALL SELECT  60,  70, '60 - 69.99'
      UNION ALL SELECT  70,  80, '70 - 79.99'
      UNION ALL SELECT  80,  90, '80 - 89.99'
      UNION ALL SELECT  90, 101, '90 and above') bands
LEFT JOIN Application_Master am
       ON am.jee_score >= bands.lo AND am.jee_score < bands.hi
GROUP BY bands.lo, bands.band_label
ORDER BY bands.lo;

-- 10h. NATURAL JOIN: joins on every column name the two tables share. Here the
--      only shared column is acceptance_id. Convenient, but fragile -- add a
--      same-named column to either table and the result silently changes, so
--      real code prefers ON or USING.
SELECT acceptance_id, student_decision, amount_due, amount_paid, payment_status
FROM Acceptance_Table
NATURAL JOIN Fee_Payment_Table
ORDER BY acceptance_id;

-- 10i. JOIN ... USING: same idea, but the join column is named explicitly
SELECT course_id, course_name, department, roll_number
FROM Enrolled_Students
JOIN Course_Master USING (course_id)
ORDER BY course_id, roll_number;

-- 10j. ANTI JOIN (LEFT JOIN ... IS NULL): accepted students with NO hostel request
SELECT am.first_name, am.last_name, acc.student_decision
FROM Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
LEFT JOIN Hostel_Accommodation_Table ht ON ht.acceptance_id = acc.acceptance_id
WHERE ht.hostel_req_id IS NULL
ORDER BY am.last_name;

-- 10k. Multi-table join with a derived table: money picture per department.
--      Scholarships are summed per student FIRST (derived table), so a student
--      with two awards does not duplicate their fee row in the totals.
SELECT cm.department,
       COUNT(es.enrollment_id)                 AS enrolled,
       SUM(fp.amount_paid)                     AS fees_collected,
       COALESCE(SUM(sch.awarded), 0)           AS scholarships_given
FROM Enrolled_Students es
JOIN Acceptance_Table acc   ON acc.acceptance_id = es.acceptance_id
JOIN Course_Master cm       ON cm.course_id      = es.course_id
JOIN Fee_Payment_Table fp   ON fp.acceptance_id  = acc.acceptance_id
LEFT JOIN (SELECT acceptance_id, SUM(amount_awarded) AS awarded
           FROM Scholarship_Table
           GROUP BY acceptance_id) sch ON sch.acceptance_id = acc.acceptance_id
GROUP BY cm.department
ORDER BY fees_collected DESC;


-- ============================================================
-- SECTION 11: SUBQUERIES -- scalar, multi-row, correlated, nested, derived
-- ============================================================

-- 11a. SCALAR subquery in WHERE: applicants scoring above the overall average
SELECT first_name, last_name, jee_score
FROM Application_Master
WHERE jee_score > (SELECT AVG(jee_score) FROM Application_Master)
ORDER BY jee_score DESC;

-- 11b. SCALAR subquery in the SELECT list: each score against the average
SELECT first_name, jee_score,
       ROUND(jee_score - (SELECT AVG(jee_score) FROM Application_Master), 2) AS vs_average
FROM Application_Master
ORDER BY vs_average DESC;

-- 11c. MULTI-ROW subquery with IN, nested two levels deep: applicants who
--      filed an appeal
SELECT first_name, last_name, status
FROM Application_Master
WHERE application_id IN (
    SELECT application_id FROM Rejection_Table
    WHERE rejection_id IN (SELECT rejection_id FROM Appeal_Table)
);

-- 11d. NOT IN: accepted applicants who are NOT yet enrolled
SELECT am.first_name, am.last_name, acc.student_decision
FROM Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE acc.acceptance_id NOT IN (SELECT acceptance_id FROM Enrolled_Students);
-- (NOT IN returns nothing if the subquery yields a NULL. Enrolled_Students.acceptance_id
--  is NOT NULL, so it is safe here; NOT EXISTS in 11g is the NULL-proof form.)

-- 11e. DERIVED TABLE (subquery in FROM): department fee balances, computed per
--      student first so scholarships cannot multiply the totals
SELECT t.department, t.students, t.total_balance,
       ROUND(t.total_balance / t.students, 2) AS avg_balance
FROM (
    SELECT cm.department,
           COUNT(*) AS students,
           SUM(fp.amount_due - fp.amount_paid) AS total_balance
    FROM Course_Eligibility_Table cet
    JOIN Course_Master cm      ON cm.course_id     = cet.course_id
    JOIN Fee_Payment_Table fp  ON fp.acceptance_id = cet.acceptance_id
    WHERE cet.allocation_status = 'ALLOCATED'
    GROUP BY cm.department
) t
WHERE t.total_balance > 0
ORDER BY t.total_balance DESC;

-- 11f. ANY / ALL: scored higher than EVERY SC applicant; OBC applicants who beat AT LEAST ONE SC applicant
SELECT first_name, category, jee_score
FROM Application_Master
WHERE jee_score > ALL (SELECT jee_score FROM Application_Master WHERE category = 'SC')
  AND category <> 'SC'
ORDER BY jee_score
LIMIT 5;

SELECT first_name, category, jee_score
FROM Application_Master
WHERE category = 'OBC'
  AND jee_score > ANY (SELECT jee_score FROM Application_Master WHERE category = 'SC');

-- 11g. EXISTS / NOT EXISTS (semi-join and anti-join forms)
--      who holds at least one scholarship
SELECT am.first_name, am.last_name
FROM Application_Master am
WHERE EXISTS (SELECT 1
              FROM Acceptance_Table acc
              JOIN Scholarship_Table st ON st.acceptance_id = acc.acceptance_id
              WHERE acc.application_id = am.application_id);

--      accepted applicants with NO scholarship
SELECT am.first_name, am.last_name
FROM Application_Master am
WHERE am.status = 'ACCEPTED'
  AND NOT EXISTS (SELECT 1
                  FROM Acceptance_Table acc
                  JOIN Scholarship_Table st ON st.acceptance_id = acc.acceptance_id
                  WHERE acc.application_id = am.application_id);

-- 11h. CORRELATED subquery in WHERE: above the average of their OWN category.
--      The inner query is re-evaluated for every outer row (it refers to am.category).
SELECT am.first_name, am.category, am.jee_score
FROM Application_Master am
WHERE am.jee_score > (SELECT AVG(a2.jee_score)
                      FROM Application_Master a2
                      WHERE a2.category = am.category)
ORDER BY am.category, am.jee_score DESC;

-- 11i. CORRELATED subquery in the SELECT list: allocated vs waitlisted per course
SELECT cm.course_name,
       (SELECT COUNT(*) FROM Course_Eligibility_Table cet
        WHERE cet.course_id = cm.course_id AND cet.allocation_status = 'ALLOCATED')  AS allocated,
       (SELECT COUNT(*) FROM Course_Eligibility_Table cet
        WHERE cet.course_id = cm.course_id AND cet.allocation_status = 'WAITLISTED') AS waitlisted
FROM Course_Master cm
ORDER BY allocated DESC;

-- 11j. CORRELATED subquery with MAX: the LATEST status change of every applicant
SELECT h.application_id, h.old_status, h.new_status, h.changed_at
FROM Application_Status_History h
WHERE h.history_id = (SELECT MAX(h2.history_id)
                      FROM Application_Status_History h2
                      WHERE h2.application_id = h.application_id)
ORDER BY h.application_id;

-- 11k. Subquery in HAVING (with a derived table inside it): courses with more
--      allocated students than the average course
SELECT cm.course_name, COUNT(*) AS allocated
FROM Course_Eligibility_Table cet
JOIN Course_Master cm ON cm.course_id = cet.course_id
WHERE cet.allocation_status = 'ALLOCATED'
GROUP BY cm.course_id, cm.course_name
HAVING COUNT(*) > (SELECT AVG(per_course.n)
                   FROM (SELECT COUNT(*) AS n
                         FROM Course_Eligibility_Table
                         WHERE allocation_status = 'ALLOCATED'
                         GROUP BY course_id) per_course);

-- 11l. ROW subquery: the top scorer(s) of each category, matched on a (category, score) pair
SELECT first_name, last_name, category, jee_score
FROM Application_Master
WHERE (category, jee_score) IN (SELECT category, MAX(jee_score)
                                FROM Application_Master
                                GROUP BY category)
ORDER BY category;

-- 11m. NESTED subqueries, three levels: students in the department that has
--      received the most scholarship money, counting only accepted offers
SELECT am.first_name, am.last_name, cm.course_name, cm.department
FROM Application_Master am
JOIN Acceptance_Table acc         ON acc.application_id = am.application_id
JOIN Course_Eligibility_Table cet ON cet.acceptance_id  = acc.acceptance_id
                                 AND cet.allocation_status = 'ALLOCATED'
JOIN Course_Master cm             ON cm.course_id       = cet.course_id
WHERE cm.department = (
        SELECT cm2.department                                          -- level 2
        FROM Scholarship_Table st
        JOIN Course_Eligibility_Table c2 ON c2.acceptance_id = st.acceptance_id
                                        AND c2.allocation_status = 'ALLOCATED'
        JOIN Course_Master cm2           ON cm2.course_id = c2.course_id
        WHERE st.acceptance_id IN (SELECT acceptance_id               -- level 3
                                   FROM Acceptance_Table
                                   WHERE student_decision = 'ACCEPTED')
        GROUP BY cm2.department
        ORDER BY SUM(st.amount_awarded) DESC
        LIMIT 1
      )
ORDER BY am.last_name;


-- ============================================================
-- SECTION 12: CTEs, WINDOW FUNCTIONS, SET OPERATIONS, ROLLUP
-- ============================================================

-- 12a. CTE (WITH): outcome share of the whole intake
WITH outcome AS (
    SELECT status, COUNT(*) AS n FROM Application_Master GROUP BY status
),
total AS (
    SELECT SUM(n) AS t FROM outcome
)
SELECT o.status, o.n, ROUND(100 * o.n / t.t, 1) AS pct
FROM outcome o CROSS JOIN total t
ORDER BY o.n DESC;

-- 12b. RECURSIVE CTE: generates the score bands 40, 50, ... 90 and draws a text histogram
WITH RECURSIVE bands AS (
    SELECT 40 AS lo
    UNION ALL
    SELECT lo + 10 FROM bands WHERE lo < 90
)
SELECT CONCAT(b.lo, ' - ', b.lo + 9.99) AS score_band,
       COUNT(am.application_id)          AS applicants,
       REPEAT('#', COUNT(am.application_id)) AS histogram
FROM bands b
LEFT JOIN Application_Master am ON am.jee_score >= b.lo AND am.jee_score < b.lo + 10
GROUP BY b.lo
ORDER BY b.lo;

-- 12c. RECURSIVE CTE as a date generator: unanswered offers by deadline, next 5 weeks
WITH RECURSIVE days AS (
    SELECT CURDATE() AS d
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM days WHERE d < CURDATE() + INTERVAL 34 DAY
)
SELECT days.d AS deadline_date, COUNT(acc.acceptance_id) AS offers_expiring
FROM days
LEFT JOIN Acceptance_Table acc
       ON acc.response_deadline = days.d AND acc.student_decision = 'PENDING'
GROUP BY days.d
HAVING COUNT(acc.acceptance_id) > 0
ORDER BY days.d;

-- 12d. WINDOW functions -- ranking. Note how ties are treated by each function.
SELECT first_name, jee_score,
       ROW_NUMBER() OVER w AS row_no,
       RANK()       OVER w AS rnk,
       DENSE_RANK() OVER w AS dense_rnk,
       NTILE(4)     OVER w AS quartile
FROM Application_Master
WINDOW w AS (ORDER BY jee_score DESC)
ORDER BY row_no;

-- 12e. PARTITION BY: rank inside each category, plus the category's best score
SELECT category, first_name, jee_score,
       RANK() OVER (PARTITION BY category ORDER BY jee_score DESC)          AS rank_in_category,
       FIRST_VALUE(first_name) OVER (PARTITION BY category ORDER BY jee_score DESC) AS category_topper,
       ROUND(AVG(jee_score) OVER (PARTITION BY category), 2)                AS category_avg
FROM Application_Master
ORDER BY category, rank_in_category;

-- 12f. LAG / LEAD: gap to the applicant just above and just below
SELECT first_name, jee_score,
       LAG(jee_score)  OVER (ORDER BY jee_score DESC) AS score_above,
       LEAD(jee_score) OVER (ORDER BY jee_score DESC) AS score_below,
       ROUND(LAG(jee_score) OVER (ORDER BY jee_score DESC) - jee_score, 2) AS gap_to_next_up
FROM Application_Master
ORDER BY jee_score DESC;

-- 12g. Running total and share of total over scholarship awards
SELECT st.scholarship_id, st.scholarship_code, st.amount_awarded,
       SUM(st.amount_awarded) OVER (ORDER BY st.scholarship_id)               AS running_total,
       ROUND(100 * st.amount_awarded / SUM(st.amount_awarded) OVER (), 1)    AS pct_of_all_awards
FROM Scholarship_Table st
ORDER BY st.scholarship_id;

-- 12h. Moving average with an explicit frame (3 applicants at a time)
SELECT application_id, first_name, jee_score,
       ROUND(AVG(jee_score) OVER (ORDER BY application_id
                                  ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS moving_avg_3
FROM Application_Master
ORDER BY application_id;

-- 12i. CUME_DIST / PERCENT_RANK: where each score sits in the distribution
SELECT first_name, jee_score,
       ROUND(PERCENT_RANK() OVER (ORDER BY jee_score), 3) AS pct_rank,
       ROUND(CUME_DIST()    OVER (ORDER BY jee_score), 3) AS cume_dist
FROM Application_Master
ORDER BY jee_score DESC;

-- 12j. SET OPERATIONS. UNION removes duplicates; UNION ALL keeps them.
--      One follow-up list for the admissions office, with the reason for each row.
SELECT CONCAT(am.first_name, ' ', am.last_name) AS applicant, 'Documents missing' AS action_needed
FROM Application_Master am WHERE am.status = 'INCOMPLETE'
UNION
SELECT CONCAT(am.first_name, ' ', am.last_name), 'Offer not answered'
FROM Acceptance_Table acc JOIN Application_Master am ON am.application_id = acc.application_id
WHERE acc.student_decision = 'PENDING'
UNION
SELECT CONCAT(am.first_name, ' ', am.last_name), 'Fees outstanding'
FROM vw_fee_defaulters d JOIN Application_Master am ON am.application_id = d.application_id
ORDER BY applicant, action_needed;

-- 12k. INTERSECT and EXCEPT. MySQL 8.0.31+ supports them natively:
--        SELECT acceptance_id FROM Scholarship_Table
--        INTERSECT
--        SELECT acceptance_id FROM Hostel_Accommodation_Table;
--      The portable equivalents below run on every MySQL 8.0 release.
--      INTERSECT: students with a scholarship AND a hostel request
SELECT DISTINCT st.acceptance_id
FROM Scholarship_Table st
WHERE st.acceptance_id IN (SELECT acceptance_id FROM Hostel_Accommodation_Table);

--      EXCEPT: accepted offers that did NOT become an enrollment
--        (native:  SELECT acceptance_id FROM Acceptance_Table
--                  EXCEPT SELECT acceptance_id FROM Enrolled_Students;)
SELECT acc.acceptance_id
FROM Acceptance_Table acc
WHERE NOT EXISTS (SELECT 1 FROM Enrolled_Students es WHERE es.acceptance_id = acc.acceptance_id);

-- 12l. GROUP BY ... WITH ROLLUP: subtotals and a grand total in one pass.
--      GROUPING() tells a real value from a rolled-up NULL.
SELECT IF(GROUPING(category), 'ALL CATEGORIES', category) AS category,
       IF(GROUPING(status),   'ALL STATUSES',   status)   AS status,
       COUNT(*) AS applicants
FROM Application_Master
GROUP BY category, status WITH ROLLUP;

-- 12m. HAVING + conditional aggregation: categories where more than half applied successfully
SELECT category,
       COUNT(*)                                  AS applied,
       SUM(status = 'ACCEPTED')                  AS accepted,
       ROUND(100 * SUM(status = 'ACCEPTED') / COUNT(*), 1) AS acceptance_rate_pct,
       ROUND(STDDEV_POP(jee_score), 2)           AS score_stddev
FROM Application_Master
GROUP BY category
HAVING SUM(status = 'ACCEPTED') / COUNT(*) > 0.5
ORDER BY acceptance_rate_pct DESC;

-- 12n. GROUP_CONCAT: each course with the names of its allocated students
SELECT cm.course_name,
       COUNT(*) AS allocated,
       GROUP_CONCAT(am.first_name ORDER BY am.first_name SEPARATOR ', ') AS students
FROM Course_Eligibility_Table cet
JOIN Course_Master cm      ON cm.course_id = cet.course_id
JOIN Acceptance_Table acc  ON acc.acceptance_id = cet.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE cet.allocation_status = 'ALLOCATED'
GROUP BY cm.course_id, cm.course_name
ORDER BY allocated DESC, cm.course_name;

-- 12o. Scalar function showcase: string, date, NULL-handling and CASE functions
SELECT UPPER(CONCAT(first_name, ' ', last_name))               AS applicant,
       SUBSTRING_INDEX(email, '@', -1)                          AS email_domain,
       fn_applicant_age(dob)                                    AS age,
       DATE_FORMAT(dob, '%d %b %Y')                             AS born_on,
       fn_score_band(jee_score)                                 AS score_band,
       fn_composite_score(jee_score, high_school_pct)           AS composite_score,
       IFNULL(NULLIF(category, 'GENERAL'), 'No reservation')    AS reservation,
       CASE WHEN docs_submitted THEN 'Complete' ELSE 'Missing' END AS documents
FROM Application_Master
ORDER BY composite_score DESC
LIMIT 10;



-- ============================================================
-- SECTION 13: RUNNING THE FUNCTIONS, VIEWS, PROCEDURES AND CURSORS
-- ============================================================

-- 13a. Functions used directly inside SELECTs
SELECT fn_score_band(92.50)              AS band,
       fn_composite_score(92.50, 88.20)  AS composite,
       fn_applicant_age('2006-03-14')    AS age;

SELECT cm.course_name, cm.total_seats,
       fn_seats_left(cm.course_id) AS seats_left
FROM Course_Master cm
ORDER BY seats_left;

SELECT am.first_name, am.last_name, fn_fee_balance(acc.acceptance_id) AS fee_balance
FROM Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE fn_fee_balance(acc.acceptance_id) > 0
ORDER BY fee_balance DESC;

-- 13b. Every view
SELECT * FROM vw_admission_funnel;
SELECT * FROM vw_fee_defaulters ORDER BY balance_due DESC;
SELECT * FROM vw_course_seat_status ORDER BY fill_pct DESC;
SELECT * FROM vw_pending_documents;
SELECT * FROM vw_scholarship_summary ORDER BY total_awarded DESC;
SELECT * FROM vw_public_applicant WHERE status = 'REJECTED';
SELECT * FROM vw_open_applications;                 -- empty: every applicant has been decided
SELECT * FROM vw_category_toppers ORDER BY category, category_rank;

-- 13c. EXPLICIT CURSOR (LOOP / LEAVE): queue fee reminders for balances of Rs 10,000+
CALL sp_send_fee_reminders(10000.00, @reminders);
SELECT @reminders AS reminders_queued;

SELECT am.first_name, am.last_name, cl.message_summary
FROM Communication_Log cl
JOIN Application_Master am ON am.application_id = cl.application_id
WHERE cl.message_summary LIKE 'Fee reminder%'
ORDER BY cl.log_id;

-- 13d. EXPLICIT CURSOR (REPEAT / UNTIL): the top-10 merit list with tie handling
CALL sp_build_merit_rank_list(10);

-- 13e. NESTED EXPLICIT CURSORS: one row per course with its enrolled roster
CALL sp_course_roster_report();

-- 13f. IMPLICIT-CURSOR behaviour: a row that exists, and one that does not
CALL sp_implicit_cursor_demo('aarav.sharma@example.com');
CALL sp_implicit_cursor_demo('nobody@example.com');

-- 13g. Procedures run inside a transaction that is rolled back, so the demo
--      leaves the data exactly as it found it.

--      (i) payment -> status trigger -> enrollment, for Priya
START TRANSACTION;
SELECT acc.acceptance_id INTO @priya_acc
FROM Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE am.email = 'priya.iyer@example.com';

SELECT fn_fee_balance(@priya_acc) AS balance_before, payment_status AS status_before
FROM Fee_Payment_Table WHERE acceptance_id = @priya_acc;

CALL sp_record_payment(@priya_acc, fn_fee_balance(@priya_acc));   -- pays the whole balance
CALL sp_enroll_student(@priya_acc);                               -- allowed only now that fees are PAID

SELECT fp.payment_status AS status_after, es.roll_number, es.enrollment_date
FROM Fee_Payment_Table fp
JOIN Enrolled_Students es ON es.acceptance_id = fp.acceptance_id
WHERE fp.acceptance_id = @priya_acc;

SELECT old_paid, new_paid, old_status, new_status      -- written by trg_fee_audit
FROM Fee_Audit_Log
WHERE payment_id = (SELECT payment_id FROM Fee_Payment_Table WHERE acceptance_id = @priya_acc)
ORDER BY audit_id;
ROLLBACK;

--      (ii) ROW_COUNT() / SQL%ROWCOUNT: add 10 seats to every CSE course
START TRANSACTION;
CALL sp_expand_department_seats('CSE', 10, @rows_changed);
SELECT @rows_changed AS courses_updated;
SELECT course_name, total_seats FROM Course_Master WHERE department = 'CSE';
ROLLBACK;

--      (iii) expiry job: pretend Riya's grace period ended yesterday
START TRANSACTION;
UPDATE Incomplete_Table it
JOIN Application_Master am ON am.application_id = it.application_id
SET it.grace_period_end = DATE_SUB(CURDATE(), INTERVAL 1 DAY)
WHERE am.email = 'riya.agarwal@example.com';

CALL sp_expire_incomplete_applications(@expired);
SELECT @expired AS applications_expired;

SELECT am.first_name, am.status, rt.rejection_reason
FROM Application_Master am
JOIN Rejection_Table rt ON rt.application_id = am.application_id
WHERE am.email = 'riya.agarwal@example.com';
ROLLBACK;


-- ============================================================
-- SECTION 14: TRANSACTION CONTROL (COMMIT / ROLLBACK / SAVEPOINT)
-- ============================================================

-- 14a. COMMIT: Priya pays Rs 10,000 more, and it is kept.
START TRANSACTION;
UPDATE Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
SET fp.amount_paid = fp.amount_paid + 10000
WHERE am.email = 'priya.iyer@example.com';
COMMIT;

-- 14b. ROLLBACK: a catastrophic DELETE is undone
START TRANSACTION;
DELETE FROM Communication_Log;
SELECT COUNT(*) AS log_rows_inside_transaction FROM Communication_Log;
ROLLBACK;
SELECT COUNT(*) AS log_rows_after_rollback FROM Communication_Log;

-- 14c. SAVEPOINT: undo only the second of two changes
START TRANSACTION;

UPDATE Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
SET fp.amount_paid = fp.amount_paid + 10000
WHERE am.email = 'saanvi.joshi@example.com';

SAVEPOINT after_saanvi;

UPDATE Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
SET fp.amount_paid = fp.amount_paid + 10000
WHERE am.email = 'advait.deshmukh@example.com';

SELECT am.first_name, fp.amount_paid AS paid_with_both_changes
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE am.email IN ('saanvi.joshi@example.com', 'advait.deshmukh@example.com');

ROLLBACK TO SAVEPOINT after_saanvi;                 -- Advait's change vanishes, Saanvi's stays

SELECT am.first_name, fp.amount_paid AS paid_after_partial_rollback
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE am.email IN ('saanvi.joshi@example.com', 'advait.deshmukh@example.com');

ROLLBACK;                                           -- (use COMMIT here to keep Saanvi's payment)


-- ============================================================
-- SECTION 15: EVENT SCHEDULER
-- A daily job that rejects incomplete applications once the grace period
-- has ended. For the event to actually fire, the scheduler must be on:
--     SET GLOBAL event_scheduler = ON;
-- ============================================================

CREATE EVENT ev_expire_incomplete_applications
ON SCHEDULE EVERY 1 DAY
STARTS (CURRENT_TIMESTAMP + INTERVAL 1 DAY)
COMMENT 'Reject incomplete applications whose grace period has ended'
DO CALL sp_expire_incomplete_applications(@ev_expired);

SHOW EVENTS FROM admission_workflow_db;


-- ============================================================
-- SECTION 16: BUSINESS-RULE TESTS
-- Every statement below SHOULD FAIL. The procedure catches each error with
-- a CONTINUE handler + GET DIAGNOSTICS and reports the message, so the
-- whole script keeps running. A line reading '!! NOT BLOCKED' would mean a
-- rule is missing.
-- ============================================================

DELIMITER $$

CREATE PROCEDURE sp_test_business_rules()
BEGIN
    DECLARE v_msg TEXT DEFAULT NULL;
    DECLARE v_old_seats INT;

    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
    END;

    DROP TEMPORARY TABLE IF EXISTS tmp_rule_tests;
    CREATE TEMPORARY TABLE tmp_rule_tests (
        test_no    INT,
        rule_tested VARCHAR(70),
        outcome    TEXT
    );

    -- 1. scholarship above the scheme's cap (trigger)
    SET v_msg = NULL;
    INSERT INTO Scholarship_Table (acceptance_id, scholarship_code, amount_awarded)
    SELECT acc.acceptance_id, 'SPORTS', 30000
    FROM Acceptance_Table acc
    JOIN Application_Master am ON am.application_id = acc.application_id
    WHERE am.email = 'aarav.sharma@example.com';
    INSERT INTO tmp_rule_tests VALUES (1, 'Scholarship above scheme cap', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 2. refund larger than the amount paid (trigger)
    SET v_msg = NULL;
    INSERT INTO Refund_Table (payment_id, amount_refunded)
    SELECT fp.payment_id, 999999
    FROM Fee_Payment_Table fp
    JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
    JOIN Application_Master am ON am.application_id = acc.application_id
    WHERE am.email = 'aarav.sharma@example.com';
    INSERT INTO tmp_rule_tests VALUES (2, 'Refund above amount paid', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 3. enrolling a student who has only part-paid (trigger)
    SET v_msg = NULL;
    INSERT INTO Enrolled_Students (acceptance_id, course_id, enrollment_date, roll_number)
    SELECT acc.acceptance_id,
           (SELECT course_id FROM Course_Master WHERE course_name = 'B.Tech Computer Science'),
           CURDATE(), 'TEST001'
    FROM Acceptance_Table acc
    JOIN Application_Master am ON am.application_id = acc.application_id
    WHERE am.email = 'saanvi.joshi@example.com';
    INSERT INTO tmp_rule_tests VALUES (3, 'Enrol with fees not fully paid', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 4. re-opening a decided application (trigger)
    SET v_msg = NULL;
    UPDATE Application_Master SET status = 'SUBMITTED' WHERE email = 'aarav.sharma@example.com';
    INSERT INTO tmp_rule_tests VALUES (4, 'Reopen a decided application', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 5. under-age applicant (trigger)
    SET v_msg = NULL;
    INSERT INTO Application_Master (first_name, last_name, dob, email, jee_score, high_school_pct)
    VALUES ('Too', 'Young', DATE_SUB(CURDATE(), INTERVAL 10 YEAR), 'too.young@example.com', 50, 50);
    INSERT INTO tmp_rule_tests VALUES (5, 'Applicant under 16', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 6. second ALLOCATED course for one applicant (trigger)
    SET v_msg = NULL;
    INSERT INTO Course_Eligibility_Table (acceptance_id, course_id, priority_preference, allocation_status)
    SELECT acc.acceptance_id, cm.course_id, 3, 'ALLOCATED'
    FROM Acceptance_Table acc
    JOIN Application_Master am ON am.application_id = acc.application_id
    JOIN Course_Master cm      ON cm.course_name = 'B.Tech Biotechnology'
    WHERE am.email = 'aarav.sharma@example.com';
    INSERT INTO tmp_rule_tests VALUES (6, 'Two allocated courses for one student', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 7. allocating into a full course (trigger). Civil is squeezed to 1 seat
    --    (Rohan already holds it), the attempt is made, then the seats are restored.
    SELECT total_seats INTO v_old_seats FROM Course_Master WHERE course_name = 'B.Tech Civil Engineering';
    UPDATE Course_Master SET total_seats = 1 WHERE course_name = 'B.Tech Civil Engineering';
    SET v_msg = NULL;
    UPDATE Course_Eligibility_Table cet
    JOIN Acceptance_Table acc  ON acc.acceptance_id = cet.acceptance_id
    JOIN Application_Master am ON am.application_id = acc.application_id
    JOIN Course_Master cm      ON cm.course_id = cet.course_id
    SET cet.allocation_status = 'ALLOCATED'
    WHERE am.email = 'reyansh.chauhan@example.com' AND cm.course_name = 'B.Tech Civil Engineering';
    INSERT INTO tmp_rule_tests VALUES (7, 'Allocate into a full course', COALESCE(v_msg, '!! NOT BLOCKED'));
    UPDATE Course_Master SET total_seats = v_old_seats WHERE course_name = 'B.Tech Civil Engineering';

    -- 8. same scholarship twice (UNIQUE constraint)
    SET v_msg = NULL;
    INSERT INTO Scholarship_Table (acceptance_id, scholarship_code, amount_awarded)
    SELECT acc.acceptance_id, 'MERIT', 1000
    FROM Acceptance_Table acc
    JOIN Application_Master am ON am.application_id = acc.application_id
    WHERE am.email = 'aarav.sharma@example.com';
    INSERT INTO tmp_rule_tests VALUES (8, 'Duplicate scholarship (UNIQUE)', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 9. impossible score (CHECK constraint)
    SET v_msg = NULL;
    INSERT INTO Application_Master (first_name, last_name, dob, email, jee_score, high_school_pct)
    VALUES ('Bad', 'Score', '2006-01-01', 'bad.score@example.com', 150, 50);
    INSERT INTO tmp_rule_tests VALUES (9, 'JEE score above 100 (CHECK)', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 10. deleting a course that students are enrolled in (FK ... RESTRICT)
    SET v_msg = NULL;
    DELETE FROM Course_Master WHERE course_name = 'B.Tech Civil Engineering';
    INSERT INTO tmp_rule_tests VALUES (10, 'Delete a referenced course (FK RESTRICT)', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 11. decision procedure: unknown applicant, and one already decided
    SET v_msg = NULL;
    CALL sp_decide_application(99999, 70.00);
    INSERT INTO tmp_rule_tests VALUES (11, 'Decide a non-existent application', COALESCE(v_msg, '!! NOT BLOCKED'));

    SET v_msg = NULL;
    CALL sp_decide_application(1, 70.00);
    INSERT INTO tmp_rule_tests VALUES (12, 'Re-decide an ACCEPTED application', COALESCE(v_msg, '!! NOT BLOCKED'));

    -- 13. over-payment
    SET v_msg = NULL;
    CALL sp_record_payment(
        (SELECT acc.acceptance_id FROM Acceptance_Table acc
         JOIN Application_Master am ON am.application_id = acc.application_id
         WHERE am.email = 'aarav.sharma@example.com'),
        1000000);
    INSERT INTO tmp_rule_tests VALUES (13, 'Payment above amount due', COALESCE(v_msg, '!! NOT BLOCKED'));

    SELECT test_no, rule_tested, outcome FROM tmp_rule_tests ORDER BY test_no;
    DROP TEMPORARY TABLE tmp_rule_tests;
END$$

DELIMITER ;

CALL sp_test_business_rules();

-- Integrity re-check after all that abuse: nothing should have changed.
SELECT * FROM vw_admission_funnel;


-- ============================================================
-- SECTION 17: DCL -- roles and privileges (optional)
-- Needs an account allowed to create users (e.g. root). Uncomment to run.
-- ============================================================
-- CREATE ROLE IF NOT EXISTS admissions_office, finance_team;
-- GRANT SELECT ON admission_workflow_db.vw_public_applicant   TO admissions_office;
-- GRANT SELECT, UPDATE ON admission_workflow_db.vw_open_applications TO admissions_office;
-- GRANT SELECT ON admission_workflow_db.vw_fee_defaulters      TO finance_team;
-- GRANT SELECT ON admission_workflow_db.vw_scholarship_summary TO finance_team;
-- GRANT EXECUTE ON PROCEDURE admission_workflow_db.sp_record_payment TO finance_team;
-- CREATE USER IF NOT EXISTS 'frontdesk'@'localhost' IDENTIFIED BY 'ChangeMe#2026';
-- GRANT admissions_office TO 'frontdesk'@'localhost';
-- SHOW GRANTS FOR admissions_office;
-- REVOKE UPDATE ON admission_workflow_db.vw_open_applications FROM admissions_office;
-- DROP USER 'frontdesk'@'localhost';
