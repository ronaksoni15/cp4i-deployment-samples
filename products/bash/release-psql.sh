#!/bin/bash
#******************************************************************************
# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2020. All Rights Reserved.
#
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.
#******************************************************************************

#******************************************************************************
# PREREQUISITES:
#   - Logged into cluster on the OC CLI (https://docs.openshift.com/container-platform/4.4/cli_reference/openshift_cli/getting-started-cli.html)
#
# PARAMETERS:
#   -n : <POSTGRES_NAMESPACE> (string), Defaults to 'cp4i'
#   -m : <METADATA_NAME> (string)
#   -u : <METADATA_UID> (string)
#
# USAGE:
#   ./release-psql.sh
#
#   To add ownerReferences for the demos operator
#     ./release-ar.sh -m METADATA_NAME -u METADATA_UID

#******************************************************************************

function usage() {
  echo "Usage: $0 -n <POSTGRES_NAMESPACE> -m <METADATA_NAME> -u <METADATA_UID>"
  exit 1
}

POSTGRES_NAMESPACE="cp4i"

while getopts "n:m:u:" opt; do
  case ${opt} in
  n)
    POSTGRES_NAMESPACE="$OPTARG"
    ;;
  m)
    METADATA_NAME="$OPTARG"
    ;;
  u)
    METADATA_UID="$OPTARG"
    ;;
  \?)
    usage
    ;;
  esac
done

CURRENT_DIR=$(dirname $0)

echo "Postgres namespace for release-psql: '$POSTGRES_NAMESPACE'\n"

echo "Installing PostgreSQL..."
cat <<EOF >/tmp/postgres.env
  MEMORY_LIMIT=2Gi
  NAMESPACE=openshift
  DATABASE_SERVICE_NAME=postgresql
  POSTGRESQL_USER=admin
  POSTGRESQL_DATABASE=sampledb
  VOLUME_CAPACITY=1Gi
  POSTGRESQL_VERSION=10
EOF

oc create namespace $POSTGRES_NAMESPACE

echo "Checking the '/tmp' directory..."
ls -al /tmp

if [[ ! -z $METADATA_UID && ! -z $METADATA_NAME ]]; then
  oc process -n openshift postgresql-persistent --param-file=/tmp/postgres.env >/tmp/postgres.json
  jq '.items[3].metadata += {"ownerReferences": [{"apiVersion": "integration.ibm.com/v1beta1", "kind": "Demo", "name": "'$METADATA_NAME'", "uid": "'$METADATA_UID'"}]}' /tmp/postgres.json >/tmp/postgres-owner-ref.json
  oc apply -n $POSTGRES_NAMESPACE -f /tmp/postgres-owner-ref.json
  cat /tmp/postgres-owner-ref.json
  oc get deploymentconfig/postgresql -o json | jq '.'
else
  oc process -n openshift postgresql-persistent --param-file=/tmp/postgres.env | oc apply -n $POSTGRES_NAMESPACE -f -
fi

echo "INFO: Waiting for postgres to be ready in the $POSTGRES_NAMESPACE namespace"
oc wait -n $POSTGRES_NAMESPACE --for=condition=available --timeout=20m deploymentconfig/postgresql

DB_POD=$(oc get pod -n $POSTGRES_NAMESPACE -l name=postgresql -o jsonpath='{.items[].metadata.name}')
echo "INFO: Found DB pod as: ${DB_POD}"

echo "INFO: Changing DB parameters for Debezium support"
oc exec -n $POSTGRES_NAMESPACE -i $DB_POD \
  -- psql <<EOF
ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_wal_senders=10;
ALTER SYSTEM SET max_replication_slots=10;
EOF

echo "INFO: Restarting postgres to pick up the parameter changes"
oc rollout latest -n $POSTGRES_NAMESPACE dc/postgresql

echo "INFO: Waiting for postgres to restart"
sleep 30
oc wait -n $POSTGRES_NAMESPACE --for=condition=available --timeout=20m deploymentconfig/postgresql

DB_POD=$(oc get pod -n $POSTGRES_NAMESPACE -l name=postgresql -o jsonpath='{.items[].metadata.name}')
echo "INFO: Found new DB pod as: ${DB_POD}"
