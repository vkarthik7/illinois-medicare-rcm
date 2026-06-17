/* ============================================================================
   HOSPITAL MANAGEMENT SYSTEM (HMS)  —  PHASE 1: DATA LOADING
   ----------------------------------------------------------------------------
   PURPOSE
     Create the database and pull three RAW data sources into "staging" tables.
     A staging table holds the file exactly as it arrives (every column as
     text), so nothing is rejected or silently mangled during import. All
     typing and cleaning happens later, in Phase 2 (02_data_cleaning.sql).

   DATA SOURCES (all real, public CMS/CDC data)
     1. CMS Medicare Physician & Other Practitioners, by Provider & Service 2024
     2. CMS Hospital Price Transparency Enforcement Activities (Apr–May 2026)
     3. CMS/CDC ICD-10-CM diagnosis code list (2026)

   NOTE
     The LOAD DATA paths below point at a local Windows machine. Edit them to
     match wherever the CSV/TXT files live on your system before running.
   ============================================================================ */


/* ----------------------------------------------------------------------------
   0) ENABLE LOCAL FILE IMPORT
   LOAD DATA LOCAL INFILE reads a file from THIS computer (the client) rather
   than from the database server. It is disabled by default for security, so
   we turn it on. You must ALSO enable it on the connection itself:
   MySQL Workbench > Manage Connections > your connection > Advanced >
   add  OPT_LOCAL_INFILE=1  to "Others".
---------------------------------------------------------------------------- */
SET GLOBAL local_infile = 1;

CREATE DATABASE IF NOT EXISTS healthcare_db;
USE healthcare_db;


/* ============================================================================
   1) MEDICARE  —  the core dataset (becomes fact_claims later)
   Every column is VARCHAR on purpose: the money columns contain "$" and commas
   (e.g. "$1,234.56") and the count columns contain commas too. Importing them
   as text guarantees the load never fails on a stray character; we convert them
   to real numbers during cleaning.
   ============================================================================ */
CREATE TABLE staging_medicare (
    npi                      VARCHAR(20),
    last_name                VARCHAR(100),
    first_name               VARCHAR(100),
    middle_initial           VARCHAR(10),
    credentials              VARCHAR(50),
    entity_code              VARCHAR(5),    -- 'I' = individual, 'O' = organization
    street1                  VARCHAR(200),
    street2                  VARCHAR(200),
    city                     VARCHAR(100),
    state                    VARCHAR(10),
    state_fips               VARCHAR(10),
    zip                      VARCHAR(20),
    ruca                     VARCHAR(10),   -- rural/urban classification code
    ruca_desc                VARCHAR(300),
    country                  VARCHAR(10),
    provider_type            VARCHAR(150),  -- specialty (drives dim_departments)
    medicare_participating   VARCHAR(5),
    hcpcs_code               VARCHAR(10),   -- procedure/service code
    hcpcs_desc               VARCHAR(500),
    hcpcs_drug_ind           VARCHAR(5),    -- 'Y' = drug, 'N' = procedure/service
    place_of_service         VARCHAR(5),
    total_beneficiaries      VARCHAR(20),   -- distinct patients
    total_services           VARCHAR(20),   -- times the service was performed
    total_bene_day_services  VARCHAR(20),
    avg_submitted_charge     VARCHAR(30),   -- provider's list price  (billed)
    avg_allowed_amount       VARCHAR(30),   -- Medicare fee-schedule  (allowed)
    avg_payment_amount       VARCHAR(30),   -- what Medicare actually paid
    avg_standardized_amount  VARCHAR(30)
);

LOAD DATA LOCAL INFILE 'C:/Users/karth/OneDrive/Desktop/DATABASE/hms/Medicare_Physician_Other_Practitioners_by_Provider_and_Service_2024.csv'
INTO TABLE staging_medicare
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ','          -- standard CSV: columns split on commas
OPTIONALLY ENCLOSED BY '"'        -- fields that contain commas are wrapped in "
LINES TERMINATED BY '\n'          -- this file uses Unix line endings
IGNORE 1 LINES;                   -- skip the header row


/* ============================================================================
   2) HOSPITALS  —  price-transparency enforcement (becomes dim_hospitals)
   IMPORTANT: this file is loaded as latin1, not utf8mb4. One hospital name
   contains a byte that is invalid UTF-8 and aborts the import under utf8mb4.
   latin1 accepts every single byte, so the load completes; the affected
   characters are cosmetic and don't affect the analysis.
   ============================================================================ */
CREATE TABLE staging_hospitals (
    case_id        VARCHAR(20),
    hosp_name      VARCHAR(255),
    hosp_address   VARCHAR(255),
    city           VARCHAR(100),
    state          VARCHAR(10),
    action         VARCHAR(100),   -- enforcement outcome (Warning Notice, etc.)
    date_of_action VARCHAR(20)
);

LOAD DATA LOCAL INFILE 'C:/Users/karth/OneDrive/Desktop/DATABASE/hms/Hospital_Price_Transparency_Enforcement_Activities_and_Outcomes_April_May_2026.csv'
INTO TABLE staging_hospitals
CHARACTER SET latin1
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'        -- this file uses Windows line endings (CR+LF)
IGNORE 1 LINES;


/* ============================================================================
   3) ICD-10 CODES  —  diagnosis lookup (becomes dim_diagnoses)
   This is a fixed-width text file, NOT a CSV: each line is one code followed
   by its description, padded with spaces. There are no delimiters to split on,
   so we load the WHOLE line into a single column and parse it during cleaning.
   ============================================================================ */
CREATE TABLE staging_icd10 (
    raw_line VARCHAR(600)
);

LOAD DATA LOCAL INFILE 'C:/Users/karth/OneDrive/Desktop/DATABASE/hms/icd10cm_codes_2026.txt'
INTO TABLE staging_icd10
CHARACTER SET latin1
LINES TERMINATED BY '\r\n';       -- no FIELDS clause: keep the entire row intact


/* ============================================================================
   4) SANITY CHECKS  —  confirm every file landed as expected
   Run these after the three loads. They answer: did all rows arrive? are key
   columns populated? how many distinct providers/procedures do we have?
   ============================================================================ */

-- Row count of all three sources side by side
SELECT 'medicare'  AS source, COUNT(*) AS total_rows FROM staging_medicare
UNION ALL
SELECT 'hospitals', COUNT(*)               FROM staging_hospitals
UNION ALL
SELECT 'icd10',     COUNT(*)               FROM staging_icd10;

-- Medicare: no rows should be missing the NPI (the provider key)
SELECT COUNT(*) AS missing_npi
FROM staging_medicare
WHERE npi = '' OR npi IS NULL;

-- Medicare: how many distinct providers and procedures we're working with
SELECT
    COUNT(DISTINCT npi)        AS unique_providers,
    COUNT(DISTINCT hcpcs_code) AS unique_procedures
FROM staging_medicare;

-- Hospitals: distribution of enforcement outcomes (drives compliance_status)
SELECT action, COUNT(*) AS cnt
FROM staging_hospitals
GROUP BY action
ORDER BY cnt DESC;

-- ICD-10: longest line, to confirm VARCHAR(600) is wide enough
SELECT MAX(LENGTH(raw_line)) AS longest_line FROM staging_icd10;
