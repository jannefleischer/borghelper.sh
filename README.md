# This is a collection of helper scripts, related to the use of borg

startborg.sh stops a docker-compose stack, backs its directory and starts the stack again. Obviously assuming only binds, no volumes as they would be lost with this.