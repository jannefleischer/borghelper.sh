#!/bin/bash
#/*
# * Copyright (c) 2024 Janne Jakob Fleischer (ILS gGmbH).
# *
# * This program is free software: you can redistribute it and/or modify
# * it under the terms of the GNU General Public License as published by
# * the Free Software Foundation, version 3.
# *
# * This program is distributed in the hope that it will be useful, but
# * WITHOUT ANY WARRANTY; without even the implied warranty of
# * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# * General Public License for more details.
# *
# * You should have received a copy of the GNU General Public License
# * along with this program. If not, see <http://www.gnu.org/licenses/>.
# */

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

# sends a notification mail to MAILTO (configured in .env), if set.
# nutzt einen SMTP-Server (SMTP_HOST/... in .env), falls konfiguriert,
# ansonsten faellt es auf das lokale sendmail zurueck.
send_alert_mail() {
  local subject="$1"
  local body="$2"

  if [[ -z "$MAILTO" ]]; then
    echo "MAILTO ist nicht in $ENV_FILE gesetzt - Mail-Benachrichtigung wird übersprungen." >&2
    return
  fi

  local mail_from="${SMTP_FROM:-$MAILTO}"
  local msg_file
  msg_file=$(mktemp)
  {
    echo "From: $mail_from"
    echo "To: $MAILTO"
    echo "Subject: $subject"
    echo "Date: $(date -R)"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    echo -e "$body"
  } > "$msg_file"

  if [[ -n "$SMTP_HOST" ]]; then
    local smtp_url
    if [[ "${SMTP_PORT:-587}" == "465" ]]; then
      smtp_url="smtps://$SMTP_HOST:${SMTP_PORT}"
    else
      smtp_url="smtp://$SMTP_HOST:${SMTP_PORT:-587}"
    fi

    local curl_args=(--silent --show-error
      --url "$smtp_url"
      --mail-from "$mail_from"
      --mail-rcpt "$MAILTO"
      --upload-file "$msg_file")

    if [[ "${SMTP_INSECURE}" != "true" ]]; then
      curl_args+=(--ssl-reqd)
    fi

    if [[ -n "$SMTP_USER" ]]; then
      # davmail unterstuetzt kein AUTH PLAIN (obwohl beworben), daher AUTH LOGIN erzwingen
      curl_args+=(--user "$SMTP_USER:$SMTP_PASSWORD" --login-options "AUTH=LOGIN")
    fi

    if ! curl "${curl_args[@]}"; then
      echo "Fehler beim Senden der Mail via SMTP ($SMTP_HOST:${SMTP_PORT:-587})." >&2
    fi
  else
    sendmail -t < "$msg_file"
  fi

  rm -f "$msg_file"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -r=*|--repo=*)
      REPO="${1#*=}"
      ;;
    -c=*|--composestack=*)
      COMPOSESTACK="${1#*=}"
      ;;
    -f=*|--composefile=*)
      COMPOSEFILE="${1#*=}"
      ;;
    -e=*|--exclude=*)
      EXCLUDED="${1#*=}"
      ;;
    -a=*|--archive=*)
      ARCHIVENAME="${1#*=}"
      ;;
    -h=*|--hot=*)
      HOT="${1#*=}"
      ;;
    *)
      echo "This parameter we can't understand:"
      echo "possible are: -r (repo), -c (composestack), -f (composefile), -e (exclude), -a (archive), -h (hot)"
      echo $1
      echo "${1#*=}"
      exit 1
  esac
  shift
done

#necessary attributes missing:
if [[ ( -v REPO && -z $REPO ) || ( -v COMPOSESTACK && -z $COMPOSESTACK ) ]]
then
  printf "Error: REPO or COMPOSESTACK are missing!"
  exit 2
fi

# kein -f gesetzt: docker compose beim Aufruf im COMPOSESTACK-Verzeichnis
# selbst die COMPOSE_FILE-Kette aus dessen .env ermitteln lassen (siehe unten).
if [[ -n "$COMPOSEFILE" ]]
then
  COMPOSE_FILE_ARGS=(-f "$COMPOSESTACK/$COMPOSEFILE")
else
  COMPOSE_FILE_ARGS=()
fi

ISODATE=$(date --iso-8601)
LISTCOMMAND=$(sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list --short --glob-archives "$ISODATE*" $REPO)
#echo "command for existing archives: sudo borg list --short --glob-archives $ISODATE $REPO"
echo "Existing archives: $LISTCOMMAND \n"

EXISTING_ARCHIVES=$(sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list --short --glob-archives "$ISODATE*" $REPO | wc -l)
echo "Existierende Archive:" $EXISTING_ARCHIVES "\n"

#check if archive of today does exist. If it does add a counter to it.
if [[ $EXISTING_ARCHIVES -eq 0 ]]; then
  ISODATE=$ISODATE
else
  ISODATE+=-$((EXISTING_ARCHIVES+1))
fi

#generate Archivename if not given
if [[ -v ARCHIVENAME || -z $ARCHIVENAME ]]
then
  ARCHIVENAME=$ISODATE
fi

echo REPO=$REPO
echo COMPOSESTACK=$COMPOSESTACK
echo COMPOSEFILE=$COMPOSEFILE
echo EXCLUDED=$EXCLUDED
echo ARCHIVENAME=$ARCHIVENAME
echo HOT=$HOT

#check if something is to be excluded
if [[ -v EXCLUDED && -z $EXCLUDED ]]
then
  EXCLUDED_FLAG=""
else
  EXCLUDED_FLAG="--exclude \"$EXCLUDED\""
fi

echo $EXCLUDE_FLAG

ENDSTRING="$REPO/::$ARCHIVENAME $COMPOSESTACK"

if [[ -v ENDSTRING && -z $ENDSTRING ]]
then
  printf "sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats $EXCLUDED_FLAG $ENDSTRING\n"
  printf "Endstring missing, something wrong"
  exit 2
else
  if [[ -z "${HOT}" ]]
  then
    # stop the stack
    printf "\nRUNNING (in %s): sudo docker compose %s stop\n" "$COMPOSESTACK" "${COMPOSE_FILE_ARGS[*]}"
    (cd "$COMPOSESTACK" && sudo docker compose "${COMPOSE_FILE_ARGS[@]}" stop)

    # start borgbackup
    printf "\nRUNNING: sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats $EXCLUDED_FLAG $ENDSTRING\n"
    sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats $EXCLUDED_FLAG $ENDSTRING
    BORG_EXIT=$?
    if [[ $BORG_EXIT -ne 0 ]]; then
      send_alert_mail "[borg] Borg-Backup fehlgeschlagen: $COMPOSESTACK" "Das Backup fuer Stack '$COMPOSESTACK' (Repo: $REPO) ist mit Exit-Code $BORG_EXIT fehlgeschlagen.\n\nArchiv: $ARCHIVENAME\nHost: $(hostname)\nZeitpunkt: $(date --iso-8601=seconds)"
    fi

    # restart the stack
    printf "\nRUNNING (in %s): sudo docker compose %s start\n" "$COMPOSESTACK" "${COMPOSE_FILE_ARGS[*]}"
    (cd "$COMPOSESTACK" && sudo docker compose "${COMPOSE_FILE_ARGS[@]}" start)
    DOCKER_START_EXIT=$?
    if [[ $DOCKER_START_EXIT -ne 0 ]]; then
      send_alert_mail "[borg] Docker-Stack konnte nicht neu gestartet werden: $COMPOSESTACK" "Der Stack '$COMPOSESTACK' ($COMPOSESTACK/$COMPOSEFILE) konnte nach dem Backup nicht wieder gestartet werden (Exit-Code $DOCKER_START_EXIT).\n\nHost: $(hostname)\nZeitpunkt: $(date --iso-8601=seconds)\n\nBitte manuell pruefen!"
    fi
  else
    # only start borgbackup
    printf "\nRUNNING: sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats --comment 'HOT dump! - taken while docker was running.' $EXCLUDED_FLAG $ENDSTRING\n"
    sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats --comment "HOT dump! - taken while docker was running." $EXCLUDED_FLAG $ENDSTRING
    BORG_EXIT=$?
    if [[ $BORG_EXIT -ne 0 ]]; then
      send_alert_mail "Borg-Backup (HOT) fehlgeschlagen: $COMPOSESTACK" "Das HOT-Backup fuer Stack '$COMPOSESTACK' (Repo: $REPO) ist mit Exit-Code $BORG_EXIT fehlgeschlagen.\n\nArchiv: $ARCHIVENAME\nHost: $(hostname)\nZeitpunkt: $(date --iso-8601=seconds)"
    fi
  fi
fi

# start borgbackup

LISTFORMAT="{archive}\t{time}\t{comment}\n"
printf "\nRUNNING: sudo borg list $REPO\n"
ARCHIVELIST=$(sudo BORG_PASSPHRASE="" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes borg list $REPO --format "$LISTFORMAT")
printf "$ARCHIVELIST"

