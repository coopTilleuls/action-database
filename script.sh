#!/bin/bash

set -e
# debug
# set -x

if [ ! -f ~/.kube/config ]; then
    echo "~/.kube/config missing"
    echo "if running github action, action kubernetes_set_env must be run before"
    echo "this is needed to read/write db password in Kubernetes secret"
    exit 1
fi

# Checking envvars
if [ -z "$ACTION" ]; then
    echo "ACTION env var is missing"
    exit=1
fi

if [ -z "$DBMS" ]; then
    echo "DBMS env var is missing"
    exit=1
fi

if [ -z "$CLUSTER" ]; then
    echo "CLUSTER env var is missing"
    exit=1
fi

if [ -z "$PREFIX_NAME" ]; then
    echo "PREFIX_NAME env var is missing"
    exit=1
fi

if [ -z "$DUMP_FILENAME" ]; then
    echo "DUMP_FILENAME env var is missing"
    exit=1
fi

if [ -z "$DUMP_SUBSTITUTIONS" ]; then
    echo "DUMP_SUBSTITUTIONS env var is missing"
    exit=1
fi


if [ -n "$exit" ]; then
    exit 1
fi

CLUSTER=${CLUSTER}
CLUSTER_UC=$(echo $CLUSTER | tr a-z A-Z)

# If in Github actions context 
if [ ! -z "$SECRETS_JSON" ]; then
    function get_input() {
        local key=$1
        jq -r ".$key // empty" <<EOF
        ${SECRETS_JSON}
EOF
    }

    SQL_INSTANCE="$(get_input SQL_INSTANCE_${CLUSTER_UC})"
    SQL_PROXY_AUTH_BASE64="$(get_input SQL_PROXY_AUTH_BASE64_${CLUSTER_UC})"
    SQL_ADMIN_USER="$(get_input SQL_ADMIN_USER_${CLUSTER_UC})"
    SQL_ADMIN_PASSWORD="$(get_input SQL_ADMIN_PASSWORD_${CLUSTER_UC})"

    if [ -z "$SQL_PROXY_AUTH_BASE64" ]; then
        echo "SQL_PROXY_AUTH_BASE64_${CLUSTER_UC} secret is missing"
        exit=1
    fi

    if [ -z "$SQL_INSTANCE" ]; then
        echo "SQL_INSTANCE_${CLUSTER_UC} secret is missing"
        exit=1
    fi

    if [ -z "$SQL_ADMIN_USER" ]; then
        echo "SQL_ADMIN_USER_${CLUSTER_UC} secret is missing"
        exit=1
    fi

    if [ -z "$SQL_ADMIN_PASSWORD" ]; then
        echo "SQL_ADMIN_PASSWORD_${CLUSTER_UC} secret is missing"
        exit=1
    fi

    if [ -n "$exit" ]; then
        exit 1
    fi

# Else in a local docker context
else
    # Vars should be provided by env

    if [ -z "$SQL_INSTANCE" ]; then
        echo "SQL_INSTANCE env var is missing"
        exit=1
    fi

    if [ -z "$SQL_PROXY_AUTH_BASE64" ]; then
        echo "SQL_PROXY_AUTH_BASE64 env var is missing"
        exit=1
    fi

    if [ -z "$SQL_ADMIN_USER" ]; then
        echo "SQL_ADMIN_USER env var is missing"
        exit=1
    fi

    if [ -z "$SQL_ADMIN_PASSWORD" ]; then
        echo "SQL_ADMIN_PASSWORD env var is missing"
        exit=1
    fi

    if [ -z "$DB_NAME" ]; then
        echo "DB_NAME env var is missing"
        exit=1
    fi

    if [ -z "$DB_USER" ]; then
        echo "DB_USER env var is missing"
        exit=1
    fi

    if [ -n "$exit" ]; then
        exit 1
    fi
fi

AUTH_FILE=/tmp/gce-cloudsql-proxy-key.json

# create sql auth config
base64 -d <<EOF > $AUTH_FILE
$SQL_PROXY_AUTH_BASE64
EOF

if [[ $DBMS == 'mysql' ]]; then
    DBMS_PORT=3306
    CONNPARAMS="-h 127.0.0.1 -P $DBMS_PORT -u $SQL_ADMIN_USER -p$SQL_ADMIN_PASSWORD"
    MYSQL_OPTIONS="${CONNPARAMS} --connect-timeout=1"
    MYSQLDUMP_OPTIONS="${CONNPARAMS} --opt $DB_NAME --set-gtid-purged=OFF --single-transaction"
    mysql_q="mysql $MYSQL_OPTIONS -e"
else
    DBMS_PORT=5432
    # Don't set $DB_NAME in CONNPARAMS because we need to be connected to another one (e.g. postgres) to create/delete $DB_NAME
    CONNPARAMS="--dbname=postgresql://${SQL_ADMIN_USER}:${SQL_ADMIN_PASSWORD}@127.0.0.1:${DBMS_PORT}"
    psql_q="psql $CONNPARAMS --tuples-only --command"
fi

# launch proxy
./cloud_sql_proxy \
    -instances=${SQL_INSTANCE}=tcp:0.0.0.0:$DBMS_PORT \
    -credential_file $AUTH_FILE \
    &

# test db connection via proxy
for i in $(seq 1 10); do
    if [[ $DBMS == 'mysql' ]]; then
        mysql $MYSQL_OPTIONS -e "select 1;" && break;
    else
        pg_isready $CONNPARAMS && break;
    fi

    if [ $i -eq 10 ]; then
    echo no connection to $DBMS after $i retries
    exit 1
    fi
    sleep 1
done

# this function replace all search/replace from the DUMP_SUBSTITUTIONS input
# this can be reverted for db exports
function dump_substitute() {
    FILE=$1
    REVERT=$2
    for i in $(seq 0 $(expr $(jq ". | length" substitutions.json) - 1 )); do
    if [ -z "$REVERT" ]; then
        sed -i -e 's#'$(jq -r ".[$i].search" substitutions.json)'#'$(jq -r ".[$i].replace" substitutions.json)'#g' $FILE
    else
        sed -i -e 's#'$(jq -r ".[$i].replace" substitutions.json)'#'$(jq -r ".[$i].search" substitutions.json)'#g' $FILE
    fi
    done
}

cat > substitutions.json <<EOF
    $DUMP_SUBSTITUTIONS
EOF

if [ "${ACTION}" == "create" ]; then

    # get or set db password in Kubernetes Secret
    # if secret exist, read password, else create it
    if kubectl get secret ${PREFIX_NAME}-${DBMS}; then
        if [[ $DBMS == 'mysql' ]]; then
            JSON_PWD_PATH='{.data.mysql-password}';
        else
            JSON_PWD_PATH='{.data.postgresql-password}';
        fi
        DB_PASSWORD=$(kubectl get secret ${PREFIX_NAME}-$DBMS -o=jsonpath=$JSON_PWD_PATH | base64 -d)
    else
        DB_PASSWORD=$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | head -c14)
        kubectl create secret generic ${PREFIX_NAME}-${DBMS} \
            --from-literal=${DBMS}-password=$DB_PASSWORD
    fi

    if [[ $DBMS == 'mysql' ]]; then
        # create user if not exists
        $mysql_q "create user if not exists '$DB_USER'@'%' identified by '$DB_PASSWORD';"

        # create database if not exists
        $mysql_q "create database if not exists \`$DB_NAME\`;"

        # grant privileges
        $mysql_q "grant all privileges on \`$DB_NAME\`.* TO '$DB_USER'@'%';"
    else
        # create user if not exists
        $psql_q "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'" | grep -q 1 || $psql_q "CREATE ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}'; GRANT ${DB_USER} TO \"${SQL_ADMIN_USER}\";"
        # create database if not exists
        $psql_q "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 || $psql_q "CREATE DATABASE $DB_NAME OWNER ${DB_USER};"
    fi

fi

if [ "${ACTION}" == "import" ]; then
    # import database
    if [ ! -f "${DUMP_FILENAME}.sql.gz" ]; then
        echo "Nothing to import, ${DUMP_FILENAME}.sql.gz does not exist"
    else
        echo "some tables are excluded for ci/cd performance"
        gunzip --keep ${DUMP_FILENAME}.sql.gz
        # call DUMP_SUBSTITUTIONS replacement function
        dump_substitute ${DUMP_FILENAME}.sql

        if [[ $DBMS == 'mysql' ]]; then
            cat ${DUMP_FILENAME}.sql | mysql $MYSQL_OPTIONS $DB_NAME
        else
            psql $CONNPARAMS/${DB_NAME} < ${DUMP_FILENAME}.sql
        fi
    fi

fi

if [ "${ACTION}" == "export" ] ;then
    DATEDJ=$(date +%F)

    if [[ $DBMS == 'mysql' ]]; then
        mysqldump $MYSQLDUMP_OPTIONS > ${DATEDJ}-dump.sql
    else
        pg_dump $CONNPARAMS/${DB_NAME} > ${DATEDJ}-dump.sql
    fi

    # call DUMP_SUBSTITUTIONS replacement function, revert mode during export
    dump_substitute ${DATEDJ}-dump.sql revert
    gzip ${DATEDJ}-dump.sql
fi

if [ "${ACTION}" == "delete" ]; then
    if [ "${PREFIX_NAME}" == "main" -o "${PREFIX_NAME}" == "prod" ]; then
        echo "Cannot delete production dbs"
        exit 1
    else
        if [[ $DBMS == 'mysql' ]]; then
            $mysql_q "drop database if exists \`$DB_NAME\`;"
            $mysql_q "drop user if exists '$DB_USER'@'%';"
        else
            # drop database if it exists
            # WITH (FORCE) remove database even if user is connected to it
            $psql_q "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 && $psql_q "DROP DATABASE $DB_NAME WITH (FORCE);"

            # drop user if it exists
            $psql_q "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'" | grep -q 1 && $psql_q "DROP USER $DB_USER;"
        fi

        kubectl delete secret ${PREFIX_NAME}-${DBMS}
    fi
fi

# stop sql proxy
kill %1
