#!/bin/bash

# This script uses the `gcloud` SDK to:
# - Check for required resources
# - Create required resources if necessary (optional)
# - Deploy the application

# In addition to `gcloud` commands, this deployment leverages Redis Cloud (https://app.redislabs.com/)
# to create a small (but free) fully-managed Redis instance (potential hosts: AWS/GCP/Azure)
# A URI of this connection should be defined as MIGAS_REDIS_URI in the service instance

# See `example.env` for an example expected .env file

set -eux

HERE=$(dirname $(realpath $0))
ROOT=$(dirname $(dirname $HERE))


# These should be available, but will be account specific
# PROJECT_ID=
# SQL_INSTANCE_PASSWORD=

# Defaults
GCP_REGION="us-central1"
SQL_INSTANCE_NAME="migas-postgres"
SQL_INSTANCE_TIER="db-g1-micro"
CLOUD_RUN_SERVICE_NAME="migas-server"
CLOUD_RUN_ENV_FILE="$HERE/.env"
CLOUD_BUILD_YAML="$HERE/cloudbuild.yml"

# Step 0: Install SDK
# https://github.com/google-github-actions/setup-gcloud

# Step 1: Check for SQL database
SQL_EXISTS=$(gcloud sql instances list --filter name=$SQL_INSTANCE_NAME --uri)

if [[ -z $SQL_EXISTS ]]; then
    # Step 1.5: If not, create it
    gcloud sql instances create $SQL_INSTANCE_NAME \
        --database-version=POSTGRES_14 \
        --region=$GCP_REGION \
        --root-password=$SQL_INSTANCE_PASSWORD \
        --insights-config-query-insights-enabled \
        --tier=$SQL_INSTANCE_TIER

    # create migas database
    gcloud sql databases create migas --instance=migas-postgres
fi

# Step 2: Build the service image
VERSION=${1-"unknown"}
set +e
VER=$(hatch version 2> /dev/null)
if [[ "$VERSION" = "unknown" ]] && [[ -n $VER ]]; then
    VERSION=$VER
fi
set -e
echo "Tagging version: $VERSION"

GCR_TAG=gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME:$VERSION
# gcloud builds submit \
#     --tag $GCR_TAG
gcloud builds submit --config $CLOUD_BUILD_YAML --substitutions=TAG_NAME=$VERSION


# Step 3: Deploy the service
CLOUD_SQL_INSTANCE_ID="$PROJECT_ID:$GCP_REGION:$SQL_INSTANCE_NAME"
if [[ -f $CLOUD_RUN_ENV_FILE ]]; then
    ENV_VARS="--env-vars-file=$CLOUD_RUN_ENV_FILE"
else
    ENV_VARS='--set-env-vars MIGAS_REDIS_URI='$REDIS_URI' \
    --set-env-vars DATABASE_USER=postgres \
    --set-env-vars '"^||^DATABASE_PASSWORD=$SQL_INSTANCE_PASSWORD"' \
    --set-env-vars DATABASE_NAME=migas \
    --set-env-vars GCP_SQL_CONNECTION='"$CLOUD_SQL_INSTANCE_ID"
fi

DEPLOY_CMD="gcloud run deploy $CLOUD_RUN_SERVICE_NAME \
    --region=$GCP_REGION \
    --image=$GCR_TAG \
    --platform=managed \
    --min-instances=1 \
    --max-instances=3 \
    --ingress=all \
    --allow-unauthenticated \
    --set-cloudsql-instances=$CLOUD_SQL_INSTANCE_ID \
    --memory=512Mi \
    --cpu=2 \
    --args=--host,0.0.0.0,--port,8080,--proxy-headers,--header,X-Backend-Server:migas \
    --cpu-throttling \
    $ENV_VARS"

$DEPLOY_CMD

# # Step 4: Map service to custom domain (only needs to be done once)
# ROOT_DOMAIN=nipreps.org  # The root domain name
# TARGET_DOMAIN=migas.nipreps.org  # The target domain, including any subdomains

# gcloud domains verify $ROOT_DOMAIN
# gcloud beta run domain-mappings create --service $CLOUD_RUN_SERVICE_NAME --domain $TARGET_DOMAIN
# # Generate DNS record
# gcloud beta run domain-mappings describe --domain $TARGET_DOMAIN
