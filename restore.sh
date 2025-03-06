#!/bin/bash
set -e

# Required parameters:
# - GPG_PRIVATE_KEY: the public key that will be used to decrypt the backup file
# - GPG_PASSPHRASE: the passphrase that will be used to decrypt the backup file
# - ETCD_DIR: the directory where the etcd data will be stored. Default: /etcd
# - ETCD_BACKUP_DIR: the directory where the backup file will be stored. Default: /backups

# Optional parameters for S5CMD - if any of these are not set, the script will not get the backup from S3:
# - S3_BUCKET_NAME: the name of the S3 bucket where the backup will be stored
# - S3_APPLICATION_KEY_ID: the application key ID that will be used to authenticate
# - S3_APPLICATION_KEY: the application key that will be used to authenticate

# Future improvement:
# - Check if the file exist before downloading it using the sha1 hash

S3_ENABLED=1

# ------------------------------------------- #
# Ensure that the required parameters are set #
# ------------------------------------------- #

if [ -z "$GPG_PRIVATE_KEY" ]; then
  if [ -z "$GPG_PRIVATE_KEY_B64" ]; then
    echo "GPG_PRIVATE_KEY" or "GPG_PRIVATE_KEY_B64" is not set. Please set it to the private key that will be used to encrypt the backup file.
    exit 1
  fi 
    echo "$GPG_PRIVATE_KEY_B64" | base64 -d > /root/bk.key
    GPG_PRIVATE_KEY=/root/bk.key
fi
if [ -z "$GPG_PASSPHRASE" ]; then
  echo "GPG_PASSPHRASE is not set. Please set it to the passphrase that will be used to decrypt the backup file."
  exit 1
fi
if [ -z "$ETCD_DIR" ]; then
  ETCD_DIR="/etcd"
fi
if [ -z "$ETCD_BACKUP_DIR" ]; then
  ETCD_BACKUP_DIR="/backups"
fi

# Ensure the etcd directory exists before start
if [ ! -d $ETCD_DIR ]; then
  echo "The etcd directory does not exist. Are you sure that you have mounted the volume correctly?"
  exit 1
fi

# Ensure the etcd directory is empty before start
if [ "$(ls -A $ETCD_DIR)" ]; then
  echo "The backup directory is not empty. Skipping the restore."
  exit 0
fi

# Ensure the backup directory exists or create it
mkdir -p $ETCD_BACKUP_DIR

# We check if any S3 parameters is not set
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$S3_BUCKET_NAME" ] || [ -z "$S3_ENDPOINT_URL" ]; then
  echo "One or more of the AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET_NAME, S3_ENDPOINT_URL environment variables are not set."
  echo "Disabling S3 backup."
  S3_ENABLED=0
fi

BACKUP_FILE_TO_RESTORE=""

if [ $S3_ENABLED -eq 1 ]; then
  BACKUP_FILE_TO_RESTORE=$(s5cmd ls s3://$S3_BUCKET_NAME | tail -n 1)

  # Get the file if it exists
  if [ -n "$BACKUP_FILE_TO_RESTORE" ]; then
    echo "Downloading the latest backup from S3:"
    s5cmd cp s3://$S3_BUCKET_NAME/$BACKUP_FILE_TO_RESTORE $ETCD_BACKUP_DIR/$BACKUP_FILE_TO_RESTORE
  else
    echo "No backup found in S3. Exiting."
    exit 1
  fi
else
  echo "S3 backup is disabled. Skipping the download and using the local backup."
  BACKUP_FILE_TO_RESTORE=$(ls -t $ETCD_BACKUP_DIR | head -n 1)
fi

echo "Using the following backup file: $BACKUP_FILE_TO_RESTORE"

# ---------------------------------------------- #
# Decrypt the snapshot using the GPG Private Key #
# ---------------------------------------------- #

if [ ! -f "$GPG_PRIVATE_KEY" ]; then
  echo "The private key file does not exist: $GPG_PRIVATE_KEY"
  exit 1
fi
echo "Add the private key to the keyring and read the name of the key"
gpg --batch --import $GPG_PRIVATE_KEY

GPG_KEY_ID=$(gpg --list-keys --with-colons | grep '^pub' | cut -d':' -f5)

echo Decrypting the backup file using the key $GPG_KEY_ID
gpg --batch --yes --pinentry-mode loopback --passphrase=$GPG_PASSPHRASE --output /tmp/omni-etcd-snapshot.db.xz --decrypt $ETCD_BACKUP_DIR/$BACKUP_FILE_TO_RESTORE

# --------------------- #
# Unzip the backup file #
# --------------------- #

echo "Unzipping the backup file"
xz -d /tmp/omni-etcd-snapshot.db.xz

# -------------------------------- #
# Check the status of the snapshot #
# -------------------------------- #

etcdutl snapshot status /tmp/omni-etcd-snapshot.db

# -------------------------- #
# Extract the backup content #
# -------------------------- #

etcdutl snapshot restore /tmp/omni-etcd-snapshot.db --data-dir=$ETCD_DIR
rm /tmp/omni-etcd-snapshot.db