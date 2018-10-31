#!/bin/bash
# fail explicitly on various errors
#  from https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# From https://stackoverflow.com/a/25515370/788155
yell() { echo "$0: $*" >&2; }
die() { yell "$*"; exit 111; }
try() { "$@" || die "cannot $*"; }

# print self and arguments, if any
ARGS=""
if [[ $# -gt 0 ]] ; then ARGS="with arguments '${@}'"; fi
echo "Starting '${0}' ${ARGS}"

#- dumpdb.sh 0.5
## Usage: dumpdb.sh [-d directory] [-h] [-v]
##
##       -h     Show help options.
##       -v     Print version info.
##
## Example:
##
##      dumpdb.sh -d dump_destination_folder
##
##

#
# This dump script will create hostname.database.table.sql.gz files which are sorted and compressed with
# pigz rsyncable compression. There will be a server-side configuration file which will allow setting a 
# flag to disable the sort and/or compression on a database or a database.table combination.
# The format of the config file will be 
# This was ported from:
# http://stackoverflow.com/questions/10867520/mysqldump-with-db-in-a-separate-file/26292371#26292371
# with some changes to fit our requirements
#

HOME_USERNAME=jeff

HOSTNAME="$(hostname -s)"
MYSQL_DUMP_FOLDER="/home/$HOME_USERNAME/mysql"
# MYSQL_DUMP_SKIP_TABLES="/home/$HOME_USERNAME/dumpdb_excluded_tables.txt"
MYSQL_DUMP_SKIP_TABLES=""
COMPRESS_CMD="pigz --rsyncable"
FORCE_IGNORE_TIME="FALSE"

help=$(grep "^## " "${BASH_SOURCE[0]}" | cut -c 4-)
version=$(grep "^#- "  "${BASH_SOURCE[0]}" | cut -c 4-)

opt_h() {
  echo "$help"
  exit 0
}

opt_v() {
  echo "$version"
  exit 0
}

opt_d() {
  MYSQL_DUMP_FOLDER="${OPTARG}"
}

opt_f() {
  FORCE_IGNORE_TIME="TRUE"
}

while getopts "hvd:f" opt; do
  eval "opt_$opt"
done

if [ -f /home/backuppc/.my.cnf ] # if file exists
then
  MYSQL_LOGIN_INFO="/home/backuppc/.my.cnf"
  DUMP_DEFAULTS=""
elif [ -f /home/backuppc/.mylogin.cnf ] # if file exists
then
  MYSQL_LOGIN_INFO="/home/backuppc/.mylogin.cnf"
  DUMP_DEFAULTS=""
else
  MYSQL_LOGIN_INFO="/root/.mylogin.cnf"
  DUMP_DEFAULTS="--defaults-extra-file=${MYSQL_LOGIN_INFO}"
fi
# Show source for creds and dump defaults
echo "Using login credentials from: ${MYSQL_LOGIN_INFO}"
if [[ ! -z ${DUMP_DEFAULTS} ]] ; then echo "DUMP_DEFAULTS = ${DUMP_DEFAULTS}"; fi

PRECHECK_DUMP=""
STRUCTURE_DUMP=""
DATA_DUMP=""
COMPRESS_ROUTINE=""

### Functions ###

# Pipe and concat the head/end with the stoutput of mysqlump ( '-' cat argument)
# question for GG - do we want --skip-extended-insert when dumping only the structure?
DUMP_STRUCTURE(){
  try mysqldump ${DUMP_DEFAULTS} --skip-extended-insert ${I} --no-data | cat /tmp/sqlhead.sql - > "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql"
}
DUMP_DATA(){
  try mysqldump ${DUMP_DEFAULTS} --skip-extended-insert ${I} --no-create-info ${IGNORED_TABLES_STRING} | cat - /tmp/sqlend.sql >> "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql"
}
COMPRESS_DUMP(){
  try ${COMPRESS_CMD} "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql"
}

### BEGIN ###

if [ -f "${MYSQL_DUMP_SKIP_TABLES}" ] # if file exists
then
  IFS=$'\r\n' GLOBIGNORE='*' command eval  'EXCLUDED_TABLES=($(cat "${MYSQL_DUMP_SKIP_TABLES}"))'
  IGNORED_TABLES_STRING=''
  for TABLE in "${EXCLUDED_TABLES[@]}"
  do :
   IGNORED_TABLES_STRING+=" --ignore-table=${TABLE}"
  done
  echo "-- IGNORED_TABLES_STRING = ${IGNORED_TABLES_STRING}"
else                                  # if empty
    IGNORED_TABLES_STRING=''
fi

echo "-- START DATABASE DUMP --"

# Ensure path exists or throw error
if [ ! -d "${MYSQL_DUMP_FOLDER}" ]; then
  printf "Error: folder does not exist! %s\n" "$MYSQL_DUMP_FOLDER"
  PRECHECK_DUMP="ERROR"
  exit 1
fi

# Test database access or throw error
mysql ${DUMP_DEFAULTS} -e 'show databases' > /dev/null || \
  { 
    printf "Error: cannot read database! %s\n";  \
    PRECHECK_DUMP="ERROR"; exit 1
  }

# Set SQLend string:
echo "SET autocommit=1;SET unique_checks=1;SET foreign_key_checks=1;" > /tmp/sqlend.sql
if [ ! -f /tmp/sqlend.sql ]; then
  printf "Error: backuppc user is unable to create /tmp/sqlend.sql. Does it already exist?"
  PRECHECK_DUMP="ERROR"
  exit 1
fi

echo "-- Dumping all DB ..."
for I in $(mysql ${DUMP_DEFAULTS} -e 'show databases' -s --skip-column-names); 
do

  # Set SQLhead string while in loop
  echo "USE ${I};SET autocommit=0;SET unique_checks=0;SET foreign_key_checks=0;" > /tmp/sqlhead.sql
  if [ ! -f /tmp/sqlhead.sql ]; then
    printf "Error: backuppc user is unable to create /tmp/sqlhead.sql. Does it already exist?"
    exit 1
    PRECHECK_DUMP="ERROR"
  fi
  # Skip schema & other DBs
  if [ "${I}" = information_schema ] || [ "${I}" =  mysql ] || [ "${I}" =  phpmyadmin ] || [ "${I}" =  performance_schema ] || [ "${I}" =  sys ]
  then
    echo "-- Skip - Matches exclude list: \"${I}\""
    continue
  fi
  # Skip if recent dump already exists unless forced
  if [ "`find ${MYSQL_DUMP_FOLDER} -name "${HOSTNAME}.${I}.sql*" -mmin -540`" ] && [ "${FORCE_IGNORE_TIME}" = "FALSE" ]
  then
    # DUMP_AGE=$(try find ${MYSQL_DUMP_FOLDER} -name "${HOSTNAME}.${I}.sql*" -mmin -540 -exec 'try echo "$(($(date +%s) - $(date +%s -r {} )) / 3600) hours"' \;)
    try echo "-- Skip - Last dump of \"${I}\" is newer than specified time."
    continue
  fi
  # delete sql.gz file if it exists
  if [ -f "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql.gz" ]
  then
    echo "-- deleting \"${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql.gz\""
    rm -f "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql.gz"
  fi

  # delete .sql file if it exists
  if [ -f "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql" ]
  then
    echo "-- deleting \"${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql\""
    rm -f "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql"
  fi

  echo "-- BEGIN dumping structure for: \"${I}\""
  DUMP_STRUCTURE
  if [ $? -ne 0 ]
  then
    echo "-- Error returned from function for dumping structure"
    STRUCTURE_DUMP="ERROR"
    exit 1
  else
    echo "-- END dumping structure for: \"${I}\""
  fi

  echo "-- BEGIN dumping data for: \"${I}\""
  DUMP_DATA
  if [ $? -ne 0 ]
  then
    echo "-- Error returned from function for dumping data"
    DATA_DUMP="ERROR"
    exit 1
  else
    echo "-- END dumping data for: \"${I}\""
  fi

  echo "-- BEGIN compress: \"${I}.sql\""
  COMPRESS_DUMP
  if [ $? -ne 0 ]
  then
    echo "-- Error returned from function for compressing dump"
    COMPRESS_ROUTINE="ERROR"
    exit 1
  else
    echo "-- END compress: \"${I}.sql\""
  fi
done

# remove tmp files
rm -f /tmp/sqlhead.sql /tmp/sqlend.sql

if [ -z "${PRECHECK_DUMP}" ] ; then
  echo "-- Precheck passed"
else
  echo "-- ***ERROR ENCOUNTERED*** - Check above for details"
  echo "PRECHECK_DUMP = ${PRECHECK_DUMP}"
  exit 111
fi
if [ -z "${STRUCTURE_DUMP}" ] ; then
  echo "-- Structure passed"
else
  echo "-- ***ERROR ENCOUNTERED*** - Check above for details"
  echo "STRUCTURE_DUMP = ${STRUCTURE_DUMP}"
  exit 111
fi
if [ -z "${DATA_DUMP}" ] ; then
  echo "-- Data passed"
else
  echo "-- ***ERROR ENCOUNTERED*** - Check above for details"
  echo "DATA_DUMP = ${DATA_DUMP}"
  exit 111
fi
if [ -z "${COMPRESS_ROUTINE}" ] ; then
  echo "-- Compress passed"
else
  echo "-- ***ERROR ENCOUNTERED*** - Check above for details"
  echo "COMPRESS_ROUTINE = ${COMPRESS_ROUTINE}"
  exit 111
fi

echo "-- FINISH DATABASE DUMP --"
