#!/usr/bin/env bash
# Wrapper to set env vars and run 05_cutover.sh without quoting issues
: "${NEW_MONGO_URI:?set NEW_MONGO_URI in the environment (<set-in-env>)}"
export NEW_MONGO_URI
export ENV_FILE='/home/deploy/production/coachify/.env.production'
export LOGFILE='/home/deploy/mongodb-cutover2.log'
exec bash /home/deploy/production/coachify/scripts/mongodb/05_cutover.sh
