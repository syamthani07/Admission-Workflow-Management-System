
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- MySQL Workbench compatible script
-- Tables -> Triggers/Procedures/View -> Sample Data -> DML -> DQL


DROP DATABASE IF EXISTS admission_workflow_db;
CREATE DATABASE admission_workflow_db;
USE admission_workflow_db;


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
--
-- Course_Master and Scholarship_Master are the two lookup
-- (reference) tables; they are not owned by any applicant.
-- ============================================================


-- SECTION 1: TABLE CREATION (16 tables)


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


-- ============================================================
-- SECTION 2: TRIGGERS
-- ============================================================

DELIMITER $$

-- 2a. Auto-log status changes on the master table.
CREATE TRIGGER trg_log_status_change
AFTER UPDATE ON Application_Master
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO Application_Status_History (application_id, old_status, new_status)
        VALUES (NEW.application_id, OLD.status, NEW.status);
    END IF;
END$$

-- 2b. Every acceptance gets a fee record, automatically. This is what makes
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

-- 2c. Awarding a scholarship reduces what the student owes, whenever it
--     is awarded -- so Fee_Payment stays derived from Scholarship_Table.
CREATE TRIGGER trg_fee_discount_on_scholarship
AFTER INSERT ON Scholarship_Table
FOR EACH ROW
BEGIN
    UPDATE Fee_Payment_Table
    SET amount_due = GREATEST(0, amount_due - NEW.amount_awarded)
    WHERE acceptance_id = NEW.acceptance_id;
END$$

-- 2d. Keep payment_status derived from the amounts, so it can never
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

-- 2e. A scholarship award may not exceed the cap in Scholarship_Master.
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

DELIMITER ;


-- ============================================================
-- SECTION 3: STORED PROCEDURES
-- ============================================================

DELIMITER $$

-- 3a. Route an application to Accepted / Rejected / Incomplete.
CREATE PROCEDURE sp_decide_application(
    IN p_application_id INT,
    IN p_cutoff_score DECIMAL(6,2)
)
BEGIN
    DECLARE v_score DECIMAL(6,2);
    DECLARE v_docs BOOLEAN;

    SELECT jee_score, docs_submitted INTO v_score, v_docs
    FROM Application_Master WHERE application_id = p_application_id;

    IF v_docs = FALSE THEN
        UPDATE Application_Master SET status = 'INCOMPLETE' WHERE application_id = p_application_id;
        INSERT INTO Incomplete_Table (application_id, grace_period_end)
        VALUES (p_application_id, DATE_ADD(CURDATE(), INTERVAL 14 DAY));

    ELSEIF v_score >= p_cutoff_score THEN
        UPDATE Application_Master SET status = 'ACCEPTED' WHERE application_id = p_application_id;
        INSERT INTO Acceptance_Table (application_id, offer_date, response_deadline)
        VALUES (p_application_id, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 21 DAY));

    ELSE
        UPDATE Application_Master SET status = 'REJECTED' WHERE application_id = p_application_id;
        INSERT INTO Rejection_Table (application_id, rejection_reason, appeal_eligible)
        VALUES (p_application_id, 'Score below cutoff', TRUE);
    END IF;
END$$

-- 3b. Approve an appeal.
--     Flipping Application_Master.status to ACCEPTED by hand leaves the
--     applicant with no Acceptance_Table row -- an orphan that every
--     downstream join silently drops. This keeps the two in step.
CREATE PROCEDURE sp_approve_appeal(IN p_appeal_id INT)
BEGIN
    DECLARE v_application_id INT;

    SELECT rt.application_id INTO v_application_id
    FROM Appeal_Table ap
    JOIN Rejection_Table rt ON rt.rejection_id = ap.rejection_id
    WHERE ap.appeal_id = p_appeal_id;

    IF v_application_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No such appeal';
    END IF;

    UPDATE Appeal_Table SET appeal_status = 'APPROVED' WHERE appeal_id = p_appeal_id;
    UPDATE Application_Master SET status = 'ACCEPTED' WHERE application_id = v_application_id;

    INSERT INTO Acceptance_Table (application_id, offer_date, response_deadline)
    SELECT v_application_id, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 21 DAY)
    WHERE NOT EXISTS (
        SELECT 1 FROM Acceptance_Table WHERE application_id = v_application_id
    );
END$$

DELIMITER ;


-- ============================================================
-- SECTION 4: VIEWS
-- ============================================================

CREATE VIEW vw_admission_funnel AS
SELECT
    status,
    COUNT(*) AS total_applications
FROM Application_Master
GROUP BY status;

-- One row per applicant, walking the whole chain from the master table
-- down to enrollment. LEFT JOINs, because most applicants stop partway.
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
    es.roll_number
FROM Application_Master am
LEFT JOIN Acceptance_Table acc            ON acc.application_id = am.application_id
LEFT JOIN Course_Eligibility_Table cet    ON cet.acceptance_id  = acc.acceptance_id
                                          AND cet.allocation_status = 'ALLOCATED'
LEFT JOIN Course_Master cm                ON cm.course_id       = cet.course_id
LEFT JOIN Fee_Payment_Table fp            ON fp.acceptance_id   = acc.acceptance_id
LEFT JOIN Hostel_Accommodation_Table ht   ON ht.acceptance_id   = acc.acceptance_id
LEFT JOIN Enrolled_Students es            ON es.acceptance_id   = acc.acceptance_id;


-- ============================================================
-- SECTION 5: SAMPLE DATA
-- ============================================================

-- 5.1 Courses (lookup)
INSERT INTO Course_Master (course_name, department, total_seats) VALUES
('B.Tech Artificial Intelligence',     'CSE',   120),
('B.Tech Computer Science',            'CSE',   180),
('B.Tech Electronics & Communication', 'ECE',   100),
('B.Tech Mechanical Engineering',      'MECH',   90),
('B.Tech Civil Engineering',           'CIVIL',  60),
('B.Tech Data Science',                'CSE',    90),
('B.Tech Electrical Engineering',      'EEE',    80),
('B.Tech Biotechnology',               'BT',     45);

-- 5.2 Scholarships (lookup)
INSERT INTO Scholarship_Master (scholarship_code, scholarship_name, max_amount) VALUES
('MERIT',    'Merit Scholarship',          50000.00),
('CATEGORY', 'Category Fee Waiver',        35000.00),
('SPORTS',   'Sports Excellence Award',    25000.00),
('DIVERSITY','Girl Child Education Grant', 30000.00),
('NEED',     'Need-Based Financial Aid',   40000.00);

-- 5.3 Applicants -- 25 rows, every one of them entering through the master table
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

-- 5.4 Route every applicant through the decision procedure (cutoff = 70.00)
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

-- 5.5 Standard document checklist for every incomplete application
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

-- 5.6 Appeals filed by rejected applicants
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

-- Vihaan's appeal is denied
UPDATE Appeal_Table ap
JOIN Rejection_Table rt    ON rt.rejection_id = ap.rejection_id
JOIN Application_Master am ON am.application_id = rt.application_id
SET ap.appeal_status = 'DENIED'
WHERE am.email = 'vihaan.shetty@example.com';

-- 5.7 Course preferences for every accepted applicant
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

-- 5.8 Scholarship awards
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

-- 5.9 No INSERT needed here: trg_fee_row_on_accept already created a fee
--     row for every acceptance, and trg_fee_discount_on_scholarship already
--     deducted the awards inserted in 5.8.

-- 5.10 Payments received (payment_status is set by trg_fee_status_upd)
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

-- 5.11 Hostel requests
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

-- 5.12 Students respond to their offers
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

-- 5.13 Enrollment: derived, not typed in. A student enrolls only when all
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

-- 5.14 Refunds against fee payments
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

-- 5.15 Communication log, generated from each applicant's outcome
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
-- SECTION 6: DML EXAMPLES (UPDATE / DELETE)
-- ============================================================

-- 6a. Advait finally replies and accepts his offer
UPDATE Acceptance_Table acc
JOIN Application_Master am ON am.application_id = acc.application_id
SET acc.student_decision = 'ACCEPTED'
WHERE am.email = 'advait.deshmukh@example.com';

-- 6b. Ananya submits her missing documents, so she is re-decided.
--     The status change is picked up by trg_log_status_change automatically.
UPDATE Application_Master SET docs_submitted = TRUE
WHERE email = 'ananya.das@example.com';

DELETE it FROM Incomplete_Table it
JOIN Application_Master am ON am.application_id = it.application_id
WHERE am.email = 'ananya.das@example.com';   -- cascades to Document_Checklist

CALL sp_decide_application(
    (SELECT application_id FROM Application_Master WHERE email = 'ananya.das@example.com'),
    70.00
);

-- 6c. Diya's appeal is approved on review -- procedure keeps master + acceptance in step
CALL sp_approve_appeal((
    SELECT ap.appeal_id FROM Appeal_Table ap
    JOIN Rejection_Table rt    ON rt.rejection_id = ap.rejection_id
    JOIN Application_Master am ON am.application_id = rt.application_id
    WHERE am.email = 'diya.kulkarni@example.com'
));

-- 6d. Ira's refund completes
UPDATE Refund_Table r
JOIN Fee_Payment_Table fp  ON fp.payment_id = r.payment_id
JOIN Acceptance_Table acc  ON acc.acceptance_id = fp.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
SET r.refund_status = 'COMPLETED'
WHERE am.email = 'ira.banerjee@example.com';

-- 6e. Drop stale document reminders for applications that are no longer incomplete
DELETE cl FROM Communication_Log cl
JOIN Application_Master am ON am.application_id = cl.application_id
WHERE cl.channel = 'SMS' AND am.status <> 'INCOMPLETE';

-- 6f. Free a hostel room for a student who declined
UPDATE Hostel_Accommodation_Table ht
JOIN Acceptance_Table acc ON acc.acceptance_id = ht.acceptance_id
SET ht.allotted_room_number = NULL
WHERE acc.student_decision = 'DECLINED';


-- ============================================================
-- SECTION 7: DQL EXAMPLES (SELECT queries)
-- ============================================================

-- 7a. Full applicant list with current status
SELECT application_id, first_name, last_name, category, jee_score, status
FROM Application_Master
ORDER BY jee_score DESC;

-- 7b. Accepted students with their allocated course
SELECT am.first_name, am.last_name, cm.course_name, cm.department, cet.allocation_status
FROM Application_Master am
JOIN Acceptance_Table acc         ON acc.application_id = am.application_id
JOIN Course_Eligibility_Table cet ON cet.acceptance_id  = acc.acceptance_id
JOIN Course_Master cm             ON cm.course_id       = cet.course_id
WHERE cet.allocation_status = 'ALLOCATED'
ORDER BY cm.department, am.last_name;

-- 7c. Fee balance per accepted student
SELECT am.first_name, am.last_name,
       fp.amount_due, fp.amount_paid,
       (fp.amount_due - fp.amount_paid) AS balance_due,
       fp.payment_status
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc  ON acc.acceptance_id  = fp.acceptance_id
JOIN Application_Master am ON am.application_id  = acc.application_id
ORDER BY balance_due DESC;

-- 7d. Rejected applicants still eligible to appeal but who haven't yet
SELECT am.first_name, am.last_name, am.jee_score, rt.rejection_reason
FROM Rejection_Table rt
JOIN Application_Master am ON am.application_id = rt.application_id
WHERE rt.appeal_eligible = TRUE
  AND rt.rejection_id NOT IN (SELECT rejection_id FROM Appeal_Table);

-- 7e. Full audit trail for one applicant (Rohan: rejected, appealed, accepted)
SELECT am.first_name, h.old_status, h.new_status, h.changed_at
FROM Application_Status_History h
JOIN Application_Master am ON am.application_id = h.application_id
WHERE am.email = 'rohan.verma@example.com'
ORDER BY h.changed_at, h.history_id;

-- 7f. Funnel counts via the view
SELECT * FROM vw_admission_funnel;

-- 7g. Seat demand per course
SELECT cm.course_name, cm.department, cm.total_seats,
       COUNT(cet.eligibility_id) AS applicants,
       SUM(cet.allocation_status = 'ALLOCATED') AS allocated,
       cm.total_seats - SUM(cet.allocation_status = 'ALLOCATED') AS seats_left
FROM Course_Master cm
LEFT JOIN Course_Eligibility_Table cet ON cet.course_id = cm.course_id
GROUP BY cm.course_id, cm.course_name, cm.department, cm.total_seats
ORDER BY applicants DESC;

-- 7h. Applicants who still need document reminders
SELECT am.first_name, am.last_name, it.grace_period_end,
       COUNT(*) AS documents_outstanding
FROM Incomplete_Table it
JOIN Application_Master am  ON am.application_id = it.application_id
JOIN Document_Checklist dc  ON dc.incomplete_id  = it.incomplete_id
WHERE dc.status <> 'VERIFIED' AND it.grace_period_end >= CURDATE()
GROUP BY am.application_id, am.first_name, am.last_name, it.grace_period_end;

-- 7i. Scholarship spend by scheme
SELECT sm.scholarship_name, sm.max_amount,
       COUNT(st.scholarship_id) AS awards,
       COALESCE(SUM(st.amount_awarded), 0) AS total_awarded
FROM Scholarship_Master sm
LEFT JOIN Scholarship_Table st ON st.scholarship_code = sm.scholarship_code
GROUP BY sm.scholarship_code, sm.scholarship_name, sm.max_amount
ORDER BY total_awarded DESC;

-- 7j. Category-wise outcome breakdown
SELECT category,
       COUNT(*) AS applied,
       SUM(status = 'ACCEPTED')   AS accepted,
       SUM(status = 'REJECTED')   AS rejected,
       SUM(status = 'INCOMPLETE') AS incomplete,
       ROUND(AVG(jee_score), 2)   AS avg_score
FROM Application_Master
GROUP BY category
ORDER BY applied DESC;

-- 7k. Enrolled students with course and hostel room
SELECT es.roll_number, am.first_name, am.last_name,
       cm.course_name, ht.allotted_room_number, es.enrollment_date
FROM Enrolled_Students es
JOIN Acceptance_Table acc  ON acc.acceptance_id = es.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
JOIN Course_Master cm      ON cm.course_id = es.course_id
LEFT JOIN Hostel_Accommodation_Table ht ON ht.acceptance_id = acc.acceptance_id
ORDER BY es.roll_number;

-- 7l. Accepted offers that have not converted into enrollment, and why
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

-- 7m. Appeal outcomes with the score that triggered them
SELECT am.first_name, am.last_name, am.jee_score AS original_score,
       ap.revised_score, ap.appeal_status, am.status AS current_status
FROM Appeal_Table ap
JOIN Rejection_Table rt    ON rt.rejection_id = ap.rejection_id
JOIN Application_Master am ON am.application_id = rt.application_id
ORDER BY ap.appeal_date;

-- 7n. The 360-degree view, one row per applicant
SELECT * FROM vw_applicant_360 ORDER BY application_id;

-- 7o. Integrity check: nobody marked ACCEPTED without an Acceptance_Table row
SELECT am.application_id, am.first_name, am.last_name
FROM Application_Master am
LEFT JOIN Acceptance_Table acc ON acc.application_id = am.application_id
WHERE am.status = 'ACCEPTED' AND acc.acceptance_id IS NULL;
