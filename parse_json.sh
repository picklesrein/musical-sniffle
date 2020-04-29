#!/bin/bash

#set -Eeuo pipefail
MAILTO=<privide an email address>
LOOP=`jq '. | length' dataset.json`
let "LOOP=${LOOP}-1"
for i in $(seq 0 ${LOOP})
do
  #echo ${i}
  SERVICE_NAME=`jq -r .[$i].serviceName dataset.json`
  LOCAL_IP=`jq -r .[$i].localIp dataset.json`
  REMOTE_IP=`jq -r .[$i].remoteIp dataset.json`
  REMOTE_PORT=`jq -r .[$i].remotePort dataset.json`

  nc -w 3 -zs ${LOCAL_IP} ${REMOTE_IP} ${REMOTE_PORT} ; SUCCESS=$?                                                        

  if [ ${SUCCESS} -ne 0 ]
  then
    if [ -f /tmp/${SERVICE_NAME} ]
    then
      continue
    else
      touch /tmp/${SERVICE_NAME}
      #echo "${SERVICE_NAME} is down."
      echo "Connection for ${SERVICE_NAME}, from ${LOCAL_IP} to ${REMOTE_IP}:${REMOTE_PORT}, is down." | mail -s "`hostname -s` ${SERVICE_NAME} is down." ${MAILTO}
    fi
  else
    if [ -f /tmp/${SERVICE_NAME} ]
    then
      rm /tmp/${SERVICE_NAME}
      #echo "${SERVICE_NAME} is up."
      echo "${SERVICE_NAME} is up." | mail -s "`hostname -s` ${SERVICE_NAME} is up." ${MAILTO}          
     fi
  fi
    #echo "Connection for ${SERVICE_NAME}, from ${LOCAL_IP} to ${REMOTE_IP}:${REMOTE_PORT}, is down."                     
    #echo "Connection for ${SERVICE_NAME} is up."
done
