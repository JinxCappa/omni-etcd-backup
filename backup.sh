#!/usr/bin/env bash
set -e

# Required parameters:
# - ETCD_ENDPOINT: the etcd endpoint that we want to backup
# - ETCD_BACKUP_DIR: the directory where the backup file will be stored. Default: /backups
# - GPG_PUBLIC_KEY: the public key that will be used to encrypt the backup file
# - DRY_RUN: if set to 1, the script will not perform any action
# 
# Optional parameters for S5CMD - if any of these are not set, the script will not push the backup to S3:
# - S3_BUCKET_NAME: the name of the S3 bucket where the backup will be stored
# - S3_APPLICATION_KEY_ID: the application key ID that will be used to authenticate
# - S3_APPLICATION_KEY: the application key that will be used to authenticate


S3_ENABLED=1

# ------------------------------------------- #
# Ensure that the required parameters are set #
# ------------------------------------------- #

if [ -z "$GPG_PUBLIC_KEY" ]; then
  if [ -z "$GPG_PUBLIC_KEY_B64" ]; then
    echo "GPG_PUBLIC_KEY" or "GPG_PUBLIC_KEY_B64" is not set. Please set it to the public key that will be used to encrypt the backup file.
    exit 1
  fi 
    echo "$GPG_PUBLIC_KEY_B64" | base64 -d > /root/bk.pub
    GPG_PUBLIC_KEY=/root/bk.pub
fi
if [ -z "$ETCD_ENDPOINT" ]; then
  echo "ETCD_ENDPOINT is not set. Please set it to the etcd endpoint."
  exit 1
fi
if [ -z "$ETCD_BACKUP_DIR" ]; then
  ETCD_BACKUP_DIR="/backups"
fi
if [ -z "$SNAPSHOT_NAME" ]; then
  SNAPSHOT_NAME="omni-etcd-snapshot"
fi

# We check if any S3 parameters is not set
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$S3_BUCKET_NAME" ] || [ -z "$S3_ENDPOINT_URL" ]; then
  echo "One or more of the AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET_NAME, S3_ENDPOINT_URL environment variables are not set."
  echo "Disabling S3 backup."
  S3_ENABLED=0
fi

# -------------------------- #
# Generate the ETCd snapshot #
# -------------------------- #

echo "Trying to connect to the etcd endpoint"
etcdctl --endpoints ${ETCD_ENDPOINT} endpoint health

echo "Creating the snapshot of the etcd endpoint"
etcdctl --endpoints ${ETCD_ENDPOINT} snapshot save /tmp/${SNAPSHOT_NAME}.db

# -------------------------- #
# Compress the ETCd snapshot #
# -------------------------- #

echo "Compressing the snapshot"
du -h /tmp/${SNAPSHOT_NAME}.db
xz -f /tmp/${SNAPSHOT_NAME}.db
du -h /tmp/${SNAPSHOT_NAME}.db.xz

# --------------------------------------------------- #
# Do the snapshot encryption using the GPG Public Key #
# --------------------------------------------------- #

if [ ! -f "$GPG_PUBLIC_KEY" ]; then
  echo "The public key file does not exist: $GPG_PUBLIC_KEY"
  exit 1
fi

echo "Add the public key to the keyring and read the name of the key"
gpg --import $GPG_PUBLIC_KEY
GPG_KEY_ID=$(gpg --list-keys --with-colons | grep '^pub' | cut -d':' -f5)

SNAPSHOT_GPG_NAME=${SNAPSHOT_NAME}_$(date +'%Y-%m-%d_%s').db.xz.gpg
echo "Encrypt the snapshot as $SNAPSHOT_GPG_NAME"
rm -f ${ETCD_BACKUP_DIR}/${SNAPSHOT_GPG_NAME}
gpg --trust-model always --output ${ETCD_BACKUP_DIR}/${SNAPSHOT_GPG_NAME} --encrypt --recipient $GPG_KEY_ID /tmp/${SNAPSHOT_NAME}.db.xz


echo "Remove the unencrypted snapshot"
rm /tmp/${SNAPSHOT_NAME}.db.xz

# ------------------------------------------------------------- #
# Push the encrypted snapshot to the backup storage if required #
# ------------------------------------------------------------- #

if [ $S3_ENABLED -eq 1 ]; then
  echo "Upload the encrypted snapshot to the backup storage"
  s5cmd cp ${ETCD_BACKUP_DIR}/${SNAPSHOT_GPG_NAME} s3://${S3_BUCKET_NAME}/$SNAPSHOT_GPG_NAME
else
  echo "S3 backup is disabled. Skipping the upload."
fi