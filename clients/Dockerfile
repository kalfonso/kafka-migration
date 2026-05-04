# Multi-stage build for the Java demo clients.
FROM docker.io/library/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package -DskipTests

FROM docker.io/library/eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/clients.jar /app/clients.jar
# MAIN_CLASS picks Producer or Consumer at runtime.
ENV MAIN_CLASS=com.example.kafkamigration.Producer
ENTRYPOINT ["sh", "-c", "exec java -cp /app/clients.jar $MAIN_CLASS"]
