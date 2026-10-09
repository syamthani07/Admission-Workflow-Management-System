
-- ============================================================
-- ADMISSION WORKFLOW MANAGEMENT SYSTEM
-- Script 1 of 5: QUERIES AND SUBQUERIES
-- Run review.sql first; this script works on the database it builds.
--
-- Queries
--   Query 1     Top 5 GENERAL-category applicants (WHERE, ORDER BY, LIMIT)
--   Query 2     Score statistics (COUNT, AVG, MIN, MAX)
--   Query 3     Categories averaging above 70 (GROUP BY, HAVING)
--   Query 4     Born in early 2006, name starting with A (BETWEEN, LIKE)
--   Query 5     Result band for every applicant (CASE)
-- Subqueries
--   Subquery 1  Applicants above the overall average (scalar subquery)
--   Subquery 2  Applicants who received an offer (IN)
--   Subquery 3  Courses nobody has enrolled in (NOT IN)
--   Subquery 4  Applicants who outscored every OBC applicant (ALL)
--   Subquery 5  Scholarship totals above Rs 40,000 (subquery in FROM)
-- ============================================================

USE admission_workflow_db;


-- ============================================================
-- QUERIES
-- ============================================================

-- Query 1: Top 5 GENERAL-category applicants by JEE score (WHERE, ORDER BY, LIMIT)
SELECT application_id, first_name, last_name, jee_score, status
FROM Application_Master
WHERE category = 'GENERAL'
ORDER BY jee_score DESC
LIMIT 5;

-- Query 2: Score statistics across all applicants (aggregate functions)
SELECT COUNT(*)                 AS applicants,
       ROUND(AVG(jee_score), 2) AS avg_score,
       MIN(jee_score)           AS lowest_score,
       MAX(jee_score)           AS highest_score
FROM Application_Master;

-- Query 3: Categories whose average JEE score is above 70 (GROUP BY + HAVING)
SELECT category,
       COUNT(*)                 AS applicants,
       ROUND(AVG(jee_score), 2) AS avg_score
FROM Application_Master
GROUP BY category
HAVING AVG(jee_score) > 70
ORDER BY avg_score DESC;

-- Query 4: Applicants born in the first half of 2006 whose name starts with A (BETWEEN, LIKE)
SELECT first_name, last_name, dob, email
FROM Application_Master
WHERE dob BETWEEN '2006-01-01' AND '2006-06-30'
  AND first_name LIKE 'A%'
ORDER BY dob;

-- Query 5: Result band for every applicant (CASE expression)
SELECT first_name, last_name, jee_score,
       CASE
           WHEN jee_score >= 90 THEN 'Distinction'
           WHEN jee_score >= 75 THEN 'First Class'
           WHEN jee_score >= 60 THEN 'Second Class'
           ELSE 'Pass'
       END AS result_band
FROM Application_Master
ORDER BY jee_score DESC;


-- ============================================================
-- SUBQUERIES
-- ============================================================

-- Subquery 1: Applicants who scored above the overall average (scalar subquery)
SELECT first_name, last_name, jee_score
FROM Application_Master
WHERE jee_score > (SELECT AVG(jee_score) FROM Application_Master)
ORDER BY jee_score DESC;

-- Subquery 2: Applicants who received an admission offer (IN)
SELECT first_name, last_name, status
FROM Application_Master
WHERE application_id IN (SELECT application_id FROM Acceptance_Table)
ORDER BY first_name;

-- Subquery 3: Courses that nobody has enrolled in yet (NOT IN)
SELECT course_name, department, total_seats
FROM Course_Master
WHERE course_id NOT IN (SELECT course_id FROM Enrolled_Students);

-- Subquery 4: Applicants who outscored every OBC applicant (ALL)
SELECT first_name, last_name, category, jee_score
FROM Application_Master
WHERE jee_score > ALL (SELECT jee_score FROM Application_Master WHERE category = 'OBC')
ORDER BY jee_score DESC;

-- Subquery 5: Students awarded more than Rs 40,000 in scholarships in total (subquery in FROM)
SELECT am.first_name, am.last_name, s.schemes, s.total_award
FROM (
    SELECT acceptance_id, COUNT(*) AS schemes, SUM(amount_awarded) AS total_award
    FROM Scholarship_Table
    GROUP BY acceptance_id
) s
JOIN Acceptance_Table acc  ON acc.acceptance_id = s.acceptance_id
JOIN Application_Master am ON am.application_id = acc.application_id
WHERE s.total_award > 40000
ORDER BY s.total_award DESC;
