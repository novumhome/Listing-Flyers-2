--
-- PostgreSQL database dump
--

-- Dumped from database version 14.13 (Homebrew)
-- Dumped by pg_dump version 14.13 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: loan_program_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.loan_program_type AS ENUM (
    'Conforming',
    'FHA',
    'VA',
    'USDA'
);


ALTER TYPE public.loan_program_type OWNER TO postgres;

--
-- Name: calculate_discount_points(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_discount_points() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    base_key_value TEXT;
    lowest_note_rate NUMERIC;
    corresponding_final_net_price NUMERIC;
BEGIN
    -- Step 1: Determine the base key value based on loan_program_code
    SELECT key INTO base_key_value
    FROM (
        VALUES 
            ('Conforming30DownH', '107460300'),
            ('Conforming30DownL', '107460300'),
            ('Conforming5DownH', '107460300'),
            ('Conforming5DownL', '107460300'),
            ('FHAH', '105360300'),
            ('FHAL', '105360300'),
            ('VAH', '107700300'),
            ('VAL', '107700300'),
            ('USDAH', '105360300'),
            ('USDAL', '105360300')
    ) AS mapping(loan_program_code, key)
    WHERE mapping.loan_program_code = NEW.loan_program_code;

    RAISE NOTICE 'Base key value: %', base_key_value;

    -- Step 2 and 3: Find the corresponding rate and final_net_price from the ratesheets table
    IF NEW.loan_program_code LIKE '%L' THEN
        -- For 'L' (low), find the lowest note_rate with the highest final_net_price
        SELECT note_rate, final_net_price INTO lowest_note_rate, corresponding_final_net_price
        FROM ratesheets
        WHERE key::TEXT LIKE base_key_value || '%'  -- Cast key to TEXT and match the beginning of the key
        ORDER BY note_rate ASC, final_net_price DESC
        LIMIT 1;
    ELSE
        -- For 'H' (high), find the lowest note_rate with the lowest absolute final_net_price
        SELECT note_rate, final_net_price INTO lowest_note_rate, corresponding_final_net_price
        FROM ratesheets
        WHERE key::TEXT LIKE base_key_value || '%'  -- Cast key to TEXT and match the beginning of the key
        ORDER BY ABS(final_net_price) ASC, note_rate ASC  -- Use ABS() to sort by absolute value of final_net_price
        LIMIT 1;
    END IF;

    RAISE NOTICE 'Selected note_rate: %, final_net_price: %', lowest_note_rate, corresponding_final_net_price;

    -- Step 4: Update the loan_scenarios table with the found values
    UPDATE loan_scenarios
    SET
        interest_rate = lowest_note_rate,  -- Update interest_rate with note_rate from ratesheets
        discount_points_percent = corresponding_final_net_price -- Map final_net_price to discount_points_percent
    WHERE scenario_id = NEW.scenario_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.calculate_discount_points() OWNER TO postgres;

--
-- Name: calculate_discount_points_and_interest_rate(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_discount_points_and_interest_rate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    base_key_value TEXT;
    lowest_note_rate NUMERIC;
    corresponding_final_net_price NUMERIC;
    calculated_principal_and_interest NUMERIC;
BEGIN
    -- Conditional check to avoid recursion
    IF NEW.interest_rate IS NOT NULL AND NEW.discount_points_percent IS NOT NULL THEN
        RAISE NOTICE 'Skipping trigger execution to avoid recursion for scenario_id: %', NEW.scenario_id;
        RETURN NEW;
    END IF;

    -- Step 1: Determine the base key value based on loan_program_code
    SELECT key INTO base_key_value
    FROM (
        VALUES 
            ('Conforming30DownH', '107460300'),
            ('Conforming30DownL', '107460300'),
            ('Conforming5DownH', '107460300'),
            ('Conforming5DownL', '107460300'),
            ('FHAH', '105360300'),
            ('FHAL', '105360300'),
            ('VAH', '107700300'),
            ('VAL', '107700300'),
            ('USDAH', '105360300'),
            ('USDAL', '105360300')
    ) AS mapping(loan_program_code, key)
    WHERE mapping.loan_program_code = NEW.loan_program_code;

    RAISE NOTICE 'Base key value: %', base_key_value;

    -- Step 2 and 3: Find the corresponding rate and final_net_price from the ratesheets table
    IF NEW.loan_program_code LIKE '%L' THEN
        -- For 'L' (low), find the lowest note_rate with the highest final_net_price, capped at 3
        SELECT note_rate, final_net_price INTO lowest_note_rate, corresponding_final_net_price
        FROM ratesheets
        WHERE key::TEXT LIKE base_key_value || '%'  -- Cast key to TEXT and match the beginning of the key
        AND ABS(final_net_price) <= 3  -- Cap the absolute final_net_price at 3
        ORDER BY note_rate ASC, ABS(final_net_price) ASC  -- Sort by note_rate ascending and final_net_price ascending
        LIMIT 1;
    ELSE
        -- For 'H' (high), find the lowest note_rate with the lowest absolute final_net_price
        SELECT note_rate, final_net_price INTO lowest_note_rate, corresponding_final_net_price
        FROM ratesheets
        WHERE key::TEXT LIKE base_key_value || '%'  -- Cast key to TEXT and match the beginning of the key
        ORDER BY ABS(final_net_price) ASC, note_rate ASC  -- Use ABS() to sort by absolute value of final_net_price
        LIMIT 1;
    END IF;

    RAISE NOTICE 'Selected note_rate: %, final_net_price: %', lowest_note_rate, corresponding_final_net_price;

    -- Step 4: Update the loan_scenarios table with the found values
    UPDATE loan_scenarios
    SET
        interest_rate = lowest_note_rate,  -- Update interest_rate with note_rate from ratesheets
        discount_points_percent = corresponding_final_net_price, -- Map final_net_price to discount_points_percent
        principal_and_interest = (NEW.total_loan_amount * lowest_note_rate / 1200) / (1 - (1 / (1 + (lowest_note_rate / 1200)) ^ 360))
    WHERE scenario_id = NEW.scenario_id;

    -- Step 5: Calculate and update total_payment field
    UPDATE loan_scenarios
    SET
        total_payment = principal_and_interest + property_taxes + private_mortgage_insurance + home_insurance_mo_pmt
    WHERE scenario_id = NEW.scenario_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.calculate_discount_points_and_interest_rate() OWNER TO postgres;

--
-- Name: calculate_loan_amounts(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_loan_amounts() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Calculate the base loan amount
    NEW.base_loan_amount := NEW.purchase_price * (1 - NEW.down_payment);

    -- Calculate the total loan amount, ensuring base_loan_amount is set first
    IF NEW.base_loan_amount IS NOT NULL THEN
        NEW.total_loan_amount := (NEW.base_loan_amount * NEW.financed_mi_premium_funding_fee) + NEW.base_loan_amount;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.calculate_loan_amounts() OWNER TO postgres;

--
-- Name: calculate_loan_scenario_fields(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_loan_scenario_fields() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    calculated_down_payment NUMERIC;
    calculated_base_loan_amount NUMERIC;
    calculated_total_loan_amount NUMERIC;
    calculated_home_insurance_mo_pmt NUMERIC;
    calculated_private_mortgage_insurance NUMERIC;
    calculated_homeowners_insurance_year_1 NUMERIC;
    calculated_annual_pmi_percent NUMERIC;
    calculated_ok_mortgage_tax NUMERIC;
    calculated_up_front_mi_funding_fee NUMERIC;
    calculated_title_insurance NUMERIC;
    calculated_property_tax_escrow NUMERIC;
    calculated_home_insurance_escrow NUMERIC;
    calculated_loan_borrower_discount_points NUMERIC;
BEGIN
    -- Calculate down_payment
    SELECT COALESCE(
        (SELECT value FROM defaults_percentage
         WHERE default_type = 'Down Payment %'
         AND defaults_percentage.loan_program = NEW.loan_program_code
         AND (defaults_percentage.state = NEW.state OR defaults_percentage.state IS NULL)
         LIMIT 1),
        (SELECT value FROM defaults_percentage
         WHERE default_type = 'Down Payment %'
         AND defaults_percentage.loan_program IS NULL
         AND defaults_percentage.state IS NULL
         LIMIT 1)
    ) INTO calculated_down_payment;

    -- Calculate base loan amount
    calculated_base_loan_amount := NEW.purchase_price * (1 - calculated_down_payment);

    -- Look up Annual PMI % from defaults_percentage table based on loan_program_code
    SELECT value INTO calculated_annual_pmi_percent
    FROM defaults_percentage
    WHERE default_type = 'Annual PMI %'
    AND loan_program = NEW.loan_program_code
    LIMIT 1;

    -- Calculate private mortgage insurance (monthly)
    calculated_private_mortgage_insurance := (calculated_annual_pmi_percent * calculated_base_loan_amount) / 12;

    -- Calculate total loan amount using Up-Front MI/Funding Fee %
    SELECT value INTO calculated_up_front_mi_funding_fee
    FROM defaults_percentage
    WHERE default_type = 'Up-Front MI/Funding Fee %'
    AND loan_program = NEW.loan_program_code
    LIMIT 1;

    calculated_total_loan_amount := (calculated_base_loan_amount * calculated_up_front_mi_funding_fee) + calculated_base_loan_amount;

    -- Calculate home insurance monthly payment
    calculated_home_insurance_mo_pmt := (NEW.purchase_price * NEW.home_insurance) / 12;

    -- Calculate homeowners insurance for the first year
    calculated_homeowners_insurance_year_1 := NEW.purchase_price * NEW.home_insurance;

    -- Calculate OK mortgage tax (ensure total_loan_amount is set)
    IF NEW.state = 'OK' THEN
        calculated_ok_mortgage_tax := calculated_total_loan_amount * 0.001;
    ELSE
        calculated_ok_mortgage_tax := NULL;  -- No OK mortgage tax for other states
    END IF;

    -- Calculate upfront MI funding fee (ensure base_loan_amount is set)
    calculated_up_front_mi_funding_fee := NEW.financed_mi_premium_funding_fee * calculated_base_loan_amount;

    -- Calculate title insurance based on the state
    IF NEW.state = 'TX' THEN
        -- Directly calculate Texas title insurance here
        IF NEW.purchase_price <= 100000 THEN
            calculated_title_insurance := NEW.purchase_price * 5.40 / 1000;
        ELSIF NEW.purchase_price <= 1000000 THEN
            calculated_title_insurance := 100000 * 5.40 / 1000 + (NEW.purchase_price - 100000) * 5.00 / 1000;
        ELSIF NEW.purchase_price <= 5000000 THEN
            calculated_title_insurance := 100000 * 5.40 / 1000 + 900000 * 5.00 / 1000 + (NEW.purchase_price - 1000000) * 2.30 / 1000;
        ELSIF NEW.purchase_price <= 15000000 THEN
            calculated_title_insurance := 100000 * 5.40 / 1000 + 900000 * 5.00 / 1000 + 4000000 * 2.30 / 1000 + (NEW.purchase_price - 5000000) * 1.60 / 1000;
        ELSE
            calculated_title_insurance := 100000 * 5.40 / 1000 + 900000 * 5.00 / 1000 + 4000000 * 2.30 / 1000 + 10000000 * 1.60 / 1000 + (NEW.purchase_price - 15000000) * 1.00 / 1000;
        END IF;
    ELSIF NEW.state = 'OK' THEN
        calculated_title_insurance := ((NEW.purchase_price - 100000) * 0.003) + 900;
    ELSE
        calculated_title_insurance := NULL;  -- Default to NULL or add more states as needed
    END IF;

    -- Calculate property tax escrow
    calculated_property_tax_escrow := NEW.property_taxes * 3;

    -- Calculate home insurance escrow (ensure home_insurance_mo_pmt is set)
    calculated_home_insurance_escrow := calculated_home_insurance_mo_pmt * 3;

    -- Calculate loan borrower discount points (ensure total_loan_amount and discount_points_percent are set)
    IF NEW.total_loan_amount IS NOT NULL AND NEW.discount_points_percent IS NOT NULL THEN
        calculated_loan_borrower_discount_points := NEW.total_loan_amount * (NEW.discount_points_percent / 100);
    ELSE
        RAISE NOTICE 'Skipping loan_borrower_discount_points calculation due to missing values: total_loan_amount = %, discount_points_percent = %', NEW.total_loan_amount, NEW.discount_points_percent;
    END IF;

    -- Calculate prepaid interest (interest_rate divided by 100)
    NEW.prepaid_interest := 15 * (calculated_base_loan_amount + calculated_up_front_mi_funding_fee) * (NEW.interest_rate / 100 / 360);

    -- Assign the calculated values back to the NEW record
    NEW.down_payment := calculated_down_payment;
    NEW.base_loan_amount := calculated_base_loan_amount;
    NEW.total_loan_amount := calculated_total_loan_amount;
    NEW.home_insurance_mo_pmt := calculated_home_insurance_mo_pmt;
    NEW.private_mortgage_insurance := calculated_private_mortgage_insurance;
    NEW.homeowners_insurance_year_1 := calculated_homeowners_insurance_year_1;
    NEW.annual_pmi_percent := calculated_annual_pmi_percent;
    NEW.ok_mortgage_tax := calculated_ok_mortgage_tax;
    NEW.up_front_mi_funding_fee := calculated_up_front_mi_funding_fee;
    NEW.title_insurance := calculated_title_insurance;
    NEW.property_tax_escrow := calculated_property_tax_escrow;
    NEW.home_insurance_escrow := calculated_home_insurance_escrow;
    NEW.loan_borrower_discount_points := calculated_loan_borrower_discount_points;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.calculate_loan_scenario_fields() OWNER TO postgres;

--
-- Name: calculate_total_payment(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.calculate_total_payment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Calculate the total payment regardless of whether the fields are set or not
    NEW.total_payment := COALESCE(NEW.principal_and_interest, 0) + 
                         COALESCE(NEW.property_taxes, 0) + 
                         COALESCE(NEW.private_mortgage_insurance, 0) + 
                         COALESCE(NEW.home_insurance_mo_pmt, 0);

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.calculate_total_payment() OWNER TO postgres;

--
-- Name: create_loan_scenarios(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_loan_scenarios() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    loan_program TEXT;
    scenario_num INTEGER;
    scenario_count INTEGER;
    state_value VARCHAR(2);
BEGIN
    state_value := NEW.state; -- Assuming 'state' is in the new_record table

    -- Loop over each loan program in the array
    FOREACH loan_program IN ARRAY NEW.loan_programs LOOP
        IF loan_program = 'Conforming' THEN
            scenario_count := 4;
        ELSE
            scenario_count := 2;
        END IF;

        -- Create the scenarios
        FOR scenario_num IN 1..scenario_count LOOP
            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state)
            VALUES (NEW.record_id, scenario_num, loan_program, state_value);
        END LOOP;
    END LOOP;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.create_loan_scenarios() OWNER TO postgres;

--
-- Name: disable_trigger(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.disable_trigger(trigger_name text, table_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    EXECUTE format('ALTER TABLE %I DISABLE TRIGGER %I', table_name, trigger_name);
END;
$$;


ALTER FUNCTION public.disable_trigger(trigger_name text, table_name text) OWNER TO postgres;

--
-- Name: enable_trigger(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enable_trigger(trigger_name text, table_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    EXECUTE format('ALTER TABLE %I ENABLE TRIGGER %I', table_name, trigger_name);
END;
$$;


ALTER FUNCTION public.enable_trigger(trigger_name text, table_name text) OWNER TO postgres;

--
-- Name: generate_listing_flyer_details(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.generate_listing_flyer_details(IN p_record_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_scenario_id INTEGER;
    v_total_loan_amount NUMERIC;
    v_amount_needed_to_purchase NUMERIC;
    v_total_payment NUMERIC;
    v_interest_rate NUMERIC;
    v_discount_points_percent NUMERIC;
    v_apr NUMERIC;
    v_loan_program_code TEXT;
    loan_amount NUMERIC;
    total_cost NUMERIC;
    annual_pmi_percent NUMERIC;
    r NUMERIC;
    n INTEGER := 360;  -- Assuming a 30-year loan term (360 months)
BEGIN
    FOR v_scenario_id IN
        SELECT scenario_id
        FROM loan_scenarios
        WHERE record_id = p_record_id
    LOOP
        -- Calculate and set total_loan_amount
        SELECT ls.total_loan_amount INTO v_total_loan_amount
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Calculate and set amount_needed_to_purchase
        SELECT
            (ls.purchase_price + ls.lender_charges + ls.loan_borrower_discount_points + ls.appraisal +
            ls.appraiser_reinspection + ls.credit_reports + ls.title_services + ls.title_insurance +
            ls.recording_fees + COALESCE(ls.ok_mortgage_tax, 0) + ls.survey + ls.pest_home_inspections +
            COALESCE(ls.prepaid_interest, 0) + ls.up_front_mi_funding_fee + ls.homeowners_insurance_year_1 +
            ls.property_tax_escrow + ls.home_insurance_escrow) - ls.total_loan_amount
        INTO v_amount_needed_to_purchase
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Fetch and set total_payment, interest_rate, discount_points_percent, and annual_pmi_percent
        SELECT
            ls.total_payment,
            ls.interest_rate,
            ls.discount_points_percent,
            ls.total_loan_amount,
            ls.lender_charges + ls.loan_borrower_discount_points + ls.credit_reports + ls.title_services + COALESCE(ls.prepaid_interest, 0),
            ls.annual_pmi_percent,
            ls.loan_program_code
        INTO
            v_total_payment,
            v_interest_rate,
            v_discount_points_percent,
            loan_amount,
            total_cost,
            annual_pmi_percent,
            v_loan_program_code
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Ensure interest rate is correctly scaled for percentage
        r := ((v_interest_rate / 100) + annual_pmi_percent) / 12;  -- Monthly interest rate

        -- Calculate APR using the provided formula
        v_apr := (POWER(1 + r, 12) - 1) * 100;  -- Convert to annual percentage rate and express as a percentage

        -- Insert the results into the loan_scenario_results table
        INSERT INTO loan_scenario_results (
            scenario_id,
            record_id,
            loan_program_code,
            total_loan_amount,
            amount_needed_to_purchase,
            total_payment,
            interest_rate,
            discount_points_percent,
            apr
        ) VALUES (
            v_scenario_id,
            p_record_id,
            v_loan_program_code,
            v_total_loan_amount,
            v_amount_needed_to_purchase,
            v_total_payment,
            v_interest_rate,
            v_discount_points_percent,
            v_apr
        )
        ON CONFLICT (scenario_id) 
        DO UPDATE SET
            loan_program_code = EXCLUDED.loan_program_code,
            total_loan_amount = EXCLUDED.total_loan_amount,
            amount_needed_to_purchase = EXCLUDED.amount_needed_to_purchase,
            total_payment = EXCLUDED.total_payment,
            interest_rate = EXCLUDED.interest_rate,
            discount_points_percent = EXCLUDED.discount_points_percent,
            apr = EXCLUDED.apr;
    END LOOP;
END;
$$;


ALTER PROCEDURE public.generate_listing_flyer_details(IN p_record_id integer) OWNER TO postgres;

--
-- Name: populate_non_calculated_fields(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.populate_non_calculated_fields() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE loan_scenarios
    SET
        loan_term = COALESCE(
            (SELECT value FROM defaults_count
             WHERE default_type = 'Loan Term'
             AND defaults_count.loan_program = NEW.loan_program_code
             AND (defaults_count.state = NEW.state OR defaults_count.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_count
             WHERE default_type = 'Loan Term'
             AND defaults_count.loan_program IS NULL
             AND defaults_count.state IS NULL
             LIMIT 1)
        ),
        lender_charges = COALESCE(
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Lender Charges'
             AND defaults_amount.loan_program = NEW.loan_program_code
             AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Lender Charges'
             AND defaults_amount.loan_program IS NULL
             AND defaults_amount.state IS NULL
             LIMIT 1)
        ),
        appraisal = COALESCE(
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Appraisal'
             AND defaults_amount.loan_program = NEW.loan_program_code
             AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Appraisal'
             AND defaults_amount.loan_program IS NULL
             AND defaults_amount.state IS NULL
             LIMIT 1)
        ),
        appraiser_reinspection = COALESCE(
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Appraiser Reinspection'
             AND defaults_amount.loan_program = NEW.loan_program_code
             AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Appraiser Reinspection'
             AND defaults_amount.loan_program IS NULL
             AND defaults_amount.state IS NULL
             LIMIT 1)
        ),
        credit_reports = COALESCE(
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Credit Reports'
             AND defaults_amount.loan_program = NEW.loan_program_code
             AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Credit Reports'
             AND defaults_amount.loan_program IS NULL
             AND defaults_amount.state IS NULL
             LIMIT 1)
        ),
        pest_home_inspections = COALESCE(
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Pest and Home Inspections'
             AND defaults_amount.loan_program = NEW.loan_program_code
             AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Pest and Home Inspections'
             AND defaults_amount.loan_program IS NULL
             AND defaults_amount.state IS NULL
             LIMIT 1)
        ),
        earnest_money = COALESCE(
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Earnest Money'
             AND defaults_amount.loan_program = NEW.loan_program_code
             AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_amount
             WHERE default_type = 'Earnest Money'
             AND defaults_amount.loan_program IS NULL
             AND defaults_amount.state IS NULL
             LIMIT 1)
        ),
        home_insurance = COALESCE(
            (SELECT value FROM defaults_percentage
             WHERE default_type = 'Annual Home Insurance'
             AND defaults_percentage.loan_program = NEW.loan_program_code
             AND (defaults_percentage.state = NEW.state OR defaults_percentage.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_percentage
             WHERE default_type = 'Annual Home Insurance'
             AND defaults_percentage.loan_program IS NULL
             AND defaults_percentage.state IS NULL
             LIMIT 1)
        ),
        -- Removed the hoa_fees calculation
        annual_pmi_percent = COALESCE(
            (SELECT value FROM defaults_percentage
             WHERE default_type = 'Annual PMI %'
             AND defaults_percentage.loan_program = NEW.loan_program_code
             AND (defaults_percentage.state = NEW.state OR defaults_percentage.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_percentage
             WHERE default_type = 'Annual PMI %'
             AND defaults_percentage.loan_program IS NULL
             AND defaults_percentage.state IS NULL
             LIMIT 1)
        ),
        financed_mi_premium_funding_fee = (
            SELECT value FROM defaults_percentage
            WHERE default_type = 'Up-Front MI/Funding Fee %'
            AND defaults_percentage.loan_program = NEW.loan_program_code
            AND (defaults_percentage.state = NEW.state OR defaults_percentage.state IS NULL)
            LIMIT 1
        ),
        down_payment = COALESCE(
            (SELECT value FROM defaults_percentage
             WHERE default_type = 'Down Payment %'
             AND defaults_percentage.loan_program = NEW.loan_program_code
             AND (defaults_percentage.state = NEW.state OR defaults_percentage.state IS NULL)
             LIMIT 1),
            (SELECT value FROM defaults_percentage
             WHERE default_type = 'Down Payment %'
             AND defaults_percentage.loan_program IS NULL
             AND defaults_percentage.state IS NULL
             LIMIT 1)
        ),
        recording_fees = COALESCE(
            (SELECT value FROM defaults_amount
            WHERE default_type = 'Recording Fees'
            AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
            AND (defaults_amount.loan_program = NEW.loan_program_code OR defaults_amount.loan_program IS NULL)
            LIMIT 1),
            (SELECT value FROM defaults_amount
            WHERE default_type = 'Recording Fees'
            AND defaults_amount.state IS NULL
            LIMIT 1)
        ),
        title_services = COALESCE(
            (SELECT value FROM defaults_amount
            WHERE default_type = 'Title Services'
            AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
            AND (defaults_amount.loan_program = NEW.loan_program_code OR defaults_amount.loan_program IS NULL)
            LIMIT 1),
            (SELECT value FROM defaults_amount
            WHERE default_type = 'Title Services'
            AND defaults_amount.state IS NULL
            AND defaults_amount.loan_program IS NULL
            LIMIT 1)
        ),
        survey = COALESCE(
            (SELECT value FROM defaults_amount
            WHERE default_type = 'Survey'
            AND (defaults_amount.state = NEW.state OR defaults_amount.state IS NULL)
            AND (defaults_amount.loan_program = NEW.loan_program_code OR defaults_amount.loan_program IS NULL)
            LIMIT 1),
            (SELECT value FROM defaults_amount
            WHERE default_type = 'Survey'
            AND defaults_amount.state IS NULL
            AND defaults_amount.loan_program IS NULL
            LIMIT 1)
        )
    WHERE
        scenario_id = NEW.scenario_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.populate_non_calculated_fields() OWNER TO postgres;

--
-- Name: process_new_record_loan_programs(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.process_new_record_loan_programs() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    loan_program TEXT;
    scenario_num INTEGER := 1;  -- Initialize scenario number
BEGIN
    -- Loop through the selected loan programs (stored as an array in NEW.loan_programs)
    FOR loan_program IN (SELECT UNNEST(NEW.loan_programs)) LOOP
        -- Map the loan program to the corresponding loan_program_code(s)
        IF loan_program = 'Conforming' THEN
            -- Create 4 scenarios for Conforming
            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'Conforming30DownH', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'Conforming30DownL', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'Conforming5DownH', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'Conforming5DownL', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

        ELSIF loan_program = 'FHA' THEN
            -- Create 2 scenarios for FHA
            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'FHAH', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'FHAL', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

        ELSIF loan_program = 'VA' THEN
            -- Create 2 scenarios for VA
            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'VAH', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'VAL', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

        ELSIF loan_program = 'USDA' THEN
            -- Create 2 scenarios for USDA
            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'USDAH', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

            INSERT INTO loan_scenarios (record_id, scenario_number, loan_program_code, state, purchase_price, property_taxes)
            VALUES (NEW.record_id, scenario_num, 'USDAL', NEW.state, NEW.sales_price, NEW.property_tax_amount / 12);
            scenario_num := scenario_num + 1;

        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.process_new_record_loan_programs() OWNER TO postgres;

--
-- Name: total_third_party_services(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.total_third_party_services(p_scenario_id integer) RETURNS TABLE(total_appraisal numeric, total_appraiser_reinspection numeric, total_credit_reports numeric, total_title_services numeric, total_title_insurance numeric, total_recording_fees numeric, total_ok_mortgage_tax numeric, total_survey numeric, total_pest_and_home_inspections numeric, grand_total numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        SUM(appraisal) AS total_appraisal,
        SUM(appraiser_reinspection) AS total_appraiser_reinspection,
        SUM(credit_reports) AS total_credit_reports,
        SUM(title_services) AS total_title_services,
        SUM(title_insurance) AS total_title_insurance,
        SUM(recording_fees) AS total_recording_fees,
        SUM(ok_mortgage_tax) AS total_ok_mortgage_tax,
        SUM(survey) AS total_survey,
        SUM(pest_home_inspections) AS total_pest_and_home_inspections,
        -- Calculate the grand total of all the above fields
        SUM(appraisal + appraiser_reinspection + credit_reports + title_services +
            title_insurance + recording_fees + ok_mortgage_tax + survey + pest_home_inspections) AS grand_total
    FROM
        loan_scenarios
    WHERE
        loan_scenarios.scenario_id = p_scenario_id;
END;
$$;


ALTER FUNCTION public.total_third_party_services(p_scenario_id integer) OWNER TO postgres;

--
-- Name: trg_calculate_discount_points_and_interest_rate(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_calculate_discount_points_and_interest_rate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    base_key_value TEXT;
    lowest_note_rate NUMERIC;
    corresponding_final_net_price NUMERIC;
    calculated_principal_and_interest NUMERIC;
BEGIN
    -- Conditional check to avoid recursion
    IF NEW.interest_rate IS NOT NULL AND NEW.discount_points_percent IS NOT NULL THEN
        RAISE NOTICE 'Skipping trigger execution to avoid recursion for scenario_id: %', NEW.scenario_id;
        RETURN NEW;
    END IF;

    -- Step 1: Determine the base key value based on loan_program_code
    SELECT key INTO base_key_value
    FROM (
        VALUES
            ('Conforming30DownH', '107460300'),
            ('Conforming30DownL', '107460300'),
            ('Conforming5DownH', '107460300'),
            ('Conforming5DownL', '107460300'),
            ('FHAH', '105360300'),
            ('FHAL', '105360300'),
            ('VAH', '107700300'),
            ('VAL', '107700300'),
            ('USDAH', '105360300'),
            ('USDAL', '105360300')
    ) AS mapping(loan_program_code, key)
    WHERE mapping.loan_program_code = NEW.loan_program_code;

    RAISE NOTICE 'Base key value: %', base_key_value;

    -- Step 2 and 3: Find the corresponding rate and final_net_price from the ratesheets table
    IF NEW.loan_program_code LIKE '%L' THEN
        -- For 'L' (low), find the lowest note_rate with the highest final_net_price
        SELECT note_rate, final_net_price INTO lowest_note_rate, corresponding_final_net_price
        FROM ratesheets
        WHERE key::TEXT LIKE base_key_value || '%'  -- Cast key to TEXT and match the beginning of the key
        ORDER BY note_rate ASC, final_net_price DESC
        LIMIT 1;
    ELSE
        -- For 'H' (high), find the lowest note_rate with the lowest absolute final_net_price
        SELECT note_rate, final_net_price INTO lowest_note_rate, corresponding_final_net_price
        FROM ratesheets
        WHERE key::TEXT LIKE base_key_value || '%'  -- Cast key to TEXT and match the beginning of the key
        ORDER BY ABS(final_net_price) ASC, note_rate ASC  -- Use ABS() to sort by absolute value of final_net_price
        LIMIT 1;
    END IF;

    RAISE NOTICE 'Selected note_rate: %, final_net_price: %', lowest_note_rate, corresponding_final_net_price;

    -- Step 4: Update the loan_scenarios table with the found values
    UPDATE loan_scenarios
    SET
        interest_rate = lowest_note_rate,  -- Update interest_rate with note_rate from ratesheets
        discount_points_percent = corresponding_final_net_price, -- Map final_net_price to discount_points_percent
        principal_and_interest = (NEW.total_loan_amount * lowest_note_rate / 1200) / (1 - (1 / (1 + (lowest_note_rate / 1200)) ^ 360))
    WHERE scenario_id = NEW.scenario_id;

    -- Step 5: Calculate and update total_payment field
    UPDATE loan_scenarios
    SET
        total_payment = principal_and_interest + property_taxes + private_mortgage_insurance + home_insurance_mo_pmt
    WHERE scenario_id = NEW.scenario_id;

    -- Step 6: Calculate and update loan_borrower_discount_points
    UPDATE loan_scenarios
    SET
        loan_borrower_discount_points = COALESCE(NEW.total_loan_amount, 0) * COALESCE(NEW.discount_points_percent, 0) / 100
    WHERE scenario_id = NEW.scenario_id;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_calculate_discount_points_and_interest_rate() OWNER TO postgres;

--
-- Name: trigger_generate_listing_flyer_details(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trigger_generate_listing_flyer_details() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Call the stored procedure using the NEW.record_id from the inserted row
    CALL generate_listing_flyer_details(NEW.record_id);
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trigger_generate_listing_flyer_details() OWNER TO postgres;

--
-- Name: view_summary_calculations(integer); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.view_summary_calculations(IN p_record_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_scenario_id INTEGER;
    v_total_origination_cost NUMERIC;
    v_total_third_party_services NUMERIC;
    v_total_prepaid_and_reserves NUMERIC;
    v_total_closing_costs_and_prepaids NUMERIC;
    v_total_due NUMERIC;
    v_amount_due_at_closing NUMERIC;
    v_total_amount_needed_to_purchase NUMERIC;
    v_earnest_money NUMERIC;
    v_appraisal NUMERIC;
    v_pest_home_inspections NUMERIC;
BEGIN
    -- Iterate over each scenario for the given record_id
    FOR v_scenario_id IN
        SELECT scenario_id
        FROM loan_scenarios
        WHERE record_id = p_record_id
    LOOP
        -- Calculate total_origination_cost
        SELECT
            ls.lender_charges + ls.loan_borrower_discount_points
        INTO v_total_origination_cost
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Calculate total_third_party_services
        SELECT
            ls.appraisal + ls.appraiser_reinspection + ls.credit_reports + ls.title_services + ls.title_insurance +
            ls.recording_fees + COALESCE(ls.ok_mortgage_tax, 0) + ls.survey + ls.pest_home_inspections
        INTO v_total_third_party_services
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Calculate total_prepaid_and_reserves
        SELECT
            COALESCE(ls.prepaid_interest, 0) + COALESCE(ls.up_front_mi_funding_fee, 0) + ls.homeowners_insurance_year_1 +
            ls.property_tax_escrow + ls.home_insurance_escrow
        INTO v_total_prepaid_and_reserves
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Calculate total_closing_costs_and_prepaids
        v_total_closing_costs_and_prepaids := v_total_origination_cost + v_total_third_party_services + v_total_prepaid_and_reserves;

        -- Calculate total_due
        SELECT
            ls.purchase_price + v_total_closing_costs_and_prepaids
        INTO v_total_due
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Fetch earnest_money, appraisal, and pest_home_inspections into variables
        SELECT 
            ls.earnest_money, 
            ls.appraisal, 
            ls.pest_home_inspections
        INTO 
            v_earnest_money, 
            v_appraisal, 
            v_pest_home_inspections
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Calculate amount_due_at_closing
        SELECT
            v_total_due - (ls.base_loan_amount + COALESCE(ls.up_front_mi_funding_fee, 0) + v_earnest_money + v_appraisal + v_pest_home_inspections)
        INTO v_amount_due_at_closing
        FROM loan_scenarios ls
        WHERE ls.scenario_id = v_scenario_id;

        -- Calculate total_amount_needed_to_purchase
        v_total_amount_needed_to_purchase := v_amount_due_at_closing - (v_earnest_money + v_appraisal + v_pest_home_inspections);

        -- Output the results using RAISE NOTICE
        RAISE NOTICE 'Scenario ID: %, Total Origination Cost: %, Total Third Party Services: %, Total Prepaid and Reserves: %', 
            v_scenario_id, v_total_origination_cost, v_total_third_party_services, v_total_prepaid_and_reserves;
        RAISE NOTICE 'Total Closing Costs and Prepaids: %, Total Due: %, Amount Due at Closing: %, Total Amount Needed to Purchase: %',
            v_total_closing_costs_and_prepaids, v_total_due, v_amount_due_at_closing, v_total_amount_needed_to_purchase;
    END LOOP;
END;
$$;


ALTER PROCEDURE public.view_summary_calculations(IN p_record_id integer) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: defaults_amount; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.defaults_amount (
    default_id integer NOT NULL,
    default_type character varying(100) NOT NULL,
    loan_program character varying(50),
    state character varying(2),
    value numeric(10,2) NOT NULL
);


ALTER TABLE public.defaults_amount OWNER TO postgres;

--
-- Name: defaults_amount_default_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.defaults_amount_default_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.defaults_amount_default_id_seq OWNER TO postgres;

--
-- Name: defaults_amount_default_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.defaults_amount_default_id_seq OWNED BY public.defaults_amount.default_id;


--
-- Name: defaults_count; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.defaults_count (
    default_id integer NOT NULL,
    default_type character varying(100) NOT NULL,
    loan_program character varying(50),
    state character varying(2),
    value integer NOT NULL
);


ALTER TABLE public.defaults_count OWNER TO postgres;

--
-- Name: defaults_count_default_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.defaults_count_default_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.defaults_count_default_id_seq OWNER TO postgres;

--
-- Name: defaults_count_default_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.defaults_count_default_id_seq OWNED BY public.defaults_count.default_id;


--
-- Name: defaults_percentage; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.defaults_percentage (
    default_id integer NOT NULL,
    default_type character varying(100) NOT NULL,
    loan_program character varying(50),
    state character varying(2),
    value numeric(10,5) NOT NULL
);


ALTER TABLE public.defaults_percentage OWNER TO postgres;

--
-- Name: defaults_percentage_default_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.defaults_percentage_default_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.defaults_percentage_default_id_seq OWNER TO postgres;

--
-- Name: defaults_percentage_default_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.defaults_percentage_default_id_seq OWNED BY public.defaults_percentage.default_id;


--
-- Name: loan_scenario_results; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.loan_scenario_results (
    scenario_id integer NOT NULL,
    record_id integer NOT NULL,
    loan_program_code text NOT NULL,
    total_loan_amount numeric NOT NULL,
    amount_needed_to_purchase numeric NOT NULL,
    total_payment numeric NOT NULL,
    interest_rate numeric NOT NULL,
    discount_points_percent numeric NOT NULL,
    apr numeric NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.loan_scenario_results OWNER TO postgres;

--
-- Name: loan_scenario_results_scenario_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.loan_scenario_results_scenario_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.loan_scenario_results_scenario_id_seq OWNER TO postgres;

--
-- Name: loan_scenario_results_scenario_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.loan_scenario_results_scenario_id_seq OWNED BY public.loan_scenario_results.scenario_id;


--
-- Name: loan_scenarios; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.loan_scenarios (
    scenario_id integer NOT NULL,
    record_id integer NOT NULL,
    scenario_number integer NOT NULL,
    purchase_price numeric(15,0),
    base_loan_amount numeric(15,0),
    total_loan_amount numeric(15,0),
    down_payment numeric(15,4),
    principal_and_interest numeric(15,0),
    property_taxes numeric(15,0),
    home_insurance numeric(15,4),
    private_mortgage_insurance numeric(15,0),
    total_payment numeric(15,0),
    interest_rate numeric(5,3),
    discount_points_percent numeric(5,3),
    lender_charges numeric(15,0),
    loan_borrower_discount_points numeric(15,0),
    appraisal numeric(15,0),
    appraiser_reinspection numeric(15,0),
    credit_reports numeric(15,0),
    title_services numeric(15,0),
    title_insurance numeric(15,0),
    recording_fees numeric(15,0),
    ok_mortgage_tax numeric(15,0),
    survey numeric(15,0),
    pest_home_inspections numeric(15,0),
    up_front_mi_funding_fee numeric(15,0),
    prepaid_interest numeric(15,0),
    homeowners_insurance_year_1 numeric(15,0),
    property_tax_escrow numeric(15,0),
    home_insurance_escrow numeric(15,0),
    financed_mi_premium_funding_fee numeric(10,5),
    earnest_money numeric(15,0),
    annual_pmi_percent numeric(10,5),
    loan_term integer,
    loan_program_code character varying(50),
    state character varying(2),
    home_insurance_mo_pmt numeric(10,2)
);


ALTER TABLE public.loan_scenarios OWNER TO postgres;

--
-- Name: loan_scenarios_scenario_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.loan_scenarios_scenario_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.loan_scenarios_scenario_id_seq OWNER TO postgres;

--
-- Name: loan_scenarios_scenario_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.loan_scenarios_scenario_id_seq OWNED BY public.loan_scenarios.scenario_id;


--
-- Name: new_record; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.new_record (
    record_id integer NOT NULL,
    sales_price numeric(8,0) NOT NULL,
    subject_property_address character varying(50) NOT NULL,
    property_tax_amount numeric(5,0) NOT NULL,
    seller_incentives numeric(5,0) NOT NULL,
    loan_programs text[],
    state character varying(2)
);


ALTER TABLE public.new_record OWNER TO postgres;

--
-- Name: new_record_record_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.new_record_record_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.new_record_record_id_seq OWNER TO postgres;

--
-- Name: new_record_record_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.new_record_record_id_seq OWNED BY public.new_record.record_id;


--
-- Name: ratesheets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ratesheets (
    key bigint NOT NULL,
    note_rate numeric(10,3) NOT NULL,
    final_base_price numeric(10,4) NOT NULL,
    final_net_price numeric(10,4) NOT NULL,
    abs_final_net_price numeric(10,4) NOT NULL,
    lpname character varying(50) NOT NULL,
    effective_time timestamp with time zone NOT NULL
);


ALTER TABLE public.ratesheets OWNER TO postgres;

--
-- Name: ratesheets_key_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.ratesheets_key_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ratesheets_key_seq OWNER TO postgres;

--
-- Name: ratesheets_key_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.ratesheets_key_seq OWNED BY public.ratesheets.key;


--
-- Name: defaults_amount default_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.defaults_amount ALTER COLUMN default_id SET DEFAULT nextval('public.defaults_amount_default_id_seq'::regclass);


--
-- Name: defaults_count default_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.defaults_count ALTER COLUMN default_id SET DEFAULT nextval('public.defaults_count_default_id_seq'::regclass);


--
-- Name: defaults_percentage default_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.defaults_percentage ALTER COLUMN default_id SET DEFAULT nextval('public.defaults_percentage_default_id_seq'::regclass);


--
-- Name: loan_scenario_results scenario_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loan_scenario_results ALTER COLUMN scenario_id SET DEFAULT nextval('public.loan_scenario_results_scenario_id_seq'::regclass);


--
-- Name: loan_scenarios scenario_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loan_scenarios ALTER COLUMN scenario_id SET DEFAULT nextval('public.loan_scenarios_scenario_id_seq'::regclass);


--
-- Name: new_record record_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.new_record ALTER COLUMN record_id SET DEFAULT nextval('public.new_record_record_id_seq'::regclass);


--
-- Name: ratesheets key; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ratesheets ALTER COLUMN key SET DEFAULT nextval('public.ratesheets_key_seq'::regclass);


--
-- Data for Name: defaults_amount; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.defaults_amount (default_id, default_type, loan_program, state, value) FROM stdin;
7	Lender Charges	\N	\N	1100.00
8	Appraisal	\N	\N	625.00
9	Appraiser Reinspection	\N	\N	200.00
10	Credit Reports	\N	\N	85.00
11	Survey	\N	OK	225.00
13	Title Services	\N	OK	1400.00
15	Recording Fees	\N	OK	102.00
17	Pest and Home Inspections	\N	\N	525.00
18	Earnest Money	\N	\N	2500.00
16	Recording Fees	\N	TX	200.00
12	Survey	\N	TX	500.00
14	Title Services	\N	TX	1600.00
\.


--
-- Data for Name: defaults_count; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.defaults_count (default_id, default_type, loan_program, state, value) FROM stdin;
1	Property Tax Escrow	\N	\N	3
2	Home Insurance Escrow	\N	\N	3
3	Prepaid Interest (Days)	\N	\N	15
4	Loan Term	\N	\N	360
\.


--
-- Data for Name: defaults_percentage; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.defaults_percentage (default_id, default_type, loan_program, state, value) FROM stdin;
15	Up-Front MI/Funding Fee %	Conforming5DownH	\N	0.00000
16	Up-Front MI/Funding Fee %	Conforming5DownL	\N	0.00000
29	Down Payment %	VAH	\N	0.00000
30	Down Payment %	VAL	\N	0.00000
31	Down Payment %	USDAH	\N	0.00000
32	Down Payment %	USDAL	\N	0.00000
7	Annual PMI %	VAH	\N	0.00000
8	Annual PMI %	VAL	\N	0.00000
3	Annual PMI %	Conforming5DownH	\N	0.00290
4	Annual PMI %	Conforming5DownL	\N	0.00290
5	Annual PMI %	FHAH	\N	0.00550
6	Annual PMI %	FHAL	\N	0.00550
10	Annual PMI %	USDAL	\N	0.00350
9	Annual PMI %	USDAH	\N	0.00350
11	Annual Home Insurance	\N	\N	0.00800
13	Up-Front MI/Funding Fee %	Conforming30DownH	\N	0.00000
14	Up-Front MI/Funding Fee %	Conforming30DownL	\N	0.00000
1	Annual PMI %	Conforming30DownH	\N	0.00000
2	Annual PMI %	Conforming30DownL	\N	0.00000
25	Down Payment %	Conforming5DownH	\N	0.05000
26	Down Payment %	Conforming5DownL	\N	0.05000
28	Down Payment %	FHAL	\N	0.03500
27	Down Payment %	FHAH	\N	0.03500
23	Down Payment %	Conforming30DownH	\N	0.20000
24	Down Payment %	Conforming30DownL	\N	0.20000
17	Up-Front MI/Funding Fee %	FHAH	\N	0.01750
18	Up-Front MI/Funding Fee %	FHAL	\N	0.01750
20	Up-Front MI/Funding Fee %	VAL	\N	0.02300
19	Up-Front MI/Funding Fee %	VAH	\N	0.02300
22	Up-Front MI/Funding Fee %	USDAL	\N	0.01000
21	Up-Front MI/Funding Fee %	USDAH	\N	0.01000
\.


--
-- Data for Name: loan_scenario_results; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.loan_scenario_results (scenario_id, record_id, loan_program_code, total_loan_amount, amount_needed_to_purchase, total_payment, interest_rate, discount_points_percent, apr, created_at) FROM stdin;
2166	305	Conforming30DownH	320000	94707	3185	5.999	0.164	6.16672479543496817800	2024-09-02 06:48:04.914893
2167	305	Conforming30DownL	320000	100678	3084	5.500	2.051	5.64078603855353481300	2024-09-02 06:48:04.914893
2168	305	Conforming5DownH	380000	35015	3637	5.999	0.164	6.47348228494983786400	2024-09-02 06:48:04.914893
2169	305	Conforming5DownL	380000	42107	3517	5.500	2.051	5.94615040001084451200	2024-09-02 06:48:04.914893
2170	305	FHAH	392755	27858	3705	5.625	-0.132	6.35279807140798563200	2024-09-02 06:48:04.914893
2171	305	FHAL	392755	39965	3522	4.875	2.982	5.56194391439395997000	2024-09-02 06:48:04.914893
2172	305	VAH	409200	14956	3688	5.875	0.118	6.03580695832318258800	2024-09-02 06:48:04.914893
2173	305	VAL	409200	25273	3433	4.875	2.681	4.98541438868244369300	2024-09-02 06:48:04.914893
2174	305	USDAH	404000	13880	3710	5.625	-0.132	6.14137430150288260200	2024-09-02 06:48:04.914893
2175	305	USDAL	404000	26334	3522	4.875	2.982	5.35196187311548470100	2024-09-02 06:48:04.914893
2211	309	FHAL	392755	40385	3522	4.875	2.982	5.56194391439395997000	2024-09-02 06:58:35.913527
2212	309	VAH	409200	15360	3688	5.875	0.118	6.03580695832318258800	2024-09-02 06:58:35.913527
2213	309	VAL	409200	25677	3433	4.875	2.681	4.98541438868244369300	2024-09-02 06:58:35.913527
2214	309	USDAH	404000	14289	3710	5.625	-0.132	6.14137430150288260200	2024-09-02 06:58:35.913527
2222	310	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 07:05:44.346974
2223	310	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 07:05:44.346974
2216	310	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 07:05:44.346974
2217	310	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 07:05:44.346974
2218	310	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 07:05:44.346974
2219	310	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 07:05:44.346974
2220	310	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 07:05:44.346974
2221	310	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 07:05:44.346974
2215	309	USDAL	404000	26743	3522	4.875	2.982	5.35196187311548470100	2024-09-02 06:58:35.913527
2206	309	Conforming30DownH	320000	95200	3185	5.999	0.164	6.16672479543496817800	2024-09-02 06:58:35.913527
2207	309	Conforming30DownL	320000	101171	3084	5.500	2.051	5.64078603855353481300	2024-09-02 06:58:35.913527
2208	309	Conforming5DownH	380000	35448	3637	5.999	0.164	6.47348228494983786400	2024-09-02 06:58:35.913527
2209	309	Conforming5DownL	380000	42540	3517	5.500	2.051	5.94615040001084451200	2024-09-02 06:58:35.913527
2210	309	FHAH	392755	28278	3705	5.625	-0.132	6.35279807140798563200	2024-09-02 06:58:35.913527
2224	310	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 07:05:44.346974
2225	310	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 07:05:44.346974
2226	311	Conforming30DownH	320000	95449	3268	5.999	0.164	6.16672479543496817800	2024-09-02 07:05:44.424281
2227	311	Conforming30DownL	320000	101420	3167	5.500	2.051	5.64078603855353481300	2024-09-02 07:05:44.424281
2228	311	Conforming5DownH	380000	35697	3720	5.999	0.164	6.47348228494983786400	2024-09-02 07:05:44.424281
2229	311	Conforming5DownL	380000	42789	3600	5.500	2.051	5.94615040001084451200	2024-09-02 07:05:44.424281
2230	311	FHAH	392755	28527	3788	5.625	-0.132	6.35279807140798563200	2024-09-02 07:05:44.424281
2231	311	FHAL	392755	40634	3605	4.875	2.982	5.56194391439395997000	2024-09-02 07:05:44.424281
2232	311	VAH	409200	15609	3771	5.875	0.118	6.03580695832318258800	2024-09-02 07:05:44.424281
2233	311	VAL	409200	25926	3516	4.875	2.681	4.98541438868244369300	2024-09-02 07:05:44.424281
2234	311	USDAH	404000	14538	3793	5.625	-0.132	6.14137430150288260200	2024-09-02 07:05:44.424281
2235	311	USDAL	404000	26992	3605	4.875	2.982	5.35196187311548470100	2024-09-02 07:05:44.424281
2236	312	Conforming30DownH	160000	50285	1759	5.999	0.164	6.16672479543496817800	2024-09-02 08:29:28.413687
2237	312	Conforming30DownL	160000	53272	1708	5.500	2.051	5.64078603855353481300	2024-09-02 08:29:28.413687
2238	312	Conforming5DownH	190000	20440	1985	5.999	0.164	6.47348228494983786400	2024-09-02 08:29:28.413687
2239	312	Conforming5DownL	190000	23985	1925	5.500	2.051	5.94615040001084451200	2024-09-02 08:29:28.413687
2240	312	FHAH	196378	16860	2018	5.625	-0.132	6.35279807140798563200	2024-09-02 08:29:28.413687
2241	312	FHAL	196378	22914	1927	4.875	2.982	5.56194391439395997000	2024-09-02 08:29:28.413687
2242	312	VAH	204600	10410	2010	5.875	0.118	6.03580695832318258800	2024-09-02 08:29:28.413687
2243	312	VAL	204600	15569	1883	4.875	2.681	4.98541438868244369300	2024-09-02 08:29:28.413687
2244	312	USDAH	202000	9871	2021	5.625	-0.132	6.14137430150288260200	2024-09-02 08:29:28.413687
2245	312	USDAL	202000	16099	1927	4.875	2.982	5.35196187311548470100	2024-09-02 08:29:28.413687
2246	313	Conforming30DownH	392000	114848	3677	5.999	0.164	6.16672479543496817800	2024-09-02 08:41:03.260742
2247	313	Conforming30DownL	392000	122163	3553	5.500	2.051	5.64078603855353481300	2024-09-02 08:41:03.260742
2248	313	Conforming5DownH	465500	41652	4230	5.999	0.164	6.47348228494983786400	2024-09-02 08:41:03.260742
2249	313	Conforming5DownL	465500	50339	4082	5.500	2.051	5.94615040001084451200	2024-09-02 08:41:03.260742
2250	313	FHAH	481125	32868	4314	5.625	-0.132	6.35279807140798563200	2024-09-02 08:41:03.260742
2251	313	FHAL	481125	47699	4090	4.875	2.982	5.56194391439395997000	2024-09-02 08:41:03.260742
2252	313	VAH	501270	17043	4292	5.875	0.118	6.03580695832318258800	2024-09-02 08:41:03.260742
2253	313	VAL	501270	29682	3980	4.875	2.681	4.98541438868244369300	2024-09-02 08:41:03.260742
2254	313	USDAH	494900	15732	4319	5.625	-0.132	6.14137430150288260200	2024-09-02 08:41:03.260742
2255	313	USDAL	494900	30988	4089	4.875	2.982	5.35196187311548470100	2024-09-02 08:41:03.260742
2256	314	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 08:42:53.611084
2257	314	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 08:42:53.611084
2258	314	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 08:42:53.611084
2259	314	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 08:42:53.611084
2260	314	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 08:42:53.611084
2261	314	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 08:42:53.611084
2262	314	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 08:42:53.611084
2263	314	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 08:42:53.611084
2264	314	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 08:42:53.611084
2265	314	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 08:42:53.611084
2266	315	Conforming30DownH	480000	138862	4278	5.999	0.164	6.16672479543496817800	2024-09-02 08:42:53.72782
2267	315	Conforming30DownL	480000	147820	4125	5.500	2.051	5.64078603855353481300	2024-09-02 08:42:53.72782
2268	315	Conforming5DownH	570000	49235	4955	5.999	0.164	6.47348228494983786400	2024-09-02 08:42:53.72782
2269	315	Conforming5DownL	570000	59872	4774	5.500	2.051	5.94615040001084451200	2024-09-02 08:42:53.72782
2270	315	FHAH	589133	38478	5056	5.625	-0.132	6.35279807140798563200	2024-09-02 08:42:53.72782
2271	315	FHAL	589133	56640	4783	4.875	2.982	5.56194391439395997000	2024-09-02 08:42:53.72782
2272	315	VAH	613800	19102	5031	5.875	0.118	6.03580695832318258800	2024-09-02 08:42:53.72782
2273	315	VAL	613800	34578	4648	4.875	2.681	4.98541438868244369300	2024-09-02 08:42:53.72782
2274	315	USDAH	606000	17495	5063	5.625	-0.132	6.14137430150288260200	2024-09-02 08:42:53.72782
2275	315	USDAL	606000	36177	4782	4.875	2.982	5.35196187311548470100	2024-09-02 08:42:53.72782
2276	316	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 08:46:31.794065
2277	316	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 08:46:31.794065
2278	316	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 08:46:31.794065
2279	316	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 08:46:31.794065
2280	316	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 08:46:31.794065
2281	316	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 08:46:31.794065
2282	316	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 08:46:31.794065
2283	316	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 08:46:31.794065
2284	316	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 08:46:31.794065
2285	316	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 08:46:31.794065
2286	317	Conforming30DownH	200000	62453	2366	5.999	0.164	6.16672479543496817800	2024-09-02 10:31:57.708275
2287	317	Conforming30DownL	200000	66185	2303	5.500	2.051	5.64078603855353481300	2024-09-02 10:31:57.708275
2288	317	Conforming5DownH	237500	25109	2648	5.999	0.164	6.47348228494983786400	2024-09-02 10:31:57.708275
2289	317	Conforming5DownL	237500	29540	2572	5.500	2.051	5.94615040001084451200	2024-09-02 10:31:57.708275
2290	317	FHAH	245472	20626	2691	5.625	-0.132	6.35279807140798563200	2024-09-02 10:31:57.708275
2291	317	FHAL	245472	28194	2577	4.875	2.982	5.56194391439395997000	2024-09-02 10:31:57.708275
2292	317	VAH	255750	12553	2680	5.875	0.118	6.03580695832318258800	2024-09-02 10:31:57.708275
2293	317	VAL	255750	19001	2520	4.875	2.681	4.98541438868244369300	2024-09-02 10:31:57.708275
2294	317	USDAH	252500	11884	2694	5.625	-0.132	6.14137430150288260200	2024-09-02 10:31:57.708275
2295	317	USDAL	252500	19668	2576	4.875	2.982	5.35196187311548470100	2024-09-02 10:31:57.708275
2306	319	Conforming30DownH	192000	60270	2311	5.999	0.164	6.16672479543496817800	2024-09-02 10:34:38.884477
2296	318	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 10:31:57.853498
2297	318	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 10:31:57.853498
2298	318	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 10:31:57.853498
2299	318	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 10:31:57.853498
2300	318	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 10:31:57.853498
2301	318	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 10:31:57.853498
2302	318	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 10:31:57.853498
2303	318	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 10:31:57.853498
2304	318	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 10:31:57.853498
2305	318	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 10:31:57.853498
2307	319	Conforming30DownL	192000	63853	2250	5.500	2.051	5.64078603855353481300	2024-09-02 10:34:38.884477
2308	319	Conforming5DownH	228000	24419	2582	5.999	0.164	6.47348228494983786400	2024-09-02 10:34:38.884477
2309	319	Conforming5DownL	228000	28674	2510	5.500	2.051	5.94615040001084451200	2024-09-02 10:34:38.884477
2310	319	FHAH	235653	20116	2623	5.625	-0.132	6.35279807140798563200	2024-09-02 10:34:38.884477
2311	319	FHAL	235653	27381	2513	4.875	2.982	5.56194391439395997000	2024-09-02 10:34:38.884477
2312	319	VAH	245520	12366	2612	5.875	0.118	6.03580695832318258800	2024-09-02 10:34:38.884477
2313	319	VAL	245520	18556	2459	4.875	2.681	4.98541438868244369300	2024-09-02 10:34:38.884477
2314	319	USDAH	242400	11723	2625	5.625	-0.132	6.14137430150288260200	2024-09-02 10:34:38.884477
2315	319	USDAL	242400	19195	2513	4.875	2.982	5.35196187311548470100	2024-09-02 10:34:38.884477
2316	320	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 10:55:48.198943
2317	320	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 10:55:48.198943
2318	320	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 10:55:48.198943
2319	320	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 10:55:48.198943
2320	320	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 10:55:48.198943
2321	320	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 10:55:48.198943
2322	320	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 10:55:48.198943
2323	320	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 10:55:48.198943
2324	320	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 10:55:48.198943
2325	320	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 10:55:48.198943
2336	322	Conforming30DownH	160000	50534	1842	5.999	0.164	6.16672479543496817800	2024-09-02 11:13:34.608628
2326	321	Conforming30DownH	320000	94206	3018	5.999	0.164	6.16672479543496817800	2024-09-02 10:55:48.315564
2327	321	Conforming30DownL	320000	100177	2917	5.500	2.051	5.64078603855353481300	2024-09-02 10:55:48.315564
2328	321	Conforming5DownH	380000	34514	3470	5.999	0.164	6.47348228494983786400	2024-09-02 10:55:48.315564
2329	321	Conforming5DownL	380000	41606	3350	5.500	2.051	5.94615040001084451200	2024-09-02 10:55:48.315564
2330	321	FHAH	392755	27357	3538	5.625	-0.132	6.35279807140798563200	2024-09-02 10:55:48.315564
2331	321	FHAL	392755	39464	3355	4.875	2.982	5.56194391439395997000	2024-09-02 10:55:48.315564
2332	321	VAH	409200	14455	3521	5.875	0.118	6.03580695832318258800	2024-09-02 10:55:48.315564
2333	321	VAL	409200	24772	3266	4.875	2.681	4.98541438868244369300	2024-09-02 10:55:48.315564
2334	321	USDAH	404000	13379	3543	5.625	-0.132	6.14137430150288260200	2024-09-02 10:55:48.315564
2335	321	USDAL	404000	25833	3355	4.875	2.982	5.35196187311548470100	2024-09-02 10:55:48.315564
2337	322	Conforming30DownL	160000	53521	1791	5.500	2.051	5.64078603855353481300	2024-09-02 11:13:34.608628
2338	322	Conforming5DownH	190000	20689	2068	5.999	0.164	6.47348228494983786400	2024-09-02 11:13:34.608628
2339	322	Conforming5DownL	190000	24234	2008	5.500	2.051	5.94615040001084451200	2024-09-02 11:13:34.608628
2340	322	FHAH	196378	17109	2101	5.625	-0.132	6.35279807140798563200	2024-09-02 11:13:34.608628
2341	322	FHAL	196378	23163	2010	4.875	2.982	5.56194391439395997000	2024-09-02 11:13:34.608628
2342	322	VAH	204600	10659	2093	5.875	0.118	6.03580695832318258800	2024-09-02 11:13:34.608628
2343	322	VAL	204600	15818	1966	4.875	2.681	4.98541438868244369300	2024-09-02 11:13:34.608628
2344	322	USDAH	202000	10120	2104	5.625	-0.132	6.14137430150288260200	2024-09-02 11:13:34.608628
2345	322	USDAL	202000	16348	2010	4.875	2.982	5.35196187311548470100	2024-09-02 11:13:34.608628
2346	323	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 11:13:34.685207
2347	323	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 11:13:34.685207
2348	323	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 11:13:34.685207
2349	323	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 11:13:34.685207
2350	323	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 11:13:34.685207
2351	323	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 11:13:34.685207
2352	323	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 11:13:34.685207
2353	323	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 11:13:34.685207
2354	323	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 11:13:34.685207
2355	323	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 11:13:34.685207
2366	325	Conforming30DownH	240000	72996	2639	5.999	0.164	6.16672479543496817800	2024-09-02 11:52:18.288984
2367	325	Conforming30DownL	240000	77474	2563	5.500	2.051	5.64078603855353481300	2024-09-02 11:52:18.288984
2368	325	Conforming5DownH	285000	28226	2978	5.999	0.164	6.47348228494983786400	2024-09-02 11:52:18.288984
2356	324	Conforming30DownH	540000	155236	4687	5.999	0.164	6.16672479543496817800	2024-09-02 11:21:57.723335
2357	324	Conforming30DownL	540000	165313	4516	5.500	2.051	5.64078603855353481300	2024-09-02 11:21:57.723335
2358	324	Conforming5DownH	641250	54405	5449	5.999	0.164	6.47348228494983786400	2024-09-02 11:21:57.723335
2359	324	Conforming5DownL	641250	66372	5246	5.500	2.051	5.94615040001084451200	2024-09-02 11:21:57.723335
2360	324	FHAH	662774	42303	5564	5.625	-0.132	6.35279807140798563200	2024-09-02 11:21:57.723335
2361	324	FHAL	662774	62735	5256	4.875	2.982	5.56194391439395997000	2024-09-02 11:21:57.723335
2362	324	VAH	690525	20505	5535	5.875	0.118	6.03580695832318258800	2024-09-02 11:21:57.723335
2363	324	VAL	690525	37916	5104	4.875	2.681	4.98541438868244369300	2024-09-02 11:21:57.723335
2364	324	USDAH	681750	18698	5572	5.625	-0.132	6.14137430150288260200	2024-09-02 11:21:57.723335
2365	324	USDAL	681750	39715	5255	4.875	2.982	5.35196187311548470100	2024-09-02 11:21:57.723335
2369	325	Conforming5DownL	285000	33545	2887	5.500	2.051	5.94615040001084451200	2024-09-02 11:52:18.288984
2370	325	FHAH	294566	22858	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 11:52:18.288984
2371	325	FHAL	294566	31939	2892	4.875	2.982	5.56194391439395997000	2024-09-02 11:52:18.288984
2372	325	VAH	306900	13182	3015	5.875	0.118	6.03580695832318258800	2024-09-02 11:52:18.288984
2373	325	VAL	306900	20920	2824	4.875	2.681	4.98541438868244369300	2024-09-02 11:52:18.288984
2374	325	USDAH	303000	12375	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 11:52:18.288984
2375	325	USDAL	303000	21715	2892	4.875	2.982	5.35196187311548470100	2024-09-02 11:52:18.288984
2376	326	Conforming30DownH	240000	72495	2472	5.999	0.164	6.16672479543496817800	2024-09-02 11:58:44.584514
2377	326	Conforming30DownL	240000	76973	2396	5.500	2.051	5.64078603855353481300	2024-09-02 11:58:44.584514
2378	326	Conforming5DownH	285000	27725	2811	5.999	0.164	6.47348228494983786400	2024-09-02 11:58:44.584514
2379	326	Conforming5DownL	285000	33044	2720	5.500	2.051	5.94615040001084451200	2024-09-02 11:58:44.584514
2380	326	FHAH	294566	22357	2862	5.625	-0.132	6.35279807140798563200	2024-09-02 11:58:44.584514
2381	326	FHAL	294566	31438	2725	4.875	2.982	5.56194391439395997000	2024-09-02 11:58:44.584514
2382	326	VAH	306900	12681	2848	5.875	0.118	6.03580695832318258800	2024-09-02 11:58:44.584514
2383	326	VAL	306900	20419	2657	4.875	2.681	4.98541438868244369300	2024-09-02 11:58:44.584514
2384	326	USDAH	303000	11874	2865	5.625	-0.132	6.14137430150288260200	2024-09-02 11:58:44.584514
2385	326	USDAL	303000	21214	2725	4.875	2.982	5.35196187311548470100	2024-09-02 11:58:44.584514
2396	328	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 12:02:44.745959
2397	328	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 12:02:44.745959
2398	328	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 12:02:44.745959
2399	328	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 12:02:44.745959
2386	327	Conforming30DownH	240000	72495	2472	5.999	0.164	6.16672479543496817800	2024-09-02 12:00:56.403095
2387	327	Conforming30DownL	240000	76973	2396	5.500	2.051	5.64078603855353481300	2024-09-02 12:00:56.403095
2388	327	Conforming5DownH	285000	27725	2811	5.999	0.164	6.47348228494983786400	2024-09-02 12:00:56.403095
2389	327	Conforming5DownL	285000	33044	2720	5.500	2.051	5.94615040001084451200	2024-09-02 12:00:56.403095
2390	327	FHAH	294566	22357	2862	5.625	-0.132	6.35279807140798563200	2024-09-02 12:00:56.403095
2391	327	FHAL	294566	31438	2725	4.875	2.982	5.56194391439395997000	2024-09-02 12:00:56.403095
2392	327	VAH	306900	12681	2848	5.875	0.118	6.03580695832318258800	2024-09-02 12:00:56.403095
2393	327	VAL	306900	20419	2657	4.875	2.681	4.98541438868244369300	2024-09-02 12:00:56.403095
2394	327	USDAH	303000	11874	2865	5.625	-0.132	6.14137430150288260200	2024-09-02 12:00:56.403095
2395	327	USDAL	303000	21214	2725	4.875	2.982	5.35196187311548470100	2024-09-02 12:00:56.403095
2400	328	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 12:02:44.745959
2401	328	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 12:02:44.745959
2402	328	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 12:02:44.745959
2403	328	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 12:02:44.745959
2404	328	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 12:02:44.745959
2405	328	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 12:02:44.745959
2406	329	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 12:05:10.062801
2407	329	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 12:05:10.062801
2408	329	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 12:05:10.062801
2409	329	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 12:05:10.062801
2410	329	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 12:05:10.062801
2411	329	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 12:05:10.062801
2412	329	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 12:05:10.062801
2413	329	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 12:05:10.062801
2414	329	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 12:05:10.062801
2415	329	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 12:05:10.062801
2416	330	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 12:06:44.435233
2417	330	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 12:06:44.435233
2418	330	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 12:06:44.435233
2419	330	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 12:06:44.435233
2420	330	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 12:06:44.435233
2421	330	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 12:06:44.435233
2422	330	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 12:06:44.435233
2423	330	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 12:06:44.435233
2424	330	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 12:06:44.435233
2425	330	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 12:06:44.435233
2426	331	Conforming30DownH	160000	50783	1925	5.999	0.164	6.16672479543496817800	2024-09-02 12:06:44.492103
2427	331	Conforming30DownL	160000	53770	1874	5.500	2.051	5.64078603855353481300	2024-09-02 12:06:44.492103
2428	331	Conforming5DownH	190000	20938	2151	5.999	0.164	6.47348228494983786400	2024-09-02 12:06:44.492103
2429	331	Conforming5DownL	190000	24483	2091	5.500	2.051	5.94615040001084451200	2024-09-02 12:06:44.492103
2430	331	FHAH	196378	17358	2184	5.625	-0.132	6.35279807140798563200	2024-09-02 12:06:44.492103
2431	331	FHAL	196378	23412	2093	4.875	2.982	5.56194391439395997000	2024-09-02 12:06:44.492103
2432	331	VAH	204600	10908	2176	5.875	0.118	6.03580695832318258800	2024-09-02 12:06:44.492103
2433	331	VAL	204600	16067	2049	4.875	2.681	4.98541438868244369300	2024-09-02 12:06:44.492103
2434	331	USDAH	202000	10369	2187	5.625	-0.132	6.14137430150288260200	2024-09-02 12:06:44.492103
2435	331	USDAL	202000	16597	2093	4.875	2.982	5.35196187311548470100	2024-09-02 12:06:44.492103
2436	332	Conforming30DownH	400000	117031	3731	5.999	0.164	6.16672479543496817800	2024-09-02 12:08:27.107259
2437	332	Conforming30DownL	400000	124496	3604	5.500	2.051	5.64078603855353481300	2024-09-02 12:08:27.107259
2438	332	Conforming5DownH	475000	42341	4296	5.999	0.164	6.47348228494983786400	2024-09-02 12:08:27.107259
2439	332	Conforming5DownL	475000	51206	4145	5.500	2.051	5.94615040001084451200	2024-09-02 12:08:27.107259
2440	332	FHAH	490944	33378	4380	5.625	-0.132	6.35279807140798563200	2024-09-02 12:08:27.107259
2441	332	FHAL	490944	48512	4152	4.875	2.982	5.56194391439395997000	2024-09-02 12:08:27.107259
2442	332	VAH	511500	17231	4359	5.875	0.118	6.03580695832318258800	2024-09-02 12:08:27.107259
2443	332	VAL	511500	30127	4040	4.875	2.681	4.98541438868244369300	2024-09-02 12:08:27.107259
2444	332	USDAH	505000	15892	4386	5.625	-0.132	6.14137430150288260200	2024-09-02 12:08:27.107259
2445	332	USDAL	505000	31460	4152	4.875	2.982	5.35196187311548470100	2024-09-02 12:08:27.107259
2446	333	Conforming30DownH	364000	107957	3735	5.999	0.164	6.16672479543496817800	2024-09-02 12:55:33.935804
2447	333	Conforming30DownL	364000	114750	3620	5.500	2.051	5.64078603855353481300	2024-09-02 12:55:33.935804
2448	333	Conforming5DownH	432250	39989	4248	5.999	0.164	6.47348228494983786400	2024-09-02 12:55:33.935804
2449	333	Conforming5DownL	432250	48056	4111	5.500	2.051	5.94615040001084451200	2024-09-02 12:55:33.935804
2450	333	FHAH	446759	31832	4326	5.625	-0.132	6.35279807140798563200	2024-09-02 12:55:33.935804
2451	333	FHAL	446759	45604	4118	4.875	2.982	5.56194391439395997000	2024-09-02 12:55:33.935804
2452	333	VAH	465465	17138	4306	5.875	0.118	6.03580695832318258800	2024-09-02 12:55:33.935804
2453	333	VAL	465465	28874	4016	4.875	2.681	4.98541438868244369300	2024-09-02 12:55:33.935804
2454	333	USDAH	459550	15920	4331	5.625	-0.132	6.14137430150288260200	2024-09-02 12:55:33.935804
2455	333	USDAL	459550	30087	4118	4.875	2.982	5.35196187311548470100	2024-09-02 12:55:33.935804
2456	334	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 12:58:48.735439
2457	334	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 12:58:48.735439
2458	334	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 12:58:48.735439
2459	334	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 12:58:48.735439
2460	334	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 12:58:48.735439
2461	334	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 12:58:48.735439
2462	334	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 12:58:48.735439
2463	334	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 12:58:48.735439
2464	334	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 12:58:48.735439
2465	334	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 12:58:48.735439
2466	335	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 13:00:28.855981
2467	335	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 13:00:28.855981
2468	335	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 13:00:28.855981
2469	335	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 13:00:28.855981
2470	335	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 13:00:28.855981
2471	335	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 13:00:28.855981
2472	335	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 13:00:28.855981
2473	335	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 13:00:28.855981
2474	335	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 13:00:28.855981
2475	335	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 13:00:28.855981
2482	336	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 13:11:18.240404
2483	336	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 13:11:18.240404
2484	336	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 13:11:18.240404
2485	336	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 13:11:18.240404
2476	336	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 13:11:18.240404
2477	336	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 13:11:18.240404
2478	336	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 13:11:18.240404
2479	336	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 13:11:18.240404
2480	336	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 13:11:18.240404
2481	336	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 13:11:18.240404
2486	337	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 13:28:30.076924
2487	337	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 13:28:30.076924
2488	337	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 13:28:30.076924
2489	337	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 13:28:30.076924
2490	337	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 13:28:30.076924
2491	337	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 13:28:30.076924
2492	337	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 13:28:30.076924
2493	337	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 13:28:30.076924
2494	337	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 13:28:30.076924
2495	337	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 13:28:30.076924
2496	338	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 13:31:24.645954
2504	338	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 13:31:24.645954
2497	338	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 13:31:24.645954
2498	338	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 13:31:24.645954
2499	338	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 13:31:24.645954
2500	338	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 13:31:24.645954
2501	338	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 13:31:24.645954
2502	338	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 13:31:24.645954
2503	338	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 13:31:24.645954
2505	338	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 13:31:24.645954
2512	339	VAH	511500	16730	4192	5.875	0.118	6.03580695832318258800	2024-09-02 13:44:11.827694
2506	339	Conforming30DownH	400000	116530	3564	5.999	0.164	6.16672479543496817800	2024-09-02 13:44:11.827694
2507	339	Conforming30DownL	400000	123995	3437	5.500	2.051	5.64078603855353481300	2024-09-02 13:44:11.827694
2508	339	Conforming5DownH	475000	41840	4129	5.999	0.164	6.47348228494983786400	2024-09-02 13:44:11.827694
2509	339	Conforming5DownL	475000	50705	3978	5.500	2.051	5.94615040001084451200	2024-09-02 13:44:11.827694
2510	339	FHAH	490944	32877	4213	5.625	-0.132	6.35279807140798563200	2024-09-02 13:44:11.827694
2511	339	FHAL	490944	48011	3985	4.875	2.982	5.56194391439395997000	2024-09-02 13:44:11.827694
2513	339	VAL	511500	29626	3873	4.875	2.681	4.98541438868244369300	2024-09-02 13:44:11.827694
2514	339	USDAH	505000	15391	4219	5.625	-0.132	6.14137430150288260200	2024-09-02 13:44:11.827694
2515	339	USDAL	505000	30959	3985	4.875	2.982	5.35196187311548470100	2024-09-02 13:44:11.827694
2516	340	Conforming30DownH	189256	58468	2041	5.999	0.164	6.16672479543496817800	2024-09-02 13:46:18.063781
2517	340	Conforming30DownL	189256	62001	1981	5.500	2.051	5.64078603855353481300	2024-09-02 13:46:18.063781
2518	340	Conforming5DownH	224742	23166	2307	5.999	0.164	6.47348228494983786400	2024-09-02 13:46:18.063781
2519	340	Conforming5DownL	224742	27359	2236	5.500	2.051	5.94615040001084451200	2024-09-02 13:46:18.063781
2520	340	FHAH	232285	18931	2348	5.625	-0.132	6.35279807140798563200	2024-09-02 13:46:18.063781
2521	340	FHAL	232285	26093	2240	4.875	2.982	5.56194391439395997000	2024-09-02 13:46:18.063781
2522	340	VAH	242011	11302	2338	5.875	0.118	6.03580695832318258800	2024-09-02 13:46:18.063781
2523	340	VAL	242011	17404	2187	4.875	2.681	4.98541438868244369300	2024-09-02 13:46:18.063781
2524	340	USDAH	238936	10666	2350	5.625	-0.132	6.14137430150288260200	2024-09-02 13:46:18.063781
2525	340	USDAL	238936	18031	2239	4.875	2.982	5.35196187311548470100	2024-09-02 13:46:18.063781
2531	341	FHAL	98189	13187	731	4.875	2.982	5.56194391439395997000	2024-09-02 15:15:28.662322
2532	341	VAH	102300	6935	772	5.875	0.118	6.03580695832318258800	2024-09-02 15:15:28.662322
2533	341	VAL	102300	9515	708	4.875	2.681	4.98541438868244369300	2024-09-02 15:15:28.662322
2534	341	USDAH	101000	6667	777	5.625	-0.132	6.14137430150288260200	2024-09-02 15:15:28.662322
2535	341	USDAL	101000	9780	731	4.875	2.982	5.35196187311548470100	2024-09-02 15:15:28.662322
2526	341	Conforming30DownH	80000	26873	647	5.999	0.164	6.16672479543496817800	2024-09-02 15:15:28.662322
2527	341	Conforming30DownL	80000	28366	621	5.500	2.051	5.64078603855353481300	2024-09-02 15:15:28.662322
2528	341	Conforming5DownH	95000	11950	760	5.999	0.164	6.47348228494983786400	2024-09-02 15:15:28.662322
2529	341	Conforming5DownL	95000	13723	729	5.500	2.051	5.94615040001084451200	2024-09-02 15:15:28.662322
2530	341	FHAH	98189	10160	776	5.625	-0.132	6.35279807140798563200	2024-09-02 15:15:28.662322
2536	342	Conforming30DownH	80000	29072	1380	5.999	0.164	6.16672479543496817800	2024-09-02 15:25:24.347193
2537	342	Conforming30DownL	80000	30565	1354	5.500	2.051	5.64078603855353481300	2024-09-02 15:25:24.347193
2538	342	Conforming5DownH	95000	14149	1493	5.999	0.164	6.47348228494983786400	2024-09-02 15:25:24.347193
2539	342	Conforming5DownL	95000	15922	1462	5.500	2.051	5.94615040001084451200	2024-09-02 15:25:24.347193
2540	342	FHAH	98189	12359	1509	5.625	-0.132	6.35279807140798563200	2024-09-02 15:25:24.347193
2542	342	VAH	102300	9134	1505	5.875	0.118	6.03580695832318258800	2024-09-02 15:25:24.347193
2541	342	FHAL	98189	15386	1464	4.875	2.982	5.56194391439395997000	2024-09-02 15:25:24.347193
2543	342	VAL	102300	11714	1441	4.875	2.681	4.98541438868244369300	2024-09-02 15:25:24.347193
2544	342	USDAH	101000	8866	1510	5.625	-0.132	6.14137430150288260200	2024-09-02 15:25:24.347193
2545	342	USDAL	101000	11979	1464	4.875	2.982	5.35196187311548470100	2024-09-02 15:25:24.347193
2556	344	Conforming30DownH	220000	67568	2502	5.999	0.164	6.16672479543496817800	2024-09-02 15:27:34.789908
2557	344	Conforming30DownL	220000	71673	2432	5.500	2.051	5.64078603855353481300	2024-09-02 15:27:34.789908
2546	343	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 15:26:35.134672
2547	343	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 15:26:35.134672
2548	343	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 15:26:35.134672
2549	343	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 15:26:35.134672
2550	343	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 15:26:35.134672
2551	343	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 15:26:35.134672
2552	343	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 15:26:35.134672
2553	343	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 15:26:35.134672
2554	343	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 15:26:35.134672
2555	343	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 15:26:35.134672
2558	344	Conforming5DownH	261250	26529	2812	5.999	0.164	6.47348228494983786400	2024-09-02 15:27:34.789908
2559	344	Conforming5DownL	261250	31405	2729	5.500	2.051	5.94615040001084451200	2024-09-02 15:27:34.789908
2560	344	FHAH	270019	21609	2859	5.625	-0.132	6.35279807140798563200	2024-09-02 15:27:34.789908
2561	344	FHAL	270019	29932	2734	4.875	2.982	5.56194391439395997000	2024-09-02 15:27:34.789908
2562	344	VAH	281325	12739	2847	5.875	0.118	6.03580695832318258800	2024-09-02 15:27:34.789908
2563	344	VAL	281325	19831	2672	4.875	2.681	4.98541438868244369300	2024-09-02 15:27:34.789908
2564	344	USDAH	277750	11999	2862	5.625	-0.132	6.14137430150288260200	2024-09-02 15:27:34.789908
2565	344	USDAL	277750	20562	2733	4.875	2.982	5.35196187311548470100	2024-09-02 15:27:34.789908
2566	345	Conforming30DownH	240000	70746	1889	5.999	0.164	6.16672479543496817800	2024-09-02 15:28:17.030895
2567	345	Conforming30DownL	240000	75224	1813	5.500	2.051	5.64078603855353481300	2024-09-02 15:28:17.030895
2568	345	Conforming5DownH	285000	25976	2228	5.999	0.164	6.47348228494983786400	2024-09-02 15:28:17.030895
2569	345	Conforming5DownL	285000	31295	2137	5.500	2.051	5.94615040001084451200	2024-09-02 15:28:17.030895
2570	345	FHAH	294566	20608	2279	5.625	-0.132	6.35279807140798563200	2024-09-02 15:28:17.030895
2571	345	FHAL	294566	29689	2142	4.875	2.982	5.56194391439395997000	2024-09-02 15:28:17.030895
2572	345	VAH	306900	10932	2265	5.875	0.118	6.03580695832318258800	2024-09-02 15:28:17.030895
2573	345	VAL	306900	18670	2074	4.875	2.681	4.98541438868244369300	2024-09-02 15:28:17.030895
2574	345	USDAH	303000	10125	2282	5.625	-0.132	6.14137430150288260200	2024-09-02 15:28:17.030895
2575	345	USDAL	303000	19465	2142	4.875	2.982	5.35196187311548470100	2024-09-02 15:28:17.030895
2586	347	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-02 19:50:54.286237
2587	347	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-02 19:50:54.286237
2588	347	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-02 19:50:54.286237
2576	346	Conforming30DownH	240000	71745	2222	5.999	0.164	6.16672479543496817800	2024-09-02 15:48:16.025775
2577	346	Conforming30DownL	240000	76223	2146	5.500	2.051	5.64078603855353481300	2024-09-02 15:48:16.025775
2578	346	Conforming5DownH	285000	26975	2561	5.999	0.164	6.47348228494983786400	2024-09-02 15:48:16.025775
2579	346	Conforming5DownL	285000	32294	2470	5.500	2.051	5.94615040001084451200	2024-09-02 15:48:16.025775
2580	346	FHAH	294566	21607	2612	5.625	-0.132	6.35279807140798563200	2024-09-02 15:48:16.025775
2581	346	FHAL	294566	30688	2475	4.875	2.982	5.56194391439395997000	2024-09-02 15:48:16.025775
2582	346	VAH	306900	11931	2598	5.875	0.118	6.03580695832318258800	2024-09-02 15:48:16.025775
2583	346	VAL	306900	19669	2407	4.875	2.681	4.98541438868244369300	2024-09-02 15:48:16.025775
2584	346	USDAH	303000	11124	2615	5.625	-0.132	6.14137430150288260200	2024-09-02 15:48:16.025775
2585	346	USDAL	303000	20464	2475	4.875	2.982	5.35196187311548470100	2024-09-02 15:48:16.025775
2589	347	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-02 19:50:54.286237
2590	347	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 19:50:54.286237
2591	347	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-02 19:50:54.286237
2592	347	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-02 19:50:54.286237
2593	347	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-02 19:50:54.286237
2594	347	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 19:50:54.286237
2595	347	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-02 19:50:54.286237
2596	348	Conforming30DownH	400000	117031	3731	5.999	0.164	6.16672479543496817800	2024-09-02 20:26:00.685462
2597	348	Conforming30DownL	400000	124496	3604	5.500	2.051	5.64078603855353481300	2024-09-02 20:26:00.685462
2598	348	Conforming5DownH	475000	42341	4296	5.999	0.164	6.47348228494983786400	2024-09-02 20:26:00.685462
2599	348	Conforming5DownL	475000	51206	4145	5.500	2.051	5.94615040001084451200	2024-09-02 20:26:00.685462
2600	348	FHAH	490944	33378	4380	5.625	-0.132	6.35279807140798563200	2024-09-02 20:26:00.685462
2601	348	FHAL	490944	48512	4152	4.875	2.982	5.56194391439395997000	2024-09-02 20:26:00.685462
2602	348	VAH	511500	17231	4359	5.875	0.118	6.03580695832318258800	2024-09-02 20:26:00.685462
2603	348	VAL	511500	30127	4040	4.875	2.681	4.98541438868244369300	2024-09-02 20:26:00.685462
2604	348	USDAH	505000	15892	4386	5.625	-0.132	6.14137430150288260200	2024-09-02 20:26:00.685462
2605	348	USDAL	505000	31460	4152	4.875	2.982	5.35196187311548470100	2024-09-02 20:26:00.685462
2621	350	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 20:41:12.483262
2622	350	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 20:41:12.483262
2623	350	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 20:41:12.483262
2624	350	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 20:41:12.483262
2606	349	Conforming30DownH	160000	49038	1259	5.999	0.164	6.16672479543496817800	2024-09-02 20:39:45.690267
2607	349	Conforming30DownL	160000	52025	1208	5.500	2.051	5.64078603855353481300	2024-09-02 20:39:45.690267
2608	349	Conforming5DownH	190000	19163	1485	5.999	0.164	6.47348228494983786400	2024-09-02 20:39:45.690267
2609	349	Conforming5DownL	190000	22708	1425	5.500	2.051	5.94615040001084451200	2024-09-02 20:39:45.690267
2610	349	FHAH	196378	15577	1518	5.625	-0.132	6.35279807140798563200	2024-09-02 20:39:45.690267
2611	349	FHAL	196378	21631	1427	4.875	2.982	5.56194391439395997000	2024-09-02 20:39:45.690267
2612	349	VAH	204600	9118	1510	5.875	0.118	6.03580695832318258800	2024-09-02 20:39:45.690267
2613	349	VAL	204600	14277	1383	4.875	2.681	4.98541438868244369300	2024-09-02 20:39:45.690267
2614	349	USDAH	202000	8582	1521	5.625	-0.132	6.14137430150288260200	2024-09-02 20:39:45.690267
2615	349	USDAL	202000	14810	1427	4.875	2.982	5.35196187311548470100	2024-09-02 20:39:45.690267
2625	350	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 20:41:12.483262
2616	350	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 20:41:12.483262
2617	350	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 20:41:12.483262
2618	350	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 20:41:12.483262
2619	350	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 20:41:12.483262
2620	350	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 20:41:12.483262
2626	351	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-02 20:42:31.93108
2627	351	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-02 20:42:31.93108
2628	351	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-02 20:42:31.93108
2629	351	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-02 20:42:31.93108
2630	351	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-02 20:42:31.93108
2631	351	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-02 20:42:31.93108
2632	351	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-02 20:42:31.93108
2633	351	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-02 20:42:31.93108
2634	351	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-02 20:42:31.93108
2635	351	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-02 20:42:31.93108
2636	352	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 20:43:23.664986
2637	352	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 20:43:23.664986
2638	352	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 20:43:23.664986
2639	352	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 20:43:23.664986
2640	352	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 20:43:23.664986
2641	352	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 20:43:23.664986
2642	352	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 20:43:23.664986
2643	352	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 20:43:23.664986
2644	352	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 20:43:23.664986
2645	352	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 20:43:23.664986
2646	353	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 20:43:57.603224
2647	353	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 20:43:57.603224
2648	353	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 20:43:57.603224
2649	353	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 20:43:57.603224
2650	353	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 20:43:57.603224
2651	353	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 20:43:57.603224
2652	353	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 20:43:57.603224
2653	353	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 20:43:57.603224
2654	353	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 20:43:57.603224
2655	353	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 20:43:57.603224
2656	354	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 20:44:34.737105
2657	354	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 20:44:34.737105
2658	354	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 20:44:34.737105
2659	354	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 20:44:34.737105
2660	354	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 20:44:34.737105
2661	354	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 20:44:34.737105
2662	354	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 20:44:34.737105
2663	354	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 20:44:34.737105
2664	354	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 20:44:34.737105
2665	354	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 20:44:34.737105
2666	355	Conforming30DownH	160000	53538	2759	5.999	0.164	6.16672479543496817800	2024-09-02 20:45:03.377566
2667	355	Conforming30DownL	160000	56525	2708	5.500	2.051	5.64078603855353481300	2024-09-02 20:45:03.377566
2668	355	Conforming5DownH	190000	23663	2985	5.999	0.164	6.47348228494983786400	2024-09-02 20:45:03.377566
2669	355	Conforming5DownL	190000	27208	2925	5.500	2.051	5.94615040001084451200	2024-09-02 20:45:03.377566
2670	355	FHAH	196378	20077	3018	5.625	-0.132	6.35279807140798563200	2024-09-02 20:45:03.377566
2671	355	FHAL	196378	26131	2927	4.875	2.982	5.56194391439395997000	2024-09-02 20:45:03.377566
2672	355	VAH	204600	13618	3010	5.875	0.118	6.03580695832318258800	2024-09-02 20:45:03.377566
2673	355	VAL	204600	18777	2883	4.875	2.681	4.98541438868244369300	2024-09-02 20:45:03.377566
2674	355	USDAH	202000	13082	3021	5.625	-0.132	6.14137430150288260200	2024-09-02 20:45:03.377566
2675	355	USDAL	202000	19310	2927	4.875	2.982	5.35196187311548470100	2024-09-02 20:45:03.377566
2676	356	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-02 20:46:32.703567
2677	356	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-02 20:46:32.703567
2678	356	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-02 20:46:32.703567
2679	356	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-02 20:46:32.703567
2680	356	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-02 20:46:32.703567
2681	356	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-02 20:46:32.703567
2682	356	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-02 20:46:32.703567
2683	356	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-02 20:46:32.703567
2684	356	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-02 20:46:32.703567
2685	356	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-02 20:46:32.703567
2686	357	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-03 06:17:44.819706
2687	357	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-03 06:17:44.819706
2688	357	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-03 06:17:44.819706
2689	357	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-03 06:17:44.819706
2690	357	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 06:17:44.819706
2691	357	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-03 06:17:44.819706
2692	357	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-03 06:17:44.819706
2693	357	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-03 06:17:44.819706
2694	357	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 06:17:44.819706
2695	357	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-03 06:17:44.819706
2696	358	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-03 06:22:08.7098
2697	358	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-03 06:22:08.7098
2698	358	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-03 06:22:08.7098
2699	358	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-03 06:22:08.7098
2700	358	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 06:22:08.7098
2701	358	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-03 06:22:08.7098
2702	358	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-03 06:22:08.7098
2703	358	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-03 06:22:08.7098
2704	358	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 06:22:08.7098
2705	358	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-03 06:22:08.7098
2716	360	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-03 07:52:07.354786
2706	359	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-03 07:50:52.7513
2707	359	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-03 07:50:52.7513
2708	359	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-03 07:50:52.7513
2709	359	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-03 07:50:52.7513
2710	359	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 07:50:52.7513
2711	359	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-03 07:50:52.7513
2712	359	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-03 07:50:52.7513
2713	359	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-03 07:50:52.7513
2714	359	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 07:50:52.7513
2715	359	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-03 07:50:52.7513
2717	360	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-03 07:52:07.354786
2718	360	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-03 07:52:07.354786
2719	360	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-03 07:52:07.354786
2720	360	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 07:52:07.354786
2721	360	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-03 07:52:07.354786
2722	360	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-03 07:52:07.354786
2723	360	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-03 07:52:07.354786
2724	360	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 07:52:07.354786
2725	360	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-03 07:52:07.354786
2726	361	Conforming30DownH	160000	48533	1175	5.999	0.164	6.16672479543496817800	2024-09-03 07:53:18.860041
2727	361	Conforming30DownL	160000	51520	1124	5.500	2.051	5.64078603855353481300	2024-09-03 07:53:18.860041
2728	361	Conforming5DownH	190000	18688	1401	5.999	0.164	6.47348228494983786400	2024-09-03 07:53:18.860041
2729	361	Conforming5DownL	190000	22233	1341	5.500	2.051	5.94615040001084451200	2024-09-03 07:53:18.860041
2730	361	FHAH	196378	15108	1434	5.625	-0.132	6.35279807140798563200	2024-09-03 07:53:18.860041
2731	361	FHAL	196378	21162	1343	4.875	2.982	5.56194391439395997000	2024-09-03 07:53:18.860041
2732	361	VAH	204600	8658	1426	5.875	0.118	6.03580695832318258800	2024-09-03 07:53:18.860041
2733	361	VAL	204600	13817	1299	4.875	2.681	4.98541438868244369300	2024-09-03 07:53:18.860041
2734	361	USDAH	202000	8119	1437	5.625	-0.132	6.14137430150288260200	2024-09-03 07:53:18.860041
2735	361	USDAL	202000	14347	1343	4.875	2.982	5.35196187311548470100	2024-09-03 07:53:18.860041
2746	363	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-03 08:07:44.370506
2747	363	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-03 08:07:44.370506
2736	362	Conforming30DownH	240000	72996	2639	5.999	0.164	6.16672479543496817800	2024-09-03 07:56:41.009842
2737	362	Conforming30DownL	240000	77474	2563	5.500	2.051	5.64078603855353481300	2024-09-03 07:56:41.009842
2738	362	Conforming5DownH	285000	28226	2978	5.999	0.164	6.47348228494983786400	2024-09-03 07:56:41.009842
2739	362	Conforming5DownL	285000	33545	2887	5.500	2.051	5.94615040001084451200	2024-09-03 07:56:41.009842
2740	362	FHAH	294566	22858	3029	5.625	-0.132	6.35279807140798563200	2024-09-03 07:56:41.009842
2741	362	FHAL	294566	31939	2892	4.875	2.982	5.56194391439395997000	2024-09-03 07:56:41.009842
2742	362	VAH	306900	13182	3015	5.875	0.118	6.03580695832318258800	2024-09-03 07:56:41.009842
2743	362	VAL	306900	20920	2824	4.875	2.681	4.98541438868244369300	2024-09-03 07:56:41.009842
2744	362	USDAH	303000	12375	3032	5.625	-0.132	6.14137430150288260200	2024-09-03 07:56:41.009842
2745	362	USDAL	303000	21715	2892	4.875	2.982	5.35196187311548470100	2024-09-03 07:56:41.009842
2748	363	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-03 08:07:44.370506
2749	363	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-03 08:07:44.370506
2750	363	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-03 08:07:44.370506
2751	363	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-03 08:07:44.370506
2752	363	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-03 08:07:44.370506
2753	363	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-03 08:07:44.370506
2754	363	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-03 08:07:44.370506
2755	363	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-03 08:07:44.370506
2757	364	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-03 08:10:31.16274
2758	364	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-03 08:10:31.16274
2759	364	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-03 08:10:31.16274
2760	364	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 08:10:31.16274
2761	364	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-03 08:10:31.16274
2762	364	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-03 08:10:31.16274
2763	364	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-03 08:10:31.16274
2764	364	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 08:10:31.16274
2765	364	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-03 08:10:31.16274
2756	364	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-03 08:10:31.16274
2776	366	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-03 08:16:33.332418
2777	366	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-03 08:16:33.332418
2778	366	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-03 08:16:33.332418
2779	366	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-03 08:16:33.332418
2770	365	FHAH	294566	23176	3029	5.625	-0.132	6.35279807140798563200	2024-09-03 08:12:20.693759
2771	365	FHAL	294566	32257	2892	4.875	2.982	5.56194391439395997000	2024-09-03 08:12:20.693759
2766	365	Conforming30DownH	240000	73369	2639	5.999	0.164	6.16672479543496817800	2024-09-03 08:12:20.693759
2767	365	Conforming30DownL	240000	77847	2563	5.500	2.051	5.64078603855353481300	2024-09-03 08:12:20.693759
2768	365	Conforming5DownH	285000	28554	2978	5.999	0.164	6.47348228494983786400	2024-09-03 08:12:20.693759
2769	365	Conforming5DownL	285000	33873	2887	5.500	2.051	5.94615040001084451200	2024-09-03 08:12:20.693759
2772	365	VAH	306900	13488	3015	5.875	0.118	6.03580695832318258800	2024-09-03 08:12:20.693759
2773	365	VAL	306900	21226	2824	4.875	2.681	4.98541438868244369300	2024-09-03 08:12:20.693759
2774	365	USDAH	303000	12685	3032	5.625	-0.132	6.14137430150288260200	2024-09-03 08:12:20.693759
2775	365	USDAL	303000	22025	2892	4.875	2.982	5.35196187311548470100	2024-09-03 08:12:20.693759
2780	366	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 08:16:33.332418
2781	366	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-03 08:16:33.332418
2782	366	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-03 08:16:33.332418
2783	366	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-03 08:16:33.332418
2784	366	USDAH	202000	11081	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 08:16:33.332418
2785	366	USDAL	202000	17309	2260	4.875	2.982	5.35196187311548470100	2024-09-03 08:16:33.332418
2795	367	USDAL	277750	20847	2733	4.875	2.982	5.35196187311548470100	2024-09-03 08:52:03.111497
2786	367	Conforming30DownH	220000	67911	2502	5.999	0.164	6.16672479543496817800	2024-09-03 08:52:03.111497
2787	367	Conforming30DownL	220000	72016	2432	5.500	2.051	5.64078603855353481300	2024-09-03 08:52:03.111497
2788	367	Conforming5DownH	261250	26831	2812	5.999	0.164	6.47348228494983786400	2024-09-03 08:52:03.111497
2789	367	Conforming5DownL	261250	31707	2729	5.500	2.051	5.94615040001084451200	2024-09-03 08:52:03.111497
2790	367	FHAH	270019	21902	2859	5.625	-0.132	6.35279807140798563200	2024-09-03 08:52:03.111497
2791	367	FHAL	270019	30225	2734	4.875	2.982	5.56194391439395997000	2024-09-03 08:52:03.111497
2792	367	VAH	281325	13021	2847	5.875	0.118	6.03580695832318258800	2024-09-03 08:52:03.111497
2793	367	VAL	281325	20113	2672	4.875	2.681	4.98541438868244369300	2024-09-03 08:52:03.111497
2794	367	USDAH	277750	12284	2862	5.625	-0.132	6.14137430150288260200	2024-09-03 08:52:03.111497
2811	369	FHAL	294566	31507	2642	4.875	2.982	5.56194391439395997000	2024-09-03 08:55:36.584666
2812	369	VAH	306900	12738	2765	5.875	0.118	6.03580695832318258800	2024-09-03 08:55:36.584666
2813	369	VAL	306900	20476	2574	4.875	2.681	4.98541438868244369300	2024-09-03 08:55:36.584666
2806	369	Conforming30DownH	240000	72619	2389	5.999	0.164	6.16672479543496817800	2024-09-03 08:55:36.584666
2796	368	Conforming30DownH	176000	55904	2202	5.999	0.164	6.16672479543496817800	2024-09-03 08:53:04.874035
2797	368	Conforming30DownL	176000	59188	2146	5.500	2.051	5.64078603855353481300	2024-09-03 08:53:04.874035
2798	368	Conforming5DownH	209000	23040	2451	5.999	0.164	6.47348228494983786400	2024-09-03 08:53:04.874035
2799	368	Conforming5DownL	209000	26941	2385	5.500	2.051	5.94615040001084451200	2024-09-03 08:53:04.874035
2800	368	FHAH	216015	19096	2488	5.625	-0.132	6.35279807140798563200	2024-09-03 08:53:04.874035
2801	368	FHAL	216015	25756	2387	4.875	2.982	5.56194391439395997000	2024-09-03 08:53:04.874035
2802	368	VAH	225060	11992	2478	5.875	0.118	6.03580695832318258800	2024-09-03 08:53:04.874035
2803	368	VAL	225060	17666	2338	4.875	2.681	4.98541438868244369300	2024-09-03 08:53:04.874035
2804	368	USDAH	222200	11403	2490	5.625	-0.132	6.14137430150288260200	2024-09-03 08:53:04.874035
2805	368	USDAL	222200	18252	2387	4.875	2.982	5.35196187311548470100	2024-09-03 08:53:04.874035
2807	369	Conforming30DownL	240000	77097	2313	5.500	2.051	5.64078603855353481300	2024-09-03 08:55:36.584666
2808	369	Conforming5DownH	285000	27804	2728	5.999	0.164	6.47348228494983786400	2024-09-03 08:55:36.584666
2809	369	Conforming5DownL	285000	33123	2637	5.500	2.051	5.94615040001084451200	2024-09-03 08:55:36.584666
2810	369	FHAH	294566	22426	2779	5.625	-0.132	6.35279807140798563200	2024-09-03 08:55:36.584666
2814	369	USDAH	303000	11935	2782	5.625	-0.132	6.14137430150288260200	2024-09-03 08:55:36.584666
2815	369	USDAL	303000	21275	2642	4.875	2.982	5.35196187311548470100	2024-09-03 08:55:36.584666
2816	370	Conforming30DownH	176000	55904	2202	5.999	0.164	6.16672479543496817800	2024-09-03 09:12:48.064464
2817	370	Conforming30DownL	176000	59188	2146	5.500	2.051	5.64078603855353481300	2024-09-03 09:12:48.064464
2818	370	Conforming5DownH	209000	23040	2451	5.999	0.164	6.47348228494983786400	2024-09-03 09:12:48.064464
2819	370	Conforming5DownL	209000	26941	2385	5.500	2.051	5.94615040001084451200	2024-09-03 09:12:48.064464
2820	370	FHAH	216015	19096	2488	5.625	-0.132	6.35279807140798563200	2024-09-03 09:12:48.064464
2821	370	FHAL	216015	25756	2387	4.875	2.982	5.56194391439395997000	2024-09-03 09:12:48.064464
2822	370	VAH	225060	11992	2478	5.875	0.118	6.03580695832318258800	2024-09-03 09:12:48.064464
2823	370	VAL	225060	17666	2338	4.875	2.681	4.98541438868244369300	2024-09-03 09:12:48.064464
2824	370	USDAH	222200	11403	2490	5.625	-0.132	6.14137430150288260200	2024-09-03 09:12:48.064464
2825	370	USDAL	222200	18252	2387	4.875	2.982	5.35196187311548470100	2024-09-03 09:12:48.064464
2826	371	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-03 09:23:08.836432
2827	371	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-03 09:23:08.836432
2828	371	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-03 09:23:08.836432
2829	371	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-03 09:23:08.836432
2830	371	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-03 09:23:08.836432
2831	371	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-03 09:23:08.836432
2832	371	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-03 09:23:08.836432
2833	371	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-03 09:23:08.836432
2834	371	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-03 09:23:08.836432
2835	371	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-03 09:23:08.836432
2837	374	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 04:13:57.818495
2838	374	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 04:13:57.818495
2839	374	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 04:13:57.818495
2840	374	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 04:13:57.818495
2841	374	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 04:13:57.818495
2842	374	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 04:13:57.818495
2843	374	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 04:13:57.818495
2844	374	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 04:13:57.818495
2845	374	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 04:13:57.818495
2846	374	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 04:13:57.818495
2855	377	Conforming30DownH	160000	54284	3092	5.999	0.164	6.16672479543496817800	2024-09-04 04:19:35.509136
2856	377	Conforming30DownL	160000	57271	3041	5.500	2.051	5.64078603855353481300	2024-09-04 04:19:35.509136
2857	377	Conforming5DownH	190000	24439	3318	5.999	0.164	6.47348228494983786400	2024-09-04 04:19:35.509136
2858	377	Conforming5DownL	190000	27984	3258	5.500	2.051	5.94615040001084451200	2024-09-04 04:19:35.509136
2859	377	FHAH	196378	20859	3351	5.625	-0.132	6.35279807140798563200	2024-09-04 04:19:35.509136
2860	377	FHAL	196378	26913	3260	4.875	2.982	5.56194391439395997000	2024-09-04 04:19:35.509136
2861	377	VAH	204600	14409	3343	5.875	0.118	6.03580695832318258800	2024-09-04 04:19:35.509136
2862	377	VAL	204600	19568	3216	4.875	2.681	4.98541438868244369300	2024-09-04 04:19:35.509136
2863	377	USDAH	202000	13870	3354	5.625	-0.132	6.14137430150288260200	2024-09-04 04:19:35.509136
2864	377	USDAL	202000	20098	3260	4.875	2.982	5.35196187311548470100	2024-09-04 04:19:35.509136
2865	383	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 04:34:19.542744
2866	383	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 04:34:19.542744
2867	383	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 04:34:19.542744
2868	383	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 04:34:19.542744
2869	383	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 04:34:19.542744
2870	383	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 04:34:19.542744
2871	383	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 04:34:19.542744
2872	383	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 04:34:19.542744
2873	383	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 04:34:19.542744
2874	383	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 04:34:19.542744
2875	388	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 07:45:53.679225
2876	388	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 07:45:53.679225
2887	390	Conforming30DownH	160000	51537	2092	5.999	0.164	6.16672479543496817800	2024-09-04 07:50:35.767317
2888	390	Conforming30DownL	160000	54524	2041	5.500	2.051	5.64078603855353481300	2024-09-04 07:50:35.767317
2889	390	Conforming5DownH	190000	21662	2318	5.999	0.164	6.47348228494983786400	2024-09-04 07:50:35.767317
2890	390	Conforming5DownL	190000	25207	2258	5.500	2.051	5.94615040001084451200	2024-09-04 07:50:35.767317
2891	390	FHAH	196378	18076	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 07:50:35.767317
2892	390	FHAL	196378	24130	2260	4.875	2.982	5.56194391439395997000	2024-09-04 07:50:35.767317
2893	390	VAH	204600	11617	2343	5.875	0.118	6.03580695832318258800	2024-09-04 07:50:35.767317
2894	390	VAL	204600	16776	2216	4.875	2.681	4.98541438868244369300	2024-09-04 07:50:35.767317
2877	389	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 07:45:53.743066
2878	389	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 07:45:53.743066
2879	389	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 07:45:53.743066
2880	389	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 07:45:53.743066
2881	389	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 07:45:53.743066
2882	389	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 07:45:53.743066
2883	389	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 07:45:53.743066
2884	389	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 07:45:53.743066
2885	389	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 07:45:53.743066
2886	389	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 07:45:53.743066
2895	391	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 07:51:36.524329
2896	391	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 07:51:36.524329
2897	391	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 07:51:36.524329
2898	391	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 07:51:36.524329
2899	391	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 07:51:36.524329
2900	391	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 07:51:36.524329
2901	391	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 07:51:36.524329
2902	391	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 07:51:36.524329
2903	391	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 07:51:36.524329
2904	391	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 07:51:36.524329
2913	393	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 07:59:44.673343
2914	393	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 07:59:44.673343
2915	393	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 07:59:44.673343
2916	393	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 07:59:44.673343
2905	392	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 07:59:31.34383
2906	392	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 07:59:31.34383
2907	392	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 07:59:31.34383
2908	392	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 07:59:31.34383
2909	392	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 07:59:31.34383
2910	392	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 07:59:31.34383
2911	392	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 07:59:31.34383
2912	392	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 07:59:31.34383
2917	393	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 07:59:44.673343
2918	393	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 07:59:44.673343
2919	393	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 07:59:44.673343
2920	393	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 07:59:44.673343
2921	393	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 07:59:44.673343
2922	393	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 07:59:44.673343
2923	394	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:04:22.96547
2924	394	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:04:22.96547
2925	394	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:04:22.96547
2926	394	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:04:22.96547
2927	394	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:04:22.96547
2928	394	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:04:22.96547
2929	394	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:04:22.96547
2930	394	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:04:22.96547
2931	394	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:04:22.96547
2932	394	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:04:22.96547
2943	396	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:05:38.464918
2944	396	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:05:38.464918
2945	396	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:05:38.464918
2946	396	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:05:38.464918
2933	395	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:05:13.576399
2934	395	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:05:13.576399
2935	395	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:05:13.576399
2936	395	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:05:13.576399
2937	395	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:05:13.576399
2938	395	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:05:13.576399
2939	395	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:05:13.576399
2940	395	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:05:13.576399
2941	395	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:05:13.576399
2942	395	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:05:13.576399
2947	396	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:05:38.464918
2948	396	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:05:38.464918
2949	396	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:05:38.464918
2950	396	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:05:38.464918
2951	396	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:05:38.464918
2952	396	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:05:38.464918
2959	397	VAH	204600	10908	2176	5.875	0.118	6.03580695832318258800	2024-09-04 08:08:26.417643
2960	397	VAL	204600	16067	2049	4.875	2.681	4.98541438868244369300	2024-09-04 08:08:26.417643
2961	397	USDAH	202000	10369	2187	5.625	-0.132	6.14137430150288260200	2024-09-04 08:08:26.417643
2962	397	USDAL	202000	16597	2093	4.875	2.982	5.35196187311548470100	2024-09-04 08:08:26.417643
2953	397	Conforming30DownH	160000	50783	1925	5.999	0.164	6.16672479543496817800	2024-09-04 08:08:26.417643
2954	397	Conforming30DownL	160000	53770	1874	5.500	2.051	5.64078603855353481300	2024-09-04 08:08:26.417643
2955	397	Conforming5DownH	190000	20938	2151	5.999	0.164	6.47348228494983786400	2024-09-04 08:08:26.417643
2956	397	Conforming5DownL	190000	24483	2091	5.500	2.051	5.94615040001084451200	2024-09-04 08:08:26.417643
2957	397	FHAH	196378	17358	2184	5.625	-0.132	6.35279807140798563200	2024-09-04 08:08:26.417643
2958	397	FHAL	196378	23412	2093	4.875	2.982	5.56194391439395997000	2024-09-04 08:08:26.417643
2963	398	Conforming30DownH	160000	51533	2175	5.999	0.164	6.16672479543496817800	2024-09-04 08:12:38.1523
2964	398	Conforming30DownL	160000	54520	2124	5.500	2.051	5.64078603855353481300	2024-09-04 08:12:38.1523
2965	398	Conforming5DownH	190000	21688	2401	5.999	0.164	6.47348228494983786400	2024-09-04 08:12:38.1523
2966	398	Conforming5DownL	190000	25233	2341	5.500	2.051	5.94615040001084451200	2024-09-04 08:12:38.1523
2967	398	FHAH	196378	18108	2434	5.625	-0.132	6.35279807140798563200	2024-09-04 08:12:38.1523
2968	398	FHAL	196378	24162	2343	4.875	2.982	5.56194391439395997000	2024-09-04 08:12:38.1523
2969	398	VAH	204600	11658	2426	5.875	0.118	6.03580695832318258800	2024-09-04 08:12:38.1523
2970	398	VAL	204600	16817	2299	4.875	2.681	4.98541438868244369300	2024-09-04 08:12:38.1523
2971	398	USDAH	202000	11119	2437	5.625	-0.132	6.14137430150288260200	2024-09-04 08:12:38.1523
2972	398	USDAL	202000	17347	2343	4.875	2.982	5.35196187311548470100	2024-09-04 08:12:38.1523
2973	399	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:24:40.795098
2974	399	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:24:40.795098
2975	399	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:24:40.795098
2976	399	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:24:40.795098
2977	399	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:24:40.795098
2978	399	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:24:40.795098
2979	399	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:24:40.795098
2980	399	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:24:40.795098
2998	401	VAL	204600	16067	2049	4.875	2.681	4.98541438868244369300	2024-09-04 08:27:57.842344
2991	401	Conforming30DownH	160000	50783	1925	5.999	0.164	6.16672479543496817800	2024-09-04 08:27:57.842344
2992	401	Conforming30DownL	160000	53770	1874	5.500	2.051	5.64078603855353481300	2024-09-04 08:27:57.842344
2993	401	Conforming5DownH	190000	20938	2151	5.999	0.164	6.47348228494983786400	2024-09-04 08:27:57.842344
2994	401	Conforming5DownL	190000	24483	2091	5.500	2.051	5.94615040001084451200	2024-09-04 08:27:57.842344
2995	401	FHAH	196378	17358	2184	5.625	-0.132	6.35279807140798563200	2024-09-04 08:27:57.842344
2996	401	FHAL	196378	23412	2093	4.875	2.982	5.56194391439395997000	2024-09-04 08:27:57.842344
2997	401	VAH	204600	10908	2176	5.875	0.118	6.03580695832318258800	2024-09-04 08:27:57.842344
2981	400	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:24:56.653104
2982	400	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:24:56.653104
2983	400	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:24:56.653104
2984	400	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:24:56.653104
2985	400	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:24:56.653104
2986	400	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:24:56.653104
2987	400	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:24:56.653104
2988	400	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:24:56.653104
2989	400	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:24:56.653104
2990	400	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:24:56.653104
2999	402	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:28:15.417468
3000	402	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:28:15.417468
3001	402	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:28:15.417468
3002	402	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:28:15.417468
3003	402	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:28:15.417468
3004	402	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:28:15.417468
3005	402	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:28:15.417468
3006	402	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:28:15.417468
3007	402	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:28:15.417468
3008	402	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:28:15.417468
3009	403	Conforming30DownH	160000	51533	2175	5.999	0.164	6.16672479543496817800	2024-09-04 08:46:50.604011
3010	403	Conforming30DownL	160000	54520	2124	5.500	2.051	5.64078603855353481300	2024-09-04 08:46:50.604011
3011	403	Conforming5DownH	190000	21688	2401	5.999	0.164	6.47348228494983786400	2024-09-04 08:46:50.604011
3012	403	Conforming5DownL	190000	25233	2341	5.500	2.051	5.94615040001084451200	2024-09-04 08:46:50.604011
3013	403	FHAH	196378	18108	2434	5.625	-0.132	6.35279807140798563200	2024-09-04 08:46:50.604011
3014	403	FHAL	196378	24162	2343	4.875	2.982	5.56194391439395997000	2024-09-04 08:46:50.604011
3015	403	VAH	204600	11658	2426	5.875	0.118	6.03580695832318258800	2024-09-04 08:46:50.604011
3016	403	VAL	204600	16817	2299	4.875	2.681	4.98541438868244369300	2024-09-04 08:46:50.604011
3017	403	USDAH	202000	11119	2437	5.625	-0.132	6.14137430150288260200	2024-09-04 08:46:50.604011
3018	403	USDAL	202000	17347	2343	4.875	2.982	5.35196187311548470100	2024-09-04 08:46:50.604011
3019	404	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:51:09.68815
3020	404	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:51:09.68815
3021	404	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:51:09.68815
3022	404	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:51:09.68815
3023	404	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:51:09.68815
3024	404	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:51:09.68815
3025	404	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:51:09.68815
3026	404	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:51:09.68815
3027	404	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:51:09.68815
3028	404	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:51:09.68815
3029	405	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:57:32.88519
3030	405	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:57:32.88519
3031	405	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:57:32.88519
3032	405	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:57:32.88519
3033	405	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:57:32.88519
3034	405	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:57:32.88519
3035	405	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:57:32.88519
3036	405	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:57:32.88519
3037	405	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:57:32.88519
3038	405	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:57:32.88519
3049	407	Conforming30DownH	1600000	442085	11925	5.999	0.164	6.16672479543496817800	2024-09-04 08:59:20.87487
3050	407	Conforming30DownL	1600000	471945	11418	5.500	2.051	5.64078603855353481300	2024-09-04 08:59:20.87487
3051	407	Conforming5DownH	1900000	143627	14182	5.999	0.164	6.47348228494983786400	2024-09-04 08:59:20.87487
3052	407	Conforming5DownL	1900000	179085	13580	5.500	2.051	5.94615040001084451200	2024-09-04 08:59:20.87487
3053	407	FHAH	1963775	107837	14523	5.625	-0.132	6.35279807140798563200	2024-09-04 08:59:20.87487
3054	407	FHAL	1963775	168375	13610	4.875	2.982	5.56194391439395997000	2024-09-04 08:59:20.87487
3055	407	VAH	2046000	43330	14436	5.875	0.118	6.03580695832318258800	2024-09-04 08:59:20.87487
3056	407	VAL	2046000	94917	13161	4.875	2.681	4.98541438868244369300	2024-09-04 08:59:20.87487
3039	406	Conforming30DownH	160000	51284	2092	5.999	0.164	6.16672479543496817800	2024-09-04 08:59:08.149114
3040	406	Conforming30DownL	160000	54271	2041	5.500	2.051	5.64078603855353481300	2024-09-04 08:59:08.149114
3041	406	Conforming5DownH	190000	21439	2318	5.999	0.164	6.47348228494983786400	2024-09-04 08:59:08.149114
3042	406	Conforming5DownL	190000	24984	2258	5.500	2.051	5.94615040001084451200	2024-09-04 08:59:08.149114
3043	406	FHAH	196378	17859	2351	5.625	-0.132	6.35279807140798563200	2024-09-04 08:59:08.149114
3044	406	FHAL	196378	23913	2260	4.875	2.982	5.56194391439395997000	2024-09-04 08:59:08.149114
3045	406	VAH	204600	11409	2343	5.875	0.118	6.03580695832318258800	2024-09-04 08:59:08.149114
3046	406	VAL	204600	16568	2216	4.875	2.681	4.98541438868244369300	2024-09-04 08:59:08.149114
3047	406	USDAH	202000	10870	2354	5.625	-0.132	6.14137430150288260200	2024-09-04 08:59:08.149114
3048	406	USDAL	202000	17098	2260	4.875	2.982	5.35196187311548470100	2024-09-04 08:59:08.149114
3064	408	VAL	511500	30127	4040	4.875	2.681	4.98541438868244369300	2024-09-04 09:07:47.657004
3065	408	USDAH	505000	15892	4386	5.625	-0.132	6.14137430150288260200	2024-09-04 09:07:47.657004
3066	408	USDAL	505000	31460	4152	4.875	2.982	5.35196187311548470100	2024-09-04 09:07:47.657004
3057	408	Conforming30DownH	400000	117031	3731	5.999	0.164	6.16672479543496817800	2024-09-04 09:07:47.657004
3058	408	Conforming30DownL	400000	124496	3604	5.500	2.051	5.64078603855353481300	2024-09-04 09:07:47.657004
3061	408	FHAH	490944	33378	4380	5.625	-0.132	6.35279807140798563200	2024-09-04 09:07:47.657004
3059	408	Conforming5DownH	475000	42341	4296	5.999	0.164	6.47348228494983786400	2024-09-04 09:07:47.657004
3060	408	Conforming5DownL	475000	51206	4145	5.500	2.051	5.94615040001084451200	2024-09-04 09:07:47.657004
3062	408	FHAL	490944	48512	4152	4.875	2.982	5.56194391439395997000	2024-09-04 09:07:47.657004
3063	408	VAH	511500	17231	4359	5.875	0.118	6.03580695832318258800	2024-09-04 09:07:47.657004
3067	409	Conforming30DownH	400000	115242	3339	5.999	0.164	6.16672479543496817800	2024-09-04 09:56:39.209555
3068	409	Conforming30DownL	400000	122707	3212	5.500	2.051	5.64078603855353481300	2024-09-04 09:56:39.209555
3069	409	Conforming5DownH	475000	40627	3904	5.999	0.164	6.47348228494983786400	2024-09-04 09:56:39.209555
3070	409	Conforming5DownL	475000	49492	3753	5.500	2.051	5.94615040001084451200	2024-09-04 09:56:39.209555
3071	409	FHAH	490944	31680	3988	5.625	-0.132	6.35279807140798563200	2024-09-04 09:56:39.209555
3073	409	VAH	511500	15554	3967	5.875	0.118	6.03580695832318258800	2024-09-04 09:56:39.209555
3074	409	VAL	511500	28450	3648	4.875	2.681	4.98541438868244369300	2024-09-04 09:56:39.209555
3075	409	USDAH	505000	14208	3994	5.625	-0.132	6.14137430150288260200	2024-09-04 09:56:39.209555
3076	409	USDAL	505000	29776	3760	4.875	2.982	5.35196187311548470100	2024-09-04 09:56:39.209555
3077	410	Conforming30DownH	352000	103002	3093	5.999	0.164	6.16672479543496817800	2024-09-04 10:49:56.828558
3078	410	Conforming30DownL	352000	109572	2982	5.500	2.051	5.64078603855353481300	2024-09-04 10:49:56.828558
3079	410	Conforming5DownH	418000	37276	3590	5.999	0.164	6.47348228494983786400	2024-09-04 10:49:56.828558
3080	410	Conforming5DownL	418000	45076	3457	5.500	2.051	5.94615040001084451200	2024-09-04 10:49:56.828558
3081	410	FHAH	432031	29388	3665	5.625	-0.132	6.35279807140798563200	2024-09-04 10:49:56.828558
3082	410	FHAL	432031	42706	3464	4.875	2.982	5.56194391439395997000	2024-09-04 10:49:56.828558
3083	410	VAH	450120	15178	3646	5.875	0.118	6.03580695832318258800	2024-09-04 10:49:56.828558
3084	410	VAL	450120	26527	3365	4.875	2.681	4.98541438868244369300	2024-09-04 10:49:56.828558
3085	410	USDAH	444400	14000	3669	5.625	-0.132	6.14137430150288260200	2024-09-04 10:49:56.828558
3086	410	USDAL	444400	27700	3463	4.875	2.982	5.35196187311548470100	2024-09-04 10:49:56.828558
3072	409	FHAL	490944	46814	3760	4.875	2.982	5.56194391439395997000	2024-09-04 09:56:39.209555
3087	411	Conforming30DownH	352000	102900	3065	5.875	0.140	6.03580695832318258800	2024-09-05 13:58:31.797098
3088	411	Conforming30DownL	352000	107227	2982	5.500	1.385	5.64078603855353481300	2024-09-05 13:58:31.797098
3089	411	Conforming5DownH	418000	37153	3557	5.875	0.140	6.34221772126073691200	2024-09-05 13:58:31.797098
3090	411	Conforming5DownL	418000	42292	3457	5.500	1.385	5.94615040001084451200	2024-09-05 13:58:31.797098
3091	411	FHAH	432031	30305	3734	5.875	0.070	6.61762064005667960700	2024-09-05 13:58:31.797098
3092	411	FHAL	432031	40231	3464	4.875	2.409	5.56194391439395997000	2024-09-05 13:58:31.797098
3093	411	VAH	450120	14473	3539	5.500	-0.023	5.64078603855353481300	2024-09-05 13:58:31.797098
3094	411	VAL	450120	27197	3331	4.750	2.835	4.85478814458860950600	2024-09-05 13:58:31.797098
\.


--
-- Data for Name: loan_scenarios; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.loan_scenarios (scenario_id, record_id, scenario_number, purchase_price, base_loan_amount, total_loan_amount, down_payment, principal_and_interest, property_taxes, home_insurance, private_mortgage_insurance, total_payment, interest_rate, discount_points_percent, lender_charges, loan_borrower_discount_points, appraisal, appraiser_reinspection, credit_reports, title_services, title_insurance, recording_fees, ok_mortgage_tax, survey, pest_home_inspections, up_front_mi_funding_fee, prepaid_interest, homeowners_insurance_year_1, property_tax_escrow, home_insurance_escrow, financed_mi_premium_funding_fee, earnest_money, annual_pmi_percent, loan_term, loan_program_code, state, home_insurance_mo_pmt) FROM stdin;
2086	297	1	300000	240000	240000	0.2000	1497	917	0.0080	0	2614	6.375	-0.097	1100	-233	625	200	85	1600	1540	200	\N	500	525	0	637	2400	2751	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2126	301	1	200000	160000	160000	0.2000	959	500	0.0080	0	1592	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	1500	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2087	297	2	300000	240000	240000	0.2000	1363	917	0.0080	0	2480	5.500	2.467	1100	5921	625	200	85	1600	1540	200	\N	500	525	0	550	2400	2751	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2166	305	1	400000	320000	320000	0.2000	1918	1000	0.0080	0	3185	5.999	0.164	1100	525	625	200	85	1400	1800	102	320	225	525	0	800	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownH	OK	266.67
2127	301	2	200000	160000	160000	0.2000	908	500	0.0080	0	1541	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	1500	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2088	297	3	300000	285000	285000	0.0500	1778	917	0.0080	69	2964	6.375	-0.097	1100	-276	625	200	85	1600	1540	200	\N	500	525	0	757	2400	2751	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2196	308	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2215	309	10	400000	400000	404000	0.0000	2138	1000	0.0080	117	3522	4.875	2.982	1100	12047	625	200	85	1600	2040	200	\N	500	525	4000	821	3200	3000	800	0.01000	2500	0.00350	360	USDAL	TX	266.67
2089	297	4	300000	285000	285000	0.0500	1618	917	0.0080	69	2804	5.500	2.467	1100	7031	625	200	85	1600	1540	200	\N	500	525	0	653	2400	2751	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2167	305	2	400000	320000	320000	0.2000	1817	1000	0.0080	0	3084	5.500	2.051	1100	6563	625	200	85	1400	1800	102	320	225	525	0	733	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownL	OK	266.67
2128	301	3	200000	190000	190000	0.0500	1139	500	0.0080	46	1818	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	1500	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2090	297	5	300000	289500	294566	0.0350	1696	917	0.0080	133	2946	5.625	0.016	1100	47	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	2751	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2129	301	4	200000	190000	190000	0.0500	1079	500	0.0080	46	1758	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	1500	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2091	297	6	300000	289500	294566	0.0350	1581	917	0.0080	133	2831	5.000	2.299	1100	6772	625	200	85	1600	1540	200	\N	500	525	5066	614	2400	2751	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2197	308	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2168	305	3	400000	380000	380000	0.0500	2278	1000	0.0080	92	3637	5.999	0.164	1100	623	625	200	85	1400	1800	102	380	225	525	0	950	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownH	OK	266.67
2130	301	5	200000	193000	196378	0.0350	1130	500	0.0080	88	1851	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	1500	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2236	312	1	200000	160000	160000	0.2000	959	667	0.0080	0	1759	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	2001	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2222	310	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2169	305	4	400000	380000	380000	0.0500	2158	1000	0.0080	92	3517	5.500	2.051	1100	7794	625	200	85	1400	1800	102	380	225	525	0	871	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownL	OK	266.67
2198	308	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2296	318	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2237	312	2	200000	160000	160000	0.2000	908	667	0.0080	0	1708	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	2001	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2223	310	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2336	322	1	200000	160000	160000	0.2000	959	750	0.0080	0	1842	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	2250	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2356	324	1	675000	540000	540000	0.2000	3237	1000	0.0080	0	4687	5.999	0.164	1100	886	625	200	85	1600	3415	200	\N	500	525	0	1350	5400	3000	1350	0.00000	2500	0.00000	360	Conforming30DownH	TX	450.00
2297	318	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2396	328	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2426	331	1	200000	160000	160000	0.2000	959	833	0.0080	0	1925	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	2499	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2496	338	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2546	343	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2092	297	7	300000	300000	306900	0.0000	1767	917	0.0080	0	2884	5.625	-0.127	1100	-390	625	200	85	1600	1540	200	\N	500	525	6900	719	2400	2751	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2131	301	6	200000	193000	196378	0.0350	1039	500	0.0080	88	1760	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	1500	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2093	297	8	300000	300000	306900	0.0000	1624	917	0.0080	0	2741	4.875	2.696	1100	8274	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	2751	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2170	305	5	400000	386000	392755	0.0350	2261	1000	0.0080	177	3705	5.625	-0.132	1100	-518	625	200	85	1400	1800	102	393	225	525	6755	921	3200	3000	800	0.01750	2500	0.00550	360	FHAH	OK	266.67
2094	297	9	300000	300000	303000	0.0000	1744	917	0.0080	88	2949	5.625	0.016	1100	48	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	2751	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2132	301	7	200000	200000	204600	0.0000	1210	500	0.0080	0	1843	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	1500	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2238	312	3	200000	190000	190000	0.0500	1139	667	0.0080	46	1985	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	2001	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2095	297	10	300000	300000	303000	0.0000	1627	917	0.0080	88	2832	5.000	2.299	1100	6966	625	200	85	1600	1540	200	\N	500	525	3000	631	2400	2751	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2171	305	6	400000	386000	392755	0.0350	2078	1000	0.0080	177	3522	4.875	2.982	1100	11712	625	200	85	1400	1800	102	393	225	525	6755	798	3200	3000	800	0.01750	2500	0.00550	360	FHAL	OK	266.67
2133	301	8	200000	200000	204600	0.0000	1083	500	0.0080	0	1716	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	1500	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2216	310	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2134	301	9	200000	200000	202000	0.0000	1163	500	0.0080	58	1854	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	1500	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2172	305	7	400000	400000	409200	0.0000	2421	1000	0.0080	0	3688	5.875	0.118	1100	483	625	200	85	1400	1800	102	409	225	525	9200	1002	3200	3000	800	0.02300	2500	0.00000	360	VAH	OK	266.67
2357	324	2	675000	540000	540000	0.2000	3066	1000	0.0080	0	4516	5.500	2.051	1100	11075	625	200	85	1600	3415	200	\N	500	525	0	1238	5400	3000	1350	0.00000	2500	0.00000	360	Conforming30DownL	TX	450.00
2135	301	10	200000	200000	202000	0.0000	1069	500	0.0080	58	1760	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	1500	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2239	312	4	200000	190000	190000	0.0500	1079	667	0.0080	46	1925	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	2001	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2217	310	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2173	305	8	400000	400000	409200	0.0000	2166	1000	0.0080	0	3433	4.875	2.681	1100	10971	625	200	85	1400	1800	102	409	225	525	9200	831	3200	3000	800	0.02300	2500	0.00000	360	VAL	OK	266.67
2298	318	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2276	316	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2174	305	9	400000	400000	404000	0.0000	2326	1000	0.0080	117	3710	5.625	-0.132	1100	-533	625	200	85	1400	1800	102	404	225	525	4000	947	3200	3000	800	0.01000	2500	0.00350	360	USDAH	OK	266.67
2218	310	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2240	312	5	200000	193000	196378	0.0350	1130	667	0.0080	88	2018	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	2001	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2219	310	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2277	316	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2299	318	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2358	324	3	675000	641250	641250	0.0500	3844	1000	0.0080	155	5449	5.999	0.164	1100	1052	625	200	85	1600	3415	200	\N	500	525	0	1603	5400	3000	1350	0.00000	2500	0.00290	360	Conforming5DownH	TX	450.00
2427	331	2	200000	160000	160000	0.2000	908	833	0.0080	0	1874	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	2499	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2666	355	1	200000	160000	160000	0.2000	959	1667	0.0080	0	2759	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	5001	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2416	330	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2837	374	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2547	343	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2646	353	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2241	312	6	200000	193000	196378	0.0350	1039	667	0.0080	88	1927	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	2001	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2175	305	10	400000	400000	404000	0.0000	2138	1000	0.0080	117	3522	4.875	2.982	1100	12047	625	200	85	1400	1800	102	404	225	525	4000	821	3200	3000	800	0.01000	2500	0.00350	360	USDAL	OK	266.67
2096	298	1	300000	240000	240000	0.2000	1439	917	0.0080	0	2556	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	2751	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2136	302	1	400000	320000	320000	0.2000	1918	1000	0.0080	0	3185	5.999	0.164	1100	525	625	200	85	1600	2040	200	\N	500	525	0	800	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownH	TX	266.67
2199	308	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2097	298	2	300000	240000	240000	0.2000	1363	917	0.0080	0	2480	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	2751	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2137	302	2	400000	320000	320000	0.2000	1817	1000	0.0080	0	3084	5.500	2.051	1100	6563	625	200	85	1600	2040	200	\N	500	525	0	733	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownL	TX	266.67
2098	298	3	300000	285000	285000	0.0500	1709	917	0.0080	69	2895	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	2751	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2300	318	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2200	308	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2099	298	4	300000	285000	285000	0.0500	1618	917	0.0080	69	2804	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	2751	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2138	302	3	400000	380000	380000	0.0500	2278	1000	0.0080	92	3637	5.999	0.164	1100	623	625	200	85	1600	2040	200	\N	500	525	0	950	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownH	TX	266.67
2100	298	5	300000	289500	294566	0.0350	1696	917	0.0080	133	2946	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	2751	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2242	312	7	200000	200000	204600	0.0000	1210	667	0.0080	0	2010	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	2001	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2286	317	1	250000	200000	200000	0.2000	1199	1000	0.0080	0	2366	5.999	0.164	1100	328	625	200	85	1600	1290	200	\N	500	525	0	500	2000	3000	500	0.00000	2500	0.00000	360	Conforming30DownH	TX	166.67
2139	302	4	400000	380000	380000	0.0500	2158	1000	0.0080	92	3517	5.500	2.051	1100	7794	625	200	85	1600	2040	200	\N	500	525	0	871	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownL	TX	266.67
2101	298	6	300000	289500	294566	0.0350	1559	917	0.0080	133	2809	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	2751	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2201	308	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2140	302	5	400000	386000	392755	0.0350	2261	1000	0.0080	177	3705	5.625	-0.132	1100	-518	625	200	85	1600	2040	200	\N	500	525	6755	921	3200	3000	800	0.01750	2500	0.00550	360	FHAH	TX	266.67
2243	312	8	200000	200000	204600	0.0000	1083	667	0.0080	0	1883	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	2001	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2202	308	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2359	324	4	675000	641250	641250	0.0500	3641	1000	0.0080	155	5246	5.500	2.051	1100	13152	625	200	85	1600	3415	200	\N	500	525	0	1470	5400	3000	1350	0.00000	2500	0.00290	360	Conforming5DownL	TX	450.00
2287	317	2	250000	200000	200000	0.2000	1136	1000	0.0080	0	2303	5.500	2.051	1100	4102	625	200	85	1600	1290	200	\N	500	525	0	458	2000	3000	500	0.00000	2500	0.00000	360	Conforming30DownL	TX	166.67
2244	312	9	200000	200000	202000	0.0000	1163	667	0.0080	58	2021	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	2001	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2301	318	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2428	331	3	200000	190000	190000	0.0500	1139	833	0.0080	46	2151	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	2499	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2288	317	3	250000	237500	237500	0.0500	1424	1000	0.0080	57	2648	5.999	0.164	1100	390	625	200	85	1600	1290	200	\N	500	525	0	594	2000	3000	500	0.00000	2500	0.00290	360	Conforming5DownH	TX	166.67
2302	318	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2360	324	5	675000	651375	662774	0.0350	3815	1000	0.0080	299	5564	5.625	-0.132	1100	-875	625	200	85	1600	3415	200	\N	500	525	11399	1553	5400	3000	1350	0.01750	2500	0.00550	360	FHAH	TX	450.00
2667	355	2	200000	160000	160000	0.2000	908	1667	0.0080	0	2708	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	5001	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2429	331	4	200000	190000	190000	0.0500	1079	833	0.0080	46	2091	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	2499	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2548	343	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2838	374	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2102	298	7	300000	300000	306900	0.0000	1815	917	0.0080	0	2932	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	2751	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2141	302	6	400000	386000	392755	0.0350	2078	1000	0.0080	177	3522	4.875	2.982	1100	11712	625	200	85	1600	2040	200	\N	500	525	6755	798	3200	3000	800	0.01750	2500	0.00550	360	FHAL	TX	266.67
2103	298	8	300000	300000	306900	0.0000	1624	917	0.0080	0	2741	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	2751	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2245	312	10	200000	200000	202000	0.0000	1069	667	0.0080	58	1927	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	2001	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2142	302	7	400000	400000	409200	0.0000	2421	1000	0.0080	0	3688	5.875	0.118	1100	483	625	200	85	1600	2040	200	\N	500	525	9200	1002	3200	3000	800	0.02300	2500	0.00000	360	VAH	TX	266.67
2104	298	9	300000	300000	303000	0.0000	1744	917	0.0080	88	2949	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	2751	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2176	306	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2105	298	10	300000	300000	303000	0.0000	1604	917	0.0080	88	2809	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	2751	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2143	302	8	400000	400000	409200	0.0000	2166	1000	0.0080	0	3433	4.875	2.681	1100	10971	625	200	85	1600	2040	200	\N	500	525	9200	831	3200	3000	800	0.02300	2500	0.00000	360	VAL	TX	266.67
2303	318	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2177	306	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2144	302	9	400000	400000	404000	0.0000	2326	1000	0.0080	117	3710	5.625	-0.132	1100	-533	625	200	85	1600	2040	200	\N	500	525	4000	947	3200	3000	800	0.01000	2500	0.00350	360	USDAH	TX	266.67
2246	313	1	490000	392000	392000	0.2000	2350	1000	0.0080	0	3677	5.999	0.164	1100	643	625	200	85	1600	2490	200	\N	500	525	0	980	3920	3000	980	0.00000	2500	0.00000	360	Conforming30DownH	TX	326.67
2145	302	10	400000	400000	404000	0.0000	2138	1000	0.0080	117	3522	4.875	2.982	1100	12047	625	200	85	1600	2040	200	\N	500	525	4000	821	3200	3000	800	0.01000	2500	0.00350	360	USDAL	TX	266.67
2361	324	6	675000	651375	662774	0.0350	3507	1000	0.0080	299	5256	4.875	2.982	1100	19764	625	200	85	1600	3415	200	\N	500	525	11399	1346	5400	3000	1350	0.01750	2500	0.00550	360	FHAL	TX	450.00
2178	306	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2247	313	2	490000	392000	392000	0.2000	2226	1000	0.0080	0	3553	5.500	2.051	1100	8040	625	200	85	1600	2490	200	\N	500	525	0	898	3920	3000	980	0.00000	2500	0.00000	360	Conforming30DownL	TX	326.67
2179	306	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2304	318	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2180	306	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2248	313	3	490000	465500	465500	0.0500	2791	1000	0.0080	112	4230	5.999	0.164	1100	763	625	200	85	1600	2490	200	\N	500	525	0	1164	3920	3000	980	0.00000	2500	0.00290	360	Conforming5DownH	TX	326.67
2430	331	5	200000	193000	196378	0.0350	1130	833	0.0080	88	2184	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	2499	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2362	324	7	675000	675000	690525	0.0000	4085	1000	0.0080	0	5535	5.875	0.118	1100	815	625	200	85	1600	3415	200	\N	500	525	15525	1690	5400	3000	1350	0.02300	2500	0.00000	360	VAH	TX	450.00
2305	318	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2549	343	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2668	355	3	200000	190000	190000	0.0500	1139	1667	0.0080	46	2985	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	5001	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2363	324	8	675000	675000	690525	0.0000	3654	1000	0.0080	0	5104	4.875	2.681	1100	18513	625	200	85	1600	3415	200	\N	500	525	15525	1403	5400	3000	1350	0.02300	2500	0.00000	360	VAL	TX	450.00
2431	331	6	200000	193000	196378	0.0350	1039	833	0.0080	88	2093	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	2499	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2647	353	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2839	374	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
3072	409	6	500000	482500	490944	0.0350	2598	608	0.0080	221	3760	4.875	2.982	1100	14640	625	200	85	1400	2100	102	491	225	525	8444	997	4000	1824	1000	0.01750	2500	0.00550	360	FHAL	OK	333.33
2106	299	1	500000	400000	400000	0.2000	2398	1083	0.0080	0	3814	5.999	0.164	1100	656	625	200	85	1600	2540	200	\N	500	525	0	1000	4000	3249	1000	0.00000	2500	0.00000	360	Conforming30DownH	TX	333.33
2249	313	4	490000	465500	465500	0.0500	2643	1000	0.0080	112	4082	5.500	2.051	1100	9547	625	200	85	1600	2490	200	\N	500	525	0	1067	3920	3000	980	0.00000	2500	0.00290	360	Conforming5DownL	TX	326.67
2146	303	1	500000	400000	400000	0.2000	2398	1000	0.0080	0	3731	5.999	0.164	1100	656	625	200	85	1400	2100	102	400	225	525	0	1000	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownH	OK	333.33
2181	306	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2107	299	2	500000	400000	400000	0.2000	2271	1083	0.0080	0	3687	5.500	2.051	1100	8204	625	200	85	1600	2540	200	\N	500	525	0	917	4000	3249	1000	0.00000	2500	0.00000	360	Conforming30DownL	TX	333.33
2147	303	2	500000	400000	400000	0.2000	2271	1000	0.0080	0	3604	5.500	2.051	1100	8204	625	200	85	1400	2100	102	400	225	525	0	917	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownL	OK	333.33
2108	299	3	500000	475000	475000	0.0500	2848	1083	0.0080	115	4379	5.999	0.164	1100	779	625	200	85	1600	2540	200	\N	500	525	0	1187	4000	3249	1000	0.00000	2500	0.00290	360	Conforming5DownH	TX	333.33
2306	319	1	240000	192000	192000	0.2000	1151	1000	0.0080	0	2311	5.999	0.164	1100	315	625	200	85	1600	1240	200	\N	500	525	0	480	1920	3000	480	0.00000	2500	0.00000	360	Conforming30DownH	TX	160.00
2182	306	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2109	299	4	500000	475000	475000	0.0500	2697	1083	0.0080	115	4228	5.500	2.051	1100	9742	625	200	85	1600	2540	200	\N	500	525	0	1089	4000	3249	1000	0.00000	2500	0.00290	360	Conforming5DownL	TX	333.33
2148	303	3	500000	475000	475000	0.0500	2848	1000	0.0080	115	4296	5.999	0.164	1100	779	625	200	85	1400	2100	102	475	225	525	0	1187	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownH	OK	333.33
2110	299	5	500000	482500	490944	0.0350	2826	1083	0.0080	221	4463	5.625	-0.132	1100	-648	625	200	85	1600	2540	200	\N	500	525	8444	1151	4000	3249	1000	0.01750	2500	0.00550	360	FHAH	TX	333.33
2250	313	5	490000	472850	481125	0.0350	2770	1000	0.0080	217	4314	5.625	-0.132	1100	-635	625	200	85	1600	2490	200	\N	500	525	8275	1128	3920	3000	980	0.01750	2500	0.00550	360	FHAH	TX	326.67
2289	317	4	250000	237500	237500	0.0500	1348	1000	0.0080	57	2572	5.500	2.051	1100	4871	625	200	85	1600	1290	200	\N	500	525	0	544	2000	3000	500	0.00000	2500	0.00290	360	Conforming5DownL	TX	166.67
2149	303	4	500000	475000	475000	0.0500	2697	1000	0.0080	115	4145	5.500	2.051	1100	9742	625	200	85	1400	2100	102	475	225	525	0	1089	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownL	OK	333.33
2111	299	6	500000	482500	490944	0.0350	2598	1083	0.0080	221	4235	4.875	2.982	1100	14640	625	200	85	1600	2540	200	\N	500	525	8444	997	4000	3249	1000	0.01750	2500	0.00550	360	FHAL	TX	333.33
2183	306	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2150	303	5	500000	482500	490944	0.0350	2826	1000	0.0080	221	4380	5.625	-0.132	1100	-648	625	200	85	1400	2100	102	491	225	525	8444	1151	4000	3000	1000	0.01750	2500	0.00550	360	FHAH	OK	333.33
2550	343	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2251	313	6	490000	472850	481125	0.0350	2546	1000	0.0080	217	4090	4.875	2.982	1100	14347	625	200	85	1600	2490	200	\N	500	525	8275	977	3920	3000	980	0.01750	2500	0.00550	360	FHAL	TX	326.67
2184	306	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2364	324	9	675000	675000	681750	0.0000	3925	1000	0.0080	197	5572	5.625	-0.132	1100	-900	625	200	85	1600	3415	200	\N	500	525	6750	1598	5400	3000	1350	0.01000	2500	0.00350	360	USDAH	TX	450.00
2290	317	5	250000	241250	245472	0.0350	1413	1000	0.0080	111	2691	5.625	-0.132	1100	-324	625	200	85	1600	1290	200	\N	500	525	4222	575	2000	3000	500	0.01750	2500	0.00550	360	FHAH	TX	166.67
2252	313	7	490000	490000	501270	0.0000	2965	1000	0.0080	0	4292	5.875	0.118	1100	591	625	200	85	1600	2490	200	\N	500	525	11270	1227	3920	3000	980	0.02300	2500	0.00000	360	VAH	TX	326.67
2307	319	2	240000	192000	192000	0.2000	1090	1000	0.0080	0	2250	5.500	2.051	1100	3938	625	200	85	1600	1240	200	\N	500	525	0	440	1920	3000	480	0.00000	2500	0.00000	360	Conforming30DownL	TX	160.00
2432	331	7	200000	200000	204600	0.0000	1210	833	0.0080	0	2176	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	2499	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2669	355	4	200000	190000	190000	0.0500	1079	1667	0.0080	46	2925	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	5001	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2291	317	6	250000	241250	245472	0.0350	1299	1000	0.0080	111	2577	4.875	2.982	1100	7320	625	200	85	1600	1290	200	\N	500	525	4222	499	2000	3000	500	0.01750	2500	0.00550	360	FHAL	TX	166.67
2365	324	10	675000	675000	681750	0.0000	3608	1000	0.0080	197	5255	4.875	2.982	1100	20330	625	200	85	1600	3415	200	\N	500	525	6750	1385	5400	3000	1350	0.01000	2500	0.00350	360	USDAL	TX	450.00
2433	331	8	200000	200000	204600	0.0000	1083	833	0.0080	0	2049	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	2499	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2551	343	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2840	374	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2112	299	7	500000	500000	511500	0.0000	3026	1083	0.0080	0	4442	5.875	0.118	1100	604	625	200	85	1600	2540	200	\N	500	525	11500	1252	4000	3249	1000	0.02300	2500	0.00000	360	VAH	TX	333.33
2185	306	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2151	303	6	500000	482500	490944	0.0350	2598	1000	0.0080	221	4152	4.875	2.982	1100	14640	625	200	85	1400	2100	102	491	225	525	8444	997	4000	3000	1000	0.01750	2500	0.00550	360	FHAL	OK	333.33
2113	299	8	500000	500000	511500	0.0000	2707	1083	0.0080	0	4123	4.875	2.681	1100	13713	625	200	85	1600	2540	200	\N	500	525	11500	1039	4000	3249	1000	0.02300	2500	0.00000	360	VAL	TX	333.33
2203	308	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2114	299	9	500000	500000	505000	0.0000	2907	1083	0.0080	146	4469	5.625	-0.132	1100	-667	625	200	85	1600	2540	200	\N	500	525	5000	1184	4000	3249	1000	0.01000	2500	0.00350	360	USDAH	TX	333.33
2152	303	7	500000	500000	511500	0.0000	3026	1000	0.0080	0	4359	5.875	0.118	1100	604	625	200	85	1400	2100	102	512	225	525	11500	1252	4000	3000	1000	0.02300	2500	0.00000	360	VAH	OK	333.33
2278	316	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2115	299	10	500000	500000	505000	0.0000	2673	1083	0.0080	146	4235	4.875	2.982	1100	15059	625	200	85	1600	2540	200	\N	500	525	5000	1026	4000	3249	1000	0.01000	2500	0.00350	360	USDAL	TX	333.33
2253	313	8	490000	490000	501270	0.0000	2653	1000	0.0080	0	3980	4.875	2.681	1100	13439	625	200	85	1600	2490	200	\N	500	525	11270	1018	3920	3000	980	0.02300	2500	0.00000	360	VAL	TX	326.67
2204	308	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2153	303	8	500000	500000	511500	0.0000	2707	1000	0.0080	0	4040	4.875	2.681	1100	13713	625	200	85	1400	2100	102	512	225	525	11500	1039	4000	3000	1000	0.02300	2500	0.00000	360	VAL	OK	333.33
2308	319	3	240000	228000	228000	0.0500	1367	1000	0.0080	55	2582	5.999	0.164	1100	374	625	200	85	1600	1240	200	\N	500	525	0	570	1920	3000	480	0.00000	2500	0.00290	360	Conforming5DownH	TX	160.00
2076	296	1	500000	400000	400000	0.2000	2495	1167	0.0080	0	3995	6.375	-0.097	1100	-388	625	200	85	1600	2540	200	\N	500	525	0	1062	4000	3501	1000	0.00000	2500	0.00000	360	Conforming30DownH	TX	333.33
2154	303	9	500000	500000	505000	0.0000	2907	1000	0.0080	146	4386	5.625	-0.132	1100	-667	625	200	85	1400	2100	102	505	225	525	5000	1184	4000	3000	1000	0.01000	2500	0.00350	360	USDAH	OK	333.33
2205	308	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2077	296	2	500000	400000	400000	0.2000	2271	1167	0.0080	0	3771	5.500	2.467	1100	9868	625	200	85	1600	2540	200	\N	500	525	0	917	4000	3501	1000	0.00000	2500	0.00000	360	Conforming30DownL	TX	333.33
2155	303	10	500000	500000	505000	0.0000	2673	1000	0.0080	146	4152	4.875	2.982	1100	15059	625	200	85	1400	2100	102	505	225	525	5000	1026	4000	3000	1000	0.01000	2500	0.00350	360	USDAL	OK	333.33
2254	313	9	490000	490000	494900	0.0000	2849	1000	0.0080	143	4319	5.625	-0.132	1100	-653	625	200	85	1600	2490	200	\N	500	525	4900	1160	3920	3000	980	0.01000	2500	0.00350	360	USDAH	TX	326.67
2078	296	3	500000	475000	475000	0.0500	2963	1167	0.0080	115	4578	6.375	-0.097	1100	-461	625	200	85	1600	2540	200	\N	500	525	0	1262	4000	3501	1000	0.00000	2500	0.00290	360	Conforming5DownH	TX	333.33
2220	310	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2279	316	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2366	325	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1400	1500	102	240	225	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	OK	200.00
2221	310	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2255	313	10	490000	490000	494900	0.0000	2619	1000	0.0080	143	4089	4.875	2.982	1100	14758	625	200	85	1600	2490	200	\N	500	525	4900	1005	3920	3000	980	0.01000	2500	0.00350	360	USDAL	TX	326.67
2309	319	4	240000	228000	228000	0.0500	1295	1000	0.0080	55	2510	5.500	2.051	1100	4676	625	200	85	1600	1240	200	\N	500	525	0	523	1920	3000	480	0.00000	2500	0.00290	360	Conforming5DownL	TX	160.00
2280	316	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2670	355	5	200000	193000	196378	0.0350	1130	1667	0.0080	88	3018	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	5001	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2434	331	9	200000	200000	202000	0.0000	1163	833	0.0080	58	2187	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	2499	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2310	319	5	240000	231600	235653	0.0350	1357	1000	0.0080	106	2623	5.625	-0.132	1100	-311	625	200	85	1600	1240	200	\N	500	525	4053	552	1920	3000	480	0.01750	2500	0.00550	360	FHAH	TX	160.00
2504	338	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2552	343	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2116	300	1	400000	320000	320000	0.2000	1918	1000	0.0080	0	3185	5.999	0.164	1100	525	625	200	85	1400	1800	102	320	225	525	0	800	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownH	OK	266.67
2156	304	1	400000	320000	320000	0.2000	1918	1000	0.0080	0	3185	5.999	0.164	1100	525	625	200	85	1400	1800	102	320	225	525	0	800	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownH	OK	266.67
2367	325	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1400	1500	102	240	225	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	OK	200.00
2117	300	2	400000	320000	320000	0.2000	1817	1000	0.0080	0	3084	5.500	2.051	1100	6563	625	200	85	1400	1800	102	320	225	525	0	733	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownL	OK	266.67
2186	307	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2157	304	2	400000	320000	320000	0.2000	1817	1000	0.0080	0	3084	5.500	2.051	1100	6563	625	200	85	1400	1800	102	320	225	525	0	733	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownL	OK	266.67
2118	300	3	400000	380000	380000	0.0500	2278	1000	0.0080	92	3637	5.999	0.164	1100	623	625	200	85	1400	1800	102	380	225	525	0	950	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownH	OK	266.67
2206	309	1	400000	320000	320000	0.2000	1918	1000	0.0080	0	3185	5.999	0.164	1100	525	625	200	85	1600	2040	200	\N	500	525	0	800	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownH	TX	266.67
2119	300	4	400000	380000	380000	0.0500	2158	1000	0.0080	92	3517	5.500	2.051	1100	7794	625	200	85	1400	1800	102	380	225	525	0	871	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownL	OK	266.67
2187	307	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2158	304	3	400000	380000	380000	0.0500	2278	1000	0.0080	92	3637	5.999	0.164	1100	623	625	200	85	1400	1800	102	380	225	525	0	950	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownH	OK	266.67
2120	300	5	400000	386000	392755	0.0350	2261	1000	0.0080	177	3705	5.625	-0.132	1100	-518	625	200	85	1400	1800	102	393	225	525	6755	921	3200	3000	800	0.01750	2500	0.00550	360	FHAH	OK	266.67
2256	314	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2482	336	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2159	304	4	400000	380000	380000	0.0500	2158	1000	0.0080	92	3517	5.500	2.051	1100	7794	625	200	85	1400	1800	102	380	225	525	0	871	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownL	OK	266.67
2121	300	6	400000	386000	392755	0.0350	2078	1000	0.0080	177	3522	4.875	2.982	1100	11712	625	200	85	1400	1800	102	393	225	525	6755	798	3200	3000	800	0.01750	2500	0.00550	360	FHAL	OK	266.67
2207	309	2	400000	320000	320000	0.2000	1817	1000	0.0080	0	3084	5.500	2.051	1100	6563	625	200	85	1600	2040	200	\N	500	525	0	733	3200	3000	800	0.00000	2500	0.00000	360	Conforming30DownL	TX	266.67
2188	307	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2160	304	5	400000	386000	392755	0.0350	2261	1000	0.0080	177	3705	5.625	-0.132	1100	-518	625	200	85	1400	1800	102	393	225	525	6755	921	3200	3000	800	0.01750	2500	0.00550	360	FHAH	OK	266.67
2311	319	6	240000	231600	235653	0.0350	1247	1000	0.0080	106	2513	4.875	2.982	1100	7027	625	200	85	1600	1240	200	\N	500	525	4053	479	1920	3000	480	0.01750	2500	0.00550	360	FHAL	TX	160.00
2435	331	10	200000	200000	202000	0.0000	1069	833	0.0080	58	2093	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	2499	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2189	307	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2257	314	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2208	309	3	400000	380000	380000	0.0500	2278	1000	0.0080	92	3637	5.999	0.164	1100	623	625	200	85	1600	2040	200	\N	500	525	0	950	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownH	TX	266.67
2368	325	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1400	1500	102	285	225	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	OK	200.00
2312	319	7	240000	240000	245520	0.0000	1452	1000	0.0080	0	2612	5.875	0.118	1100	290	625	200	85	1600	1240	200	\N	500	525	5520	601	1920	3000	480	0.02300	2500	0.00000	360	VAH	TX	160.00
2258	314	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2671	355	6	200000	193000	196378	0.0350	1039	1667	0.0080	88	2927	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	5001	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2369	325	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1400	1500	102	285	225	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	OK	200.00
2553	343	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2841	374	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2122	300	7	400000	400000	409200	0.0000	2421	1000	0.0080	0	3688	5.875	0.118	1100	483	625	200	85	1400	1800	102	409	225	525	9200	1002	3200	3000	800	0.02300	2500	0.00000	360	VAH	OK	266.67
2161	304	6	400000	386000	392755	0.0350	2078	1000	0.0080	177	3522	4.875	2.982	1100	11712	625	200	85	1400	1800	102	393	225	525	6755	798	3200	3000	800	0.01750	2500	0.00550	360	FHAL	OK	266.67
2123	300	8	400000	400000	409200	0.0000	2166	1000	0.0080	0	3433	4.875	2.681	1100	10971	625	200	85	1400	1800	102	409	225	525	9200	831	3200	3000	800	0.02300	2500	0.00000	360	VAL	OK	266.67
2190	307	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2313	319	8	240000	240000	245520	0.0000	1299	1000	0.0080	0	2459	4.875	2.681	1100	6582	625	200	85	1600	1240	200	\N	500	525	5520	499	1920	3000	480	0.02300	2500	0.00000	360	VAL	TX	160.00
2124	300	9	400000	400000	404000	0.0000	2326	1000	0.0080	117	3710	5.625	-0.132	1100	-533	625	200	85	1400	1800	102	404	225	525	4000	947	3200	3000	800	0.01000	2500	0.00350	360	USDAH	OK	266.67
2162	304	7	400000	400000	409200	0.0000	2421	1000	0.0080	0	3688	5.875	0.118	1100	483	625	200	85	1400	1800	102	409	225	525	9200	1002	3200	3000	800	0.02300	2500	0.00000	360	VAH	OK	266.67
2259	314	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2125	300	10	400000	400000	404000	0.0000	2138	1000	0.0080	117	3522	4.875	2.982	1100	12047	625	200	85	1400	1800	102	404	225	525	4000	821	3200	3000	800	0.01000	2500	0.00350	360	USDAL	OK	266.67
2191	307	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2163	304	8	400000	400000	409200	0.0000	2166	1000	0.0080	0	3433	4.875	2.681	1100	10971	625	200	85	1400	1800	102	409	225	525	9200	831	3200	3000	800	0.02300	2500	0.00000	360	VAL	OK	266.67
2164	304	9	400000	400000	404000	0.0000	2326	1000	0.0080	117	3710	5.625	-0.132	1100	-533	625	200	85	1400	1800	102	404	225	525	4000	947	3200	3000	800	0.01000	2500	0.00350	360	USDAH	OK	266.67
2192	307	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2260	314	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2165	304	10	400000	400000	404000	0.0000	2138	1000	0.0080	117	3522	4.875	2.982	1100	12047	625	200	85	1400	1800	102	404	225	525	4000	821	3200	3000	800	0.01000	2500	0.00350	360	USDAL	OK	266.67
2314	319	9	240000	240000	242400	0.0000	1395	1000	0.0080	70	2625	5.625	-0.132	1100	-320	625	200	85	1600	1240	200	\N	500	525	2400	568	1920	3000	480	0.01000	2500	0.00350	360	USDAH	TX	160.00
2079	296	4	500000	475000	475000	0.0500	2697	1167	0.0080	115	4312	5.500	2.467	1100	11718	625	200	85	1600	2540	200	\N	500	525	0	1089	4000	3501	1000	0.00000	2500	0.00290	360	Conforming5DownL	TX	333.33
2193	307	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2672	355	7	200000	200000	204600	0.0000	1210	1667	0.0080	0	3010	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	5001	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2370	325	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1400	1500	102	295	225	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	OK	200.00
2261	314	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2194	307	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2554	343	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2315	319	10	240000	240000	242400	0.0000	1283	1000	0.0080	70	2513	4.875	2.982	1100	7228	625	200	85	1600	1240	200	\N	500	525	2400	492	1920	3000	480	0.01000	2500	0.00350	360	USDAL	TX	160.00
2337	322	2	200000	160000	160000	0.2000	908	750	0.0080	0	1791	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	2250	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2262	314	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2436	332	1	500000	400000	400000	0.2000	2398	1000	0.0080	0	3731	5.999	0.164	1100	656	625	200	85	1600	2540	200	\N	500	525	0	1000	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownH	TX	333.33
2371	325	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1400	1500	102	295	225	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	OK	200.00
2512	339	7	500000	500000	511500	0.0000	3026	833	0.0080	0	4192	5.875	0.118	1100	604	625	200	85	1600	2540	200	\N	500	525	11500	1252	4000	2499	1000	0.02300	2500	0.00000	360	VAH	TX	333.33
2842	374	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2437	332	2	500000	400000	400000	0.2000	2271	1000	0.0080	0	3604	5.500	2.051	1100	8204	625	200	85	1600	2540	200	\N	500	525	0	917	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownL	TX	333.33
2673	355	8	200000	200000	204600	0.0000	1083	1667	0.0080	0	2883	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	5001	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2080	296	5	500000	482500	490944	0.0350	2826	1167	0.0080	221	4547	5.625	0.016	1100	79	625	200	85	1600	2540	200	\N	500	525	8444	1151	4000	3501	1000	0.01750	2500	0.00550	360	FHAH	TX	333.33
2195	307	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2209	309	4	400000	380000	380000	0.0500	2158	1000	0.0080	92	3517	5.500	2.051	1100	7794	625	200	85	1600	2040	200	\N	500	525	0	871	3200	3000	800	0.00000	2500	0.00290	360	Conforming5DownL	TX	266.67
2081	296	6	500000	482500	490944	0.0350	2635	1167	0.0080	221	4356	5.000	2.299	1100	11287	625	200	85	1600	2540	200	\N	500	525	8444	1023	4000	3501	1000	0.01750	2500	0.00550	360	FHAL	TX	333.33
2263	314	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2082	296	7	500000	500000	511500	0.0000	2944	1167	0.0080	0	4444	5.625	-0.127	1100	-650	625	200	85	1600	2540	200	\N	500	525	11500	1199	4000	3501	1000	0.02300	2500	0.00000	360	VAH	TX	333.33
2210	309	5	400000	386000	392755	0.0350	2261	1000	0.0080	177	3705	5.625	-0.132	1100	-518	625	200	85	1600	2040	200	\N	500	525	6755	921	3200	3000	800	0.01750	2500	0.00550	360	FHAH	TX	266.67
2083	296	8	500000	500000	511500	0.0000	2707	1167	0.0080	0	4207	4.875	2.696	1100	13790	625	200	85	1600	2540	200	\N	500	525	11500	1039	4000	3501	1000	0.02300	2500	0.00000	360	VAL	TX	333.33
2372	325	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1400	1500	102	307	225	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	OK	200.00
2316	320	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2211	309	6	400000	386000	392755	0.0350	2078	1000	0.0080	177	3522	4.875	2.982	1100	11712	625	200	85	1600	2040	200	\N	500	525	6755	798	3200	3000	800	0.01750	2500	0.00550	360	FHAL	TX	266.67
2084	296	9	500000	500000	505000	0.0000	2907	1167	0.0080	146	4553	5.625	0.016	1100	81	625	200	85	1600	2540	200	\N	500	525	5000	1184	4000	3501	1000	0.01000	2500	0.00350	360	USDAH	TX	333.33
2264	314	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2085	296	10	500000	500000	505000	0.0000	2711	1167	0.0080	146	4357	5.000	2.299	1100	11610	625	200	85	1600	2540	200	\N	500	525	5000	1052	4000	3501	1000	0.01000	2500	0.00350	360	USDAL	TX	333.33
2555	343	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2212	309	7	400000	400000	409200	0.0000	2421	1000	0.0080	0	3688	5.875	0.118	1100	483	625	200	85	1600	2040	200	\N	500	525	9200	1002	3200	3000	800	0.02300	2500	0.00000	360	VAH	TX	266.67
2621	350	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2265	314	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2213	309	8	400000	400000	409200	0.0000	2166	1000	0.0080	0	3433	4.875	2.681	1100	10971	625	200	85	1600	2040	200	\N	500	525	9200	831	3200	3000	800	0.02300	2500	0.00000	360	VAL	TX	266.67
2317	320	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2373	325	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1400	1500	102	307	225	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	OK	200.00
2214	309	9	400000	400000	404000	0.0000	2326	1000	0.0080	117	3710	5.625	-0.132	1100	-533	625	200	85	1600	2040	200	\N	500	525	4000	947	3200	3000	800	0.01000	2500	0.00350	360	USDAH	TX	266.67
2266	315	1	600000	480000	480000	0.2000	2878	1000	0.0080	0	4278	5.999	0.164	1100	787	625	200	85	1600	3040	200	\N	500	525	0	1200	4800	3000	1200	0.00000	2500	0.00000	360	Conforming30DownH	TX	400.00
2438	332	3	500000	475000	475000	0.0500	2848	1000	0.0080	115	4296	5.999	0.164	1100	779	625	200	85	1600	2540	200	\N	500	525	0	1187	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownH	TX	333.33
2318	320	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2374	325	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1400	1500	102	303	225	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	OK	200.00
2843	374	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2439	332	4	500000	475000	475000	0.0500	2697	1000	0.0080	115	4145	5.500	2.051	1100	9742	625	200	85	1600	2540	200	\N	500	525	0	1089	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownL	TX	333.33
2622	350	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2674	355	9	200000	200000	202000	0.0000	1163	1667	0.0080	58	3021	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	5001	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2224	310	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2267	315	2	600000	480000	480000	0.2000	2725	1000	0.0080	0	4125	5.500	2.051	1100	9845	625	200	85	1600	3040	200	\N	500	525	0	1100	4800	3000	1200	0.00000	2500	0.00000	360	Conforming30DownL	TX	400.00
2225	310	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2319	320	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2268	315	3	600000	570000	570000	0.0500	3417	1000	0.0080	138	4955	5.999	0.164	1100	935	625	200	85	1600	3040	200	\N	500	525	0	1425	4800	3000	1200	0.00000	2500	0.00290	360	Conforming5DownH	TX	400.00
2226	311	1	400000	320000	320000	0.2000	1918	1083	0.0080	0	3268	5.999	0.164	1100	525	625	200	85	1600	2040	200	\N	500	525	0	800	3200	3249	800	0.00000	2500	0.00000	360	Conforming30DownH	TX	266.67
2375	325	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1400	1500	102	303	225	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	OK	200.00
2227	311	2	400000	320000	320000	0.2000	1817	1083	0.0080	0	3167	5.500	2.051	1100	6563	625	200	85	1600	2040	200	\N	500	525	0	733	3200	3249	800	0.00000	2500	0.00000	360	Conforming30DownL	TX	266.67
2397	328	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2269	315	4	600000	570000	570000	0.0500	3236	1000	0.0080	138	4774	5.500	2.051	1100	11691	625	200	85	1600	3040	200	\N	500	525	0	1306	4800	3000	1200	0.00000	2500	0.00290	360	Conforming5DownL	TX	400.00
2320	320	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2228	311	3	400000	380000	380000	0.0500	2278	1083	0.0080	92	3720	5.999	0.164	1100	623	625	200	85	1600	2040	200	\N	500	525	0	950	3200	3249	800	0.00000	2500	0.00290	360	Conforming5DownH	TX	266.67
2270	315	5	600000	579000	589133	0.0350	3391	1000	0.0080	265	5056	5.625	-0.132	1100	-778	625	200	85	1600	3040	200	\N	500	525	10133	1381	4800	3000	1200	0.01750	2500	0.00550	360	FHAH	TX	400.00
2229	311	4	400000	380000	380000	0.0500	2158	1083	0.0080	92	3600	5.500	2.051	1100	7794	625	200	85	1600	2040	200	\N	500	525	0	871	3200	3249	800	0.00000	2500	0.00290	360	Conforming5DownL	TX	266.67
2440	332	5	500000	482500	490944	0.0350	2826	1000	0.0080	221	4380	5.625	-0.132	1100	-648	625	200	85	1600	2540	200	\N	500	525	8444	1151	4000	3000	1000	0.01750	2500	0.00550	360	FHAH	TX	333.33
2321	320	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2230	311	5	400000	386000	392755	0.0350	2261	1083	0.0080	177	3788	5.625	-0.132	1100	-518	625	200	85	1600	2040	200	\N	500	525	6755	921	3200	3249	800	0.01750	2500	0.00550	360	FHAH	TX	266.67
2271	315	6	600000	579000	589133	0.0350	3118	1000	0.0080	265	4783	4.875	2.982	1100	17568	625	200	85	1600	3040	200	\N	500	525	10133	1197	4800	3000	1200	0.01750	2500	0.00550	360	FHAL	TX	400.00
2398	328	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2675	355	10	200000	200000	202000	0.0000	1069	1667	0.0080	58	2927	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	5001	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2272	315	7	600000	600000	613800	0.0000	3631	1000	0.0080	0	5031	5.875	0.118	1100	724	625	200	85	1600	3040	200	\N	500	525	13800	1503	4800	3000	1200	0.02300	2500	0.00000	360	VAH	TX	400.00
2322	320	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2844	374	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2441	332	6	500000	482500	490944	0.0350	2598	1000	0.0080	221	4152	4.875	2.982	1100	14640	625	200	85	1600	2540	200	\N	500	525	8444	997	4000	3000	1000	0.01750	2500	0.00550	360	FHAL	TX	333.33
2399	328	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2556	344	1	275000	220000	220000	0.2000	1319	1000	0.0080	0	2502	5.999	0.164	1100	361	625	200	85	1400	1425	102	220	225	525	0	550	2200	3000	550	0.00000	2500	0.00000	360	Conforming30DownH	OK	183.33
2442	332	7	500000	500000	511500	0.0000	3026	1000	0.0080	0	4359	5.875	0.118	1100	604	625	200	85	1600	2540	200	\N	500	525	11500	1252	4000	3000	1000	0.02300	2500	0.00000	360	VAH	TX	333.33
2676	356	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2557	344	2	275000	220000	220000	0.2000	1249	1000	0.0080	0	2432	5.500	2.051	1100	4512	625	200	85	1400	1425	102	220	225	525	0	504	2200	3000	550	0.00000	2500	0.00000	360	Conforming30DownL	OK	183.33
2845	374	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2231	311	6	400000	386000	392755	0.0350	2078	1083	0.0080	177	3605	4.875	2.982	1100	11712	625	200	85	1600	2040	200	\N	500	525	6755	798	3200	3249	800	0.01750	2500	0.00550	360	FHAL	TX	266.67
2323	320	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2273	315	8	600000	600000	613800	0.0000	3248	1000	0.0080	0	4648	4.875	2.681	1100	16456	625	200	85	1600	3040	200	\N	500	525	13800	1247	4800	3000	1200	0.02300	2500	0.00000	360	VAL	TX	400.00
2232	311	7	400000	400000	409200	0.0000	2421	1083	0.0080	0	3771	5.875	0.118	1100	483	625	200	85	1600	2040	200	\N	500	525	9200	1002	3200	3249	800	0.02300	2500	0.00000	360	VAH	TX	266.67
2233	311	8	400000	400000	409200	0.0000	2166	1083	0.0080	0	3516	4.875	2.681	1100	10971	625	200	85	1600	2040	200	\N	500	525	9200	831	3200	3249	800	0.02300	2500	0.00000	360	VAL	TX	266.67
2324	320	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2274	315	9	600000	600000	606000	0.0000	3488	1000	0.0080	175	5063	5.625	-0.132	1100	-800	625	200	85	1600	3040	200	\N	500	525	6000	1420	4800	3000	1200	0.01000	2500	0.00350	360	USDAH	TX	400.00
2234	311	9	400000	400000	404000	0.0000	2326	1083	0.0080	117	3793	5.625	-0.132	1100	-533	625	200	85	1600	2040	200	\N	500	525	4000	947	3200	3249	800	0.01000	2500	0.00350	360	USDAH	TX	266.67
2443	332	8	500000	500000	511500	0.0000	2707	1000	0.0080	0	4040	4.875	2.681	1100	13713	625	200	85	1600	2540	200	\N	500	525	11500	1039	4000	3000	1000	0.02300	2500	0.00000	360	VAL	TX	333.33
2376	326	1	300000	240000	240000	0.2000	1439	833	0.0080	0	2472	5.999	0.164	1100	394	625	200	85	1400	1500	102	240	225	525	0	600	2400	2499	600	0.00000	2500	0.00000	360	Conforming30DownH	OK	200.00
2275	315	10	600000	600000	606000	0.0000	3207	1000	0.0080	175	4782	4.875	2.982	1100	18071	625	200	85	1600	3040	200	\N	500	525	6000	1231	4800	3000	1200	0.01000	2500	0.00350	360	USDAL	TX	400.00
2235	311	10	400000	400000	404000	0.0000	2138	1083	0.0080	117	3605	4.875	2.982	1100	12047	625	200	85	1600	2040	200	\N	500	525	4000	821	3200	3249	800	0.01000	2500	0.00350	360	USDAL	TX	266.67
2281	316	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2325	320	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2282	316	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2677	356	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2377	326	2	300000	240000	240000	0.2000	1363	833	0.0080	0	2396	5.500	2.051	1100	4922	625	200	85	1400	1500	102	240	225	525	0	550	2400	2499	600	0.00000	2500	0.00000	360	Conforming30DownL	OK	200.00
2326	321	1	400000	320000	320000	0.2000	1918	833	0.0080	0	3018	5.999	0.164	1100	525	625	200	85	1400	1800	102	320	225	525	0	800	3200	2499	800	0.00000	2500	0.00000	360	Conforming30DownH	OK	266.67
2283	316	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2516	340	1	236570	189256	189256	0.2000	1135	748	0.0080	0	2041	5.999	0.164	1100	310	625	200	85	1400	1310	102	189	225	525	0	473	1893	2244	473	0.00000	2500	0.00000	360	Conforming30DownH	OK	157.71
2444	332	9	500000	500000	505000	0.0000	2907	1000	0.0080	146	4386	5.625	-0.132	1100	-667	625	200	85	1600	2540	200	\N	500	525	5000	1184	4000	3000	1000	0.01000	2500	0.00350	360	USDAH	TX	333.33
2327	321	2	400000	320000	320000	0.2000	1817	833	0.0080	0	2917	5.500	2.051	1100	6563	625	200	85	1400	1800	102	320	225	525	0	733	3200	2499	800	0.00000	2500	0.00000	360	Conforming30DownL	OK	266.67
2378	326	3	300000	285000	285000	0.0500	1709	833	0.0080	69	2811	5.999	0.164	1100	467	625	200	85	1400	1500	102	285	225	525	0	712	2400	2499	600	0.00000	2500	0.00290	360	Conforming5DownH	OK	200.00
2558	344	3	275000	261250	261250	0.0500	1566	1000	0.0080	63	2812	5.999	0.164	1100	428	625	200	85	1400	1425	102	261	225	525	0	653	2200	3000	550	0.00000	2500	0.00290	360	Conforming5DownH	OK	183.33
2445	332	10	500000	500000	505000	0.0000	2673	1000	0.0080	146	4152	4.875	2.982	1100	15059	625	200	85	1600	2540	200	\N	500	525	5000	1026	4000	3000	1000	0.01000	2500	0.00350	360	USDAL	TX	333.33
2846	374	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2559	344	4	275000	261250	261250	0.0500	1483	1000	0.0080	63	2729	5.500	2.051	1100	5358	625	200	85	1400	1425	102	261	225	525	0	599	2200	3000	550	0.00000	2500	0.00290	360	Conforming5DownL	OK	183.33
2517	340	2	236570	189256	189256	0.2000	1075	748	0.0080	0	1981	5.500	2.051	1100	3882	625	200	85	1400	1310	102	189	225	525	0	434	1893	2244	473	0.00000	2500	0.00000	360	Conforming30DownL	OK	157.71
2959	397	7	200000	200000	204600	0.0000	1210	833	0.0080	0	2176	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	2499	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2678	356	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2960	397	8	200000	200000	204600	0.0000	1083	833	0.0080	0	2049	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	2499	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2284	316	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2328	321	3	400000	380000	380000	0.0500	2278	833	0.0080	92	3470	5.999	0.164	1100	623	625	200	85	1400	1800	102	380	225	525	0	950	3200	2499	800	0.00000	2500	0.00290	360	Conforming5DownH	OK	266.67
2285	316	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2379	326	4	300000	285000	285000	0.0500	1618	833	0.0080	69	2720	5.500	2.051	1100	5845	625	200	85	1400	1500	102	285	225	525	0	653	2400	2499	600	0.00000	2500	0.00290	360	Conforming5DownL	OK	200.00
2329	321	4	400000	380000	380000	0.0500	2158	833	0.0080	92	3350	5.500	2.051	1100	7794	625	200	85	1400	1800	102	380	225	525	0	871	3200	2499	800	0.00000	2500	0.00290	360	Conforming5DownL	OK	266.67
2446	333	1	455000	364000	364000	0.2000	2182	1250	0.0080	0	3735	5.999	0.164	1100	597	625	200	85	1600	2315	200	\N	500	525	0	910	3640	3750	910	0.00000	2500	0.00000	360	Conforming30DownH	TX	303.33
2380	326	5	300000	289500	294566	0.0350	1696	833	0.0080	133	2862	5.625	-0.132	1100	-389	625	200	85	1400	1500	102	295	225	525	5066	690	2400	2499	600	0.01750	2500	0.00550	360	FHAH	OK	200.00
2330	321	5	400000	386000	392755	0.0350	2261	833	0.0080	177	3538	5.625	-0.132	1100	-518	625	200	85	1400	1800	102	393	225	525	6755	921	3200	2499	800	0.01750	2500	0.00550	360	FHAH	OK	266.67
2847	375	1	200000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	Conforming	OK	\N
2560	344	5	275000	265375	270019	0.0350	1554	1000	0.0080	122	2859	5.625	-0.132	1100	-356	625	200	85	1400	1425	102	270	225	525	4644	633	2200	3000	550	0.01750	2500	0.00550	360	FHAH	OK	183.33
2331	321	6	400000	386000	392755	0.0350	2078	833	0.0080	177	3355	4.875	2.982	1100	11712	625	200	85	1400	1800	102	393	225	525	6755	798	3200	2499	800	0.01750	2500	0.00550	360	FHAL	OK	266.67
2381	326	6	300000	289500	294566	0.0350	1559	833	0.0080	133	2725	4.875	2.982	1100	8784	625	200	85	1400	1500	102	295	225	525	5066	598	2400	2499	600	0.01750	2500	0.00550	360	FHAL	OK	200.00
2447	333	2	455000	364000	364000	0.2000	2067	1250	0.0080	0	3620	5.500	2.051	1100	7466	625	200	85	1600	2315	200	\N	500	525	0	834	3640	3750	910	0.00000	2500	0.00000	360	Conforming30DownL	TX	303.33
2332	321	7	400000	400000	409200	0.0000	2421	833	0.0080	0	3521	5.875	0.118	1100	483	625	200	85	1400	1800	102	409	225	525	9200	1002	3200	2499	800	0.02300	2500	0.00000	360	VAH	OK	266.67
2848	375	2	200000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	FHA	OK	\N
2679	356	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2382	326	7	300000	300000	306900	0.0000	1815	833	0.0080	0	2848	5.875	0.118	1100	362	625	200	85	1400	1500	102	307	225	525	6900	751	2400	2499	600	0.02300	2500	0.00000	360	VAH	OK	200.00
2333	321	8	400000	400000	409200	0.0000	2166	833	0.0080	0	3266	4.875	2.681	1100	10971	625	200	85	1400	1800	102	409	225	525	9200	831	3200	2499	800	0.02300	2500	0.00000	360	VAL	OK	266.67
2849	375	3	200000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	VA	OK	\N
2448	333	3	455000	432250	432250	0.0500	2591	1250	0.0080	104	4248	5.999	0.164	1100	709	625	200	85	1600	2315	200	\N	500	525	0	1080	3640	3750	910	0.00000	2500	0.00290	360	Conforming5DownH	TX	303.33
2383	326	8	300000	300000	306900	0.0000	1624	833	0.0080	0	2657	4.875	2.681	1100	8228	625	200	85	1400	1500	102	307	225	525	6900	623	2400	2499	600	0.02300	2500	0.00000	360	VAL	OK	200.00
2561	344	6	275000	265375	270019	0.0350	1429	1000	0.0080	122	2734	4.875	2.982	1100	8052	625	200	85	1400	1425	102	270	225	525	4644	548	2200	3000	550	0.01750	2500	0.00550	360	FHAL	OK	183.33
2850	375	4	200000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	USDA	OK	\N
2851	376	1	500000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	Conforming	TX	\N
2449	333	4	455000	432250	432250	0.0500	2454	1250	0.0080	104	4111	5.500	2.051	1100	8865	625	200	85	1600	2315	200	\N	500	525	0	991	3640	3750	910	0.00000	2500	0.00290	360	Conforming5DownL	TX	303.33
2852	376	2	500000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	FHA	TX	\N
2680	356	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2562	344	7	275000	275000	281325	0.0000	1664	1000	0.0080	0	2847	5.875	0.118	1100	332	625	200	85	1400	1425	102	281	225	525	6325	689	2200	3000	550	0.02300	2500	0.00000	360	VAH	OK	183.33
2853	376	3	500000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	VA	TX	\N
2854	376	4	500000	\N	\N	\N	\N	1000	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	USDA	TX	\N
2681	356	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2855	377	1	200000	160000	160000	0.2000	959	2000	0.0080	0	3092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	6000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2334	321	9	400000	400000	404000	0.0000	2326	833	0.0080	117	3543	5.625	-0.132	1100	-533	625	200	85	1400	1800	102	404	225	525	4000	947	3200	2499	800	0.01000	2500	0.00350	360	USDAH	OK	266.67
2384	326	9	300000	300000	303000	0.0000	1744	833	0.0080	88	2865	5.625	-0.132	1100	-400	625	200	85	1400	1500	102	303	225	525	3000	710	2400	2499	600	0.01000	2500	0.00350	360	USDAH	OK	200.00
2292	317	7	250000	250000	255750	0.0000	1513	1000	0.0080	0	2680	5.875	0.118	1100	302	625	200	85	1600	1290	200	\N	500	525	5750	626	2000	3000	500	0.02300	2500	0.00000	360	VAH	TX	166.67
2450	333	5	455000	439075	446759	0.0350	2572	1250	0.0080	201	4326	5.625	-0.132	1100	-590	625	200	85	1600	2315	200	\N	500	525	7684	1047	3640	3750	910	0.01750	2500	0.00550	360	FHAH	TX	303.33
2335	321	10	400000	400000	404000	0.0000	2138	833	0.0080	117	3355	4.875	2.982	1100	12047	625	200	85	1400	1800	102	404	225	525	4000	821	3200	2499	800	0.01000	2500	0.00350	360	USDAL	OK	266.67
2293	317	8	250000	250000	255750	0.0000	1353	1000	0.0080	0	2520	4.875	2.681	1100	6857	625	200	85	1600	1290	200	\N	500	525	5750	519	2000	3000	500	0.02300	2500	0.00000	360	VAL	TX	166.67
2338	322	3	200000	190000	190000	0.0500	1139	750	0.0080	46	2068	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	2250	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2294	317	9	250000	250000	252500	0.0000	1454	1000	0.0080	73	2694	5.625	-0.132	1100	-333	625	200	85	1600	1290	200	\N	500	525	2500	592	2000	3000	500	0.01000	2500	0.00350	360	USDAH	TX	166.67
2385	326	10	300000	300000	303000	0.0000	1604	833	0.0080	88	2725	4.875	2.982	1100	9035	625	200	85	1400	1500	102	303	225	525	3000	615	2400	2499	600	0.01000	2500	0.00350	360	USDAL	OK	200.00
2339	322	4	200000	190000	190000	0.0500	1079	750	0.0080	46	2008	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	2250	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2295	317	10	250000	250000	252500	0.0000	1336	1000	0.0080	73	2576	4.875	2.982	1100	7530	625	200	85	1600	1290	200	\N	500	525	2500	513	2000	3000	500	0.01000	2500	0.00350	360	USDAL	TX	166.67
2563	344	8	275000	275000	281325	0.0000	1489	1000	0.0080	0	2672	4.875	2.681	1100	7542	625	200	85	1400	1425	102	281	225	525	6325	571	2200	3000	550	0.02300	2500	0.00000	360	VAL	OK	183.33
2451	333	6	455000	439075	446759	0.0350	2364	1250	0.0080	201	4118	4.875	2.982	1100	13322	625	200	85	1600	2315	200	\N	500	525	7684	907	3640	3750	910	0.01750	2500	0.00550	360	FHAL	TX	303.33
2340	322	5	200000	193000	196378	0.0350	1130	750	0.0080	88	2101	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	2250	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2386	327	1	300000	240000	240000	0.2000	1439	833	0.0080	0	2472	5.999	0.164	1100	394	625	200	85	1400	1500	102	240	225	525	0	600	2400	2499	600	0.00000	2500	0.00000	360	Conforming30DownH	OK	200.00
2531	341	6	100000	96500	98189	0.0350	520	100	0.0080	44	731	4.875	2.982	1100	2928	625	200	85	1400	900	102	98	225	525	1689	199	800	300	200	0.01750	2500	0.00550	360	FHAL	OK	66.67
2341	322	6	200000	193000	196378	0.0350	1039	750	0.0080	88	2010	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	2250	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2387	327	2	300000	240000	240000	0.2000	1363	833	0.0080	0	2396	5.500	2.051	1100	4922	625	200	85	1400	1500	102	240	225	525	0	550	2400	2499	600	0.00000	2500	0.00000	360	Conforming30DownL	OK	200.00
2342	322	7	200000	200000	204600	0.0000	1210	750	0.0080	0	2093	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	2250	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2856	377	2	200000	160000	160000	0.2000	908	2000	0.0080	0	3041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	6000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2452	333	7	455000	455000	465465	0.0000	2753	1250	0.0080	0	4306	5.875	0.118	1100	549	625	200	85	1600	2315	200	\N	500	525	10465	1139	3640	3750	910	0.02300	2500	0.00000	360	VAH	TX	303.33
2388	327	3	300000	285000	285000	0.0500	1709	833	0.0080	69	2811	5.999	0.164	1100	467	625	200	85	1400	1500	102	285	225	525	0	712	2400	2499	600	0.00000	2500	0.00290	360	Conforming5DownH	OK	200.00
2682	356	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2532	341	7	100000	100000	102300	0.0000	605	100	0.0080	0	772	5.875	0.118	1100	121	625	200	85	1400	900	102	102	225	525	2300	250	800	300	200	0.02300	2500	0.00000	360	VAH	OK	66.67
2453	333	8	455000	455000	465465	0.0000	2463	1250	0.0080	0	4016	4.875	2.681	1100	12479	625	200	85	1600	2315	200	\N	500	525	10465	945	3640	3750	910	0.02300	2500	0.00000	360	VAL	TX	303.33
2564	344	9	275000	275000	277750	0.0000	1599	1000	0.0080	80	2862	5.625	-0.132	1100	-367	625	200	85	1400	1425	102	278	225	525	2750	651	2200	3000	550	0.01000	2500	0.00350	360	USDAH	OK	183.33
2533	341	8	100000	100000	102300	0.0000	541	100	0.0080	0	708	4.875	2.681	1100	2743	625	200	85	1400	900	102	102	225	525	2300	208	800	300	200	0.02300	2500	0.00000	360	VAL	OK	66.67
2565	344	10	275000	275000	277750	0.0000	1470	1000	0.0080	80	2733	4.875	2.982	1100	8283	625	200	85	1400	1425	102	278	225	525	2750	564	2200	3000	550	0.01000	2500	0.00350	360	USDAL	OK	183.33
2683	356	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2857	377	3	200000	190000	190000	0.0500	1139	2000	0.0080	46	3318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	6000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2343	322	8	200000	200000	204600	0.0000	1083	750	0.0080	0	1966	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	2250	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2389	327	4	300000	285000	285000	0.0500	1618	833	0.0080	69	2720	5.500	2.051	1100	5845	625	200	85	1400	1500	102	285	225	525	0	653	2400	2499	600	0.00000	2500	0.00290	360	Conforming5DownL	OK	200.00
2344	322	9	200000	200000	202000	0.0000	1163	750	0.0080	58	2104	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	2250	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2454	333	9	455000	455000	459550	0.0000	2645	1250	0.0080	133	4331	5.625	-0.132	1100	-607	625	200	85	1600	2315	200	\N	500	525	4550	1077	3640	3750	910	0.01000	2500	0.00350	360	USDAH	TX	303.33
2345	322	10	200000	200000	202000	0.0000	1069	750	0.0080	58	2010	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	2250	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2390	327	5	300000	289500	294566	0.0350	1696	833	0.0080	133	2862	5.625	-0.132	1100	-389	625	200	85	1400	1500	102	295	225	525	5066	690	2400	2499	600	0.01750	2500	0.00550	360	FHAH	OK	200.00
2346	323	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2534	341	9	100000	100000	101000	0.0000	581	100	0.0080	29	777	5.625	-0.132	1100	-133	625	200	85	1400	900	102	101	225	525	1000	237	800	300	200	0.01000	2500	0.00350	360	USDAH	OK	66.67
2455	333	10	455000	455000	459550	0.0000	2432	1250	0.0080	133	4118	4.875	2.982	1100	13704	625	200	85	1600	2315	200	\N	500	525	4550	933	3640	3750	910	0.01000	2500	0.00350	360	USDAL	TX	303.33
2391	327	6	300000	289500	294566	0.0350	1559	833	0.0080	133	2725	4.875	2.982	1100	8784	625	200	85	1400	1500	102	295	225	525	5066	598	2400	2499	600	0.01750	2500	0.00550	360	FHAL	OK	200.00
2347	323	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2483	336	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2757	364	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2348	323	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2392	327	7	300000	300000	306900	0.0000	1815	833	0.0080	0	2848	5.875	0.118	1100	362	625	200	85	1400	1500	102	307	225	525	6900	751	2400	2499	600	0.02300	2500	0.00000	360	VAH	OK	200.00
2566	345	1	300000	240000	240000	0.2000	1439	250	0.0080	0	1889	5.999	0.164	1100	394	625	200	85	1400	1500	102	240	225	525	0	600	2400	750	600	0.00000	2500	0.00000	360	Conforming30DownH	OK	200.00
2349	323	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2484	336	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2393	327	8	300000	300000	306900	0.0000	1624	833	0.0080	0	2657	4.875	2.681	1100	8228	625	200	85	1400	1500	102	307	225	525	6900	623	2400	2499	600	0.02300	2500	0.00000	360	VAL	OK	200.00
2535	341	10	100000	100000	101000	0.0000	535	100	0.0080	29	731	4.875	2.982	1100	3012	625	200	85	1400	900	102	101	225	525	1000	205	800	300	200	0.01000	2500	0.00350	360	USDAL	OK	66.67
2684	356	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2485	336	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2567	345	2	300000	240000	240000	0.2000	1363	250	0.0080	0	1813	5.500	2.051	1100	4922	625	200	85	1400	1500	102	240	225	525	0	550	2400	750	600	0.00000	2500	0.00000	360	Conforming30DownL	OK	200.00
2858	377	4	200000	190000	190000	0.0500	1079	2000	0.0080	46	3258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	6000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2685	356	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2568	345	3	300000	285000	285000	0.0500	1709	250	0.0080	69	2228	5.999	0.164	1100	467	625	200	85	1400	1500	102	285	225	525	0	712	2400	750	600	0.00000	2500	0.00290	360	Conforming5DownH	OK	200.00
2758	364	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2859	377	5	200000	193000	196378	0.0350	1130	2000	0.0080	88	3351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	6000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2350	323	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2394	327	9	300000	300000	303000	0.0000	1744	833	0.0080	88	2865	5.625	-0.132	1100	-400	625	200	85	1400	1500	102	303	225	525	3000	710	2400	2499	600	0.01000	2500	0.00350	360	USDAH	OK	200.00
2351	323	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2395	327	10	300000	300000	303000	0.0000	1604	833	0.0080	88	2725	4.875	2.982	1100	9035	625	200	85	1400	1500	102	303	225	525	3000	615	2400	2499	600	0.01000	2500	0.00350	360	USDAL	OK	200.00
2352	323	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2400	328	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2456	334	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2353	323	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2569	345	4	300000	285000	285000	0.0500	1618	250	0.0080	69	2137	5.500	2.051	1100	5845	625	200	85	1400	1500	102	285	225	525	0	653	2400	750	600	0.00000	2500	0.00290	360	Conforming5DownL	OK	200.00
2401	328	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2354	323	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2457	334	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2355	323	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2402	328	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2686	357	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2570	345	5	300000	289500	294566	0.0350	1696	250	0.0080	133	2279	5.625	-0.132	1100	-389	625	200	85	1400	1500	102	295	225	525	5066	690	2400	750	600	0.01750	2500	0.00550	360	FHAH	OK	200.00
2403	328	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2458	334	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2860	377	6	200000	193000	196378	0.0350	1039	2000	0.0080	88	3260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	6000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2459	334	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2571	345	6	300000	289500	294566	0.0350	1559	250	0.0080	133	2142	4.875	2.982	1100	8784	625	200	85	1400	1500	102	295	225	525	5066	598	2400	750	600	0.01750	2500	0.00550	360	FHAL	OK	200.00
2687	357	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2861	377	7	200000	200000	204600	0.0000	1210	2000	0.0080	0	3343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	6000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2688	357	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2404	328	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2460	334	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2405	328	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2572	345	7	300000	300000	306900	0.0000	1815	250	0.0080	0	2265	5.875	0.118	1100	362	625	200	85	1400	1500	102	307	225	525	6900	751	2400	750	600	0.02300	2500	0.00000	360	VAH	OK	200.00
2623	350	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2406	329	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2461	334	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2536	342	1	100000	80000	80000	0.2000	480	833	0.0080	0	1380	5.999	0.164	1100	131	625	200	85	1400	900	102	80	225	525	0	200	800	2499	200	0.00000	2500	0.00000	360	Conforming30DownH	OK	66.67
2407	329	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2462	334	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2408	329	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2573	345	8	300000	300000	306900	0.0000	1624	250	0.0080	0	2074	4.875	2.681	1100	8228	625	200	85	1400	1500	102	307	225	525	6900	623	2400	750	600	0.02300	2500	0.00000	360	VAL	OK	200.00
2537	342	2	100000	80000	80000	0.2000	454	833	0.0080	0	1354	5.500	2.051	1100	1641	625	200	85	1400	900	102	80	225	525	0	183	800	2499	200	0.00000	2500	0.00000	360	Conforming30DownL	OK	66.67
2409	329	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2463	334	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2862	377	8	200000	200000	204600	0.0000	1083	2000	0.0080	0	3216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	6000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2410	329	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2624	350	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2464	334	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2574	345	9	300000	300000	303000	0.0000	1744	250	0.0080	88	2282	5.625	-0.132	1100	-400	625	200	85	1400	1500	102	303	225	525	3000	710	2400	750	600	0.01000	2500	0.00350	360	USDAH	OK	200.00
2538	342	3	100000	95000	95000	0.0500	570	833	0.0080	23	1493	5.999	0.164	1100	156	625	200	85	1400	900	102	95	225	525	0	237	800	2499	200	0.00000	2500	0.00290	360	Conforming5DownH	OK	66.67
2689	357	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2539	342	4	100000	95000	95000	0.0500	539	833	0.0080	23	1462	5.500	2.051	1100	1948	625	200	85	1400	900	102	95	225	525	0	218	800	2499	200	0.00000	2500	0.00290	360	Conforming5DownL	OK	66.67
2575	345	10	300000	300000	303000	0.0000	1604	250	0.0080	88	2142	4.875	2.982	1100	9035	625	200	85	1400	1500	102	303	225	525	3000	615	2400	750	600	0.01000	2500	0.00350	360	USDAL	OK	200.00
2625	350	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2690	357	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2863	377	9	200000	200000	202000	0.0000	1163	2000	0.0080	58	3354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	6000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2465	334	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2411	329	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2412	329	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2691	357	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2466	335	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2413	329	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2576	346	1	300000	240000	240000	0.2000	1439	583	0.0080	0	2222	5.999	0.164	1100	394	625	200	85	1400	1500	102	240	225	525	0	600	2400	1749	600	0.00000	2500	0.00000	360	Conforming30DownH	OK	200.00
2864	377	10	200000	200000	202000	0.0000	1069	2000	0.0080	58	3260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	6000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2467	335	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2414	329	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2415	329	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2577	346	2	300000	240000	240000	0.2000	1363	583	0.0080	0	2146	5.500	2.051	1100	4922	625	200	85	1400	1500	102	240	225	525	0	550	2400	1749	600	0.00000	2500	0.00000	360	Conforming30DownL	OK	200.00
2468	335	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2692	357	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2469	335	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2578	346	3	300000	285000	285000	0.0500	1709	583	0.0080	69	2561	5.999	0.164	1100	467	625	200	85	1400	1500	102	285	225	525	0	712	2400	1749	600	0.00000	2500	0.00290	360	Conforming5DownH	OK	200.00
2865	383	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2470	335	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2693	357	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2579	346	4	300000	285000	285000	0.0500	1618	583	0.0080	69	2470	5.500	2.051	1100	5845	625	200	85	1400	1500	102	285	225	525	0	653	2400	1749	600	0.00000	2500	0.00290	360	Conforming5DownL	OK	200.00
2694	357	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2866	383	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2417	330	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2486	337	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2471	335	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2418	330	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2580	346	5	300000	289500	294566	0.0350	1696	583	0.0080	133	2612	5.625	-0.132	1100	-389	625	200	85	1400	1500	102	295	225	525	5066	690	2400	1749	600	0.01750	2500	0.00550	360	FHAH	OK	200.00
2419	330	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2472	335	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2487	337	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2420	330	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2473	335	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2421	330	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2695	357	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2488	337	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2422	330	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2474	335	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2581	346	6	300000	289500	294566	0.0350	1559	583	0.0080	133	2475	4.875	2.982	1100	8784	625	200	85	1400	1500	102	295	225	525	5066	598	2400	1749	600	0.01750	2500	0.00550	360	FHAL	OK	200.00
2423	330	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2867	383	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2475	335	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2795	367	10	275000	275000	277750	0.0000	1470	1000	0.0080	80	2733	4.875	2.982	1100	8283	625	200	85	1600	1415	200	\N	500	525	2750	564	2200	3000	550	0.01000	2500	0.00350	360	USDAL	TX	183.33
2489	337	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2696	358	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2582	346	7	300000	300000	306900	0.0000	1815	583	0.0080	0	2598	5.875	0.118	1100	362	625	200	85	1400	1500	102	307	225	525	6900	751	2400	1749	600	0.02300	2500	0.00000	360	VAH	OK	200.00
2583	346	8	300000	300000	306900	0.0000	1624	583	0.0080	0	2407	4.875	2.681	1100	8228	625	200	85	1400	1500	102	307	225	525	6900	623	2400	1749	600	0.02300	2500	0.00000	360	VAL	OK	200.00
2697	358	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2868	383	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2796	368	1	220000	176000	176000	0.2000	1055	1000	0.0080	0	2202	5.999	0.164	1100	289	625	200	85	1600	1140	200	\N	500	525	0	440	1760	3000	440	0.00000	2500	0.00000	360	Conforming30DownH	TX	146.67
2424	330	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2476	336	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2425	330	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2584	346	9	300000	300000	303000	0.0000	1744	583	0.0080	88	2615	5.625	-0.132	1100	-400	625	200	85	1400	1500	102	303	225	525	3000	710	2400	1749	600	0.01000	2500	0.00350	360	USDAH	OK	200.00
2698	358	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2477	336	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2869	383	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2585	346	10	300000	300000	303000	0.0000	1604	583	0.0080	88	2475	4.875	2.982	1100	9035	625	200	85	1400	1500	102	303	225	525	3000	615	2400	1749	600	0.01000	2500	0.00350	360	USDAL	OK	200.00
2478	336	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2811	369	6	300000	289500	294566	0.0350	1559	750	0.0080	133	2642	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	2250	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2699	358	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2479	336	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2586	347	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2480	336	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2587	347	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2481	336	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2700	358	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2961	397	9	200000	200000	202000	0.0000	1163	833	0.0080	58	2187	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	2499	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2812	369	7	300000	300000	306900	0.0000	1815	750	0.0080	0	2765	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	2250	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2588	347	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2870	383	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2701	358	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2813	369	8	300000	300000	306900	0.0000	1624	750	0.0080	0	2574	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	2250	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2871	383	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2962	397	10	200000	200000	202000	0.0000	1069	833	0.0080	58	2093	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	2499	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2490	337	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2589	347	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2491	337	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2702	358	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2963	398	1	200000	160000	160000	0.2000	959	1083	0.0080	0	2175	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3249	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2492	337	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2590	347	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2872	383	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2493	337	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2703	358	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2591	347	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2494	337	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2495	337	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2592	347	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2704	358	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2873	383	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2593	347	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2964	398	2	200000	160000	160000	0.2000	908	1083	0.0080	0	2124	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3249	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2705	358	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2759	364	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2874	383	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2965	398	3	200000	190000	190000	0.0500	1139	1083	0.0080	46	2401	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3249	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2594	347	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2497	338	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2498	338	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2595	347	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2626	351	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2499	338	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2706	359	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2500	338	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2627	351	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2875	388	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2501	338	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2707	359	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2628	351	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2502	338	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2503	338	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2629	351	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2876	388	2	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2708	359	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2709	359	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2877	389	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2505	338	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2710	359	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2596	348	1	500000	400000	400000	0.2000	2398	1000	0.0080	0	3731	5.999	0.164	1100	656	625	200	85	1600	2540	200	\N	500	525	0	1000	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownH	TX	333.33
2506	339	1	500000	400000	400000	0.2000	2398	833	0.0080	0	3564	5.999	0.164	1100	656	625	200	85	1600	2540	200	\N	500	525	0	1000	4000	2499	1000	0.00000	2500	0.00000	360	Conforming30DownH	TX	333.33
2878	389	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2507	339	2	500000	400000	400000	0.2000	2271	833	0.0080	0	3437	5.500	2.051	1100	8204	625	200	85	1600	2540	200	\N	500	525	0	917	4000	2499	1000	0.00000	2500	0.00000	360	Conforming30DownL	TX	333.33
2597	348	2	500000	400000	400000	0.2000	2271	1000	0.0080	0	3604	5.500	2.051	1100	8204	625	200	85	1600	2540	200	\N	500	525	0	917	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownL	TX	333.33
2508	339	3	500000	475000	475000	0.0500	2848	833	0.0080	115	4129	5.999	0.164	1100	779	625	200	85	1600	2540	200	\N	500	525	0	1187	4000	2499	1000	0.00000	2500	0.00290	360	Conforming5DownH	TX	333.33
2711	359	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2598	348	3	500000	475000	475000	0.0500	2848	1000	0.0080	115	4296	5.999	0.164	1100	779	625	200	85	1600	2540	200	\N	500	525	0	1187	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownH	TX	333.33
2509	339	4	500000	475000	475000	0.0500	2697	833	0.0080	115	3978	5.500	2.051	1100	9742	625	200	85	1600	2540	200	\N	500	525	0	1089	4000	2499	1000	0.00000	2500	0.00290	360	Conforming5DownL	TX	333.33
2879	389	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2510	339	5	500000	482500	490944	0.0350	2826	833	0.0080	221	4213	5.625	-0.132	1100	-648	625	200	85	1600	2540	200	\N	500	525	8444	1151	4000	2499	1000	0.01750	2500	0.00550	360	FHAH	TX	333.33
2712	359	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2599	348	4	500000	475000	475000	0.0500	2697	1000	0.0080	115	4145	5.500	2.051	1100	9742	625	200	85	1600	2540	200	\N	500	525	0	1089	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownL	TX	333.33
2511	339	6	500000	482500	490944	0.0350	2598	833	0.0080	221	3985	4.875	2.982	1100	14640	625	200	85	1600	2540	200	\N	500	525	8444	997	4000	2499	1000	0.01750	2500	0.00550	360	FHAL	TX	333.33
2600	348	5	500000	482500	490944	0.0350	2826	1000	0.0080	221	4380	5.625	-0.132	1100	-648	625	200	85	1600	2540	200	\N	500	525	8444	1151	4000	3000	1000	0.01750	2500	0.00550	360	FHAH	TX	333.33
2713	359	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2880	389	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2881	389	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2513	339	8	500000	500000	511500	0.0000	2707	833	0.0080	0	3873	4.875	2.681	1100	13713	625	200	85	1600	2540	200	\N	500	525	11500	1039	4000	2499	1000	0.02300	2500	0.00000	360	VAL	TX	333.33
2714	359	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2601	348	6	500000	482500	490944	0.0350	2598	1000	0.0080	221	4152	4.875	2.982	1100	14640	625	200	85	1600	2540	200	\N	500	525	8444	997	4000	3000	1000	0.01750	2500	0.00550	360	FHAL	TX	333.33
2514	339	9	500000	500000	505000	0.0000	2907	833	0.0080	146	4219	5.625	-0.132	1100	-667	625	200	85	1600	2540	200	\N	500	525	5000	1184	4000	2499	1000	0.01000	2500	0.00350	360	USDAH	TX	333.33
2515	339	10	500000	500000	505000	0.0000	2673	833	0.0080	146	3985	4.875	2.982	1100	15059	625	200	85	1600	2540	200	\N	500	525	5000	1026	4000	2499	1000	0.01000	2500	0.00350	360	USDAL	TX	333.33
2602	348	7	500000	500000	511500	0.0000	3026	1000	0.0080	0	4359	5.875	0.118	1100	604	625	200	85	1600	2540	200	\N	500	525	11500	1252	4000	3000	1000	0.02300	2500	0.00000	360	VAH	TX	333.33
2715	359	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2882	389	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2603	348	8	500000	500000	511500	0.0000	2707	1000	0.0080	0	4040	4.875	2.681	1100	13713	625	200	85	1600	2540	200	\N	500	525	11500	1039	4000	3000	1000	0.02300	2500	0.00000	360	VAL	TX	333.33
2716	360	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2604	348	9	500000	500000	505000	0.0000	2907	1000	0.0080	146	4386	5.625	-0.132	1100	-667	625	200	85	1600	2540	200	\N	500	525	5000	1184	4000	3000	1000	0.01000	2500	0.00350	360	USDAH	TX	333.33
2883	389	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2605	348	10	500000	500000	505000	0.0000	2673	1000	0.0080	146	4152	4.875	2.982	1100	15059	625	200	85	1600	2540	200	\N	500	525	5000	1026	4000	3000	1000	0.01000	2500	0.00350	360	USDAL	TX	333.33
2717	360	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2606	349	1	200000	160000	160000	0.2000	959	167	0.0080	0	1259	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	501	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2718	360	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2884	389	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2885	389	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2719	360	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2607	349	2	200000	160000	160000	0.2000	908	167	0.0080	0	1208	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	501	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2518	340	3	236570	224742	224742	0.0500	1347	748	0.0080	54	2307	5.999	0.164	1100	369	625	200	85	1400	1310	102	225	225	525	0	562	1893	2244	473	0.00000	2500	0.00290	360	Conforming5DownH	OK	157.71
2519	340	4	236570	224742	224742	0.0500	1276	748	0.0080	54	2236	5.500	2.051	1100	4609	625	200	85	1400	1310	102	225	225	525	0	515	1893	2244	473	0.00000	2500	0.00290	360	Conforming5DownL	OK	157.71
2608	349	3	200000	190000	190000	0.0500	1139	167	0.0080	46	1485	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	501	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2886	389	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2520	340	5	236570	228290	232285	0.0350	1337	748	0.0080	105	2348	5.625	-0.132	1100	-307	625	200	85	1400	1310	102	232	225	525	3995	544	1893	2244	473	0.01750	2500	0.00550	360	FHAH	OK	157.71
2720	360	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2609	349	4	200000	190000	190000	0.0500	1079	167	0.0080	46	1425	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	501	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2521	340	6	236570	228290	232285	0.0350	1229	748	0.0080	105	2240	4.875	2.982	1100	6927	625	200	85	1400	1310	102	232	225	525	3995	472	1893	2244	473	0.01750	2500	0.00550	360	FHAL	OK	157.71
2998	401	8	200000	200000	204600	0.0000	1083	833	0.0080	0	2049	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	2499	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2522	340	7	236570	236570	242011	0.0000	1432	748	0.0080	0	2338	5.875	0.118	1100	286	625	200	85	1400	1310	102	242	225	525	5441	592	1893	2244	473	0.02300	2500	0.00000	360	VAH	OK	157.71
2721	360	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2610	349	5	200000	193000	196378	0.0350	1130	167	0.0080	88	1518	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	501	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2523	340	8	236570	236570	242011	0.0000	1281	748	0.0080	0	2187	4.875	2.681	1100	6488	625	200	85	1400	1310	102	242	225	525	5441	492	1893	2244	473	0.02300	2500	0.00000	360	VAL	OK	157.71
2887	390	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2611	349	6	200000	193000	196378	0.0350	1039	167	0.0080	88	1427	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	501	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2722	360	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2612	349	7	200000	200000	204600	0.0000	1210	167	0.0080	0	1510	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	501	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2999	402	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2888	390	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2723	360	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
3000	402	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2524	340	9	236570	236570	238936	0.0000	1375	748	0.0080	69	2350	5.625	-0.132	1100	-315	625	200	85	1400	1310	102	239	225	525	2366	560	1893	2244	473	0.01000	2500	0.00350	360	USDAH	OK	157.71
2724	360	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2525	340	10	236570	236570	238936	0.0000	1264	748	0.0080	69	2239	4.875	2.982	1100	7125	625	200	85	1400	1310	102	239	225	525	2366	485	1893	2244	473	0.01000	2500	0.00350	360	USDAL	OK	157.71
2613	349	8	200000	200000	204600	0.0000	1083	167	0.0080	0	1383	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	501	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2889	390	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2526	341	1	100000	80000	80000	0.2000	480	100	0.0080	0	647	5.999	0.164	1100	131	625	200	85	1400	900	102	80	225	525	0	200	800	300	200	0.00000	2500	0.00000	360	Conforming30DownH	OK	66.67
2614	349	9	200000	200000	202000	0.0000	1163	167	0.0080	58	1521	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	501	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2527	341	2	100000	80000	80000	0.2000	454	100	0.0080	0	621	5.500	2.051	1100	1641	625	200	85	1400	900	102	80	225	525	0	183	800	300	200	0.00000	2500	0.00000	360	Conforming30DownL	OK	66.67
2725	360	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2760	364	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2528	341	3	100000	95000	95000	0.0500	570	100	0.0080	23	760	5.999	0.164	1100	156	625	200	85	1400	900	102	95	225	525	0	237	800	300	200	0.00000	2500	0.00290	360	Conforming5DownH	OK	66.67
2615	349	10	200000	200000	202000	0.0000	1069	167	0.0080	58	1427	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	501	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2630	351	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2529	341	4	100000	95000	95000	0.0500	539	100	0.0080	23	729	5.500	2.051	1100	1948	625	200	85	1400	900	102	95	225	525	0	218	800	300	200	0.00000	2500	0.00290	360	Conforming5DownL	OK	66.67
2890	390	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2631	351	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2530	341	5	100000	96500	98189	0.0350	565	100	0.0080	44	776	5.625	-0.132	1100	-130	625	200	85	1400	900	102	98	225	525	1689	230	800	300	200	0.01750	2500	0.00550	360	FHAH	OK	66.67
2761	364	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2632	351	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2762	364	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2891	390	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2892	390	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2540	342	5	100000	96500	98189	0.0350	565	833	0.0080	44	1509	5.625	-0.132	1100	-130	625	200	85	1400	900	102	98	225	525	1689	230	800	2499	200	0.01750	2500	0.00550	360	FHAH	OK	66.67
2616	350	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2541	342	6	100000	96500	98189	0.0350	520	833	0.0080	44	1464	4.875	2.982	1100	2928	625	200	85	1400	900	102	98	225	525	1689	199	800	2499	200	0.01750	2500	0.00550	360	FHAL	OK	66.67
2726	361	1	200000	160000	160000	0.2000	959	83	0.0080	0	1175	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	249	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2542	342	7	100000	100000	102300	0.0000	605	833	0.0080	0	1505	5.875	0.118	1100	121	625	200	85	1400	900	102	102	225	525	2300	250	800	2499	200	0.02300	2500	0.00000	360	VAH	OK	66.67
2617	350	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2893	390	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2543	342	8	100000	100000	102300	0.0000	541	833	0.0080	0	1441	4.875	2.681	1100	2743	625	200	85	1400	900	102	102	225	525	2300	208	800	2499	200	0.02300	2500	0.00000	360	VAL	OK	66.67
2727	361	2	200000	160000	160000	0.2000	908	83	0.0080	0	1124	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	249	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2618	350	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2544	342	9	100000	100000	101000	0.0000	581	833	0.0080	29	1510	5.625	-0.132	1100	-133	625	200	85	1400	900	102	101	225	525	1000	237	800	2499	200	0.01000	2500	0.00350	360	USDAH	OK	66.67
3001	402	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2545	342	10	100000	100000	101000	0.0000	535	833	0.0080	29	1464	4.875	2.982	1100	3012	625	200	85	1400	900	102	101	225	525	1000	205	800	2499	200	0.01000	2500	0.00350	360	USDAL	OK	66.67
2619	350	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2894	390	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2728	361	3	200000	190000	190000	0.0500	1139	83	0.0080	46	1401	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	249	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2620	350	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2729	361	4	200000	190000	190000	0.0500	1079	83	0.0080	46	1341	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	249	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2895	391	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2633	351	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2896	391	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2730	361	5	200000	193000	196378	0.0350	1130	83	0.0080	88	1434	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	249	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2634	351	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2731	361	6	200000	193000	196378	0.0350	1039	83	0.0080	88	1343	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	249	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2635	351	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2897	391	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2636	352	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2732	361	7	200000	200000	204600	0.0000	1210	83	0.0080	0	1426	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	249	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3009	403	1	200000	160000	160000	0.2000	959	1083	0.0080	0	2175	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3249	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2637	352	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2898	391	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2733	361	8	200000	200000	204600	0.0000	1083	83	0.0080	0	1299	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	249	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2638	352	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2639	352	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2734	361	9	200000	200000	202000	0.0000	1163	83	0.0080	58	1437	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	249	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
3010	403	2	200000	160000	160000	0.2000	908	1083	0.0080	0	2124	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3249	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2899	391	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2900	391	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
3011	403	3	200000	190000	190000	0.0500	1139	1083	0.0080	46	2401	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3249	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2735	361	10	200000	200000	202000	0.0000	1069	83	0.0080	58	1343	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	249	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2640	352	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2641	352	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2736	362	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1400	1500	102	240	225	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	OK	200.00
2901	391	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2642	352	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2737	362	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1400	1500	102	240	225	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	OK	200.00
2643	352	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2902	391	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2644	352	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2738	362	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1400	1500	102	285	225	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	OK	200.00
2645	352	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2739	362	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1400	1500	102	285	225	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	OK	200.00
2903	391	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2740	362	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1400	1500	102	295	225	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	OK	200.00
2904	391	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2648	353	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2763	364	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2741	362	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1400	1500	102	295	225	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	OK	200.00
2649	353	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2905	392	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2650	353	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2742	362	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1400	1500	102	307	225	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	OK	200.00
2764	364	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2651	353	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2743	362	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1400	1500	102	307	225	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	OK	200.00
2652	353	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2906	392	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2765	364	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2653	353	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2744	362	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1400	1500	102	303	225	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	OK	200.00
2654	353	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2770	365	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2745	362	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1400	1500	102	303	225	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	OK	200.00
2771	365	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2907	392	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2908	392	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2655	353	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2656	354	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2746	363	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2766	365	1	300000	240000	240000	0.2000	1439	1000	0.0080	0	2639	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2657	354	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2909	392	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2747	363	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2658	354	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2767	365	2	300000	240000	240000	0.2000	1363	1000	0.0080	0	2563	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	3000	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2659	354	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2748	363	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2660	354	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2910	392	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2749	363	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2661	354	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2768	365	3	300000	285000	285000	0.0500	1709	1000	0.0080	69	2978	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2750	363	5	300000	289500	294566	0.0350	1696	1000	0.0080	133	3029	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	3000	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2911	392	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2769	365	4	300000	285000	285000	0.0500	1618	1000	0.0080	69	2887	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	3000	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2912	392	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2662	354	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2751	363	6	300000	289500	294566	0.0350	1559	1000	0.0080	133	2892	4.875	2.982	1100	8784	625	200	85	1600	1540	200	\N	500	525	5066	598	2400	3000	600	0.01750	2500	0.00550	360	FHAL	TX	200.00
2663	354	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2966	398	4	200000	190000	190000	0.0500	1079	1083	0.0080	46	2341	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3249	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2752	363	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2664	354	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2665	354	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2967	398	5	200000	193000	196378	0.0350	1130	1083	0.0080	88	2434	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3249	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2753	363	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2754	363	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2968	398	6	200000	193000	196378	0.0350	1039	1083	0.0080	88	2343	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3249	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2755	363	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2969	398	7	200000	200000	204600	0.0000	1210	1083	0.0080	0	2426	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3249	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2756	364	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2970	398	8	200000	200000	204600	0.0000	1083	1083	0.0080	0	2299	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3249	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2772	365	7	300000	300000	306900	0.0000	1815	1000	0.0080	0	3015	5.875	0.118	1100	362	625	200	85	1600	1540	200	\N	500	525	6900	751	2400	3000	600	0.02300	2500	0.00000	360	VAH	TX	200.00
2773	365	8	300000	300000	306900	0.0000	1624	1000	0.0080	0	2824	4.875	2.681	1100	8228	625	200	85	1600	1540	200	\N	500	525	6900	623	2400	3000	600	0.02300	2500	0.00000	360	VAL	TX	200.00
2786	367	1	275000	220000	220000	0.2000	1319	1000	0.0080	0	2502	5.999	0.164	1100	361	625	200	85	1600	1415	200	\N	500	525	0	550	2200	3000	550	0.00000	2500	0.00000	360	Conforming30DownH	TX	183.33
2774	365	9	300000	300000	303000	0.0000	1744	1000	0.0080	88	3032	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	3000	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2913	393	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2971	398	9	200000	200000	202000	0.0000	1163	1083	0.0080	58	2437	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3249	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2787	367	2	275000	220000	220000	0.2000	1249	1000	0.0080	0	2432	5.500	2.051	1100	4512	625	200	85	1600	1415	200	\N	500	525	0	504	2200	3000	550	0.00000	2500	0.00000	360	Conforming30DownL	TX	183.33
2775	365	10	300000	300000	303000	0.0000	1604	1000	0.0080	88	2892	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	3000	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2914	393	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2776	366	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1600	1040	200	\N	500	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	TX	133.33
2972	398	10	200000	200000	202000	0.0000	1069	1083	0.0080	58	2343	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3249	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2777	366	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1600	1040	200	\N	500	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	TX	133.33
2915	393	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2778	366	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1600	1040	200	\N	500	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	TX	133.33
2916	393	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2973	399	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2974	399	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2917	393	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2779	366	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1600	1040	200	\N	500	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	TX	133.33
2780	366	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1600	1040	200	\N	500	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	TX	133.33
2918	393	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2781	366	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1600	1040	200	\N	500	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	TX	133.33
2919	393	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2782	366	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1600	1040	200	\N	500	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	TX	133.33
2783	366	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1600	1040	200	\N	500	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	TX	133.33
2920	393	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2784	366	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1600	1040	200	\N	500	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	TX	133.33
2921	393	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2785	366	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1600	1040	200	\N	500	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	TX	133.33
2922	393	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2788	367	3	275000	261250	261250	0.0500	1566	1000	0.0080	63	2812	5.999	0.164	1100	428	625	200	85	1600	1415	200	\N	500	525	0	653	2200	3000	550	0.00000	2500	0.00290	360	Conforming5DownH	TX	183.33
2923	394	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2789	367	4	275000	261250	261250	0.0500	1483	1000	0.0080	63	2729	5.500	2.051	1100	5358	625	200	85	1600	1415	200	\N	500	525	0	599	2200	3000	550	0.00000	2500	0.00290	360	Conforming5DownL	TX	183.33
2790	367	5	275000	265375	270019	0.0350	1554	1000	0.0080	122	2859	5.625	-0.132	1100	-356	625	200	85	1600	1415	200	\N	500	525	4644	633	2200	3000	550	0.01750	2500	0.00550	360	FHAH	TX	183.33
2924	394	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2791	367	6	275000	265375	270019	0.0350	1429	1000	0.0080	122	2734	4.875	2.982	1100	8052	625	200	85	1600	1415	200	\N	500	525	4644	548	2200	3000	550	0.01750	2500	0.00550	360	FHAL	TX	183.33
2925	394	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2792	367	7	275000	275000	281325	0.0000	1664	1000	0.0080	0	2847	5.875	0.118	1100	332	625	200	85	1600	1415	200	\N	500	525	6325	689	2200	3000	550	0.02300	2500	0.00000	360	VAH	TX	183.33
2793	367	8	275000	275000	281325	0.0000	1489	1000	0.0080	0	2672	4.875	2.681	1100	7542	625	200	85	1600	1415	200	\N	500	525	6325	571	2200	3000	550	0.02300	2500	0.00000	360	VAL	TX	183.33
2926	394	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2794	367	9	275000	275000	277750	0.0000	1599	1000	0.0080	80	2862	5.625	-0.132	1100	-367	625	200	85	1600	1415	200	\N	500	525	2750	651	2200	3000	550	0.01000	2500	0.00350	360	USDAH	TX	183.33
2927	394	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2797	368	2	220000	176000	176000	0.2000	999	1000	0.0080	0	2146	5.500	2.051	1100	3610	625	200	85	1600	1140	200	\N	500	525	0	403	1760	3000	440	0.00000	2500	0.00000	360	Conforming30DownL	TX	146.67
2928	394	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2798	368	3	220000	209000	209000	0.0500	1253	1000	0.0080	51	2451	5.999	0.164	1100	343	625	200	85	1600	1140	200	\N	500	525	0	522	1760	3000	440	0.00000	2500	0.00290	360	Conforming5DownH	TX	146.67
2929	394	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2799	368	4	220000	209000	209000	0.0500	1187	1000	0.0080	51	2385	5.500	2.051	1100	4287	625	200	85	1600	1140	200	\N	500	525	0	479	1760	3000	440	0.00000	2500	0.00290	360	Conforming5DownL	TX	146.67
2800	368	5	220000	212300	216015	0.0350	1244	1000	0.0080	97	2488	5.625	-0.132	1100	-285	625	200	85	1600	1140	200	\N	500	525	3715	506	1760	3000	440	0.01750	2500	0.00550	360	FHAH	TX	146.67
2930	394	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2801	368	6	220000	212300	216015	0.0350	1143	1000	0.0080	97	2387	4.875	2.982	1100	6442	625	200	85	1600	1140	200	\N	500	525	3715	439	1760	3000	440	0.01750	2500	0.00550	360	FHAL	TX	146.67
2931	394	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2802	368	7	220000	220000	225060	0.0000	1331	1000	0.0080	0	2478	5.875	0.118	1100	266	625	200	85	1600	1140	200	\N	500	525	5060	551	1760	3000	440	0.02300	2500	0.00000	360	VAH	TX	146.67
2803	368	8	220000	220000	225060	0.0000	1191	1000	0.0080	0	2338	4.875	2.681	1100	6034	625	200	85	1600	1140	200	\N	500	525	5060	457	1760	3000	440	0.02300	2500	0.00000	360	VAL	TX	146.67
2932	394	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2933	395	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2804	368	9	220000	220000	222200	0.0000	1279	1000	0.0080	64	2490	5.625	-0.132	1100	-293	625	200	85	1600	1140	200	\N	500	525	2200	521	1760	3000	440	0.01000	2500	0.00350	360	USDAH	TX	146.67
2805	368	10	220000	220000	222200	0.0000	1176	1000	0.0080	64	2387	4.875	2.982	1100	6626	625	200	85	1600	1140	200	\N	500	525	2200	451	1760	3000	440	0.01000	2500	0.00350	360	USDAL	TX	146.67
2934	395	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2806	369	1	300000	240000	240000	0.2000	1439	750	0.0080	0	2389	5.999	0.164	1100	394	625	200	85	1600	1540	200	\N	500	525	0	600	2400	2250	600	0.00000	2500	0.00000	360	Conforming30DownH	TX	200.00
2935	395	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2807	369	2	300000	240000	240000	0.2000	1363	750	0.0080	0	2313	5.500	2.051	1100	4922	625	200	85	1600	1540	200	\N	500	525	0	550	2400	2250	600	0.00000	2500	0.00000	360	Conforming30DownL	TX	200.00
2808	369	3	300000	285000	285000	0.0500	1709	750	0.0080	69	2728	5.999	0.164	1100	467	625	200	85	1600	1540	200	\N	500	525	0	712	2400	2250	600	0.00000	2500	0.00290	360	Conforming5DownH	TX	200.00
2936	395	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2809	369	4	300000	285000	285000	0.0500	1618	750	0.0080	69	2637	5.500	2.051	1100	5845	625	200	85	1600	1540	200	\N	500	525	0	653	2400	2250	600	0.00000	2500	0.00290	360	Conforming5DownL	TX	200.00
2937	395	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2810	369	5	300000	289500	294566	0.0350	1696	750	0.0080	133	2779	5.625	-0.132	1100	-389	625	200	85	1600	1540	200	\N	500	525	5066	690	2400	2250	600	0.01750	2500	0.00550	360	FHAH	TX	200.00
2938	395	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2814	369	9	300000	300000	303000	0.0000	1744	750	0.0080	88	2782	5.625	-0.132	1100	-400	625	200	85	1600	1540	200	\N	500	525	3000	710	2400	2250	600	0.01000	2500	0.00350	360	USDAH	TX	200.00
2815	369	10	300000	300000	303000	0.0000	1604	750	0.0080	88	2642	4.875	2.982	1100	9035	625	200	85	1600	1540	200	\N	500	525	3000	615	2400	2250	600	0.01000	2500	0.00350	360	USDAL	TX	200.00
2939	395	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2940	395	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2941	395	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2942	395	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2975	399	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2976	399	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2816	370	1	220000	176000	176000	0.2000	1055	1000	0.0080	0	2202	5.999	0.164	1100	289	625	200	85	1600	1140	200	\N	500	525	0	440	1760	3000	440	0.00000	2500	0.00000	360	Conforming30DownH	TX	146.67
2817	370	2	220000	176000	176000	0.2000	999	1000	0.0080	0	2146	5.500	2.051	1100	3610	625	200	85	1600	1140	200	\N	500	525	0	403	1760	3000	440	0.00000	2500	0.00000	360	Conforming30DownL	TX	146.67
2943	396	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2818	370	3	220000	209000	209000	0.0500	1253	1000	0.0080	51	2451	5.999	0.164	1100	343	625	200	85	1600	1140	200	\N	500	525	0	522	1760	3000	440	0.00000	2500	0.00290	360	Conforming5DownH	TX	146.67
2944	396	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2819	370	4	220000	209000	209000	0.0500	1187	1000	0.0080	51	2385	5.500	2.051	1100	4287	625	200	85	1600	1140	200	\N	500	525	0	479	1760	3000	440	0.00000	2500	0.00290	360	Conforming5DownL	TX	146.67
2820	370	5	220000	212300	216015	0.0350	1244	1000	0.0080	97	2488	5.625	-0.132	1100	-285	625	200	85	1600	1140	200	\N	500	525	3715	506	1760	3000	440	0.01750	2500	0.00550	360	FHAH	TX	146.67
2945	396	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2821	370	6	220000	212300	216015	0.0350	1143	1000	0.0080	97	2387	4.875	2.982	1100	6442	625	200	85	1600	1140	200	\N	500	525	3715	439	1760	3000	440	0.01750	2500	0.00550	360	FHAL	TX	146.67
2946	396	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2822	370	7	220000	220000	225060	0.0000	1331	1000	0.0080	0	2478	5.875	0.118	1100	266	625	200	85	1600	1140	200	\N	500	525	5060	551	1760	3000	440	0.02300	2500	0.00000	360	VAH	TX	146.67
2947	396	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2823	370	8	220000	220000	225060	0.0000	1191	1000	0.0080	0	2338	4.875	2.681	1100	6034	625	200	85	1600	1140	200	\N	500	525	5060	457	1760	3000	440	0.02300	2500	0.00000	360	VAL	TX	146.67
2948	396	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2824	370	9	220000	220000	222200	0.0000	1279	1000	0.0080	64	2490	5.625	-0.132	1100	-293	625	200	85	1600	1140	200	\N	500	525	2200	521	1760	3000	440	0.01000	2500	0.00350	360	USDAH	TX	146.67
3019	404	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2825	370	10	220000	220000	222200	0.0000	1176	1000	0.0080	64	2387	4.875	2.982	1100	6626	625	200	85	1600	1140	200	\N	500	525	2200	451	1760	3000	440	0.01000	2500	0.00350	360	USDAL	TX	146.67
2981	400	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2949	396	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2826	371	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2950	396	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2827	371	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
3020	404	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2982	400	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2828	371	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2951	396	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2829	371	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2983	400	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2952	396	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
3021	404	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2953	397	1	200000	160000	160000	0.2000	959	833	0.0080	0	1925	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	2499	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2830	371	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2831	371	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2954	397	2	200000	160000	160000	0.2000	908	833	0.0080	0	1874	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	2499	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2832	371	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2955	397	3	200000	190000	190000	0.0500	1139	833	0.0080	46	2151	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	2499	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2833	371	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2834	371	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2956	397	4	200000	190000	190000	0.0500	1079	833	0.0080	46	2091	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	2499	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2835	371	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2957	397	5	200000	193000	196378	0.0350	1130	833	0.0080	88	2184	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	2499	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2958	397	6	200000	193000	196378	0.0350	1039	833	0.0080	88	2093	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	2499	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2977	399	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2978	399	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2979	399	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2980	399	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2984	400	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2985	400	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2986	400	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2987	400	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
2988	400	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
2989	400	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
2990	400	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
2991	401	1	200000	160000	160000	0.2000	959	833	0.0080	0	1925	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	2499	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
2992	401	2	200000	160000	160000	0.2000	908	833	0.0080	0	1874	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	2499	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
2993	401	3	200000	190000	190000	0.0500	1139	833	0.0080	46	2151	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	2499	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
2994	401	4	200000	190000	190000	0.0500	1079	833	0.0080	46	2091	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	2499	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
2995	401	5	200000	193000	196378	0.0350	1130	833	0.0080	88	2184	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	2499	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
2996	401	6	200000	193000	196378	0.0350	1039	833	0.0080	88	2093	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	2499	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
2997	401	7	200000	200000	204600	0.0000	1210	833	0.0080	0	2176	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	2499	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3002	402	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
3003	402	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
3004	402	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
3005	402	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3006	402	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
3007	402	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
3008	402	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
3012	403	4	200000	190000	190000	0.0500	1079	1083	0.0080	46	2341	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3249	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
3013	403	5	200000	193000	196378	0.0350	1130	1083	0.0080	88	2434	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3249	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
3039	406	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
3014	403	6	200000	193000	196378	0.0350	1039	1083	0.0080	88	2343	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3249	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
3040	406	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
3015	403	7	200000	200000	204600	0.0000	1210	1083	0.0080	0	2426	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3249	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3016	403	8	200000	200000	204600	0.0000	1083	1083	0.0080	0	2299	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3249	400	0.02300	2500	0.00000	360	VAL	OK	133.33
3041	406	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
3017	403	9	200000	200000	202000	0.0000	1163	1083	0.0080	58	2437	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3249	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
3042	406	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
3018	403	10	200000	200000	202000	0.0000	1069	1083	0.0080	58	2343	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3249	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
3043	406	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
3022	404	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
3023	404	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
3024	404	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
3025	404	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3026	404	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
3027	404	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
3028	404	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
3029	405	1	200000	160000	160000	0.2000	959	1000	0.0080	0	2092	5.999	0.164	1100	262	625	200	85	1400	1200	102	160	225	525	0	400	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownH	OK	133.33
3030	405	2	200000	160000	160000	0.2000	908	1000	0.0080	0	2041	5.500	2.051	1100	3282	625	200	85	1400	1200	102	160	225	525	0	367	1600	3000	400	0.00000	2500	0.00000	360	Conforming30DownL	OK	133.33
3031	405	3	200000	190000	190000	0.0500	1139	1000	0.0080	46	2318	5.999	0.164	1100	312	625	200	85	1400	1200	102	190	225	525	0	475	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownH	OK	133.33
3032	405	4	200000	190000	190000	0.0500	1079	1000	0.0080	46	2258	5.500	2.051	1100	3897	625	200	85	1400	1200	102	190	225	525	0	435	1600	3000	400	0.00000	2500	0.00290	360	Conforming5DownL	OK	133.33
3033	405	5	200000	193000	196378	0.0350	1130	1000	0.0080	88	2351	5.625	-0.132	1100	-259	625	200	85	1400	1200	102	196	225	525	3378	460	1600	3000	400	0.01750	2500	0.00550	360	FHAH	OK	133.33
3034	405	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
3035	405	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3036	405	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
3037	405	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
3038	405	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
3044	406	6	200000	193000	196378	0.0350	1039	1000	0.0080	88	2260	4.875	2.982	1100	5856	625	200	85	1400	1200	102	196	225	525	3378	399	1600	3000	400	0.01750	2500	0.00550	360	FHAL	OK	133.33
3064	408	8	500000	500000	511500	0.0000	2707	1000	0.0080	0	4040	4.875	2.681	1100	13713	625	200	85	1600	2540	200	\N	500	525	11500	1039	4000	3000	1000	0.02300	2500	0.00000	360	VAL	TX	333.33
3045	406	7	200000	200000	204600	0.0000	1210	1000	0.0080	0	2343	5.875	0.118	1100	241	625	200	85	1400	1200	102	205	225	525	4600	501	1600	3000	400	0.02300	2500	0.00000	360	VAH	OK	133.33
3046	406	8	200000	200000	204600	0.0000	1083	1000	0.0080	0	2216	4.875	2.681	1100	5485	625	200	85	1400	1200	102	205	225	525	4600	416	1600	3000	400	0.02300	2500	0.00000	360	VAL	OK	133.33
3065	408	9	500000	500000	505000	0.0000	2907	1000	0.0080	146	4386	5.625	-0.132	1100	-667	625	200	85	1600	2540	200	\N	500	525	5000	1184	4000	3000	1000	0.01000	2500	0.00350	360	USDAH	TX	333.33
3047	406	9	200000	200000	202000	0.0000	1163	1000	0.0080	58	2354	5.625	-0.132	1100	-267	625	200	85	1400	1200	102	202	225	525	2000	473	1600	3000	400	0.01000	2500	0.00350	360	USDAH	OK	133.33
3066	408	10	500000	500000	505000	0.0000	2673	1000	0.0080	146	4152	4.875	2.982	1100	15059	625	200	85	1600	2540	200	\N	500	525	5000	1026	4000	3000	1000	0.01000	2500	0.00350	360	USDAL	TX	333.33
3048	406	10	200000	200000	202000	0.0000	1069	1000	0.0080	58	2260	4.875	2.982	1100	6024	625	200	85	1400	1200	102	202	225	525	2000	410	1600	3000	400	0.01000	2500	0.00350	360	USDAL	OK	133.33
3049	407	1	2000000	1600000	1600000	0.2000	9592	1000	0.0080	0	11925	5.999	0.164	1100	2624	625	200	85	1400	6600	102	1600	225	525	0	3999	16000	3000	4000	0.00000	2500	0.00000	360	Conforming30DownH	OK	1333.33
3050	407	2	2000000	1600000	1600000	0.2000	9085	1000	0.0080	0	11418	5.500	2.051	1100	32816	625	200	85	1400	6600	102	1600	225	525	0	3667	16000	3000	4000	0.00000	2500	0.00000	360	Conforming30DownL	OK	1333.33
3051	407	3	2000000	1900000	1900000	0.0500	11390	1000	0.0080	459	14182	5.999	0.164	1100	3116	625	200	85	1400	6600	102	1900	225	525	0	4749	16000	3000	4000	0.00000	2500	0.00290	360	Conforming5DownH	OK	1333.33
3067	409	1	500000	400000	400000	0.2000	2398	608	0.0080	0	3339	5.999	0.164	1100	656	625	200	85	1400	2100	102	400	225	525	0	1000	4000	1824	1000	0.00000	2500	0.00000	360	Conforming30DownH	OK	333.33
3052	407	4	2000000	1900000	1900000	0.0500	10788	1000	0.0080	459	13580	5.500	2.051	1100	38969	625	200	85	1400	6600	102	1900	225	525	0	4354	16000	3000	4000	0.00000	2500	0.00290	360	Conforming5DownL	OK	1333.33
3068	409	2	500000	400000	400000	0.2000	2271	608	0.0080	0	3212	5.500	2.051	1100	8204	625	200	85	1400	2100	102	400	225	525	0	917	4000	1824	1000	0.00000	2500	0.00000	360	Conforming30DownL	OK	333.33
3053	407	5	2000000	1930000	1963775	0.0350	11305	1000	0.0080	885	14523	5.625	-0.132	1100	-2592	625	200	85	1400	6600	102	1964	225	525	33775	4603	16000	3000	4000	0.01750	2500	0.00550	360	FHAH	OK	1333.33
3054	407	6	2000000	1930000	1963775	0.0350	10392	1000	0.0080	885	13610	4.875	2.982	1100	58560	625	200	85	1400	6600	102	1964	225	525	33775	3989	16000	3000	4000	0.01750	2500	0.00550	360	FHAL	OK	1333.33
3069	409	3	500000	475000	475000	0.0500	2848	608	0.0080	115	3904	5.999	0.164	1100	779	625	200	85	1400	2100	102	475	225	525	0	1187	4000	1824	1000	0.00000	2500	0.00290	360	Conforming5DownH	OK	333.33
3055	407	7	2000000	2000000	2046000	0.0000	12103	1000	0.0080	0	14436	5.875	0.118	1100	2414	625	200	85	1400	6600	102	2046	225	525	46000	5008	16000	3000	4000	0.02300	2500	0.00000	360	VAH	OK	1333.33
3070	409	4	500000	475000	475000	0.0500	2697	608	0.0080	115	3753	5.500	2.051	1100	9742	625	200	85	1400	2100	102	475	225	525	0	1089	4000	1824	1000	0.00000	2500	0.00290	360	Conforming5DownL	OK	333.33
3056	407	8	2000000	2000000	2046000	0.0000	10828	1000	0.0080	0	13161	4.875	2.681	1100	54853	625	200	85	1400	6600	102	2046	225	525	46000	4156	16000	3000	4000	0.02300	2500	0.00000	360	VAL	OK	1333.33
3071	409	5	500000	482500	490944	0.0350	2826	608	0.0080	221	3988	5.625	-0.132	1100	-648	625	200	85	1400	2100	102	491	225	525	8444	1151	4000	1824	1000	0.01750	2500	0.00550	360	FHAH	OK	333.33
3057	408	1	500000	400000	400000	0.2000	2398	1000	0.0080	0	3731	5.999	0.164	1100	656	625	200	85	1600	2540	200	\N	500	525	0	1000	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownH	TX	333.33
3058	408	2	500000	400000	400000	0.2000	2271	1000	0.0080	0	3604	5.500	2.051	1100	8204	625	200	85	1600	2540	200	\N	500	525	0	917	4000	3000	1000	0.00000	2500	0.00000	360	Conforming30DownL	TX	333.33
3059	408	3	500000	475000	475000	0.0500	2848	1000	0.0080	115	4296	5.999	0.164	1100	779	625	200	85	1600	2540	200	\N	500	525	0	1187	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownH	TX	333.33
3060	408	4	500000	475000	475000	0.0500	2697	1000	0.0080	115	4145	5.500	2.051	1100	9742	625	200	85	1600	2540	200	\N	500	525	0	1089	4000	3000	1000	0.00000	2500	0.00290	360	Conforming5DownL	TX	333.33
3061	408	5	500000	482500	490944	0.0350	2826	1000	0.0080	221	4380	5.625	-0.132	1100	-648	625	200	85	1600	2540	200	\N	500	525	8444	1151	4000	3000	1000	0.01750	2500	0.00550	360	FHAH	TX	333.33
3062	408	6	500000	482500	490944	0.0350	2598	1000	0.0080	221	4152	4.875	2.982	1100	14640	625	200	85	1600	2540	200	\N	500	525	8444	997	4000	3000	1000	0.01750	2500	0.00550	360	FHAL	TX	333.33
3063	408	7	500000	500000	511500	0.0000	3026	1000	0.0080	0	4359	5.875	0.118	1100	604	625	200	85	1600	2540	200	\N	500	525	11500	1252	4000	3000	1000	0.02300	2500	0.00000	360	VAH	TX	333.33
3073	409	7	500000	500000	511500	0.0000	3026	608	0.0080	0	3967	5.875	0.118	1100	604	625	200	85	1400	2100	102	512	225	525	11500	1252	4000	1824	1000	0.02300	2500	0.00000	360	VAH	OK	333.33
3074	409	8	500000	500000	511500	0.0000	2707	608	0.0080	0	3648	4.875	2.681	1100	13713	625	200	85	1400	2100	102	512	225	525	11500	1039	4000	1824	1000	0.02300	2500	0.00000	360	VAL	OK	333.33
3075	409	9	500000	500000	505000	0.0000	2907	608	0.0080	146	3994	5.625	-0.132	1100	-667	625	200	85	1400	2100	102	505	225	525	5000	1184	4000	1824	1000	0.01000	2500	0.00350	360	USDAH	OK	333.33
3076	409	10	500000	500000	505000	0.0000	2673	608	0.0080	146	3760	4.875	2.982	1100	15059	625	200	85	1400	2100	102	505	225	525	5000	1026	4000	1824	1000	0.01000	2500	0.00350	360	USDAL	OK	333.33
3077	410	1	440000	352000	352000	0.2000	2110	690	0.0080	0	3093	5.999	0.164	1100	577	625	200	85	1600	2240	200	\N	500	525	0	880	3520	2070	880	0.00000	2500	0.00000	360	Conforming30DownH	TX	293.33
3078	410	2	440000	352000	352000	0.2000	1999	690	0.0080	0	2982	5.500	2.051	1100	7220	625	200	85	1600	2240	200	\N	500	525	0	807	3520	2070	880	0.00000	2500	0.00000	360	Conforming30DownL	TX	293.33
3079	410	3	440000	418000	418000	0.0500	2506	690	0.0080	101	3590	5.999	0.164	1100	686	625	200	85	1600	2240	200	\N	500	525	0	1045	3520	2070	880	0.00000	2500	0.00290	360	Conforming5DownH	TX	293.33
3080	410	4	440000	418000	418000	0.0500	2373	690	0.0080	101	3457	5.500	2.051	1100	8573	625	200	85	1600	2240	200	\N	500	525	0	958	3520	2070	880	0.00000	2500	0.00290	360	Conforming5DownL	TX	293.33
3081	410	5	440000	424600	432031	0.0350	2487	690	0.0080	195	3665	5.625	-0.132	1100	-570	625	200	85	1600	2240	200	\N	500	525	7431	1013	3520	2070	880	0.01750	2500	0.00550	360	FHAH	TX	293.33
3082	410	6	440000	424600	432031	0.0350	2286	690	0.0080	195	3464	4.875	2.982	1100	12883	625	200	85	1600	2240	200	\N	500	525	7431	878	3520	2070	880	0.01750	2500	0.00550	360	FHAL	TX	293.33
3083	410	7	440000	440000	450120	0.0000	2663	690	0.0080	0	3646	5.875	0.118	1100	531	625	200	85	1600	2240	200	\N	500	525	10120	1102	3520	2070	880	0.02300	2500	0.00000	360	VAH	TX	293.33
3084	410	8	440000	440000	450120	0.0000	2382	690	0.0080	0	3365	4.875	2.681	1100	12068	625	200	85	1600	2240	200	\N	500	525	10120	914	3520	2070	880	0.02300	2500	0.00000	360	VAL	TX	293.33
3085	410	9	440000	440000	444400	0.0000	2558	690	0.0080	128	3669	5.625	-0.132	1100	-587	625	200	85	1600	2240	200	\N	500	525	4400	1042	3520	2070	880	0.01000	2500	0.00350	360	USDAH	TX	293.33
3086	410	10	440000	440000	444400	0.0000	2352	690	0.0080	128	3463	4.875	2.982	1100	13252	625	200	85	1600	2240	200	\N	500	525	4400	903	3520	2070	880	0.01000	2500	0.00350	360	USDAL	TX	293.33
3087	411	1	440000	352000	352000	0.2000	2082	690	0.0080	0	3065	5.875	0.140	1100	493	625	200	85	1600	2240	200	\N	500	525	0	862	3520	2070	880	0.00000	2500	0.00000	360	Conforming30DownH	TX	293.33
3088	411	2	440000	352000	352000	0.2000	1999	690	0.0080	0	2982	5.500	1.385	1100	4875	625	200	85	1600	2240	200	\N	500	525	0	807	3520	2070	880	0.00000	2500	0.00000	360	Conforming30DownL	TX	293.33
3089	411	3	440000	418000	418000	0.0500	2473	690	0.0080	101	3557	5.875	0.140	1100	585	625	200	85	1600	2240	200	\N	500	525	0	1023	3520	2070	880	0.00000	2500	0.00290	360	Conforming5DownH	TX	293.33
3090	411	4	440000	418000	418000	0.0500	2373	690	0.0080	101	3457	5.500	1.385	1100	5789	625	200	85	1600	2240	200	\N	500	525	0	958	3520	2070	880	0.00000	2500	0.00290	360	Conforming5DownL	TX	293.33
3091	411	5	440000	424600	432031	0.0350	2556	690	0.0080	195	3734	5.875	0.070	1100	302	625	200	85	1600	2240	200	\N	500	525	7431	1058	3520	2070	880	0.01750	2500	0.00550	360	FHAH	TX	293.33
3092	411	6	440000	424600	432031	0.0350	2286	690	0.0080	195	3464	4.875	2.409	1100	10408	625	200	85	1600	2240	200	\N	500	525	7431	878	3520	2070	880	0.01750	2500	0.00550	360	FHAL	TX	293.33
3093	411	7	440000	440000	450120	0.0000	2556	690	0.0080	0	3539	5.500	-0.023	1100	-104	625	200	85	1600	2240	200	\N	500	525	10120	1032	3520	2070	880	0.02300	2500	0.00000	360	VAH	TX	293.33
3094	411	8	440000	440000	450120	0.0000	2348	690	0.0080	0	3331	4.750	2.835	1100	12761	625	200	85	1600	2240	200	\N	500	525	10120	891	3520	2070	880	0.02300	2500	0.00000	360	VAL	TX	293.33
\.


--
-- Data for Name: new_record; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.new_record (record_id, sales_price, subject_property_address, property_tax_amount, seller_incentives, loan_programs, state) FROM stdin;
271	400000	123 Anywhere Street Tulsa, OK 98999	1	1	{Conforming,FHA,VA,USDA}	OK
272	500000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
274	100000	123 Anywhere Street Tulsa, OK 98999	1	1	{Conforming,FHA,VA,USDA}	OK
275	400000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
276	200000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
277	500000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
278	300000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
279	300000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
280	676666	123 Anywhere Street Tulsa, OK 98999	15000	10000	{Conforming,FHA,VA,USDA}	OK
281	200000	123 Anywhere Street Tulsa, OK 98999	1000	111	{Conforming,FHA,VA,USDA}	OK
282	500000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
283	400000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
284	500000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
285	500000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
286	300000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
287	400000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
288	500000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
289	400000	123 Anywhere Street Tulsa, OK 98999	12000	4000	{Conforming,FHA,VA,USDA}	OK
290	600000	3404 Halsell Court Austin, TX 78732	10000	1000	{Conforming,FHA,VA,USDA}	TX
291	400000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
292	300000	3404 Halsell Court Austin, TX 78732	10000	1000	{Conforming,FHA,VA,USDA}	TX
293	300000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
294	400000	3404 Halsell Court Austin, TX 78732	14000	1000	{Conforming,FHA,VA,USDA}	TX
295	400000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
296	500000	3404 Halsell Court Austin, TX 78732	14000	1000	{Conforming,FHA,VA,USDA}	TX
297	300000	3404 Halsell Court Austin, TX 78732	11000	2000	{Conforming,FHA,VA,USDA}	TX
298	300000	3404 Halsell Court Austin, TX 78732	11000	1000	{Conforming,FHA,VA,USDA}	TX
300	400000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
302	400000	3404 Halsell Court Austin, TX 78732	12000	2300	{Conforming,FHA,VA,USDA}	TX
304	400000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
306	300000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
308	200000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
310	300000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
311	400000	3404 Halsell Court Austin, TX 78732	13000	2000	{Conforming,FHA,VA,USDA}	TX
312	200000	123 Anywhere Street Tulsa, OK 98999	8000	2300	{Conforming,FHA,VA,USDA}	OK
313	490000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
314	300000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
315	600000	3404 Halsell Court Austin, TX 78732	12000	4000	{Conforming,FHA,VA,USDA}	TX
316	300000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
320	300000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
321	400000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
362	300000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
363	300000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
364	200000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
365	300000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
366	200000	3404 Halsell Court Austin, TX 78732	12000	4000	{Conforming,FHA,VA,USDA}	TX
367	275000	3404 Halsell Court Austin, TX 78732	12000	1500	{Conforming,FHA,VA,USDA}	TX
368	220000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA}	TX
369	300000	3404 Halsell Court Austin, TX 78732	9000	2500	{Conforming,FHA,VA,USDA}	TX
370	220000	TX	12000	2000	{Conforming,FHA,VA,USDA}	TX
371	200000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA}	OK
299	500000	3404 Halsell Court Austin, TX 78732	13000	2300	{Conforming,FHA,VA,USDA}	TX
301	200000	123 Anywhere Street Tulsa, OK 98999	6000	1300	{Conforming,FHA,VA,USDA}	OK
303	500000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
305	400000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
307	300000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
309	400000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
317	250000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
318	200000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
319	240000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
322	200000	123 Anywhere Street Tulsa, OK 98999	9000	1000	{Conforming,FHA,VA,USDA}	OK
323	200000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
324	675000	3404 Halsell Court Austin, TX 78732	12000	4000	{Conforming,FHA,VA,USDA}	TX
325	300000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
326	300000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
327	300000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
328	200000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
329	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
330	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
331	200000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
332	500000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
333	455000	3404 Halsell Court Austin, TX 78732	15000	3000	{Conforming,FHA,VA,USDA}	TX
334	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
335	200000	123 Anywhere Street Tulsa, OK 98999	12000	200	{Conforming,FHA,VA,USDA}	OK
336	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
337	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
338	300000	3404 Halsell Court Austin, TX 78732	12000	1000	{Conforming,FHA,VA,USDA}	TX
339	500000	3404 Halsell Court Austin, TX 78732	10000	3500	{Conforming,FHA,VA,USDA}	TX
340	236570	123 Anywhere Street Tulsa, OK 98999	8976	2500	{Conforming,FHA,VA,USDA}	OK
341	100000	123 Anywhere Street Tulsa, OK 98999	1200	100	{Conforming,FHA,VA,USDA}	OK
342	100000	123 Anywhere Street Tulsa, OK 98999	10000	100	{Conforming,FHA,VA,USDA}	OK
343	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
344	275000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
345	300000	123 Anywhere Street Tulsa, OK 98999	3000	1000	{Conforming,FHA,VA,USDA}	OK
346	300000	123 Anywhere Street Tulsa, OK 98999	7000	1500	{Conforming,FHA,VA,USDA}	OK
347	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
348	500000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
349	200000	3404 Halsell Court Austin, TX 78732	2000	1000	{Conforming,FHA,VA,USDA}	TX
350	300000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
351	300000	3404 Halsell Court Austin, TX 78732	12000	1200	{Conforming,FHA,VA,USDA}	TX
352	200000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
353	200000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
354	200000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
355	200000	3404 Halsell Court Austin, TX 78732	20000	3000	{Conforming,FHA,VA,USDA}	TX
356	200000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA,USDA}	TX
357	200000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
358	200000	3404 Halsell Court Austin, TX 78732	12000	2500	{Conforming,FHA,VA,USDA}	TX
359	200000	3404 Halsell Court Austin, TX 78732	12000	2500	{Conforming,FHA,VA,USDA}	TX
360	200000	3404 Halsell Court Austin, TX 78732	12000	3500	{Conforming,FHA,VA,USDA}	TX
361	200000	123 Anywhere Street Tulsa, OK 98999	1000	1000	{Conforming,FHA,VA,USDA}	OK
374	200000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
375	200000	123 Anywhere Street Tulsa, OK 98999	12000	2300	{Conforming,FHA,VA,USDA}	OK
376	500000	3404 Halsell Court Austin, TX 78732	12000	3000	{Conforming,FHA,VA,USDA}	TX
377	200000	123 Anywhere Street Tulsa, OK 98999	24000	2000	{Conforming,FHA,VA,USDA}	OK
379	200000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
380	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
381	200000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
382	200000	123 Anywhere Street Tulsa, OK 98999	12000	2400	{Conforming,FHA,VA,USDA}	OK
383	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
388	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
389	200000	123 Anywhere Street Tulsa, OK 98999	12000	2000	{Conforming,FHA,VA,USDA}	OK
390	200000	3404 Halsell Court Austin, TX 78732	12000	2000	{Conforming,FHA,VA}	TX
391	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
392	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA}	OK
393	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
394	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
395	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
396	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
397	200000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA,USDA}	OK
398	200000	123 Anywhere Street Tulsa, OK 98999	13000	2000	{Conforming,FHA,VA,USDA}	OK
399	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA}	OK
400	200000	123 Anywhere Street Tulsa, OK 98999	12000	3000	{Conforming,FHA,VA,USDA}	OK
401	200000	123 Anywhere Street Tulsa, OK 98999	10000	1000	{Conforming,FHA,VA}	OK
402	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
403	200000	123 Anywhere Street Tulsa, OK 98999	13000	1000	{Conforming,FHA,VA,USDA}	OK
404	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
405	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
406	200000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA,USDA}	OK
407	2000000	123 Anywhere Street Tulsa, OK 98999	12000	1000	{Conforming,FHA,VA}	OK
408	500000	3404 Halsell Court Austin, TX 78732	12000	2500	{Conforming,FHA,VA,USDA}	TX
409	500000	123 Anywhere Street Tulsa, OK 98999	7300	0	{Conforming,FHA,VA,USDA}	OK
410	440000	8430 Grapevine Pass San Antonio, TX 78255	8284	0	{Conforming,FHA,VA,USDA}	TX
411	440000	8430 Grapevine Pass San Antonio, TX 78255	8284	0	{Conforming,FHA,VA}	TX
\.


--
-- Data for Name: ratesheets; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ratesheets (key, note_rate, final_base_price, final_net_price, abs_final_net_price, lpname, effective_time) FROM stdin;
1074603005500	5.500	-0.1150	1.3850	1.3850	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603005624	5.624	-0.6320	0.8680	0.8680	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603005625	5.625	-0.5960	0.9040	0.9040	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603005750	5.750	-0.8130	0.6870	0.6870	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603005875	5.875	-1.3600	0.1400	0.1400	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603005999	5.999	-1.8380	-0.3380	0.3380	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006000	6.000	-1.8260	-0.3260	0.3260	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006124	6.124	-2.2890	-0.7890	0.7890	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006125	6.125	-2.2530	-0.7530	0.7530	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006250	6.250	-2.0120	-0.5120	0.5120	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006375	6.375	-2.4830	-0.9830	0.9830	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006499	6.499	-2.8690	-1.3690	1.3690	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006500	6.500	-2.8530	-1.3530	1.3530	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006624	6.624	-3.2190	-1.7190	1.7190	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006625	6.625	-3.1970	-1.6970	1.6970	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006750	6.750	-2.9570	-1.4570	1.4570	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006875	6.875	-3.3590	-1.8590	1.8590	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603006999	6.999	-3.6570	-2.1570	2.1570	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007000	7.000	-3.6470	-2.1470	2.1470	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007124	7.124	-3.8860	-2.3860	2.3860	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007125	7.125	-3.8600	-2.3600	2.3600	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007250	7.250	-3.8250	-2.3250	2.3250	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007375	7.375	-4.1000	-2.6000	2.6000	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007500	7.500	-4.3570	-2.8570	2.8570	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007625	7.625	-4.5040	-3.0040	3.0040	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007750	7.750	-4.5610	-3.0610	3.0610	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1074603007875	7.875	-4.7770	-3.2770	3.2770	Conv 25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1053603004750	4.750	1.7550	3.2550	3.2550	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603004875	4.875	0.9090	2.4090	2.4090	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005000	5.000	0.1900	1.6900	1.6900	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005125	5.125	-0.4990	1.0010	1.0010	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005250	5.250	-1.0380	0.4620	0.4620	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005375	5.375	-0.6940	0.8060	0.8060	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005500	5.500	-1.3190	0.1810	0.1810	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005625	5.625	-1.9580	-0.4580	0.4580	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005750	5.750	-2.4230	-0.9230	0.9230	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005875	5.875	-1.4300	0.0700	0.0700	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603005999	5.999	-1.9860	-0.4860	0.4860	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006000	6.000	-1.9910	-0.4910	0.4910	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006125	6.125	-2.5550	-1.0550	1.0550	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006250	6.250	-2.8470	-1.3470	1.3470	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006375	6.375	-3.1440	-1.6440	1.6440	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006499	6.499	-3.6040	-2.1040	2.1040	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006500	6.500	-3.6090	-2.1090	2.1090	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006625	6.625	-4.0780	-2.5780	2.5780	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006750	6.750	-4.2320	-2.7320	2.7320	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603006875	6.875	-3.5390	-2.0390	2.0390	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603007000	7.000	-3.9750	-2.4750	2.4750	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603007124	7.124	-4.3450	-2.8450	2.8450	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1053603007125	7.125	-4.3490	-2.8490	2.8490	FHA 20/25/30Yr Fixed > 225K <= 250K	2024-09-05 12:33:00-05
1077003004750	4.750	1.3350	2.8350	2.8350	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003004875	4.875	0.6100	2.1100	2.1100	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005000	5.000	-0.0470	1.4530	1.4530	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005125	5.125	-0.6540	0.8460	0.8460	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005250	5.250	-1.2160	0.2840	0.2840	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005375	5.375	-0.9270	0.5730	0.5730	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005500	5.500	-1.5230	-0.0230	0.0230	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005625	5.625	-2.0440	-0.5440	0.5440	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005750	5.750	-2.3960	-0.8960	0.8960	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005875	5.875	-1.4560	0.0440	0.0440	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003005999	5.999	-1.9190	-0.4190	0.4190	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006000	6.000	-1.9240	-0.4240	0.4240	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006125	6.125	-2.3010	-0.8010	0.8010	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006250	6.250	-2.4810	-0.9810	0.9810	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006375	6.375	-1.7710	-0.2710	0.2710	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006499	6.499	-2.1520	-0.6520	0.6520	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006500	6.500	-2.1560	-0.6560	0.6560	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006624	6.624	-2.5030	-1.0030	1.0030	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006625	6.625	-2.5060	-1.0060	1.0060	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006750	6.750	-2.6420	-1.1420	1.1420	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003006875	6.875	-2.2640	-0.7640	0.7640	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003007000	7.000	-2.5890	-1.0890	1.0890	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
1077003007125	7.125	-2.9150	-1.4150	1.4150	VA 20/25/30Yr Fixed > 275K <= 300K	2024-09-05 12:33:00-05
\.


--
-- Name: defaults_amount_default_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.defaults_amount_default_id_seq', 18, true);


--
-- Name: defaults_count_default_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.defaults_count_default_id_seq', 4, true);


--
-- Name: defaults_percentage_default_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.defaults_percentage_default_id_seq', 32, true);


--
-- Name: loan_scenario_results_scenario_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.loan_scenario_results_scenario_id_seq', 1, false);


--
-- Name: loan_scenarios_scenario_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.loan_scenarios_scenario_id_seq', 3094, true);


--
-- Name: new_record_record_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.new_record_record_id_seq', 411, true);


--
-- Name: ratesheets_key_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.ratesheets_key_seq', 1, false);


--
-- Name: defaults_amount defaults_amount_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.defaults_amount
    ADD CONSTRAINT defaults_amount_pkey PRIMARY KEY (default_id);


--
-- Name: defaults_count defaults_count_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.defaults_count
    ADD CONSTRAINT defaults_count_pkey PRIMARY KEY (default_id);


--
-- Name: defaults_percentage defaults_percentage_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.defaults_percentage
    ADD CONSTRAINT defaults_percentage_pkey PRIMARY KEY (default_id);


--
-- Name: loan_scenario_results loan_scenario_results_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loan_scenario_results
    ADD CONSTRAINT loan_scenario_results_pkey PRIMARY KEY (scenario_id);


--
-- Name: loan_scenarios loan_scenarios_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loan_scenarios
    ADD CONSTRAINT loan_scenarios_pkey PRIMARY KEY (scenario_id);


--
-- Name: new_record new_record_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.new_record
    ADD CONSTRAINT new_record_pkey PRIMARY KEY (record_id);


--
-- Name: ratesheets ratesheets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ratesheets
    ADD CONSTRAINT ratesheets_pkey PRIMARY KEY (key);


--
-- Name: loan_scenarios after_loan_scenario_insert_non_calculated; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER after_loan_scenario_insert_non_calculated AFTER INSERT ON public.loan_scenarios FOR EACH ROW EXECUTE FUNCTION public.populate_non_calculated_fields();


--
-- Name: new_record after_new_record_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER after_new_record_insert AFTER INSERT ON public.new_record FOR EACH ROW EXECUTE FUNCTION public.process_new_record_loan_programs();


--
-- Name: loan_scenarios trg_calculate_discount_points_and_interest_rate; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_calculate_discount_points_and_interest_rate AFTER INSERT OR UPDATE ON public.loan_scenarios FOR EACH ROW EXECUTE FUNCTION public.calculate_discount_points_and_interest_rate();


--
-- Name: loan_scenarios trg_generate_listing_flyer_details; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_generate_listing_flyer_details AFTER INSERT ON public.loan_scenarios FOR EACH ROW EXECUTE FUNCTION public.trigger_generate_listing_flyer_details();


--
-- Name: loan_scenarios trigger_calculate_loan_scenario_fields; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_calculate_loan_scenario_fields BEFORE INSERT OR UPDATE ON public.loan_scenarios FOR EACH ROW EXECUTE FUNCTION public.calculate_loan_scenario_fields();


--
-- Name: loan_scenarios loan_scenarios_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.loan_scenarios
    ADD CONSTRAINT loan_scenarios_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.new_record(record_id);


--
-- PostgreSQL database dump complete
--

