FROM ubuntu:22.04

RUN apt update && \
    apt install -y \ 
        gpg \
	wget \
	lsb-release \
	jq \
	curl

# Trying to stay as close as possible to https://github.com/actions/runner-images/blob/main/images/linux/scripts/installers/postgresql.sh
RUN wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /usr/share/keyrings/postgresql.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt update -y && \  
    DEBIAN_FRONTEND=noninteractive apt install -y \ 
        postgresql-14 \ 
	libpq-dev

# Trying to stay as close as possible to https://github.com/actions/runner-images/blob/main/images/linux/scripts/installers/mysql.sh
RUN apt update && \
  apt install -y mysql-client

# Google Cloud SQL Proxy Binary
RUN wget -nv https://dl.google.com/cloudsql/cloud_sql_proxy.linux.amd64 -O /cloud_sql_proxy && \
  chmod +x /cloud_sql_proxy

# kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

