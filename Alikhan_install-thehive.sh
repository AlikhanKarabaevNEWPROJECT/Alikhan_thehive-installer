#!/bin/bash

set -e

echo "[1/9] Определение IP-адреса..."
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "IP-адрес: $IP_ADDR"

echo "[2/9] Установка зависимостей..."
apt update
apt install -y wget gnupg apt-transport-https git ca-certificates \
ca-certificates-java curl software-properties-common python3-pip lsb-release ufw

echo "[3/9] Установка Java (Amazon Corretto 11)..."
wget -qO- https://apt.corretto.aws/corretto.key | gpg --dearmor -o /usr/share/keyrings/corretto.gpg
echo "deb [signed-by=/usr/share/keyrings/corretto.gpg] https://apt.corretto.aws stable main" > /etc/apt/sources.list.d/corretto.sources.list
apt update
apt install -y java-common java-11-amazon-corretto-jdk
echo 'JAVA_HOME="/usr/lib/jvm/java-11-amazon-corretto"' >> /etc/environment
export JAVA_HOME="/usr/lib/jvm/java-11-amazon-corretto"
source /etc/environment

echo "[4/9] Установка Apache Cassandra 4.1..."
wget -qO - https://downloads.apache.org/cassandra/KEYS | gpg --dearmor -o /usr/share/keyrings/cassandra-archive.gpg
echo "deb [signed-by=/usr/share/keyrings/cassandra-archive.gpg] https://debian.cassandra.apache.org 41x main" > /etc/apt/sources.list.d/cassandra.sources.list
apt update
apt install -y cassandra

echo "[4.1] Настройка Cassandra..."
CASS_CONF="/etc/cassandra/cassandra.yaml"
sed -i "s/^cluster_name:.*/cluster_name: 'thp'/" $CASS_CONF
sed -i "s/^listen_address:.*/listen_address: $IP_ADDR/" $CASS_CONF
sed -i "s/^rpc_address:.*/rpc_address: $IP_ADDR/" $CASS_CONF
sed -i "s/^# broadcast_address:.*/broadcast_address: $IP_ADDR/" $CASS_CONF
sed -i "s/^# broadcast_rpc_address:.*/broadcast_rpc_address: $IP_ADDR/" $CASS_CONF
sed -i "/- seeds:/c\          - seeds: \"$IP_ADDR\"" $CASS_CONF

echo "[4.2] Очистка данных Cassandra..."
systemctl stop cassandra
rm -rf /var/lib/cassandra/*
systemctl start cassandra
systemctl enable cassandra

echo "[5/9] Установка Elasticsearch 7.x..."
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" > /etc/apt/sources.list.d/elastic-7.x.list
apt update
apt install -y elasticsearch

echo "[5.1] Настройка Elasticsearch..."
ES_CONF="/etc/elasticsearch/elasticsearch.yml"
mv $ES_CONF $ES_CONF.bak
cat <<EOF > $ES_CONF
http.host: 127.0.0.1
transport.host: 127.0.0.1
cluster.name: hive
thread_pool.search.queue_size: 100000
path.logs: "/var/log/elasticsearch"
path.data: "/var/lib/elasticsearch"
xpack.security.enabled: false
script.allowed_types: "inline,stored"
EOF

mkdir -p /etc/elasticsearch/jvm.options.d
cat <<EOF > /etc/elasticsearch/jvm.options.d/jvm.options
-Dlog4j2.formatMsgNoLookups=true
-Xms2g
-Xmx2g
EOF

systemctl stop elasticsearch
rm -rf /var/lib/elasticsearch/*
systemctl start elasticsearch
systemctl enable elasticsearch

echo "[6/9] Подготовка директорий и пользователя..."
mkdir -p /opt/thp/thehive/files

echo "[6.1] Создание пользователя thehive..."
id -u thehive &>/dev/null || useradd -r -s /usr/sbin/nologin -d /opt/thehive thehive
chown -R thehive:thehive /opt/thp/thehive/files

echo "[7/9] Установка TheHive 5.4..."
wget -O- https://raw.githubusercontent.com/StrangeBeeCorp/Security/main/PGP%20keys/packages.key | gpg --dearmor -o /usr/share/keyrings/strangebee-archive-keyring.gpg
echo "deb [arch=all signed-by=/usr/share/keyrings/strangebee-archive-keyring.gpg] https://deb.strangebee.com thehive-5.4 main" > /etc/apt/sources.list.d/strangebee.list
apt update
apt install -y thehive

echo "[7.1] Настройка application.conf..."
APP_CONF="/etc/thehive/application.conf"
cat <<EOF > "$APP_CONF"
include "/etc/thehive/secret.conf"

db.janusgraph {
  storage {
    backend = cql
    hostname = ["$IP_ADDR"]
    cql {
      cluster-name = thp
      keyspace = thehive
    }
  }

  index.search {
    backend = elasticsearch
    hostname = ["127.0.0.1"]
    index-name = thehive
  }
}

storage {
  provider = localfs
  localfs.location = /opt/thp/thehive/files
}

play.http.parser.maxDiskBuffer = 1GB
play.http.parser.maxMemoryBuffer = 10M

application.baseUrl = "http://$IP_ADDR:9000"
http.address = "0.0.0.0"
http.port = 9000
play.http.context = "/"
EOF

echo "[7.2] Настройка firewall..."
ufw allow 9000/tcp

echo "[8/9] Запуск TheHive..."
systemctl daemon-reexec
systemctl start thehive
systemctl enable thehive

echo "[9/9] Проверка статуса:"
systemctl status thehive | head -20

echo ""
echo "✅ Установка завершена. TheHive доступен по адресу: http://$IP_ADDR:9000"
echo "⏳ Подожди 5-10 минут, чтобы Cassandra и Elasticsearch полностью запустились."
