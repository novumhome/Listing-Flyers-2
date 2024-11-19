import os

# Path to your backup file
backup_file = 'backup.sql'

# Fetch the DATABASE_URL environment variable
database_url = os.environ.get('DATABASE_URL')

if database_url:
    # Command to restore the database using psql
    restore_command = f'psql {database_url} < {backup_file}'

    # Execute the command to restore the database
    os.system(restore_command)

    print("Database restoration complete.")
else:
    print("DATABASE_URL environment variable not set.")