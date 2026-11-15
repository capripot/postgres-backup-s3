#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

# Deletes the backups of the database under the prefix last modified more than
# that many days ago.
remove_old_backups() {
  local prefix=$1
  local keep_days=$2
  local sec=$((86400*keep_days))
  local date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
  local backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

  echo "Removing old backups from $S3_BUCKET/$prefix..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${prefix}/${POSTGRES_DATABASE}_" \
    --query "${backups_query}" \
    --output text \
    | sed '/^None$/d' \
    | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  echo "Removal complete."
}

# Copies the backup just uploaded under the prefix, from S3 to S3: no new dump
# nor upload. A single CopyObject (up to 5 GB): `aws s3 cp` copies larger than
# 8 MB in parts, each with CopySourceIfMatch, which some S3-compatible
# providers (OVH) refuse as PreconditionFailed.
copy_backup() {
  local prefix=$1
  local key="${s3_uri#s3://${S3_BUCKET}/}"

  echo "Copying backup to $S3_BUCKET/$prefix..."
  aws $aws_args s3api copy-object \
    --bucket "${S3_BUCKET}" \
    --copy-source "${S3_BUCKET}/${key}" \
    --key "${prefix}/${key##*/}" \
    > /dev/null
  echo "Copy complete."
}

echo "Creating backup of $POSTGRES_DATABASE database..."
pg_dump --format=custom \
        -h $POSTGRES_HOST \
        -p $POSTGRES_PORT \
        -U $POSTGRES_USER \
        -d $POSTGRES_DATABASE \
        $PGDUMP_EXTRA_OPTS \
        > db.dump

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

if [ -n "$PASSPHRASE" ]; then
  echo "Encrypting backup..."
  rm -f db.dump.gpg
  gpg --symmetric --batch --passphrase "$PASSPHRASE" db.dump
  rm db.dump
  local_file="db.dump.gpg"
  s3_uri="${s3_uri_base}.gpg"
else
  local_file="db.dump"
  s3_uri="$s3_uri_base"
fi

echo "Uploading backup to $S3_BUCKET..."
aws $aws_args s3 cp "$local_file" "$s3_uri"
rm "$local_file"

echo "Backup complete."

if [ -n "$BACKUP_KEEP_DAYS" ]; then
  remove_old_backups "$S3_PREFIX" "$BACKUP_KEEP_DAYS"
fi

# A weekly copy when the last one is at least 6.5 days old: half a day of slack
# for the time the dump takes, so that a daily schedule copies every 7 days.
if [ -n "$S3_WEEKLY_PREFIX" ]; then
  since=$(date -u -d "@$(($(date +%s) - 561600))" +%Y-%m-%dT%H:%M:%S)
  recent_copies=$(aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_WEEKLY_PREFIX}/${POSTGRES_DATABASE}_" \
    --query "Contents[?LastModified>='${since}'].Key" \
    --output text)

  if [ -z "$recent_copies" ] || [ "$recent_copies" = "None" ]; then
    copy_backup "$S3_WEEKLY_PREFIX"
  fi

  if [ -n "$WEEKLY_BACKUP_KEEP_DAYS" ]; then
    remove_old_backups "$S3_WEEKLY_PREFIX" "$WEEKLY_BACKUP_KEEP_DAYS"
  fi
fi

# A monthly copy of the first backup of each month, even when the 1st was
# missed.
if [ -n "$S3_MONTHLY_PREFIX" ]; then
  month=$(echo "$timestamp" | cut -c1-7)
  month_copies=$(aws $aws_args s3 ls "s3://${S3_BUCKET}/${S3_MONTHLY_PREFIX}/${POSTGRES_DATABASE}_${month}" || true)

  if [ -z "$month_copies" ]; then
    copy_backup "$S3_MONTHLY_PREFIX"
  fi

  if [ -n "$MONTHLY_BACKUP_KEEP_DAYS" ]; then
    remove_old_backups "$S3_MONTHLY_PREFIX" "$MONTHLY_BACKUP_KEEP_DAYS"
  fi
fi
