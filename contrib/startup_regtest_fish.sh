#!/bin/fish

## Short fish shell script to startup two local nodes with
## bitcoind, all running on regtest
## Makes it easier to test things out, by hand.

## Should be called by source since it sets aliases
##
##  First load this file up.
##
##  $ source contrib/startup_regtest.sh
##
##  Start up the nodeset
##
##  $ start_ln
##
##  Let's connect the nodes.
##
##  $ l2-cli getinfo | jq .id
##    "02b96b03e42d9126cb5228752c575c628ad09bdb7a138ec5142bbca21e244ddceb"
##  $ l2-cli getinfo | jq .binding[0].port
##    9090
##  $ l1-cli connect 02b96b03e42d9126cb5228752c575c628ad09bdb7a138ec5142bbca21e244ddceb@localhost:9090
##    {
##      "id" : "030b02fc3d043d2d47ae25a9306d98d2abb7fc9bee824e68b8ce75d6d8f09d5eb7"
##    }
##
##  When you're finished, clean up or stop
##
##  $ stop_ln  # stops the services, keeps the aliases
##  $ cleanup_ln # stops and cleans up aliases
##

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

if [ -z $PATH_TO_BITCOIN ]
  if [ -d $HOME/.bitcoin ]
    set PATH_TO_BITCOIN $HOME/.bitcoin
    # Support OSX default datadir
  else if [ -d $HOME"/Library/Application Support/Bitcoin" ]
    set PATH_TO_BITCOIN $HOME"/Library/Application Support/Bitcoin"
  else
    echo "\$PATH_TO_BITCOIN not set to a .bitcoin dir?" >&2
    exit
  end
end

mkdir -p /tmp/l1-regtest /tmp/l2-regtest /tmp/l3-regtest

# Node one config
echo "network=regtest
daemon
log-level=io
log-file=/tmp/l1-regtest/log
#addr=localhost:6060
bind-addr=/tmp/l1-regtest/unix_socket" > /tmp/l1-regtest/config

# Node two config
echo "network=regtest
network=regtest
daemon
log-level=io
log-file=/tmp/l2-regtest/log
#addr=localhost:9090
bind-addr=/tmp/l2-regtest/unix_socket" > /tmp/l2-regtest/config

# Node three config
echo "network=regtest
network=regtest
daemon
log-level=io
log-file=/tmp/l3-regtest/log
#addr=localhost:12120
bind-addr=/tmp/l3-regtest/unix_socket" > /tmp/l3-regtest/config

alias l1-cli='$LCLI --lightning-dir=/tmp/l1-regtest'
alias l2-cli='$LCLI --lightning-dir=/tmp/l2-regtest'
alias l3-cli='$LCLI --lightning-dir=/tmp/l3-regtest'
alias bt-cli='bitcoin-cli -regtest'
alias l1-log='less /tmp/l1-regtest/log'
alias l2-log='less /tmp/l2-regtest/log'
alias l3-log='less /tmp/l3-regtest/log'

function start_ln
	# Start bitcoind in the background
	test -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" || bitcoind -daemon -regtest -txindex

	# Wait for it to start.
	while ! bt-cli ping 2> /dev/null
	  sleep 1
	end

	# Kick it out of initialblockdownload if necessary
	if bt-cli getblockchaininfo | grep -q 'initialblockdownload.*true'
	  bt-cli generatetoaddress 1 (bt-cli getnewaddress "" "bech32") > /dev/null
	end

	# Start the lightning nodes
	test -f /tmp/l1-regtest/lightningd-regtest.pid || $LIGHTNINGD --lightning-dir=/tmp/l1-regtest
	test -f /tmp/l2-regtest/lightningd-regtest.pid || $LIGHTNINGD --lightning-dir=/tmp/l2-regtest
	test -f /tmp/l3-regtest/lightningd-regtest.pid || $LIGHTNINGD --lightning-dir=/tmp/l3-regtest

	# fund the nodes
	fund_ln

	# Give a hint.
	echo "Commands: l1-cli, l2-cli, l3-cli, bt-cli, fund_ln, connect_ln, connect_ln_proxy, channel_ln, l1_pay_l2, l1_pay_l3, l2_pay_l1, l2_pay_l3, 13_pay_l1, l3_pay_l1, stop_ln, cleanup_ln"
end

function fund_ln
  # Generate 288 blocks to activate segwit then send 1 BTC to each lightning node, confirming it with 6 more blocks
  bt-cli generatetoaddress 288 (bt-cli getnewaddress "" bech32)
  bt-cli sendtoaddress (l1-cli newaddr | jq -r '.bech32') 1
  bt-cli sendtoaddress (l2-cli newaddr | jq -r '.bech32') 1
  bt-cli sendtoaddress (l3-cli newaddr | jq -r '.bech32') 1
  bt-cli generatetoaddress 6 (bt-cli getnewaddress "" bech32)
end

function connect_ln
  # Connect l1 to l2, and l2 to l3 via their Unix Domain Sockets
  l1-cli connect (l2-cli getinfo | jq .id) (l2-cli getinfo | jq .binding[].socket)
  l2-cli connect (l3-cli getinfo | jq .id) (l3-cli getinfo | jq .binding[].socket)
end

function connect_ln_proxy
  # Connect l1 to l2 via the Unix Domain Proxy and l2 to l3 via direct Unix Domain Socket
  l1-cli connect (l2-cli getinfo | jq .id) /tmp/unix_proxy
  l2-cli connect (l3-cli getinfo | jq .id) (l3-cli getinfo | jq .binding[].socket)
end

function channel_ln
  # Open a new channel from l1 to l2 and from l2 to l3 with max amount
  l1-cli fundchannel (l2-cli getinfo | jq .id) 16777215 10000
  l2-cli fundchannel (l3-cli getinfo | jq .id) 16777215 10000
  bt-cli generatetoaddress 6 (bt-cli getnewaddress "" bech32)
end

function l1_pay_l2
  # l1 will pay l2 an amount passed as argument
  l1-cli pay (l2-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l1_pay_l3
  # l1 will pay l2 an amount passed as argument
  l1-cli pay (l3-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l2_pay_l1
  # l2 will pay l1 an amount passed as argument
  l2-cli pay (l1-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l2_pay_l3
  # l2 will pay l1 an amount passed as argument
  l2-cli pay (l3-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l3_pay_l1
  # l2 will pay l1 an amount passed as argument
  l3-cli pay (l1-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l3_pay_l2
  # l2 will pay l1 an amount passed as argument
  l3-cli pay (l2-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function stop_ln
  # Stop both lightning nodes and bitcoind
	test ! -f /tmp/l1-regtest/lightningd-regtest.pid || kill (cat "/tmp/l1-regtest/lightningd-regtest.pid"); rm /tmp/l1-regtest/lightningd-regtest.pid
	test ! -f /tmp/l2-regtest/lightningd-regtest.pid || kill (cat "/tmp/l2-regtest/lightningd-regtest.pid"); rm /tmp/l2-regtest/lightningd-regtest.pid
	test ! -f /tmp/l3-regtest/lightningd-regtest.pid || kill (cat "/tmp/l3-regtest/lightningd-regtest.pid"); rm /tmp/l3-regtest/lightningd-regtest.pid
	test ! -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" || kill (cat "$PATH_TO_BITCOIN/regtest/bitcoind.pid"); rm "$PATH_TO_BITCOIN/regtest/bitcoind.pid"
end

function cleanup_ln
  # Run stop_ln, remove aliases, remove environment variables and cleanup bitcoin and lightning regtest directories
  stop_ln
	functions -e l1-cli
	functions -e l1-log
	functions -e l2-cli
	functions -e l2-log
	functions -e l3-cli
	functions -e l3-log
	functions -e bt-cli
	functions -e start_ln
	functions -e stop_ln
	functions -e cleanup_ln
	set -e PATH_TO_LIGHTNING
	set -e LIGHTNINGD
	set -e LCLI
	rm -Rf /tmp/l1-regtest/
	rm -Rf /tmp/l2-regtest/
	rm -Rf /tmp/l3-regtest/
	rm -Rf "$PATH_TO_BITCOIN/regtest"
end
