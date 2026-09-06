# Telecom Customer Data

End-to-end data analytics project: a messy 10K-row synthetic telecom
customer dataset cleaned with SQL (deduplication, type casting, date
standardization, missing-value handling), then visualized in an
AI-assisted BI dashboard tracking churn, revenue, and customer
acquisition.

## 1. Repository Contents

| File | Description |
|---|---|
| `Telecom Customers Raw.csv` | Original messy dataset 10,150 rows, 30 columns |
| `Telecom Customers Clean.csv` | Final cleaned dataset 10,000 rows, 30 columns, zero blank cells |
| `Telecom Cleaning Steps.sql` | Full MySQL script, 14 steps, run in order |
| `Telecom Customer Dashboard.png` | Final dashboard built from the clean data |


## 2. What the Data Represents

Each row is one telecom customer, covering four areas:

- **Demographics** `customer_id`, `full_name`, `gender`, `age`, `region`, `city`, `phone_number`, `email`
- **Plan & subscription** `sim_type`, `plan_name`, `plan_price`, `activation_date`, `contract_length_months`
- **Usage & billing** `monthly_data_used_gb`, `monthly_voice_minutes`, `monthly_sms_count`, `monthly_bill_amount`, `payment_method`, `payment_status`, `last_payment_date`, `account_balance`
- **Device, service & churn** `device_type`, `device_brand`, `network_type`, `customer_service_calls`, `complaint_type`, `satisfaction_score`, `churn_status`, `signup_channel`, `referral_code`


## 3. What the Data Looked Like *Before* Cleaning

`Telecom Customers Raw.csv` was generated with deliberate, realistic
messiness so the cleaning work would mirror what a real telecom export
looks like:

| Issue | Example |
|---|---|
| Inconsistent casing | `Prepaid`, `PREPAID`, `prepaid` all present |
| Leading/trailing whitespace | `"  Prepaid  "` |
| Inconsistent region spelling/casing | `Mogadishu`, `Benadir`, `banaadir`, `BAY`, `bay` same regions, multiple spellings |
| Inconsistent phone formats | `+252612345678`, `0612345678`, `061 234 5678` |
| Numbers stored as text | `"$5.00"`, `"27.4 USD"` |
| Impossible values | Ages of `-5`, `0`, `150`; negative bills |
| Mixed date formats | `2024-05-01`, `01/05/2024`, `05-01-2024`, `01-May-2024`, `2024/05/01` all 5 present across two date columns |
| Outliers | A handful of customers with 500+ GB monthly data use |
| Duplicate rows | 150 exact duplicate customer records |
| Missing values | Blanks and `N/A` scattered across `email`, `device_brand`, `complaint_type`, `contract_length_months`, `last_payment_date`, `satisfaction_score`, `referral_code` |


## 4. Cleaning Process

All 14 steps live in `Telecom Cleaning Steps.sql`, meant to be run one
at a time. Summary of what each stage does and why:

### Step 1 Load as text first
Every column was imported as `VARCHAR`. Numeric and date columns had
mixed formats and stray text (`$`, `USD`), so casting to `INT`/`DECIMAL`/`DATE`
immediately would have failed or silently dropped rows.

```sql
CREATE TABLE customers_raw (
    customer_id VARCHAR(20),
    ...
    plan_price VARCHAR(20),
    ...
);
LOAD DATA LOCAL INFILE '/path/to/Telecom Customers Raw.csv'
INTO TABLE customers_raw
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 ROWS;
```

### Step 2 Inspect before touching anything
`SELECT DISTINCT` on every categorical column to see the real spread of
values, rather than guessing what needed fixing.

### Step 3 Remove exact duplicates
150 rows were exact repeats of another customer. Used `ROW_NUMBER()`
over a stable row id (not `customer_id` alone, since deleting by that
key would have removed *every* copy, including the first valid one):

```sql
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
```

### Step 4 Trim whitespace
`TRIM()` applied to every text column to remove padding spaces that
would otherwise break exact-match comparisons later.

### Steps 5–8 Standardize categories
`gender`, `sim_type`, `region`, `payment_method`, `signup_channel`, and
`churn_status` were each collapsed to one consistent spelling/casing,
e.g.:

```sql
UPDATE customers_raw
SET region = CASE
    WHEN UPPER(region) IN ('MOGADISHU','BENADIR','BANAADIR') THEN 'Banaadir'
    WHEN UPPER(region) IN ('HARGEISA','WOQOOYI GALBEED') THEN 'Woqooyi Galbeed'
    WHEN UPPER(region) IN ('SHABEELLAHA HOOSE','LOWER SHABELLE') THEN 'Lower Shabelle'
    WHEN UPPER(region) = 'BAY' THEN 'Bay'
    ELSE region
END;
```

### Step 9 Fix currency-as-text
Stripped `$` and `USD`, cast to `DECIMAL(10,2)`, and corrected negative
bill amounts by taking the absolute value (a sign error, not a real
refund/credit):

```sql
UPDATE customers_raw
SET monthly_bill_clean = ABS(monthly_bill_clean)
WHERE monthly_bill_clean < 0;
```

### Step 10 Fix age outliers
Ages outside a plausible 10–100 range were set to `NULL` rather than
guessed at this stage — they get filled properly in Step 13.

### Step 11 Standardize dates
Five different date formats were detected with `REGEXP` and converted
with the matching `STR_TO_DATE` pattern:

```sql
UPDATE customers_raw
SET activation_date_clean = CASE
    WHEN activation_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(activation_date, '%Y-%m-%d')
    WHEN activation_date REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(activation_date, '%d/%m/%Y')
    WHEN activation_date REGEXP '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' THEN STR_TO_DATE(activation_date, '%m-%d-%Y')
    WHEN activation_date REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$' THEN STR_TO_DATE(activation_date, '%d-%b-%Y')
    WHEN activation_date REGEXP '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN STR_TO_DATE(activation_date, '%Y/%m/%d')
    ELSE NULL
END;
```

### Step 12 Handle obvious blanks
`complaint_type` → `'None'`, `device_brand` → `'Unknown'`, `email` →
placeholder values where "missing" itself is a meaningful, valid
category.


## 5. Missing Data: What Was Missing and How It Was Filled

After Steps 1–12, five columns still had real gaps. Rather than leave
them empty, each was filled with a defensible value so the final table
has **zero blank cells**:

| Column | Rows missing | Fill strategy | Reasoning |
|---|---|---|---|
| `contract_length_months` | 2,371 | `0` | These are prepaid customers, who have no fixed contract by definition 0 is accurate, not a guess |
| `referral_code` | 7,008 | `'NONE'` | Most customers simply didn't use a referral code turned into an explicit category instead of a blank |
| `satisfaction_score` | 2,908 | Mode (most common score) | No stronger signal exists per-row to predict an individual's rating, so the most common value is the safest fill |
| `last_payment_date` | 983 | = `activation_date` | Reasonable assumption: no recorded payment yet means the last known payment event is signup itself |
| `age` | 108 | Median age | These were the impossible values from Step 10 (negative, 0, 150+); median is robust to the outliers that caused the problem in the first place |

```sql
-- Example: contract length and referral code
UPDATE customers_raw SET contract_length_months = 0 WHERE contract_length_months IS NULL;
UPDATE customers_raw SET referral_code = 'NONE' WHERE referral_code IS NULL OR referral_code = '';

-- Example: satisfaction score filled with the mode
SET @mode_score = (
    SELECT satisfaction_score FROM customers_raw
    WHERE satisfaction_score IS NOT NULL
    GROUP BY satisfaction_score ORDER BY COUNT(*) DESC LIMIT 1
);
UPDATE customers_raw SET satisfaction_score = @mode_score WHERE satisfaction_score IS NULL;
```

**Note on transparency:** filling missing values changes the data —
it doesn't recover a fact that was never recorded. Because of that, the
fill strategy for each column is documented above and every choice was
picked to be the *least assumption-heavy* one available, not the one
that looks the cleanest. In a real production dataset, this table is
what you'd hand to a stakeholder alongside the clean file, so they know
which numbers are observed and which are estimated.


## 6. Final Table

`Telecom Customers Clean.csv` has:

- **10,000 rows** no duplicates
- **30 columns** no blank cells
- Correct data types throughout: `DATE` for dates, `DECIMAL` for money,
  `INT` for counts, consistent text categories everywhere else

```sql
SELECT
    SUM(age IS NULL) AS null_age,
    SUM(contract_length_months IS NULL) AS null_contract,
    SUM(last_payment_date IS NULL) AS null_last_payment,
    SUM(satisfaction_score IS NULL) AS null_satisfaction,
    SUM(referral_code IS NULL) AS null_referral
FROM customers_clean;
-- all five return 0
```


## 7. Using AI to Build the Dashboard

This dashboard was built with AI assistance rather than by hand from
scratch. The workflow splits the work between what AI is good at and
what still needs to happen inside the BI tool itself:

1. **Import** `Telecom Customers Clean.csv` into the dashboard tool as
   the data source the AI step doesn't replace this, it still has to
   be loaded normally.
2. **Ask the AI for the KPI logic first, not the visuals.** Describe
   each KPI in plain language (e.g. "churn rate as a percentage of
   total customers") and have it return the exact formula. This is
   where AI saves the most time measure syntax is easy to get subtly
   wrong by hand.
3. **Ask the AI to recommend a chart type per question**, not per
   column. "Which plan has the highest churn?" maps to a bar chart;
   "how has revenue moved over time?" maps to a line chart.
4. **Build the visuals** using the AI's formulas and chart suggestions
   as the spec.
5. **Validate every chart against the real column values** before
   trusting it see Section 8 below for what this caught.


## 8. Dashboard Design: KPIs, Charts, and Validation

### KPI Cards (4)

| # | KPI | Formula | Why this one |
|---|---|---|---|
| 1 | **Total Customers** | `COUNT(customer_id)` | Baseline size of the book of business — every other KPI is read relative to this |
| 2 | **Total Monthly Revenue** | `SUM(monthly_bill_amount)` | The core revenue number stakeholders will look for first |
| 3 | **Churn Rate** | `COUNT(churn_status = "Yes") / COUNT(customer_id)` | The single most-watched telecom metric directly measures customer loss |
| 4 | **ARPU (Average Revenue Per User)** | `SUM(monthly_bill_amount) / COUNT(customer_id)` | Standard telecom industry metric; shows revenue efficiency, not just volume |

### Charts (5)

| # | Chart | Type | Fields | What it answers |
|---|---|---|---|---|
| 1 | **Revenue by Region** | Bar chart | `region` (axis), `monthly_bill_amount` (value, summed) | Which regions generate the most revenue |
| 2 | **Churn Rate by Plan** | Column chart | `plan_name` (axis), churn rate measure (value) | Which plans are losing customers, guiding pricing/retention decisions |
| 3 | **Customers by Payment Method** | Donut chart | `payment_method` (category), count of customers | How customers actually pay relevant given EVC Plus/Zaad/Sahal are mobile-money-specific to this market |
| 4 | **Avg. Service Calls: Churned vs Retained** | Bar chart | `churn_status` (axis), `customer_service_calls` (value, averaged) | Whether customers who churn contact support more before leaving an early-warning signal |
| 5 | **New Signups Over Time** | Line chart | `activation_date` (by month, axis), count of customers | Growth trend whether acquisition is accelerating or slowing |

### Validation: Checking AI Output Against the Real Data

The first dashboard draft was checked column-by-column against the
clean CSV rather than accepted at face value. This caught two real
issues:

1. **"Churn Rate by Plan" used invented plan names.** The chart showed
   generic tiers (`Basic, Standard, Premium, Family, Business,
   Enterprise, VIP`) that don't exist anywhere in `plan_name` the
   real values are `Basic Talk`, `Data Saver`, `Family Share`,
   `Business Pro`, `Unlimited Max`, `Student Plan`, `Weekend Booster`.
   The AI substituted a generic template instead of reading the actual
   column. **Fix:** rebuilt the chart pointing explicitly at the real
   `plan_name` values.
2. **A leftover region-cleaning gap surfaced in the "Revenue by
   Region" chart.** `Bay`/`BAY`, `Lower Shabelle`/`lower shabelle`, and
   `Woqooyi Galbeed`/`woqooyi galbeed` were appearing as separate bars
   — the SQL cleaning step had only handled regions with a full
   rename (like `Mogadishu` → `Banaadir`), and missed regions that
   only had a casing difference. **Fix:** Step 7 in the SQL script (and
   the matching Python cleaning logic) was updated to catch case-only
   variants; the final clean CSV and dashboard both reflect the fix
   13 distinct regions, no duplicates.

Everything else validated correctly: KPI totals matched by hand
calculation, the payment-method split matched the source data, and the
service-calls comparison showing no real difference between churned
and retained customers was confirmed as an honest result rather than a
broken chart the underlying data has no built-in correlation there.

## 9. Tools Used

MySQL 8 (window functions, `STR_TO_DATE`, `CASE`) for cleaning; an
AI-assisted BI dashboard tool for visualization.
