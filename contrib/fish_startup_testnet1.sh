#!/bin/fish

# Short fish shell script to startup two local nodes without
# bitcoind, all running on testnet
# Makes it easier to test things out, by hand.

# Should be called by source since it sets aliases


# Do the Right Thing if we're currently in top of srcdir.
if [ -z $PATH_TO_LIGHTNING ] && [ -x cli/lightning-cli ] && [ -x lightningd/lightningd ]
  set PATH_TO_LIGHTNING (pwd)
end

if [ -z $PATH_TO_LIGHTNING ]
  # Check if installed already, if not, exit script
	type lightning-cli || exit
	type lightningd || exit
	set LCLI lightning-cli
	set LIGHTNINGD lightningd
else
  set LCLI "$PATH_TO_LIGHTNING"/cli/lightning-cli
	set LIGHTNINGD "$PATH_TO_LIGHTNING"/lightningd/lightningd
	# This mirrors "type" output above.
	echo lightning-cli is "$LCLI"
	echo lightningd is "$LIGHTNINGD"
end

if [ -z "$GID" ]
  echo "Please set variable GID first"
  exit
end

mkdir -p /tmp/l1-testnet

# Node config
echo "network=testnet
daemon
log-level=debug
log-file=/tmp/l1-testnet/log
bind-addr=/tmp/l1-testnet/unix_socket
rescan=5

# lnproxy config
onion-tool-path=$PATH_TO_LIGHTNING/devtools/onion
gid=$GID

# sauron config
disable-plugin=bcli
sauron-api-endpoint=https://blockstream.info/testnet/api" > /tmp/l1-testnet/config


alias l1-cli='$LCLI --lightning-dir=/tmp/l1-testnet'
alias l1-log='less /tmp/l1-testnet/log'

function start_ln

	# Start the lightning nodes
	test -f /tmp/l1-testnet/lightningd-testnet.pid || $LIGHTNINGD --lightning-dir=/tmp/l1-testnet

	# Give a hint.
	echo "Commands: l1-cli, proxy-connect, channel_ln, stop_ln, cleanup_ln"
end

function restart_ln

  test ! -f /tmp/l1-testnet/lightningd-testnet.pid || kill (cat "/tmp/l1-testnet/lightningd-testnet.pid"); rm /tmp/l1-testnet/lightningd-testnet.pid
	# kill any plugins that might still be floating around
	pkill -f "$PATH_TO_LIGHTNING/plugins/lnproxy.py"
	find /tmp/ -name "[0-9]*" | xargs rm

	sleep 1

	# Start the lightning nodes
	test -f /tmp/l1-testnet/lightningd-testnet.pid || $LIGHTNINGD --lightning-dir=/tmp/l1-testnet

end

function stop_ln
  # Stop both lightning nodes and bitcoind
	test ! -f /tmp/l1-testnet/lightningd-testnet.pid || kill (cat "/tmp/l1-testnet/lightningd-testnet.pid"); rm /tmp/l1-testnet/lightningd-testnet.pid
	# kill any plugins that might still be floating around
	pkill -f "$PATH_TO_LIGHTNING/lightningd/../plugins/lnproxy.py"
end

function cleanup_ln
  # Run stop_ln, remove aliases, remove environment variables and cleanup bitcoin and lightning testnet directories
  stop_ln
	functions -e l1-cli
	functions -e l1-log
	functions -e start_ln
	functions -e restart_ln
	functions -e stop_ln
	functions -e cleanup_ln
	set -e PATH_TO_LIGHTNING
	set -e LIGHTNINGD
	set -e LCLI
	find /tmp/ -name "[0-9]*" | xargs rm
  while true
    read --prompt "echo 'Do you wish to remove C-Lightning datadir? If using testnet, this will erase any coins in the wallet/channels!!!: ' " -l answer
    switch "$answer"
      case Y y
        rm -Rf /tmp/l1-testnet/; break
      case N n
        break
      case \*
        echo "Please enter only y/n"
      end
  end
end
