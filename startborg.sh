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

# setting default compose file name.
if [[ -v COMPOSEFILE || -z $COMPOSEFILE ]]
then
  #defaut value
  COMPOSEFILE="docker-compose.yml"
fi

ISODATE=$(date --iso-8601)
LISTCOMMAND=$(sudo borg list --short --glob-archives "$ISODATE*" $REPO)
#echo "command for existing archives: sudo borg list --short --glob-archives $ISODATE $REPO"
echo "Existing archives: $LISTCOMMAND \n"

EXISTING_ARCHIVES=$(sudo borg list --short --glob-archives "$ISODATE*" $REPO | wc -l)
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
  printf "sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats $EXCLUDED_FLAG $ENDSTRING\n"
  printf "Endstring missing, something wrong"
  exit 2
else
  if [[ -z "${HOT}" ]]
  then
    # stop the stack
    printf "\nRUNNING: sudo docker compose -f " $COMPOSESTACK/$COMPOSEFILE "stop\n"
    sudo docker compose -f $COMPOSESTACK/$COMPOSEFILE stop

    # start borgbackup
    printf "\nRUNNING: sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats $EXCLUDED_FLAG $ENDSTRING\n"
    sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats $EXCLUDED_FLAG $ENDSTRING

    # restart the stack
    printf "\nRUNNING: sudo docker compose -f" $COMPOSESTACK/$COMPOSEFILE "start\n"
    sudo docker compose -f $COMPOSESTACK/$COMPOSEFILE start
  else
    # only start borgbackup
    printf "\nRUNNING: sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats --comment 'HOT dump! - taken while docker was running.' $EXCLUDED_FLAG $ENDSTRING\n"
    sudo borg create --checkpoint-interval=600 --compression zlib,5 --progress --stats --comment "HOT dump! - taken while docker was running." $EXCLUDED_FLAG $ENDSTRING
  fi
fi

# start borgbackup

LISTFORMAT="{archive}\t{time}\t{comment}\n"
printf "\nRUNNING: sudo borg list $REPO\n"
ARCHIVELIST=$(sudo borg list $REPO --format "$LISTFORMAT")
printf "$ARCHIVELIST"

