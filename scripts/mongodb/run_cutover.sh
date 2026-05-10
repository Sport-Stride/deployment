#!/usr/bin/env bash
# Wrapper to set env vars and run 05_cutover.sh without quoting issues
export NEW_MONGO_URI='mongodb://coachifyApp:SportStride2026!@172.18.0.1:27017/coachify?authSource=coachify'
export ENV_FILE='/home/deploy/production/coachify/.env.production'
export LOGFILE='/home/deploy/mongodb-cutover2.log'
exec bash /home/deploy/production/coachify/scripts/mongodb/05_cutover.sh
