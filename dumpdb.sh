#!/bin/bash
set -o pipefail
#
#
# This was ported from:
# http://stackoverflow.com/questions/10867520/mysqldump-with-db-in-a-separate-file/26292371#26292371
# with some changes to fit our requirements

# Would like to add option #3 from:
# https://dba.stackexchange.com/questions/20/how-can-i-optimize-a-mysqldump-of-a-large-database/2227#2227

# Also:
# https://dba.stackexchange.com/questions/87100/what-are-the-optimal-mysqldump-settings


# Clear variables
MYSQL_LOGIN_INFO=""
PRECHECK_DUMP=""
STRUCTURE_DUMP=""
DATA_DUMP=""

# Set hostname, dump folder & skip file
HOSTNAME="$(hostname -s)"

# Set files
MYSQL_DUMP_FOLDER="/set/my/storage/folder"
MYSQL_DUMP_SKIP_TABLES="${MYSQL_DUMP_FOLDER}/dumpdb_excluded_tables.txt"
MYSQL_DUMP_SKIP_DATABASES="${MYSQL_DUMP_FOLDER}/dumpdb_excluded_databases.txt"

# Set login credential files
MYSQL_MY_CNF="/set/home/backup_user/.my.cnf"
MYSQL_MYLOGIN_CNF="/set/home/backup_user/.mylogin.cnf"
MYSQL_ROOT_MYLOGIN_CNF="/root/.mylogin.cnf"

# Get/Set login parameters
if [ -f "${MYSQL_MY_CNF}" ] # if file exists
then
  MYSQL_LOGIN_INFO="${MYSQL_MY_CNF}"
  DUMP_DEFAULTS=""
elif [ -f "${MYSQL_MYLOGIN_CNF}" ] # if file exists
then
  MYSQL_LOGIN_INFO="${MYSQL_MYLOGIN_CNF}"
  DUMP_DEFAULTS=""
elif [ -f "${MYSQL_ROOT_MYLOGIN_CNF}" # if file exists
  MYSQL_LOGIN_INFO="${MYSQL_ROOT_MYLOGIN_CNF}"
  DUMP_DEFAULTS="--defaults-extra-file=${MYSQL_LOGIN_INFO}"
else
  echo "No login credientials found. Exiting with error status 222."
  exit 222
fi

### Functions ###

# Pipe and concat the head/end with the stoutput of mysqlump ( '-' cat argument)
# question for GG - do we want --skip-extended-insert when dumping only the structure?
DUMP_STRUCTURE(){
  MY_ERROR=$((mysqldump ${DUMP_DEFAULTS} --skip-extended-insert ${I} --no-data | cat /tmp/sqlhead.sql - | gzip > "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql.gz") 2>&1)
  if [ -z "${MY_ERROR}" ]
  then
    #echo " -- ${I} dumped"
    return
  else
    echo " -- Error while dumping structure of database: ${I} - \"${MY_ERROR}\""
    exit 1
  fi
}
DUMP_DATA(){
  #MY_ERROR=$((mysqldump ${DUMP_DEFAULTS} --skip-extended-insert ${I} --no-create-info ${IGNORED_TABLES_STRING} | cat - /tmp/sqlend.sql >> "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql") 2>&1)
  MY_ERROR=$((mysqldump ${DUMP_DEFAULTS} --order-by-primary --skip-extended-insert ${I} --no-create-info ${IGNORED_TABLES_STRING} | cat - /tmp/sqlend.sql | pigz --fast --rsyncable >> "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql.gz") 2>&1)
  if [ -z "${MY_ERROR}" ]
  #if [[ $(echo ${PIPESTATUS[@]} | grep -qE '^[0 ]+$') = '0' ]]
  then
    #echo " -- ${I} dumped"
    return
  else
    echo " -- Error while dumping data from database: ${I} - \"${MY_ERROR}\""
        exit 1
  fi
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

# Set SQLend string:
echo "SET autocommit=1;SET unique_checks=1;SET foreign_key_checks=1;" > /tmp/sqlend.sql
if [ ! -f /tmp/sqlend.sql ]; then
  printf "Error: backuppc user is unable to create /tmp/sqlend.sql. Does it already exist?"
  PRECHECK_DUMP="ERROR"
  exit 1
fi

# If no options on command line, dump all databases (excluding schemas)
if [ -z "$1" ]
then
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
    if [ "${I}" = information_schema ] || [ "${I}" =  mysql ] || [ "${I}" =  phpmyadmin ] || [ "${I}" =  performance_schema ]
    then
      echo "-- Skip - Matches exclude list: ${I}"
      continue
    fi
    # Skip if recent dump already exists
    if [ "`find ${MYSQL_DUMP_FOLDER} -name "${HOSTNAME}.${I}.sql.gz" -mmin -360`" ]
##&& [[ $("pigz --decompress --to-stdout ${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql.gz" | tail -n 1) = $(cat /tmp/sqlend.sql) ]] # previous dump exists
    #if [ "`find ${MYSQL_DUMP_FOLDER} -name "${HOSTNAME}.${I}.sql" -mmin -360`" ] && [[ $(tail "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql" -n 1) = $(cat /tmp/sqlend.sql) ]] # previous dump exists
    then
       echo "-- Skip - Last file is newer than 6 hours: ${I}"
       continue
    fi
    if [ "`find ${MYSQL_DUMP_FOLDER} -name "${HOSTNAME}.${I}.sql"`" ]
    then
      echo "-- deleting ${HOSTNAME}.${I}.sql"
      find ${MYSQL_DUMP_FOLDER} -name "${HOSTNAME}.${I}.sql" -delete
      if [ $? -ne 0 ]
      then
        echo "-- Error returned while deleting..."
        STRUCTURE_DUMP="ERROR"
        exit 1
      fi
    fi
    echo "-- Dumping \"${I}\" structure ..."
    DUMP_STRUCTURE
    if [ $? -ne 0 ]
    then
      echo "-- Error returned from function for dumping structure"
      STRUCTURE_DUMP="ERROR"
      exit 1
    else
      echo "-- Dumped \"${I}\" structure ..."
    fi

    echo "-- Dumping \"${I}\" data ..."
    DUMP_DATA
    if [ $? -ne 0 ]
    then
      echo "-- Error returned from function for dumping data"
      DATA_DUMP="ERROR"
      exit 1
    else
      echo "-- Dumped \"${I}\" data ..."
      ##echo "-- Compressing ..."
      ##pigz --fast --rsyncable "${MYSQL_DUMP_FOLDER}/${HOSTNAME}.${I}.sql"
      ##if [ $? -ne 0 ]
      ##then
        ##echo "-- Error durring compression"
        ##DATA_DUMP="ERROR"
        ##exit 1
      ##else
        ##echo "-- Compression complete"
      ##fi
    fi
  done
else
  I=$1;

  # Set SQLhead string
  echo "USE ${I};SET autocommit=0;SET unique_checks=0;SET foreign_key_checks=0;" > /tmp/sqlhead.sql
  if [ ! -f /tmp/sqlhead.sql ]; then
    printf "Error: backuppc user is unable to create /tmp/sqlhead.sql. Does it already exist?"
    PRECHECK_DUMP="ERROR"
    exit 1
  fi

  echo "-- Dumping \"${I}\" structure ..."
  DUMP_STRUCTURE
  if [ $? -ne 0 ]
  then
    echo "-- Error returned from function for dumping structure"
    STRUCTURE_DUMP="ERROR"
    exit 1
  else
    echo "-- Dumped \"${I}\" structure ..."
  fi

  echo "-- Dumping \"${I}\" data ..."
  DUMP_DATA
  if [ $? -ne 0 ]
  then
    echo "-- Error returned from function for dumping data"
    DATA_DUMP="ERROR"
    exit 1
  else
    echo "-- Dumped \"${I}\" data ..."
  fi
fi

# remove tmp files
rm -f /tmp/sqlhead.sql /tmp/sqlend.sql

if [[ "${PRECHECK_DUMP}" == "" && "${STRUCTURE_DUMP}" == "" && "${DATA_DUMP}" == "" ]] ; then
echo "-- FINISH DATABASE DUMP --"
  exit 0
else
  echo "-- ***ERROR ENCOUNTERED*** - Check above for details"
  echo "PRECHECK_DUMP = ${PRECHECK_DUMP}"
  echo "STRUCTURE_DUMP = ${STRUCTURE_DUMP}"
  echo "DATA_DUMP = ${DATA_DUMP}"
  exit 111
fi



