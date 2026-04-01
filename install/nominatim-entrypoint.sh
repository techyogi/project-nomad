#!/bin/bash
# Custom entrypoint for Nominatim on macOS Docker
# Fixes:
# 1. PostgreSQL refuses to start on bind-mounted volumes (ownership check)
# 2. Cleanup fails on bind-mounted TIGER file (Device or resource busy)
# 3. init.sh uses 'set -ex' which exits on any error including harmless rm failures

# Fix 1: Replace 'service postgresql start/stop' with pg_ctl (skips ownership check)
cat > /usr/local/bin/pg-start-wrapper <<'WRAPPER'
#!/bin/bash
if [ "$1" = "start" ]; then
    su postgres -c "/usr/lib/postgresql/14/bin/pg_ctl start -D /var/lib/postgresql/14/main -l /var/log/postgresql/pg.log -o '-c config_file=/etc/postgresql/14/main/postgresql.conf'"
    for i in $(seq 1 30); do
        [ -S /var/run/postgresql/.s.PGSQL.5432 ] && break
        sleep 1
    done
elif [ "$1" = "stop" ]; then
    su postgres -c "/usr/lib/postgresql/14/bin/pg_ctl stop -D /var/lib/postgresql/14/main -m fast" 2>/dev/null
fi
WRAPPER
chmod +x /usr/local/bin/pg-start-wrapper

sed -i 's|service postgresql start|/usr/local/bin/pg-start-wrapper start|g' /app/start.sh /app/init.sh
sed -i 's|service postgresql stop|/usr/local/bin/pg-start-wrapper stop|g' /app/start.sh /app/init.sh

# Fix 2+3: Remove -e from bash shebang and body so rm failures don't crash the script
sed -i '1s|#!/bin/bash -ex|#!/bin/bash -x|' /app/init.sh /app/start.sh
sed -i 's|^set -ex$|set -x|g' /app/init.sh /app/start.sh

mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

exec /app/start.sh
