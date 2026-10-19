# This is a collection of helper scripts, related to the use of borg

- **startborg.sh** stops a docker-compose stack, backs up its directory and starts the stack again. Obviously assuming only binds, no volumes as they would be lost with this. Meant to be started from crontab.

  `--pdown=<profile>` / `--pup=<profile>` (each repeatable) activate compose profiles for stopping / starting separately, e.g. `--pdown=donotstart` stops services that are deliberately not started again. `-f=<file>` can be given several times for stacks split over multiple compose files: they are stopped in reverse order and started in the given order. If stopping fails, the stack is restarted, an alert mail is sent and no backup is taken.
