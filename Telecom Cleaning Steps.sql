-- TELECOM CUSTOMER DATA CLEANING PROJECT
-- Run each STEP one at a time. Check the result before moving to the next.

-- STEP 0: Setup — database + raw staging table
-- Everything is VARCHAR here on purpose. The raw file has currency
-- symbols in number columns and 5 different date formats, so forcing
-- INT/DECIMAL/DATE now would make the whole import fail.
CREATE DATABASE IF NOT EXISTS telecom_project;
USE telecom_project;

DROP TABLE IF EXISTS customers_raw;
CREATE TABLE customers_raw (
    customer_id             VARCHAR(20),
    full_name               VARCHAR(100),
    gender                  VARCHAR(20),
    age                     VARCHAR(20),
    region                  VARCHAR(50),
    city                    VARCHAR(50),
    phone_number            VARCHAR(30),
    email                   VARCHAR(100),
    sim_type                VARCHAR(20),
    plan_name               VARCHAR(50),
    plan_price              VARCHAR(20),
    activation_date         VARCHAR(30),
    contract_length_months  VARCHAR(20),
    monthly_data_used_gb    VARCHAR(20),
    monthly_voice_minutes   VARCHAR(20),
    monthly_sms_count       VARCHAR(20),
    monthly_bill_amount     VARCHAR(30),
    payment_method          VARCHAR(30),
    payment_status          VARCHAR(20),
    last_payment_date       VARCHAR(30),
    device_type             VARCHAR(30),
    device_brand            VARCHAR(30),
    network_type            VARCHAR(20),
    customer_service_calls  VARCHAR(20),
    complaint_type          VARCHAR(50),
    satisfaction_score      VARCHAR(20),
    churn_status            VARCHAR(20),
    signup_channel          VARCHAR(30),
    referral_code           VARCHAR(20),
    account_balance         VARCHAR(20)
);

-- STEP 1: Load the CSV
-- Adjust the path to wherever you saved telecom_customers_raw.csv.
-- If LOAD DATA LOCAL is blocked on your MySQL setup, use
-- MySQL Workbench > Table Data Import Wizard instead — same result.
LOAD DATA LOCAL INFILE '/path/to/telecom_customers_raw.csv'
INTO TABLE customers_raw
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- Sanity check: should show ~10,150 rows
SELECT COUNT(*) FROM customers_raw;


-- STEP 2: Look at what's actually wrong first
-- Don't clean blind — check each column before writing fixes.
SELECT DISTINCT gender FROM customers_raw;
SELECT DISTINCT sim_type FROM customers_raw;
SELECT DISTINCT region FROM customers_raw;
SELECT DISTINCT payment_method FROM customers_raw;
SELECT DISTINCT signup_channel FROM customers_raw;
SELECT DISTINCT churn_status FROM customers_raw;
SELECT DISTINCT satisfaction_score FROM customers_raw;

SELECT COUNT(*) AS null_email        FROM customers_raw WHERE email IS NULL OR email = '';
SELECT COUNT(*) AS null_complaint    FROM customers_raw WHERE complaint_type IS NULL OR complaint_type = '';
SELECT COUNT(*) AS null_device_brand FROM customers_raw WHERE device_brand IS NULL OR device_brand = '';


-- STEP 3: Remove exact duplicate rows
-- The file has ~150 duplicated customer records.
CREATE TEMPORARY TABLE dupes_to_delete AS
SELECT customer_id
FROM (
    SELECT customer_id,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_id) AS rn
    FROM customers_raw
) t
WHERE rn > 1;

-- This still deletes ALL rows for those customer_ids since PARTITION BY
-- doesn't track which physical row is which — safer approach below using a row id.
ALTER TABLE customers_raw ADD COLUMN row_id INT AUTO_INCREMENT PRIMARY KEY FIRST;

DELETE c FROM customers_raw c
JOIN (
    SELECT row_id
    FROM (
        SELECT row_id,
               ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY row_id) AS rn
        FROM customers_raw
    ) ranked
    WHERE rn > 1
) d ON c.row_id = d.row_id;

SELECT COUNT(*) FROM customers_raw; -- should now be ~10,000


-- STEP 4: Trim whitespace on every text column
-- Some values came in as "  Prepaid  " with padding spaces.
UPDATE customers_raw SET
    full_name       = TRIM(full_name),
    gender          = TRIM(gender),
    region          = TRIM(region),
    city            = TRIM(city),
    email           = TRIM(email),
    sim_type        = TRIM(sim_type),
    plan_name       = TRIM(plan_name),
    payment_method  = TRIM(payment_method),
    payment_status  = TRIM(payment_status),
    device_type     = TRIM(device_type),
    device_brand    = TRIM(device_brand),
    network_type    = TRIM(network_type),
    complaint_type  = TRIM(complaint_type),
    signup_channel  = TRIM(signup_channel);


-- STEP 5: Standardize gender
-- Male/male/M -> "Male", Female/female/F -> "Female"
UPDATE customers_raw
SET gender = CASE
    WHEN UPPER(gender) IN ('MALE','M') THEN 'Male'
    WHEN UPPER(gender) IN ('FEMALE','F') THEN 'Female'
    ELSE 'Unknown'
END;


-- STEP 6: Standardize sim_type
UPDATE customers_raw
SET sim_type = CASE
    WHEN UPPER(sim_type) = 'PREPAID'  THEN 'Prepaid'
    WHEN UPPER(sim_type) = 'POSTPAID' THEN 'Postpaid'
    ELSE sim_type
END;


-- STEP 7: Standardize region names
-- "Mogadishu", "Benadir", "banaadir" all mean the same region.
UPDATE customers_raw
SET region = CASE
    WHEN UPPER(region) IN ('MOGADISHU','BENADIR','BANAADIR') THEN 'Banaadir'
    WHEN UPPER(region) IN ('HARGEISA','WOQOOYI GALBEED') THEN 'Woqooyi Galbeed'
    WHEN UPPER(region) IN ('SHABEELLAHA HOOSE','LOWER SHABELLE') THEN 'Lower Shabelle'
    WHEN UPPER(region) = 'BAY' THEN 'Bay'
    ELSE region
END;


-- STEP 8: Standardize payment_method, payment_status, signup_channel, churn_status
UPDATE customers_raw
SET payment_method = CONCAT(UPPER(LEFT(payment_method,1)), LOWER(SUBSTRING(payment_method,2)));

UPDATE customers_raw
SET signup_channel = CONCAT(UPPER(LEFT(signup_channel,1)), LOWER(SUBSTRING(signup_channel,2)));

UPDATE customers_raw
SET churn_status = CASE
    WHEN churn_status IN ('Yes','Y','1') THEN 'Yes'
    WHEN churn_status IN ('No','N','0')  THEN 'No'
    ELSE churn_status
END;


-- STEP 9: Fix currency-as-text columns (plan_price, monthly_bill_amount)
-- Strip "$" and "USD" then convert to a clean decimal column.
UPDATE customers_raw
SET plan_price = REPLACE(REPLACE(plan_price, '$', ''), '.00', '');

UPDATE customers_raw
SET monthly_bill_amount = TRIM(REPLACE(monthly_bill_amount, 'USD', ''));

ALTER TABLE customers_raw ADD COLUMN plan_price_clean DECIMAL(10,2);
ALTER TABLE customers_raw ADD COLUMN monthly_bill_clean DECIMAL(10,2);

UPDATE customers_raw
SET plan_price_clean   = CAST(plan_price AS DECIMAL(10,2)),
    monthly_bill_clean = CAST(monthly_bill_amount AS DECIMAL(10,2));

-- Fix negative bills (data entry errors) by taking absolute value
UPDATE customers_raw
SET monthly_bill_clean = ABS(monthly_bill_clean)
WHERE monthly_bill_clean < 0;


-- STEP 10: Fix age outliers
-- Some ages are 0, negative, or 150 — impossible values.
-- Set them NULL so they don't skew analysis, rather than guessing a number.
ALTER TABLE customers_raw ADD COLUMN age_clean INT;

UPDATE customers_raw
SET age_clean = CASE
    WHEN CAST(age AS SIGNED) BETWEEN 10 AND 100 THEN CAST(age AS SIGNED)
    ELSE NULL
END;


-- STEP 11: Standardize dates (activation_date, last_payment_date)
-- The raw file mixes 5 formats: YYYY-MM-DD, DD/MM/YYYY, MM-DD-YYYY,
-- DD-Mon-YYYY, YYYY/MM/DD. STR_TO_DATE needs to try each pattern.
ALTER TABLE customers_raw ADD COLUMN activation_date_clean DATE;
ALTER TABLE customers_raw ADD COLUMN last_payment_date_clean DATE;

UPDATE customers_raw
SET activation_date_clean = CASE
    WHEN activation_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(activation_date, '%Y-%m-%d')
    WHEN activation_date REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(activation_date, '%d/%m/%Y')
    WHEN activation_date REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(activation_date, '%m-%d-%Y')
    WHEN activation_date REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$' THEN STR_TO_DATE(activation_date, '%d-%b-%Y')
    WHEN activation_date REGEXP '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN STR_TO_DATE(activation_date, '%Y/%m/%d')
    ELSE NULL
END;

UPDATE customers_raw
SET last_payment_date_clean = CASE
    WHEN last_payment_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(last_payment_date, '%Y-%m-%d')
    WHEN last_payment_date REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(last_payment_date, '%d/%m/%Y')
    WHEN last_payment_date REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(last_payment_date, '%m-%d-%Y')
    WHEN last_payment_date REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$' THEN STR_TO_DATE(last_payment_date, '%d-%b-%Y')
    WHEN last_payment_date REGEXP '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN STR_TO_DATE(last_payment_date, '%Y/%m/%d')
    ELSE NULL
END;


-- STEP 12: Handle N/A and empty values in remaining columns
UPDATE customers_raw
SET complaint_type = 'None'
WHERE complaint_type IS NULL OR complaint_type = '' OR complaint_type = 'None';

UPDATE customers_raw
SET satisfaction_score = NULL
WHERE satisfaction_score = 'N/A' OR satisfaction_score = '';

UPDATE customers_raw
SET device_brand = 'Unknown'
WHERE device_brand IS NULL OR device_brand = '';

UPDATE customers_raw
SET email = 'unknown@unknown.com'
WHERE email IS NULL OR email = '';


-- STEP 13: Fill every remaining null so no column is left empty
-- Run this AFTER Steps 9-11 (currency, age, date columns must already
-- be cleaned into plan_price_clean / monthly_bill_clean / age_clean /
-- activation_date_clean / last_payment_date_clean before this runs).

-- age_clean: fill with the median age instead of leaving blank
SET @median_age = (
    SELECT age_clean FROM (
        SELECT age_clean, ROW_NUMBER() OVER (ORDER BY age_clean) AS rn,
               COUNT(*) OVER () AS cnt
        FROM customers_raw WHERE age_clean IS NOT NULL
    ) t WHERE rn = FLOOR((cnt+1)/2)
);
UPDATE customers_raw SET age_clean = @median_age WHERE age_clean IS NULL;

-- contract_length_months: NULL means prepaid / no fixed contract -> 0
UPDATE customers_raw
SET contract_length_months = 0
WHERE contract_length_months IS NULL;

-- last_payment_date_clean: assume first payment happened at activation
UPDATE customers_raw
SET last_payment_date_clean = activation_date_clean
WHERE last_payment_date_clean IS NULL;

-- satisfaction_score: fill with the most common (mode) score
SET @mode_score = (
    SELECT satisfaction_score FROM customers_raw
    WHERE satisfaction_score IS NOT NULL
    GROUP BY satisfaction_score
    ORDER BY COUNT(*) DESC
    LIMIT 1
);
UPDATE customers_raw SET satisfaction_score = @mode_score WHERE satisfaction_score IS NULL;

-- referral_code: no code used is a valid category, not a blank
UPDATE customers_raw
SET referral_code = 'NONE'
WHERE referral_code IS NULL OR referral_code = '';


-- STEP 14: Build the final clean table with proper data types
DROP TABLE IF EXISTS customers_clean;
CREATE TABLE customers_clean AS
SELECT
    customer_id,
    full_name,
    gender,
    age_clean               AS age,
    region,
    city,
    phone_number,
    email,
    sim_type,
    plan_name,
    plan_price_clean        AS plan_price,
    activation_date_clean   AS activation_date,
    CAST(contract_length_months AS UNSIGNED) AS contract_length_months,
    CAST(monthly_data_used_gb AS DECIMAL(10,2)) AS monthly_data_used_gb,
    CAST(monthly_voice_minutes AS UNSIGNED) AS monthly_voice_minutes,
    CAST(monthly_sms_count AS UNSIGNED) AS monthly_sms_count,
    monthly_bill_clean       AS monthly_bill_amount,
    payment_method,
    payment_status,
    last_payment_date_clean AS last_payment_date,
    device_type,
    device_brand,
    network_type,
    CAST(customer_service_calls AS UNSIGNED) AS customer_service_calls,
    complaint_type,
    CAST(satisfaction_score AS UNSIGNED) AS satisfaction_score,
    churn_status,
    signup_channel,
    referral_code,
    CAST(account_balance AS DECIMAL(10,2)) AS account_balance
FROM customers_raw;

-- Final check
SELECT * FROM customers_clean LIMIT 20;
SELECT COUNT(*) FROM customers_clean;

-- Confirm zero nulls anywhere (every count below should be 0)
SELECT
    SUM(age IS NULL) AS null_age,
    SUM(contract_length_months IS NULL) AS null_contract,
    SUM(last_payment_date IS NULL) AS null_last_payment,
    SUM(satisfaction_score IS NULL) AS null_satisfaction,
    SUM(referral_code IS NULL) AS null_referral
FROM customers_clean;
