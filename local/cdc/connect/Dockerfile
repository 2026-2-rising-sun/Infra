# syntax=docker/dockerfile:1
# Filter SMT and its JSR-223 implementation are deliberately absent upstream.
FROM quay.io/debezium/connect:3.3.2.Final@sha256:42cace7bffc3c5c36aefb31ad56ace025a8373a6f701dd5224d04c9a8943f2b5
USER root
ADD --checksum=sha256:48a36ec998134dd0fc17588df6a2e14c5d4cba2e978ff3c1bcf748becbdd7fb1 https://repo.maven.apache.org/maven2/io/debezium/debezium-scripting/3.3.2.Final/debezium-scripting-3.3.2.Final.jar /kafka/connect/debezium-connector-postgres/
ADD --checksum=sha256:d77164a44ab994837e61eecead64721bdb1794fa2bc6704ac6fe70cd32ef9dd3 https://repo.maven.apache.org/maven2/org/apache/groovy/groovy/4.0.28/groovy-4.0.28.jar /kafka/connect/debezium-connector-postgres/
ADD --checksum=sha256:21a825951142f938e4159cdafc8c56cb5ea2c95f64a0ef362e32311bb3692c7d https://repo.maven.apache.org/maven2/org/apache/groovy/groovy-jsr223/4.0.28/groovy-jsr223-4.0.28.jar /kafka/connect/debezium-connector-postgres/
RUN chmod 644 /kafka/connect/debezium-connector-postgres/*groovy*.jar /kafka/connect/debezium-connector-postgres/debezium-scripting-*.jar
USER kafka
