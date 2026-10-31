# Operations log

How this project's server is run: what was done, when, by whom and why. The ec2-dedicated-host skill appends a
line under **Log** for every command that changes the server or its AWS resources — deploys, rollbacks,
maintenance, backups and restores, monitoring, resizes, upgrades, teardown, secret *names* (never values) —
whether it succeeded or not. People and the agent write decisions, incidents and one-off work under **Notes**.
Read this file before working on the server, and commit it with the project.

## Notes

_decisions, incidents, one-off work — written by people or the agent_

## Log

_appended automatically by ec2-dedicated-host; newest at the bottom_
