
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- MySQL Workbench compatible script
-- Tables -> Sample Data -> Triggers -> DML -> DQL


DROP DATABASE IF EXISTS admission_workflow_db;
CREATE DATABASE admission_workflow_db;
USE admission_workflow_db;


-- SECTION 1: TABLE CREATION (15 tables, per ERD)


-- Level 0: Entry point
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
    created_at           TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
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
        REFERENCES Incomplete_Table(incomplete_id) ON DELETE CASCADE
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

CREATE TABLE Course_Master (
    course_id                INT AUTO_INCREMENT PRIMARY KEY,
    course_name                VARCHAR(100) NOT NULL,
    department                  VARCHAR(100) NOT NULL,
    total_seats                  INT NOT NULL
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
    CONSTRAINT uq_acc_priority UNIQUE (acceptance_id, priority_preference)
);

CREATE TABLE Scholarship_Table (
    scholarship_id             INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                 INT NOT NULL,
    scholarship_name                 VARCHAR(100) NOT NULL,
    amount_awarded                    DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_sch_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE
);

CREATE TABLE Fee_Payment_Table (
    payment_id                  INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                  INT NOT NULL UNIQUE,
    amount_due                       DECIMAL(10,2) NOT NULL,
    amount_paid                        DECIMAL(10,2) NOT NULL DEFAULT 0,
    payment_status                       ENUM('PENDING','PARTIAL','PAID') NOT NULL DEFAULT 'PENDING',
    CONSTRAINT fk_fee_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE
);

CREATE TABLE Hostel_Accommodation_Table (
    hostel_req_id                 INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                     INT NOT NULL UNIQUE,
    room_type_preference                 VARCHAR(50),
    allotted_room_number                    VARCHAR(20),
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
        REFERENCES Fee_Payment_Table(payment_id) ON DELETE CASCADE
);

CREATE TABLE Enrolled_Students (
    enrollment_id                     INT AUTO_INCREMENT PRIMARY KEY,
    acceptance_id                        INT NOT NULL UNIQUE,
    enrollment_date                        DATE NOT NULL,
    roll_number                              VARCHAR(20) NOT NULL UNIQUE,
    CONSTRAINT fk_enroll_acc FOREIGN KEY (acceptance_id)
        REFERENCES Acceptance_Table(acceptance_id) ON DELETE CASCADE
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

-- Helpful indexes for common lookups/joins
CREATE INDEX idx_app_status ON Application_Master(status);
CREATE INDEX idx_app_score ON Application_Master(jee_score);
CREATE INDEX idx_hist_app ON Application_Status_History(application_id);
CREATE INDEX idx_comm_app ON Communication_Log(application_id);

-- ============================================================
-- SECTION 2: TRIGGER — auto-log status changes
-- (Good idea: whenever Application_Master.status changes,
--  Application_Status_History fills itself in automatically —
--  no app-code needed to remember to log it.)
-- ============================================================

DELIMITER $$

CREATE TRIGGER trg_log_status_change
AFTER UPDATE ON Application_Master
FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO Application_Status_History (application_id, old_status, new_status)
        VALUES (NEW.application_id, OLD.status, NEW.status);
    END IF;
END$$

DELIMITER ;


-- SECTION 3: STORED PROCEDURE — decide an application
-- (Good idea: encapsulate the "cutoff + docs" routing logic
--  from the ERD into one reusable procedure, instead of
--  scattering the same IF/ELSE across app code.)


DELIMITER $$

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

DELIMITER ;


-- SECTION 4: VIEW — admission funnel dashboard
-- (Good idea: one query the front-end/report can hit instead
--  of re-writing the same aggregation everywhere.)


CREATE VIEW vw_admission_funnel AS
SELECT
    status,
    COUNT(*) AS total_applications
FROM Application_Master
GROUP BY status;


-- SECTION 5: SAMPLE DATA


INSERT INTO Course_Master (course_name, department, total_seats) VALUES
('B.Tech Artificial Intelligence', 'CSE', 120),
('B.Tech Computer Science', 'CSE', 180),
('B.Tech Electronics & Communication', 'ECE', 100),
('B.Tech Mechanical Engineering', 'MECH', 90);

INSERT INTO Application_Master
(first_name, last_name, dob, email, jee_score, high_school_pct, category, docs_submitted, status) VALUES
('Aarav','Sharma','2006-03-14','aarav.sharma@example.com', 92.50, 88.20, 'GENERAL', TRUE,  'SUBMITTED'),
('Priya','Iyer','2006-07-22','priya.iyer@example.com',    78.30, 91.00, 'OBC',     TRUE,  'SUBMITTED'),
('Kabir','Menon','2005-11-02','kabir.menon@example.com',  55.00, 76.40, 'GENERAL', TRUE,  'SUBMITTED'),
('Ananya','Das','2006-01-19','ananya.das@example.com',    88.10, 85.00, 'EWS',     FALSE, 'SUBMITTED'),
('Rohan','Verma','2006-05-30','rohan.verma@example.com',  65.75, 70.30, 'SC',      TRUE,  'SUBMITTED');

-- Run the routing procedure for each application (cutoff = 70.00)
CALL sp_decide_application(1, 70.00);   -- Aarav  -> ACCEPTED
CALL sp_decide_application(2, 70.00);   -- Priya  -> ACCEPTED
CALL sp_decide_application(3, 70.00);   -- Kabir  -> REJECTED
CALL sp_decide_application(4, 70.00);   -- Ananya -> INCOMPLETE (docs missing)
CALL sp_decide_application(5, 70.00);   -- Rohan  -> REJECTED

-- Document checklist for the incomplete application (Ananya, incomplete_id = 1)
INSERT INTO Document_Checklist (incomplete_id, document_type, status) VALUES
(1, 'Category Certificate', 'PENDING'),
(1, 'High School Marksheet', 'RECEIVED');

-- Appeal filed by Rohan (rejection_id = 2, since Kabir was rejection_id = 1)
INSERT INTO Appeal_Table (rejection_id, appeal_date, revised_score, appeal_status) VALUES
(2, CURDATE(), 71.00, 'UNDER_REVIEW');

-- Course eligibility + scholarship + fees + hostel for the two accepted students
-- Aarav = acceptance_id 1, Priya = acceptance_id 2
INSERT INTO Course_Eligibility_Table (acceptance_id, course_id, priority_preference, allocation_status) VALUES
(1, 1, 1, 'ALLOCATED'),
(1, 2, 2, 'APPLIED'),
(2, 2, 1, 'ALLOCATED');

INSERT INTO Scholarship_Table (acceptance_id, scholarship_name, amount_awarded) VALUES
(1, 'Merit Scholarship', 50000.00);

INSERT INTO Fee_Payment_Table (acceptance_id, amount_due, amount_paid, payment_status) VALUES
(1, 150000.00, 150000.00, 'PAID'),
(2, 150000.00, 50000.00, 'PARTIAL');

INSERT INTO Hostel_Accommodation_Table (acceptance_id, room_type_preference, allotted_room_number) VALUES
(1, 'Single', 'H1-204'),
(2, 'Shared', 'H2-118');

INSERT INTO Enrolled_Students (acceptance_id, enrollment_date, roll_number) VALUES
(1, CURDATE(), 'AI2027001');

-- A refund example: suppose Aarav later withdraws partially
INSERT INTO Refund_Table (payment_id, amount_refunded, refund_status) VALUES
(1, 20000.00, 'PROCESSING');

-- Communication log entries (manually, or you could add another trigger for this)
INSERT INTO Communication_Log (application_id, channel, message_summary) VALUES
(1, 'EMAIL', 'Admission offer letter sent'),
(2, 'EMAIL', 'Admission offer letter sent'),
(3, 'EMAIL', 'Rejection notice sent'),
(4, 'SMS',   'Document reminder sent'),
(5, 'EMAIL', 'Rejection notice sent');


-- SECTION 6: DML EXAMPLES (UPDATE / DELETE)

-- 6a. Student accepts the offer (updates decision, which does NOT
--     touch Application_Master.status, so no history row is added here)
UPDATE Acceptance_Table
SET student_decision = 'ACCEPTED'
WHERE acceptance_id = 1;

-- 6b. Approve Rohan's appeal -> this also flips status on Application_Master,
--     which the trigger will automatically log
UPDATE Appeal_Table SET appeal_status = 'APPROVED' WHERE appeal_id = 1;
UPDATE Application_Master SET status = 'ACCEPTED' WHERE application_id = 5;

-- 6c. Complete Ananya's fee/document process manually update docs_submitted
UPDATE Application_Master SET docs_submitted = TRUE WHERE application_id = 4;

-- 6d. Delete a stale/duplicate communication log entry (example of DELETE)
DELETE FROM Communication_Log
WHERE application_id = 4 AND channel = 'SMS';


-- SECTION 7: DQL EXAMPLES (SELECT queries)


-- 7a. Full applicant list with current status
SELECT application_id, first_name, last_name, jee_score, status
FROM Application_Master
ORDER BY jee_score DESC;

-- 7b. All accepted students with their allocated course
SELECT
    am.first_name, am.last_name,
    cm.course_name, cet.allocation_status
FROM Application_Master am
JOIN Acceptance_Table acc   ON am.application_id = acc.application_id
JOIN Course_Eligibility_Table cet ON acc.acceptance_id = cet.acceptance_id
JOIN Course_Master cm       ON cet.course_id = cm.course_id
WHERE cet.allocation_status = 'ALLOCATED';

-- 7c. Pending fee balance per accepted student
SELECT
    am.first_name, am.last_name,
    fp.amount_due, fp.amount_paid,
    (fp.amount_due - fp.amount_paid) AS balance_due,
    fp.payment_status
FROM Fee_Payment_Table fp
JOIN Acceptance_Table acc ON fp.acceptance_id = acc.acceptance_id
JOIN Application_Master am ON acc.application_id = am.application_id;

-- 7d. Rejected applicants who are still eligible to appeal but haven't yet
SELECT am.first_name, am.last_name, rt.rejection_reason
FROM Rejection_Table rt
JOIN Application_Master am ON rt.application_id = am.application_id
WHERE rt.appeal_eligible = TRUE
  AND rt.rejection_id NOT IN (SELECT rejection_id FROM Appeal_Table);

-- 7e. Full audit trail for one applicant
SELECT old_status, new_status, changed_at
FROM Application_Status_History
WHERE application_id = 5
ORDER BY changed_at;

-- 7f. Funnel counts via the view we created
SELECT * FROM vw_admission_funnel;

-- 7g. Seat demand per course (how many applied vs how many seats exist)
SELECT
    cm.course_name, cm.total_seats,
    COUNT(cet.eligibility_id) AS applicants,
    SUM(CASE WHEN cet.allocation_status = 'ALLOCATED' THEN 1 ELSE 0 END) AS allocated
FROM Course_Master cm
LEFT JOIN Course_Eligibility_Table cet ON cm.course_id = cet.course_id
GROUP BY cm.course_id, cm.course_name, cm.total_seats;

-- 7h. Applicants who need document reminders (incomplete + grace period not over)
SELECT am.first_name, am.last_name, it.grace_period_end, dc.document_type, dc.status
FROM Incomplete_Table it
JOIN Application_Master am ON it.application_id = am.application_id
JOIN Document_Checklist dc ON dc.incomplete_id = it.incomplete_id
WHERE dc.status != 'VERIFIED' AND it.grace_period_end >= CURDATE();