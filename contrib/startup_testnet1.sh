#!/bin/sh

## Short script to startup two local nodes with
## bitcoind, all running on testnet
## Makes it easier to test things out, by hand.

## Should be called by source since it sets aliases
##
##  First load this file up.
##
##  $ source contrib/startup_testnet1.sh


# Do the Right Thing if we're currently in top of srcdir.
if [ -z "$PATH_TO_LIGHTNING" ] && [ -x cli/lightning-cli ] && [ -x lightningd/lightningd ]; then
	PATH_TO_LIGHTNING=$(pwd)
fi

if [ -z "$PATH_TO_LIGHTNING" ]; then
	# Already installed maybe?  Prints
	# shellcheck disable=SC2039
	type lightning-cli || return
	# shellcheck disable=SC2039
	type lightningd || return
	LCLI=lightning-cli
	LIGHTNINGD=lightningd
else
	LCLI="$PATH_TO_LIGHTNING"/cli/lightning-cli
	LIGHTNINGD="$PATH_TO_LIGHTNING"/lightningd/lightningd
	# This mirrors "type" output above.
	echo lightning-cli is "$LCLI"
	echo lightningd is "$LIGHTNINGD"
fi

mkdir -p /tmp/l1-testnet

# Node config
cat << EOF > /tmp/l1-testnet/config
network=testnet
daemon
log-level=debug
log-file=/tmp/l1-testnet/log
bind-addr=/tmp/l1-testnet/unix_socket
rescan=5

# lnproxy config
onion-tool-path=$PATH_TO_LIGHTNING/devtools/onion

# sauron config
disable-plugin=bcli
sauron-api-endpoint=https://blockstream.info/testnet/api
EOF


alias l1-cli='$LCLI --lightning-dir=/tmp/l1-testnet'
alias l1-log='less /tmp/l1-testnet/log'

start_ln() {

	# Start the lightning nodes
	test -f /tmp/l1-testnet/lightningd-testnet.pid || \
		"$LIGHTNINGD" --lightning-dir=/tmp/l1-testnet

	# Give a hint.
	echo "Commands: l1-cli, l1-log, restart_ln, stop_ln, cleanup_ln"
}

restart_ln() {
  stop_ln
  sleep 1
  start_ln
}

stop_ln() {
	test ! -f /tmp/l1-testnet/lightningd-testnet.pid || \
		(kill "$(cat /tmp/l1-testnet/lightningd-testnet.pid)"; \
		rm /tmp/l1-testnet/lightningd-testnet.pid)
}

cleanup_ln() {
	stop_ln
	unalias l1-cli
	unalias l1-log
	unset -f start_ln
	unset -f test_msg_ln
	unset -f restart_ln
	unset -f stop_ln
	while true; do
    read -p "Do you wish to remove C-Lightning datadir? If using testnet, this will erase any coins in the wallet/channels!!!" yn
    case $yn in
        [Yy]* ) rm -Rf /tmp/l1-testnet/; break;;
        [Nn]* ) exit;;
        * ) echo "Please answer y or n.";;
    esac
  done
	unset -f cleanup_ln
}
