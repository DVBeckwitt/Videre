export POSTGRES_FOLDER="$NIX_SHELL_DIR/db"
export NEW_DB_PORT=5433
export DB_DATABASE=invidious
export PGUSER=kemal
export PGPASSWORD="kemal"
export PGHOST="localhost"
export PGPORT=$NEW_DB_PORT
export PGDATABASE="$DB_DATABASE"
export PGROHOST="localhost"

if [ ! -d "$POSTGRES_FOLDER" ]
then
  pg_ctl initdb -D "$POSTGRES_FOLDER"
  sed -i "s|^#port.*$|port = $NEW_DB_PORT|" "$POSTGRES_FOLDER/postgresql.conf"
fi

# Development only: trust local connections without authentication.
HOST_COMMON="host\s\+all\s\+all"
sed -i "s|^$HOST_COMMON.*127.*$|host all all 127.0.0.1/32 trust|" "$POSTGRES_FOLDER/pg_hba.conf"
sed -i "s|^$HOST_COMMON.*::1.*$|host all all ::1/128 trust|" "$POSTGRES_FOLDER/pg_hba.conf"

pg_ctl \
  -D "$POSTGRES_FOLDER" \
  -l "$POSTGRES_FOLDER/postgres.log" \
  -o "-c unix_socket_directories='$POSTGRES_FOLDER'" \
  -o "-c listen_addresses='localhost'" \
  -o "-c log_destination='stderr'" \
  -o "-c logging_collector=on" \
  -o "-c log_directory='log'" \
  -o "-c log_filename='postgresql-%Y-%m-%d_%H%M%S.log'" \
  -o "-c log_min_messages=info" \
  -o "-c log_min_error_statement=info" \
  -o "-c log_connections=on" \
  start

# These commands must run as the logged-in user.
PGUSER=$(whoami) createdb "$DB_DATABASE" --host="$POSTGRES_FOLDER" -p "$NEW_DB_PORT"
PGUSER=$(whoami) createuser kemal -s --host="$POSTGRES_FOLDER" -p "$NEW_DB_PORT"
