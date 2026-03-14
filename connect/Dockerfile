FROM confluentinc/cp-kafka-connect:7.6.0

# ── Debezium PostgreSQL connector (source) ──────────────────────────────────
RUN confluent-hub install --no-prompt debezium/debezium-connector-postgresql:2.5.4

# ── Confluent JDBC connector (sink) ─────────────────────────────────────────
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:10.7.6

# ── Microsoft JDBC driver for SQL Server ────────────────────────────────────
# The Confluent JDBC connector does not bundle vendor-specific drivers.
# We drop the MSSQL jar into the JDBC connector's lib directory.
RUN curl -fsSL \
    https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.4.2.jre11/mssql-jdbc-12.4.2.jre11.jar \
    -o /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/mssql-jdbc-12.4.2.jre11.jar
