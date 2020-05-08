#!/bin/bash
set -e

USER_ID=$(id -u)

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
        CMDARG="$@"
fi

        if [ -n "$INIT_TOKUDB" ]; then
                export LD_PRELOAD=/lib64/libjemalloc.so.1
        fi
        # Get config
        DATADIR="$("mysqld" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

        if [ ! -d "$DATADIR/mysql" ]; then
                if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
                        echo >&2 'error: database is uninitialized and password option is not specified '
                        echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
                        exit 1
                fi
                mkdir -p "$DATADIR"

                echo 'Running mysql_install_db'
                mysql_install_db --user=mysql --datadir="$DATADIR" --rpm --keep-my-cnf
                echo 'Finished mysql_install_db'

                mysqld --user=mysql --datadir="$DATADIR" --skip-networking &
                pid="$!"

                mysql=( mysql --protocol=socket -uroot )

                for i in {3000..0}; do
                        if echo 'SELECT 1' | "${mysql[@]}" ; then
                                break
                        fi
                        echo 'MySQL init process in progress...'
                        sleep 1
                done
                if [ "$i" = 0 ]; then
                        echo >&2 'MySQL init process failed.'
                        exit 1
                fi

                # sed is for https://bugs.mysql.com/bug.php?id=20545
                mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
                # install TokuDB engine
                if [ -n "$INIT_TOKUDB" ]; then
                        ps_tokudb_admin --enable
                fi

                if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
                        MYSQL_ROOT_PASSWORD="$(pwmake 128)"
                        echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
                fi
                "${mysql[@]}" <<-EOSQL
-- What's done in this file shouldn't be replicated
--  or products like mysql-fabric won't work
SET @@SESSION.SQL_LOG_BIN=0;
DELETE FROM mysql.user ;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
DROP DATABASE IF EXISTS test ;
FLUSH PRIVILEGES ;
EOSQL
                if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
                        mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
                fi

                if [ "$MYSQL_DATABASE" ]; then
                        echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
                        mysql+=( "$MYSQL_DATABASE" )
                fi

                if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
                        echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" | "${mysql[@]}"

                        if [ "$MYSQL_DATABASE" ]; then
                                echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
                        fi

                        echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
                fi

                if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
                        "${mysql[@]}" <<-EOSQL
ALTER USER 'root'@'%' PASSWORD EXPIRE;
EOSQL
                fi
                if ! kill -s TERM "$pid" || ! wait "$pid"; then
                        echo >&2 'MySQL init process failed.'
                        exit 1
                fi

                echo
                echo 'MySQL init process done. Ready for start up.'
                echo
                #mv /etc/my.cnf $DATADIR
        fi

echo "Creating replication user on primary"
set +e
for i in {300..0}; do
    if echo 'SELECT 1' | mysql -u root -h primary ; then
            break
    else
            echo 'MySQL init process in progress...'
            sleep 5
    fi
done
mysql -u root -h primary <<-EOSQL
CREATE USER 'repl'@'%' IDENTIFIED BY 'password';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
EOSQL

mysqld --user=mysql --log-error=${DATADIR}error.log $CMDARG &
pid="$!"

echo "Started with PID $pid, waiting for initialization..."
set +e
for i in {300..0}; do
    if echo 'SELECT 1' | "${mysql[@]}" ; then
            break
    else
            echo 'MySQL init process in progress...'
            sleep 5
    fi
done
if [ "$i" = 0 ]; then
    echo >&2 'MySQL init process failed.'
    exit 1
fi
echo "configure primary on secondary"
"${mysql[@]}" <<-EOSQL
STOP SLAVE;
change master to master_host='primary', master_user='repl', master_password='password', master_ssl=0;
set global super_read_only = off;
EOSQL

echo "get dump from primary"
mysqldump -h primary -u root --single-transaction --master-data=1 -A | "${mysql[@]}"

echo "start secondary"
"${mysql[@]}" <<-EOSQL
set global super_read_only = on;
flush privileges;
start slave;
EOSQL

wait $pid
echo "mysqld process $pid has been terminated... exiting"
sleep 1000
