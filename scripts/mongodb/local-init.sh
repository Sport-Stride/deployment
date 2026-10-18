#!/bin/bash
# Runs once, on first start of the local-db MongoDB container (empty data volume).
# Creates the application user used by the microservices.
set -e

mongosh --quiet \
  -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --eval '
    db.getSiblingDB("coachify").createUser({
      user: process.env.MONGO_APP_USER,
      pwd: process.env.MONGO_APP_PASSWORD,
      roles: [{ role: "readWriteAnyDatabase", db: "admin" }]
    });
  '
