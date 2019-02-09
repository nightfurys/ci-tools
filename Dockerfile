FROM anchore/anchore-engine:dev

RUN apt-get update; \
    apt-get upgrade; \
    apt-get install -y ca-certificates wget gosu

# explicitly set user/group IDs for postgres
# also create the postgres user's home directory with appropriate permissions
RUN set -ex; \
    groupadd -r postgres --gid=999; \
    useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
    mkdir -p /var/lib/postgresql; \
    chown -R postgres:postgres /var/lib/postgresql; \
    mkdir /docker-entrypoint-initdb.d; \
    rm -f /config/config.yaml

ENV PG_MAJOR="9.6"
ENV PGDATA="/var/lib/postgresql/data"

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    export DEBCONF_NONINTERACTIVE_SEEN=true; \
    echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections; \
    echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections; \
    echo 'deb http://apt.postgresql.org/pub/repos/apt/ bionic-pgdg main' > /etc/apt/sources.list.d/pgdg.list; \
    curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-common; \
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
    apt-get install -y "postgresql-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2775 /var/run/postgresql
RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 700 "$PGDATA"

COPY anchore-bootstrap.sql.gz /docker-entrypoint-initdb.d/

ENV POSTGRES_USER="postgres" \
    POSTGRES_DB="postgres" \
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-mysecretpassword}"

RUN set -eux; \
    export PATH=$PATH:/usr/lib/postgresql/9.6/bin/; \
    gosu postgres bash -c 'initdb --username=${POSTGRES_USER} --pwfile=<(echo "$POSTGRES_PASSWORD")'; \
    printf '\n%s' "host all all all md5" >> "${PGDATA}/pg_hba.conf"; \
    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    gosu postgres bash -c 'pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start'; \
    export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"; \
    gosu postgres bash -c '\
        export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"; \
        export psql=( psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password --dbname "$POSTGRES_DB" ); \
        for f in /docker-entrypoint-initdb.d/*; do \
            echo running "$f"; gunzip -c "$f" | "${psql[@]}"; echo ; \
        done'; \
    PGUSER="${PGUSER:-$POSTGRES_USER}" \
    gosu postgres bash -c 'pg_ctl -D "$PGDATA" -m fast -w stop'; \
    unset PGPASSWORD; \
    rm -f /docker-entrypoint-initdb.d/anchore-bootstrap.sql.gz; \
    printf '\n%s\n\n' 'PostgreSQL init process complete, ready for start up.';

ENV REGISTRY_VERSION 2.7

RUN set -eux; \
    mkdir -p /etc/docker/registry; \
    wget -O /usr/local/bin/registry https://github.com/docker/distribution-library-image/raw/release/${REGISTRY_VERSION}/amd64/registry; \
    chmod +x /usr/local/bin/registry; \
    wget -O /etc/docker/registry/config.yml https://raw.githubusercontent.com/docker/distribution-library-image/release/${REGISTRY_VERSION}/amd64/config-example.yml; \
    apt-get purge -y ca-certificates wget; \
    rm -rf /wheels /root/.cache

COPY conf/stateless_ci_config.yaml /config/config.yaml
COPY scripts/anchore_ci_tools.py /usr/local/bin/
COPY docker-entrypoint.sh /usr/local/bin/

ENV ANCHORE_ENDPOINT_HOSTNAME="anchore-engine"

VOLUME ["/var/lib/registry"]
EXPOSE 5432 5000
ENTRYPOINT ["docker-entrypoint.sh"]