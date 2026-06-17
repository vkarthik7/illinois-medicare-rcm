/* ============================================================================
   HOSPITAL MANAGEMENT SYSTEM (HMS)  —  PHASE 2: DATA CLEANING & MODELING
   ----------------------------------------------------------------------------
   PURPOSE
     Turn the raw staging tables from Phase 1 into a clean STAR SCHEMA: small
     descriptive "dimension" tables (the who/what/where) and one central "fact"
     table holding the measurable numbers (the how-much). This is the structure
     Power BI connects to.

   THE FINAL MODEL
       dim_doctors ─┐
     dim_procedures ┤
   dim_departments ─┼──>  fact_claims   (398k real Medicare claim lines)
       dim_hospitals┘     (reference)
       dim_diagnoses      (reference)

   GRAIN NOTE (important for interviews)
     The Medicare file is one row per provider + procedure. That supports a
     claims fact, but NOT an admission- or diagnosis-level fact — there is no
     real source for those. So dim_hospitals and dim_diagnoses are kept as
     REFERENCE dimensions (used directly in the Power BI compliance / clinical
     pages) rather than being force-joined to fact_claims. Loading real data at
     a grain it doesn't actually have would be the wrong call.
   ============================================================================ */

USE healthcare_db;


/* ============================================================================
   PART A  —  CREATE THE STAR SCHEMA TABLES
   Dimensions are created first because fact_claims has foreign keys pointing
   back to them (a child can't reference a parent that doesn't exist yet).
   ============================================================================ */

CREATE TABLE dim_doctors (
    doctor_id   INT AUTO_INCREMENT PRIMARY KEY,  -- surrogate key (auto 1,2,3,…)
    npi_number  BIGINT UNIQUE,                   -- natural key from the source
    first_name  VARCHAR(100),
    last_name   VARCHAR(100),
    specialty   VARCHAR(150),
    gender      CHAR(1),                          -- not in CMS file; left NULL
    credentials VARCHAR(50),
    city        VARCHAR(100),
    state       CHAR(2),
    entity_type VARCHAR(20)                       -- 'Individual' / 'Organization'
);

CREATE TABLE dim_procedures (
    procedure_id        INT AUTO_INCREMENT PRIMARY KEY,
    hcpcs_code          VARCHAR(10) UNIQUE,
    description         VARCHAR(500),
    category            VARCHAR(150),             -- Drug vs Procedure/Service
    avg_medicare_payment DECIMAL(12,2)            -- pre-computed avg per code
);

CREATE TABLE dim_departments (
    department_id   INT AUTO_INCREMENT PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL,        -- holds the raw provider_type
    department_type VARCHAR(50),                  -- grouped bucket (Cardiology…)
    floor           INT                           -- reserved; no source data
);

CREATE TABLE dim_hospitals (
    hospital_id       INT AUTO_INCREMENT PRIMARY KEY,
    hospital_name     VARCHAR(255) NOT NULL,
    address           VARCHAR(255),
    city              VARCHAR(100),
    state             CHAR(2),
    compliance_status VARCHAR(100)                -- latest enforcement outcome
);

CREATE TABLE dim_diagnoses (
    diagnosis_id INT AUTO_INCREMENT PRIMARY KEY,
    icd10_code   VARCHAR(10) UNIQUE,
    description  VARCHAR(500),
    category     VARCHAR(150)                      -- derived from the first letter
);

-- The central fact table. Money/count columns are real numbers now (the strings
-- were cleaned on the way in, below). hospital_id is kept on the table for
-- future linkage but stays NULL — see the GRAIN NOTE at the top.
CREATE TABLE fact_claims (
    claim_id            INT AUTO_INCREMENT PRIMARY KEY,
    doctor_id           INT,
    procedure_id        INT,
    hospital_id         INT,
    department_id       INT,
    total_beneficiaries INT,
    total_services      INT,
    billed_amount       DECIMAL(12,2),   -- avg submitted charge per service
    allowed_amount      DECIMAL(12,2),   -- avg Medicare allowed per service
    paid_amount         DECIMAL(12,2),   -- avg Medicare paid per service
    standardized_amount DECIMAL(12,2),
    place_of_service    VARCHAR(5),
    FOREIGN KEY (doctor_id)     REFERENCES dim_doctors(doctor_id),
    FOREIGN KEY (procedure_id)  REFERENCES dim_procedures(procedure_id),
    FOREIGN KEY (department_id) REFERENCES dim_departments(department_id)
);


/* ============================================================================
   PART B  —  POPULATE THE DIMENSIONS
   ============================================================================ */

/* ----------------------------------------------------------------------------
   B1) dim_diagnoses  —  parse the fixed-width ICD-10 file
   Each raw line looks like:  "A000   Cholera due to Vibrio cholerae…"
   The code occupies the first 7 characters (space-padded); the description
   starts at position 9. SUBSTRING slices those pieces out and TRIM removes the
   padding. The category is derived from the FIRST letter of the code, which is
   how ICD-10 chapters are organized (A/B = infectious, C = cancer, etc.).
---------------------------------------------------------------------------- */
INSERT INTO dim_diagnoses (icd10_code, description, category)
SELECT
    TRIM(SUBSTRING(raw_line, 1, 7))  AS icd10_code,
    TRIM(SUBSTRING(raw_line, 9))     AS description,
    CASE LEFT(raw_line, 1)
        WHEN 'A' THEN 'Infectious diseases'
        WHEN 'B' THEN 'Infectious diseases'
        WHEN 'C' THEN 'Neoplasms/Cancer'
        WHEN 'D' THEN 'Blood disorders'
        WHEN 'E' THEN 'Endocrine/Metabolic'
        WHEN 'F' THEN 'Mental health'
        WHEN 'G' THEN 'Nervous system'
        WHEN 'H' THEN 'Eye and ear'
        WHEN 'I' THEN 'Circulatory system'
        WHEN 'J' THEN 'Respiratory system'
        WHEN 'K' THEN 'Digestive system'
        WHEN 'L' THEN 'Skin conditions'
        WHEN 'M' THEN 'Musculoskeletal'
        WHEN 'N' THEN 'Genitourinary'
        WHEN 'O' THEN 'Pregnancy/Childbirth'
        WHEN 'P' THEN 'Perinatal conditions'
        WHEN 'Q' THEN 'Congenital abnormalities'
        WHEN 'R' THEN 'Symptoms/Signs'
        WHEN 'S' THEN 'Injury/Trauma'
        WHEN 'T' THEN 'Injury/Poisoning'
        WHEN 'U' THEN 'Special codes'
        WHEN 'V' THEN 'External causes'
        WHEN 'W' THEN 'External causes'
        WHEN 'X' THEN 'External causes'
        WHEN 'Y' THEN 'External causes'
        WHEN 'Z' THEN 'Health status factors'
        ELSE 'Other'
    END AS category
FROM staging_icd10
WHERE raw_line IS NOT NULL AND raw_line != '';   -- skip any blank lines


/* ----------------------------------------------------------------------------
   B2) dim_hospitals  —  Illinois hospitals + their compliance outcome
   We keep only Illinois rows and only real enforcement outcomes. A single
   hospital can appear multiple times (one row per action), so we GROUP BY the
   hospital and take MAX(action) as its single compliance_status. TRIM cleans
   stray whitespace around the names/addresses.
---------------------------------------------------------------------------- */
INSERT INTO dim_hospitals (hospital_name, address, city, state, compliance_status)
SELECT
    TRIM(hosp_name)    AS hospital_name,
    TRIM(hosp_address) AS address,
    TRIM(city)         AS city,
    state,
    MAX(action)        AS compliance_status
FROM staging_hospitals
WHERE state = 'IL'
  AND action IN ('Warning Notice', 'Closure Notice', 'Met Requirements',
                 'CAP Request', 'Administrative Closure', 'CMP Notice')
GROUP BY TRIM(hosp_name), TRIM(hosp_address), TRIM(city), state;


/* ----------------------------------------------------------------------------
   B3) dim_doctors  —  one clean row per provider
   The Medicare file lists each provider many times (once per procedure). The
   GROUP BY collapses all of those service lines down to a single provider row.
   entity_code ('I'/'O') is translated into a readable entity_type.
   (Assumes a given NPI carries consistent name/city across its rows, which the
    staging sanity check confirmed — otherwise the UNIQUE npi_number would clash.)
---------------------------------------------------------------------------- */
INSERT INTO dim_doctors (npi_number, first_name, last_name, specialty,
                         credentials, city, state, entity_type)
SELECT
    npi,
    TRIM(first_name)    AS first_name,
    TRIM(last_name)     AS last_name,
    TRIM(provider_type) AS specialty,
    TRIM(credentials)   AS credentials,
    TRIM(city)          AS city,
    state,
    CASE entity_code
        WHEN 'I' THEN 'Individual'
        WHEN 'O' THEN 'Organization'
        ELSE 'Unknown'
    END AS entity_type
FROM staging_medicare
GROUP BY npi, first_name, last_name, provider_type,
         credentials, city, state, entity_code;


/* ----------------------------------------------------------------------------
   B4) dim_procedures  —  one row per HCPCS code
   category comes from the drug indicator. avg_medicare_payment is the average
   paid amount for that code across every provider — note the money cleaning:
   strip "$" and "," with nested REPLACE, then CAST the text to DECIMAL so it
   can be averaged as a real number.
---------------------------------------------------------------------------- */
INSERT INTO dim_procedures (hcpcs_code, description, category, avg_medicare_payment)
SELECT
    hcpcs_code,
    TRIM(hcpcs_desc) AS description,
    CASE hcpcs_drug_ind
        WHEN 'Y' THEN 'Drug/Medication'
        WHEN 'N' THEN 'Procedure/Service'
        ELSE 'Other'
    END AS category,
    AVG(CAST(REPLACE(REPLACE(avg_payment_amount, '$', ''), ',', '') AS DECIMAL(12,2)))
        AS avg_medicare_payment
FROM staging_medicare
GROUP BY hcpcs_code, hcpcs_desc, hcpcs_drug_ind;


/* ----------------------------------------------------------------------------
   B5) dim_departments  —  group ~100 raw specialties into clean buckets
   provider_type is very granular (Neurosurgery, Cardiology, Anesthesiology…).
   The CASE expression maps each specialty into a department_type so the
   dashboard can roll up to a handful of meaningful groups instead of 100 rows.
   department_name stores the original specialty so fact_claims can join on it.
---------------------------------------------------------------------------- */
INSERT INTO dim_departments (department_name, department_type)
SELECT
    provider_type AS department_name,
    CASE
        WHEN provider_type LIKE '%Surgery%'
          OR provider_type IN ('Neurosurgery','Urology','Otolaryngology','Orthopedic Surgery',
                               'Ophthalmology','Podiatry','Oral Surgery (Dentist only)','Maxillofacial Surgery')
            THEN 'Surgery'
        WHEN provider_type LIKE '%Cardiac%' OR provider_type LIKE '%Cardiology%'
          OR provider_type LIKE '%Heart%'
            THEN 'Cardiology'
        WHEN provider_type LIKE '%Radiology%' OR provider_type LIKE '%Pathology%'
          OR provider_type LIKE '%Laboratory%' OR provider_type LIKE '%Diagnostic%'
          OR provider_type LIKE '%X-Ray%' OR provider_type LIKE '%Nuclear%'
          OR provider_type LIKE '%Slide%'
            THEN 'Diagnostics'
        WHEN provider_type LIKE '%Oncology%' OR provider_type LIKE '%Hematology%'
          OR provider_type LIKE '%Radiation%' OR provider_type LIKE '%Transplant%'
            THEN 'Oncology'
        WHEN provider_type IN ('Family Practice','Internal Medicine','General Practice',
                               'Nurse Practitioner','Physician Assistant','Geriatric Medicine',
                               'Preventive Medicine','Pediatric Medicine')
            THEN 'Primary Care'
        WHEN provider_type LIKE '%Psych%' OR provider_type LIKE '%Counselor%'
          OR provider_type LIKE '%Social Worker%' OR provider_type LIKE '%Marriage%'
          OR provider_type LIKE '%Addiction%'
            THEN 'Mental Health'
        WHEN provider_type LIKE '%Therap%' OR provider_type LIKE '%Rehabilitation%'
          OR provider_type LIKE '%Audiologist%' OR provider_type LIKE '%Dietitian%'
          OR provider_type LIKE '%Chiropractic%'
            THEN 'Therapy & Rehab'
        WHEN provider_type LIKE '%Emergency%' OR provider_type LIKE '%Critical Care%'
          OR provider_type LIKE '%Hospitalist%' OR provider_type LIKE '%Anesthesi%'
          OR provider_type LIKE '%CRNA%'
            THEN 'Emergency & Acute'
        WHEN provider_type LIKE '%Ambulance%' OR provider_type LIKE '%Ambulatory%'
          OR provider_type LIKE '%Supplier%' OR provider_type LIKE '%Pharmacy%'
          OR provider_type LIKE '%Infusion%' OR provider_type LIKE '%Immunizer%'
          OR provider_type LIKE '%Flu%' OR provider_type LIKE '%IDTF%'
            THEN 'Support Services'
        ELSE 'Specialty Medicine'
    END AS department_type
FROM staging_medicare
GROUP BY provider_type;


/* ============================================================================
   PART C  —  POPULATE THE FACT TABLE
   Join each raw Medicare line back to the three dimensions to swap natural keys
   (NPI, HCPCS, specialty text) for the surrogate keys (doctor_id, procedure_id,
   department_id). Every money/count column is cleaned the same way: strip "$"
   and "," then CAST to a number. Counts are wrapped in ROUND() because the
   source occasionally stores fractional service counts.
   ============================================================================ */
INSERT INTO fact_claims (
    doctor_id, procedure_id, department_id,
    total_beneficiaries, total_services,
    billed_amount, allowed_amount, paid_amount, standardized_amount,
    place_of_service
)
SELECT
    doc.doctor_id,
    proc.procedure_id,
    dept.department_id,
    ROUND(CAST(REPLACE(s.total_beneficiaries, ',', '') AS DECIMAL(12,2))),
    ROUND(CAST(REPLACE(s.total_services,      ',', '') AS DECIMAL(12,2))),
    CAST(REPLACE(REPLACE(s.avg_submitted_charge,    '$', ''), ',', '') AS DECIMAL(12,2)),
    CAST(REPLACE(REPLACE(s.avg_allowed_amount,      '$', ''), ',', '') AS DECIMAL(12,2)),
    CAST(REPLACE(REPLACE(s.avg_payment_amount,      '$', ''), ',', '') AS DECIMAL(12,2)),
    CAST(REPLACE(REPLACE(s.avg_standardized_amount, '$', ''), ',', '') AS DECIMAL(12,2)),
    s.place_of_service
FROM staging_medicare s
JOIN dim_doctors     doc  ON s.npi              = doc.npi_number
JOIN dim_procedures  proc ON s.hcpcs_code       = proc.hcpcs_code
JOIN dim_departments dept ON TRIM(s.provider_type) = dept.department_name;


/* ============================================================================
   PART D  —  VALIDATION  (confirm the model populated correctly)
   ============================================================================ */

-- Row counts for every table in the model
SELECT 'dim_doctors'     AS tbl, COUNT(*) AS rows_loaded FROM dim_doctors
UNION ALL SELECT 'dim_procedures',  COUNT(*) FROM dim_procedures
UNION ALL SELECT 'dim_departments', COUNT(*) FROM dim_departments
UNION ALL SELECT 'dim_hospitals',   COUNT(*) FROM dim_hospitals
UNION ALL SELECT 'dim_diagnoses',   COUNT(*) FROM dim_diagnoses
UNION ALL SELECT 'fact_claims',     COUNT(*) FROM fact_claims;

-- Headline financials. billed/paid are AVERAGES per service, so multiply by
-- total_services to get true dollar totals before summing.
SELECT
    COUNT(*)                                                              AS total_claims,
    SUM(total_services)                                                   AS total_services_performed,
    CONCAT('$', FORMAT(SUM(billed_amount * total_services), 0))           AS total_billed,
    CONCAT('$', FORMAT(SUM(paid_amount   * total_services), 0))           AS total_paid,
    CONCAT(ROUND(SUM(paid_amount * total_services)
               / SUM(billed_amount * total_services) * 100, 1), '%')      AS payment_to_charge_rate
FROM fact_claims;

-- Sanity check on the dimension mappings
SELECT entity_type, COUNT(*) AS providers FROM dim_doctors     GROUP BY entity_type;
SELECT department_type, COUNT(*) AS specialties FROM dim_departments
GROUP BY department_type ORDER BY specialties DESC;
SELECT compliance_status, COUNT(*) AS hospitals FROM dim_hospitals GROUP BY compliance_status;
