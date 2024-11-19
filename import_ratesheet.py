import os
import time
from google.oauth2 import service_account
from googleapiclient.discovery import build
import logging
import psycopg2
from urllib.parse import urlparse

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Parse DATABASE_URL for connection parameters
db_url = os.environ.get('DATABASE_URL')
if db_url:
    url = urlparse(db_url)
    DB_NAME = url.path[1:]  # Remove leading '/'
    DB_USER = url.username
    DB_PASSWORD = url.password
    DB_HOST = url.hostname
    DB_PORT = url.port
else:
    # Fallback to individual environment variables
    DB_NAME = os.environ.get('PGDATABASE')
    DB_USER = os.environ.get('PGUSER')
    DB_PASSWORD = os.environ.get('PGPASSWORD')
    DB_HOST = os.environ.get('PGHOST')
    DB_PORT = os.environ.get('PGPORT')

# If DB_PORT is not set, use the default PostgreSQL port
if DB_PORT is None:
    DB_PORT = 5432
    logging.warning(f"DB_PORT not set. Using default port: {DB_PORT}")

# Google Drive folder ID and Sheet name
FOLDER_ID = os.environ.get('FOLDER_ID')
SHEET_NAME = os.environ.get('SHEET_NAME')

# Check if all required variables are set
required_vars = {
    'DB_NAME': DB_NAME,
    'DB_USER': DB_USER,
    'DB_PASSWORD': DB_PASSWORD,
    'DB_HOST': DB_HOST,
    'FOLDER_ID': FOLDER_ID,
    'SHEET_NAME': SHEET_NAME
}

missing_vars = [var_name for var_name, var_value in required_vars.items() if var_value is None]

if missing_vars:
    error_message = f"Missing required environment variables: {', '.join(missing_vars)}"
    logging.error(error_message)
    raise EnvironmentError(error_message)

# Log all environment variables (be careful with sensitive information)
logging.info(f"DB_NAME: {DB_NAME}")
logging.info(f"DB_USER: {DB_USER}")
logging.info(f"DB_HOST: {DB_HOST}")
logging.info(f"DB_PORT: {DB_PORT}")
logging.info(f"FOLDER_ID: {FOLDER_ID}")
logging.info(f"SHEET_NAME: {SHEET_NAME}")

def get_credentials():
    return service_account.Credentials.from_service_account_file(
        'secrets/service_account_credentials.json',
        scopes=["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/spreadsheets.readonly"]
    )

def list_files_in_folder(service, folder_id):
    logging.info(f"Listing files in folder: {folder_id}")
    query = f"'{folder_id}' in parents and trashed=false"
    try:
        results = service.files().list(q=query, pageSize=10, fields="files(id, name, createdTime)",
                                       supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
        items = results.get('files', [])
        logging.info(f"Found {len(items)} files")
        for item in items:
            logging.info(f"File ID: {item['id']}, Name: {item['name']}, Created Time: {item['createdTime']}")
        return items
    except Exception as e:
        logging.error(f"Error listing files: {e}")
        return []

def fetch_sheet_data(service, sheet_id, sheet_name):
    logging.info(f"Fetching data from sheet: {sheet_name}")
    try:
        result = service.spreadsheets().values().get(
            spreadsheetId=sheet_id,
            range=f'{sheet_name}!A:G'
        ).execute()
        values = result.get('values', [])
        if not values:
            logging.info('No data found in sheet.')
        return values
    except Exception as e:
        logging.error(f"Error fetching sheet data: {e}")
        return []

def filter_and_process_data(values):
    logging.info("Filtering and processing data...")
    
    # Define margin mapping for different product keys
    margin_mapping = {
        "107460300": 2.000,  # Margin for this product
        "105360300": 1.750,  # Margin for this product
        "107700300": 1.500   # Margin for this product
    }
    
    filter_keys = list(margin_mapping.keys())
    processed_data = []
    
    for row in values[1:]:  # Skip header row
        if len(row) > 4 and any(key in row[4] for key in filter_keys):
            note_rate = row[2]
            final_base_price = float(row[3])
            key = row[4]
            lpname = row[5] if len(row) > 5 else ''
            effective_time = row[6] if len(row) > 6 else ''

            # Determine which margin to use based on the product key
            margin = None
            for product_key, product_margin in margin_mapping.items():
                if product_key in key:
                    margin = product_margin
                    break
            
            if margin is not None:
                final_net_price = final_base_price + margin
                abs_final_net_price = abs(final_net_price)

                processed_data.append((
                    note_rate, final_base_price, key, effective_time, lpname,
                    final_net_price, abs_final_net_price
                ))

    return processed_data

def get_db_connection():
    return psycopg2.connect(
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        host=DB_HOST,
        port=DB_PORT
    )

def import_filtered_data_to_db(filtered_data):
    logging.info("Importing filtered data into database...")
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # First, delete all existing records
        delete_query = "DELETE FROM ratesheets"
        cursor.execute(delete_query)
        logging.info("Deleted existing records from ratesheets table.")

        # Now insert the new data
        insert_query = """
        INSERT INTO ratesheets (note_rate, final_base_price, key, effective_time, lpname, final_net_price, abs_final_net_price)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
        """
        for row in filtered_data:
            cursor.execute(insert_query, row)

        conn.commit()
        logging.info(f"Successfully imported {len(filtered_data)} new records.")
    except Exception as e:
        conn.rollback()
        logging.error(f"Error during import process: {e}")
    finally:
        cursor.close()
        conn.close()

def get_last_processed_file():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT last_processed_file FROM import_status ORDER BY id DESC LIMIT 1")
        result = cursor.fetchone()
        return result[0] if result else None
    except Exception as e:
        logging.error(f"Error getting last processed file: {e}")
        return None
    finally:
        cursor.close()
        conn.close()

def update_last_processed_file(file_id):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO import_status (last_processed_file) VALUES (%s)", (file_id,))
        conn.commit()
    except Exception as e:
        logging.error(f"Error updating last processed file: {e}")
        conn.rollback()
    finally:
        cursor.close()
        conn.close()

def main():
    logging.info("Starting import job")

    try:
        drive_service = build('drive', 'v3', credentials=get_credentials())
        sheets_service = build('sheets', 'v4', credentials=get_credentials())

        files = list_files_in_folder(drive_service, FOLDER_ID)
        if not files:
            logging.info('No ratesheets found.')
            return

        latest_file = files[0]
        last_processed = get_last_processed_file()

        if latest_file['id'] == last_processed:
            logging.info("No new files to process")
            return

        sheet_id = latest_file['id']
        logging.info(f"Processing file: {latest_file['name']}")

        values = fetch_sheet_data(sheets_service, sheet_id, SHEET_NAME)
        if not values:
            logging.info('No data fetched from sheet.')
            return

        filtered_data = filter_and_process_data(values)
        import_filtered_data_to_db(filtered_data)
        update_last_processed_file(sheet_id)

        logging.info("Sheet data processing completed successfully.")
    except Exception as e:
        logging.error(f"An error occurred: {str(e)}")

if __name__ == "__main__":
    logging.info("Starting one-time import job")
    main()
    logging.info("One-time import job completed")