import sys
import flask
import psycopg2
from psycopg2 import pool, OperationalError
from flask import Flask, redirect, render_template, request, url_for, jsonify, send_from_directory
import re
import os
import logging
import time

print("Python version:", sys.version)
print("Python path:", sys.path)
print("Flask version:", flask.__version__)
print("All modules imported successfully")

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

# Custom filter to format currency
@app.template_filter('format_currency')
def format_currency(value):
    try:
        return "${:,.0f}".format(float(value))
    except (ValueError, TypeError):
        return str(value)  # Return the original value if it can't be converted to float

# Custom filter to format address
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

# Mapping of full state names to abbreviations
state_mapping = {
    "texas": "TX",
    "oklahoma": "OK",
    # Add other states as needed
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
        # Attempt to recreate the connection pool
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

            logging.info(f"Received form data: sales_price={sales_price}, address={address}, property_tax={property_tax}, seller_incentives={seller_incentives}")

            state = extract_state_from_address(address)
            loan_programs = request.form.getlist('loan_program')
            loan_programs_array = '{' + ','.join(loan_programs) + '}'

            logging.info(f"Extracted state: {state}, loan_programs: {loan_programs_array}")

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

                    logging.info("About to execute database insert")
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

                logging.info(f"Record inserted and processed successfully. Record ID: {record_id}")
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

            logging.info(f"Results dictionary: {results}")

            # Add debug URLs
            debug_urls = {
                'agent_don': url_for('static', filename='images/agent-don.jpg'),
                'agent_austin': url_for('static', filename='images/agent-austin.jpg'),
                'icon_house': url_for('static', filename='images/icon-house.png'),
                'footer_bg': url_for('static', filename='images/footer-bg.jpg'),
                'header_bg': url_for('static', filename='images/header-bg.jpg')
            }
            logging.info(f"Debug URLs: {debug_urls}")

            return render_template('staging_output_file.html', results=results, debug_urls=debug_urls)

        except Exception as e:
            logging.error(f"Error in submit route: {str(e)}", exc_info=True)
            return f"An error occurred: {str(e)}", 500

    else:
        return "This is the GET request to the submit route. Use POST to submit the form."

@app.route('/static/<path:path>')
def send_static(path):
    app.logger.info(f"Requested static file: {path}")
    full_path = os.path.join(app.static_folder, path)
    app.logger.info(f"Full path: {full_path}")
    app.logger.info(f"File exists: {os.path.exists(full_path)}")
    return send_from_directory(app.static_folder, path)

@app.errorhandler(404)
def page_not_found(e):
    logging.error(f"404 error: {request.url}")
    return "404 - Page Not Found", 404

@app.errorhandler(405)
def method_not_allowed(e):
    logging.error(f"405 error: {request.method} {request.url}")
    return "405 - Method Not Allowed", 405

@app.errorhandler(Exception)
def handle_exception(e):
    logging.error(f"Unhandled exception: {str(e)}", exc_info=True)
    return "An internal error occurred", 500

if __name__ == "__main__":
    logging.info("Starting Flask application")
    app.run(host='0.0.0.0', debug=True)