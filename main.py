import sys
import flask
import psycopg2
from psycopg2 import pool, OperationalError
from flask import Flask, redirect, render_template, request, url_for, jsonify, send_from_directory
import re
import os
import logging
import time
from datetime import datetime 

# Set up logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__, static_url_path='/static', static_folder='static')
print("Flask app created")
logging.info("Flask app initialized")

# Create a connection pool
try:
    connection_pool = pool.SimpleConnectionPool(
        1, 20,
        dbname=os.getenv('PGDATABASE'),
        user=os.getenv('PGUSER'),
        password=os.getenv('PGPASSWORD'),
        host=os.getenv('PGHOST'),
        port=os.getenv('PGPORT')
    )
    logging.info("Database connection pool created successfully")
except Exception as e:
    logging.error(f"Failed to create connection pool: {str(e)}")
    print(f"Failed to create connection pool: {str(e)}", file=sys.stderr)

@app.template_filter('format_currency')
def format_currency(value):
    try:
        return "${:,.0f}".format(float(value))
    except (ValueError, TypeError):
        return str(value)

@app.template_filter('format_address')
def format_address(address):
    parts = address.split(',')
    parts = [part.strip() for part in parts]
    if len(parts) >= 3:
        formatted = ', '.join(parts[:-1])
        formatted = formatted.rsplit(',', 1)
        formatted = ' | '.join(formatted)
        return formatted.upper()
    else:
        return address.upper()

state_mapping = {
    "texas": "TX",
    "oklahoma": "OK",
}

def extract_state_from_address(address):
    state_pattern = re.compile(r'\b(TX|OK|Texas|Oklahoma)\b', re.IGNORECASE)
    match = state_pattern.search(address)
    if match:
        state = match.group(0).strip().lower()
        return state_mapping.get(state, state.upper())
    else:
        return None

def check_db_connection():
    global connection_pool
    try:
        conn = connection_pool.getconn()
        with conn.cursor() as cursor:
            cursor.execute("SELECT 1")
        connection_pool.putconn(conn)
    except Exception as e:
        logging.error(f"Database connection lost: {str(e)}")
        try:
            connection_pool = pool.SimpleConnectionPool(
                1, 20,
                dbname=os.getenv('PGDATABASE'),
                user=os.getenv('PGUSER'),
                password=os.getenv('PGPASSWORD'),
                host=os.getenv('PGHOST'),
                port=os.getenv('PGPORT')
            )
            logging.info("Database connection pool recreated successfully")
        except Exception as e:
            logging.error(f"Failed to recreate connection pool: {str(e)}")

@app.route('/')
def home():
    logging.info("Home route accessed")
    return "Welcome to the home page. <a href='/form'>Go to form</a>"

@app.route('/form')
def form():
    logging.info("Form route accessed")
    return render_template('form.html')

@app.route('/submit', methods=['GET', 'POST'])
def submit():
    check_db_connection()
    logging.info(f"Submit route accessed with method: {request.method}")

    if request.method == 'POST':
        logging.info("Processing POST request")
        logging.info("Form data: %s", request.form)

        try:
            sales_price = request.form['sales_price']
            address = request.form['subject_property_address']
            property_tax = request.form['property_tax']
            seller_incentives = request.form['seller_incentives']
            agent_team = request.form['agent_team']  # Get agent_team from form

            state = extract_state_from_address(address)
            loan_programs = request.form.getlist('loan_program')
            loan_programs_array = '{' + ','.join(loan_programs) + '}'

            conn = connection_pool.getconn()
            conn.set_session(autocommit=True)
            try:
                with conn.cursor() as cursor:
                    insert_query = """
                    INSERT INTO new_record (
                        sales_price,
                        subject_property_address,
                        property_tax_amount,
                        seller_incentives,
                        loan_programs,
                        state
                    )
                    VALUES (%s, %s, %s, %s, %s, %s)
                    RETURNING record_id
                    """

                    cursor.execute(insert_query, (sales_price, address, property_tax, seller_incentives, loan_programs_array, state))
                    record_id = cursor.fetchone()[0]

                    cursor.execute("CALL generate_listing_flyer_details(%s)", (record_id,))

                    select_results_query = """
                    SELECT loan_program_code, total_loan_amount, amount_needed_to_purchase, total_payment,
                           interest_rate, apr, discount_points_percent, sales_price
                    FROM loan_scenario_results
                    WHERE record_id = %s
                    """
                    cursor.execute(select_results_query, (record_id,))
                    raw_results = cursor.fetchall()

            except psycopg2.Error as db_error:
                logging.error(f"Database error: {str(db_error)}")
                return f"A database error occurred: {str(db_error)}", 500
            finally:
                connection_pool.putconn(conn)

            results = {}
            for row in raw_results:
                loan_program_code = row[0]
                results[loan_program_code] = {
                    'loan_amount': float(row[1]),
                    'amount_needed_to_purchase': float(row[2]),
                    'total_payment': float(row[3]),
                    'interest_rate': float(row[4]),
                    'apr': float(row[5]),
                    'discount_points_percent': float(row[6])
                }
            results['sales_price'] = float(raw_results[0][7])
            results['subject_property_address'] = address
            results['agent_team'] = agent_team
            results['current_date'] = datetime.now().strftime('%m/%d/%Y')
            
            logging.info(f"Results dictionary: {results}")

            return render_template('staging_output_file.html', results=results)

        except Exception as e:
            logging.error(f"Error in submit route: {str(e)}", exc_info=True)
            return f"An error occurred: {str(e)}", 500

    return "This is the GET request to the submit route. Use POST to submit the form."

@app.route('/static/<path:path>')
def send_static(path):
    return send_from_directory(app.static_folder, path)

if __name__ == "__main__":
    app.run(host='0.0.0.0', debug=True)