There are two scripts in this project:

1. ) weekly-maintenance.sh

- This is the main script. It's designed to be run either as a a cron job or an on demand script. All actions are logged to /var/log/weekly-maintenance
- It covers apt-get updates and upgrades currently as well as utilities like filesystem trim, rebuilding initramfs, etc.

2. ) weekly-maintenance-setup.sh

- This is a setup script that creates the needed directories, creates the loggers user group needed to view the log files and provides the ability to either adjust a user to become part of the loggers group or create a new user for the loggers group.
