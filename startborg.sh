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

# bereits vor dem Sourcing gesetzte Werte (z.B. auf der Kommandozeile) merken,
# damit sie Vorrang vor der .env-Datei behalten statt stillschweigend
# ueberschrieben zu werden.
_PRESET_BORG_PASSPHRASE="${BORG_PASSPHRASE+x}"
_PRESET_BORG_RELOCATED_REPO_ACCESS_IS_OK="${BORG_RELOCATED_REPO_ACCESS_IS_OK+x}"
_ORIG_BORG_PASSPHRASE="$BORG_PASSPHRASE"
_ORIG_BORG_RELOCATED_REPO_ACCESS_IS_OK="$BORG_RELOCATED_REPO_ACCESS_IS_OK"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

[[ -n "$_PRESET_BORG_PASSPHRASE" ]] && BORG_PASSPHRASE="$_ORIG_BORG_PASSPHRASE"
[[ -n "$_PRESET_BORG_RELOCATED_REPO_ACCESS_IS_OK" ]] && BORG_RELOCATED_REPO_ACCESS_IS_OK="$_ORIG_BORG_RELOCATED_REPO_ACCESS_IS_OK"

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

# sudo setzt die Umgebung standardmaessig zurueck, daher werden
# BORG_PASSPHRASE und BORG_RELOCATED_REPO_ACCESS_IS_OK (falls in .env gesetzt)
# hier explizit an jeden borg-Aufruf durchgereicht.
BORG_SUDO_ENV=(BORG_PASSPHRASE="$BORG_PASSPHRASE" BORG_RELOCATED_REPO_ACCESS_IS_OK="$BORG_RELOCATED_REPO_ACCESS_IS_OK")

EXCLUDES=()

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
      EXCLUDES+=("${1#*=}")
      #EXCLUDED="${1#*=}"
      ;;
    -a=*|--archive=*)
      ARCHIVENAME="${1#*=}"
      ;;
    -h=*|--hot=*)
      HOT="${1#*=}"
      ;;
    -p=*|--pre-script=*)
      PRESCRIPT="${1#*=}"
      ;;
    -m=*|--mid-script=*)
      MIDSCRIPT="${1#*=}"
      ;;
    -o=*|--post-script=*)
      POSTSCRIPT="${1#*=}"
      ;;
    *)
      echo "This parameter we can't understand:"
      echo "possible are: -r (repo), -c (composestack), -f (composefile), -e (exclude), -a (archive), -h (hot), -p (pre-script), -m (mid-script), -o (post-script)"
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

# validate pre-script early, before we stop anything
if [[ -n "$PRESCRIPT" && ! -x "$PRESCRIPT" ]]
then
  printf "Error: pre-script '%s' does not exist or is not executable (chmod +x it).\n" "$PRESCRIPT"
  exit 2
fi

# validate mid-script early, before we stop anything
if [[ -n "$MIDSCRIPT" && ! -x "$MIDSCRIPT" ]]
then
  printf "Error: mid-script '%s' does not exist or is not executable (chmod +x it).\n" "$MIDSCRIPT"
  exit 2
fi

# validate post-script early, before we stop anything
if [[ -n "$POSTSCRIPT" && ! -x "$POSTSCRIPT" ]]
then
  printf "Error: post-script '%s' does not exist or is not executable (chmod +x it).\n" "$POSTSCRIPT"
  exit 2
fi

# setting default compose file name.
if [[ ! -v COMPOSEFILE || -z $COMPOSEFILE ]]
then
  #defaut value
  COMPOSEFILE="docker-compose.yml"
fi

ISODATE=$(date --iso-8601)
LISTCOMMAND=$(sudo "${BORG_SUDO_ENV[@]}" borg list --short --glob-archives "$ISODATE*" $REPO)
#echo "command for existing archives: sudo borg list --short --glob-archives $ISODATE $REPO"
echo "Existing archives: $LISTCOMMAND \n"

EXISTING_ARCHIVES=$(sudo "${BORG_SUDO_ENV[@]}" borg list --short --glob-archives "$ISODATE*" $REPO | wc -l)
echo "Existierende Archive:" $EXISTING_ARCHIVES "\n"

#check if archive of today does exist. If it does add a counter to it.
if [[ $EXISTING_ARCHIVES -eq 0 ]]; then
  ISODATE=$ISODATE
else
  ISODATE+=-$((EXISTING_ARCHIVES+1))
fi

#generate Archivename if not given
if [[ ! -v ARCHIVENAME || -z $ARCHIVENAME ]]
then
  ARCHIVENAME=$ISODATE
fi

echo REPO=$REPO
echo COMPOSESTACK=$COMPOSESTACK
echo COMPOSEFILE=$COMPOSEFILE
echo EXCLUDED=${EXCLUDES[@]}
echo ARCHIVENAME=$ARCHIVENAME
echo HOT=$HOT
echo PRESCRIPT=$PRESCRIPT
echo MIDSCRIPT=$MIDSCRIPT
echo POSTSCRIPT=$POSTSCRIPT

#check if something is to be excluded
EXCLUDE_ARGS=()
for p in "${EXCLUDES[@]}"; do
  EXCLUDE_ARGS+=(--exclude "$p")
done
#if [[ -v EXCLUDED && -z $EXCLUDED ]]
#then
#  EXCLUDED_FLAG=""
#else
#  EXCLUDED_FLAG="--exclude \"$EXCLUDED\""
#fi

echo $EXCLUDE_FLAG

ARCHIVE_ARG="$REPO/::$ARCHIVENAME"
TARGET_PATH="$COMPOSESTACK"
#ENDSTRING="$REPO/::$ARCHIVENAME $COMPOSESTACK"

if [[ -v ENDSTRING && -z $ENDSTRING ]]
then
  printf "sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats "${EXCLUDE_ARGS[@]}" "$ARCHIVE_ARG" "$TARGET_PATH"\n"
  printf "Endstring missing, something wrong"
  exit 2
else
  if [[ -z "${HOT}" ]]
  then
    # run pre-script, if given, before the stack is stopped
    if [[ -n "$PRESCRIPT" ]]
    then
      printf "\nRUNNING pre-script: %s\n" "$PRESCRIPT"
      COMPOSESTACK="$COMPOSESTACK" COMPOSEFILE="$COMPOSEFILE" "$PRESCRIPT"
      PRESCRIPT_STATUS=$?
      if [[ $PRESCRIPT_STATUS -ne 0 ]]
      then
        printf "\nError: pre-script '%s' failed with exit code %d. Aborting backup.\n" "$PRESCRIPT" "$PRESCRIPT_STATUS"
        exit 4
      fi
    fi

    # stop the stack
    printf "\nRUNNING: sudo docker compose -f " $COMPOSESTACK/$COMPOSEFILE "stop\n"
    sudo docker compose -f $COMPOSESTACK/$COMPOSEFILE stop

    # run mid-script, if given, now that the stack is stopped
    if [[ -n "$MIDSCRIPT" ]]
    then
      printf "\nRUNNING mid-script: %s\n" "$MIDSCRIPT"
      COMPOSESTACK="$COMPOSESTACK" COMPOSEFILE="$COMPOSEFILE" "$MIDSCRIPT"
      MIDSCRIPT_STATUS=$?
      if [[ $MIDSCRIPT_STATUS -ne 0 ]]
      then
        printf "\nError: mid-script '%s' failed with exit code %d. Restarting stack and aborting backup.\n" "$MIDSCRIPT" "$MIDSCRIPT_STATUS"
        sudo docker compose -f $COMPOSESTACK/$COMPOSEFILE start
        exit 3
      fi
    fi

    # start borgbackup
    BORGCMD=(sudo "${BORG_SUDO_ENV[@]}" borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats "${EXCLUDE_ARGS[@]}" "$ARCHIVE_ARG" "$TARGET_PATH")

    # menschenlesbare, sicher gequotete Ausgabe
    printf "\nRUNNING: "
    printf '%q ' "${BORGCMD[@]}"
    printf "\n"

    # ausführen
    "${BORGCMD[@]}"
    BORG_EXIT=$?
    if [[ $BORG_EXIT -ne 0 ]]; then
      send_alert_mail "[borg] Borg-Backup fehlgeschlagen: $COMPOSESTACK" "Das Backup fuer Stack '$COMPOSESTACK' (Repo: $REPO) ist mit Exit-Code $BORG_EXIT fehlgeschlagen.\n\nArchiv: $ARCHIVENAME\nHost: $(hostname)\nZeitpunkt: $(date --iso-8601=seconds)"
    fi

    #printf "\nRUNNING: sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats "${EXCLUDE_ARGS[@]}"  "$ARCHIVE_ARG" "$TARGET_PATH"\n"
    #sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats "${EXCLUDE_ARGS[@]}"  "$ARCHIVE_ARG" "$TARGET_PATH"

    # restart the stack
    printf "\nRUNNING: sudo docker compose -f" $COMPOSESTACK/$COMPOSEFILE "start\n"
    sudo docker compose -f $COMPOSESTACK/$COMPOSEFILE start
    DOCKER_START_EXIT=$?
    if [[ $DOCKER_START_EXIT -ne 0 ]]; then
      send_alert_mail "[borg] Docker-Stack konnte nicht neu gestartet werden: $COMPOSESTACK" "Der Stack '$COMPOSESTACK' ($COMPOSESTACK/$COMPOSEFILE) konnte nach dem Backup nicht wieder gestartet werden (Exit-Code $DOCKER_START_EXIT).\n\nHost: $(hostname)\nZeitpunkt: $(date --iso-8601=seconds)\n\nBitte manuell pruefen!"
    fi

    # run post-script, if given, now that the stack is running again
    if [[ -n "$POSTSCRIPT" ]]
    then
      printf "\nRUNNING post-script: %s\n" "$POSTSCRIPT"
      COMPOSESTACK="$COMPOSESTACK" COMPOSEFILE="$COMPOSEFILE" "$POSTSCRIPT"
      POSTSCRIPT_STATUS=$?
      if [[ $POSTSCRIPT_STATUS -ne 0 ]]
      then
        printf "\nError: post-script '%s' failed with exit code %d.\n" "$POSTSCRIPT" "$POSTSCRIPT_STATUS"
        exit 3
      fi
    fi
  else
    # only start borgbackup
    printf "\nRUNNING: sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats --comment 'HOT dump! - taken while docker was running.' "${EXCLUDE_ARGS[@]}" "$ARCHIVE_ARG" "$TARGET_PATH"\n"
    sudo "${BORG_SUDO_ENV[@]}" borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats --comment "HOT dump! - taken while docker was running." "${EXCLUDE_ARGS[@]}" "$ARCHIVE_ARG" "$TARGET_PATH"
    BORG_EXIT=$?
    if [[ $BORG_EXIT -ne 0 ]]; then
      send_alert_mail "Borg-Backup (HOT) fehlgeschlagen: $COMPOSESTACK" "Das HOT-Backup fuer Stack '$COMPOSESTACK' (Repo: $REPO) ist mit Exit-Code $BORG_EXIT fehlgeschlagen.\n\nArchiv: $ARCHIVENAME\nHost: $(hostname)\nZeitpunkt: $(date --iso-8601=seconds)"
    fi
  fi
fi

# start borgbackup

LISTFORMAT="{archive}\t{time}\t{comment}\n"
printf "\nRUNNING: sudo borg list $REPO\n"
ARCHIVELIST=$(sudo "${BORG_SUDO_ENV[@]}" borg list $REPO --format "$LISTFORMAT")
printf "$ARCHIVELIST"
