#!/bin/fish

# Short fish shell script to startup two local nodes with
# bitcoind, all running on regtest
# Makes it easier to test things out, by hand.

# Should be called by source since it sets aliases
#
#  First load this file up.
#
#  $ source contrib/startup_regtest.sh
#
#  Start up the nodeset
#
#  $ start_ln
#
#  Let's connect the nodes.
#
#  $ l2-cli getinfo | jq .id
#    "02b96b03e42d9126cb5228752c575c628ad09bdb7a138ec5142bbca21e244ddceb"
#  $ l2-cli getinfo | jq .binding[0].port
#    9090
#  $ l1-cli connect 02b96b03e42d9126cb5228752c575c628ad09bdb7a138ec5142bbca21e244ddceb@localhost:9090
#    {
#      "id" : "030b02fc3d043d2d47ae25a9306d98d2abb7fc9bee824e68b8ce75d6d8f09d5eb7"
#    }
#
#  When you're finished, clean up or stop
#
#  $ stop_ln  # stops the services, keeps the aliases
#  $ cleanup_ln # stops and cleans up aliases
#

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
log-level=debug
log-file=/tmp/l1-regtest/log
bind-addr=/tmp/l1-regtest/unix_socket
plugin=/Users/will/src/lnproxy/plugin/gotenna.py
gid=1000001
rescan=5" > /tmp/l1-regtest/config

# Node two config
echo "network=regtest
network=regtest
daemon
log-level=debug
log-file=/tmp/l2-regtest/log
bind-addr=/tmp/l2-regtest/unix_socket
plugin=/Users/will/src/lnproxy/plugin/gotenna.py
gid=1000002
rescan=5" > /tmp/l2-regtest/config


alias l1-cli='$LCLI --lightning-dir=/tmp/l1-regtest'
alias l2-cli='$LCLI --lightning-dir=/tmp/l2-regtest'
alias bt-cli='bitcoin-cli -regtest'
alias l1-log='less /tmp/l1-regtest/log'
alias l2-log='less /tmp/l2-regtest/log'

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

	# fund the nodes
	fund_ln

	# Give a hint.
	echo "Commands: l1-cli, l2-cli, l3-cli, bt-cli, fund_ln, add_nodes, connect_ln, connect_ln_proxy, channel_ln,
	channel_ln_priv, l1_pay_l2,	l1_pay_l3, l2_pay_l1, l2_pay_l3, 13_pay_l1, l3_pay_l1, stop_ln, cleanup_ln, set_ln_fees"
end

function restart_ln
	
  test ! -f /tmp/l1-regtest/lightningd-regtest.pid || kill (cat "/tmp/l1-regtest/lightningd-regtest.pid"); rm /tmp/l1-regtest/lightningd-regtest.pid
	test ! -f /tmp/l2-regtest/lightningd-regtest.pid || kill (cat "/tmp/l2-regtest/lightningd-regtest.pid"); rm /tmp/l2-regtest/lightningd-regtest.pid
	# kill any plugins that might still be floating around
	pkill -f /Users/will/src/lnproxy/plugin/gotenna.py
	find /tmp/ -name "[0-9]*" | xargs rm

	# Start the lightning nodes
	test -f /tmp/l1-regtest/lightningd-regtest.pid || $LIGHTNINGD --lightning-dir=/tmp/l1-regtest
	test -f /tmp/l2-regtest/lightningd-regtest.pid || $LIGHTNINGD --lightning-dir=/tmp/l2-regtest

end

function fund_ln
  # Generate 101 blocks to mature a block then send 1 BTC to each lightning node, confirming it with 6 more blocks
  bt-cli generatetoaddress 101 (bt-cli getnewaddress "" bech32)
  bt-cli sendtoaddress (l1-cli newaddr | jq -r '.bech32') 1
  bt-cli sendtoaddress (l2-cli newaddr | jq -r '.bech32') 1
  bt-cli generatetoaddress 6 (bt-cli getnewaddress "" bech32)
end

function connect_ln
  # Connect l1 to l2, and l2 to l3 via their Unix Domain Sockets
  l1-cli connect (l2-cli getinfo | jq .id) (l2-cli getinfo | jq .binding[].socket)
end

function add_nodes
  # Add the other nodes to the routing tables by GID and node id
  l1-cli add-node 1000002 (l2-cli getinfo | jq .id)

  l2-cli add-node 1000001 (l1-cli getinfo | jq .id)
end

function connect_ln_proxy
  # Add the other nodes to the routing tables
  add_nodes
  # Connect l1 to l2 and l2 to l3
  l1-cli proxy-connect 1000002
end


function channel_ln_priv
  # Open a new channel from l1 to l2 and from l2 to l3 with 5,000,000 satoshis
  l1-cli fundchannel (l2-cli getinfo | jq .id) 5000000 10000 false
  bt-cli generatetoaddress 6 (bt-cli getnewaddress "" bech32)
  set_ln_fees 0 0
end

function set_ln_fees
  # Set the fees for all channels to zero
  for channel in (l1-cli listfunds | jq .channels[].peer_id)
    l1-cli setchannelfee $channel $argv[1] $argv[2]
  end
  for channel in (l2-cli listfunds | jq .channels[].peer_id)
    l2-cli setchannelfee $channel $argv[1] $argv[2]
  end
end

function ping_ln
  # Ping the nodes so pings don't interrupt us
  l1-cli ping (l2-cli getinfo | jq .id)
end

function l1_pay_l2
  # l1 will pay l2 500_000 msatoshis
#  l1-cli pay (l2-cli invoice $argv (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
  l1-cli pay (l2-cli invoice 500000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l1_pay_l3
  # l1 will pay l2 500_000 msatoshis
  l1-cli pay (l3-cli invoice 500000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l2_pay_l1
  # l2 will pay l1 500_000 msatoshis
  l2-cli pay (l1-cli invoice 500000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l2_pay_l3
  # l2 will pay l1 500_000 msatoshis
  l2-cli pay (l3-cli invoice 500000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l3_pay_l1
  # l2 will pay l1 500_000 msatoshis
  l3-cli pay (l1-cli invoice 500000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l3_pay_l2
  # l2 will pay l1 500_000 msatoshis
  l3-cli pay (l2-cli invoice 500000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function full_test
  # Set up from new, keep paying invoices endlessly
  connect_ln_proxy
  sleep 10
  channel_ln_priv
  sleep 30
  while true
    l1_pay_l2
    sleep 30
  end
end

function ln_message
  # Loop send messages from l1 to l3
  l1-cli waitsendpay (l1-cli message 1000003 (openssl rand -hex 12) 100000 | jq -r '.payment_hash')
end


function stop_ln
  # Stop both lightning nodes and bitcoind
	test ! -f /tmp/l1-regtest/lightningd-regtest.pid || kill (cat "/tmp/l1-regtest/lightningd-regtest.pid"); rm /tmp/l1-regtest/lightningd-regtest.pid
	test ! -f /tmp/l2-regtest/lightningd-regtest.pid || kill (cat "/tmp/l2-regtest/lightningd-regtest.pid"); rm /tmp/l2-regtest/lightningd-regtest.pid
	# kill any plugins that might still be floating around
	pkill -f /Users/will/src/lnproxy/plugin/gotenna.py
	test ! -f "$PATH_TO_BITCOIN/regtest/bitcoind.pid" || kill (cat "$PATH_TO_BITCOIN/regtest/bitcoind.pid"); rm "$PATH_TO_BITCOIN/regtest/bitcoind.pid"
end

function cleanup_ln
  # Run stop_ln, remove aliases, remove environment variables and cleanup bitcoin and lightning regtest directories
  stop_ln
	functions -e l1-cli
	functions -e l1-log
	functions -e l2-cli
	functions -e l2-log
	functions -e bt-cli
	functions -e start_ln
	functions -e restart_ln
	functions -e fund_ln
	functions -e connect_ln
	functions -e connect_ln_proxy
	functions -e add_nodes
	functions -e stop_ln
	functions -e cleanup_ln
	functions -e set_ln_fees
	functions -e channel_ln_priv
	functions -e full_test
	functions -e ln_message
	set -e PATH_TO_LIGHTNING
	set -e LIGHTNINGD
	set -e LCLI
	rm -Rf /tmp/l1-regtest/
	rm -Rf /tmp/l2-regtest/
	rm -Rf "$PATH_TO_BITCOIN/regtest"
	find /tmp/ -name "[0-9]*" | xargs rm
end
