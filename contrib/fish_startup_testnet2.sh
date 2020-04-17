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


mkdir -p /tmp/l1-testnet /tmp/l2-testnet

# Node one config
echo "network=testnet
daemon
log-level=debug
log-file=/tmp/l1-testnet/log
bind-addr=/tmp/l1-testnet/unix_socket
rescan=5

# lnproxy config
onion-tool-path=$PATH_TO_LIGHTNING/devtools/onion

# sauron config
disable-plugin=bcli
sauron-api-endpoint=https://blockstream.info/testnet/api" > /tmp/l1-testnet/config

# Node two config
echo "network=testnet
daemon
log-level=debug
log-file=/tmp/l2-testnet/log
bind-addr=/tmp/l2-testnet/unix_socket
rescan=5

# lnproxy config
onion-tool-path=$PATH_TO_LIGHTNING/devtools/onion

# sauron config
disable-plugin=bcli
sauron-api-endpoint=https://blockstream.info/testnet/api" > /tmp/l2-testnet/config


alias l1-cli='$LCLI --lightning-dir=/tmp/l1-testnet'
alias l2-cli='$LCLI --lightning-dir=/tmp/l2-testnet'
alias l1-log='less /tmp/l1-testnet/log'
alias l2-log='less /tmp/l2-testnet/log'

function start_ln

	# Start the lightning nodes
	test -f /tmp/l1-testnet/lightningd-testnet.pid || $LIGHTNINGD --lightning-dir=/tmp/l1-testnet
	test -f /tmp/l2-testnet/lightningd-testnet.pid || $LIGHTNINGD --lightning-dir=/tmp/l2-testnet

	# Give a hint.
	echo "Commands: l1-cli, l2-cli, l3-cli, add_nodes, connect_ln, connect_ln_proxy, channel_ln,
	channel_ln_priv, l1_pay_l2,	l1_pay_l3, l2_pay_l1, l2_pay_l3, 13_pay_l1, l3_pay_l1, stop_ln, cleanup_ln, set_ln_fees"
end

function restart_ln

  test ! -f /tmp/l1-testnet/lightningd-testnet.pid || kill (cat "/tmp/l1-testnet/lightningd-testnet.pid"); rm /tmp/l1-testnet/lightningd-testnet.pid
	test ! -f /tmp/l2-testnet/lightningd-testnet.pid || kill (cat "/tmp/l2-testnet/lightningd-testnet.pid"); rm /tmp/l2-testnet/lightningd-testnet.pid
	# kill any plugins that might still be floating around
	pkill -f "$PATH_TO_LIGHTNING/lightningd/../plugins/lnproxy.py"
	find /tmp/ -name "[0-9]*" | xargs rm

	sleep 1

	# Start the lightning nodes
	test -f /tmp/l1-testnet/lightningd-testnet.pid || $LIGHTNINGD --lightning-dir=/tmp/l1-testnet
	test -f /tmp/l2-testnet/lightningd-testnet.pid || $LIGHTNINGD --lightning-dir=/tmp/l2-testnet

end

function connect_ln
  # Connect l1 to l2, and l2 to l3 via their Unix Domain Sockets
  l1-cli connect (l2-cli getinfo | jq .id) (l2-cli getinfo | jq .binding[].socket)
end

function add_nodes
  # Add the other nodes to the routing tables by node id, address and listening port
  l1-cli add-node (l2-cli getinfo | jq .id) "127.0.0.1:22222" 11111
  l2-cli add-node (l1-cli getinfo | jq .id) "127.0.0.1:11111" 22222
end

function connect_ln_proxy
  # Add the other nodes to the routing tables
  add_nodes
  # Connect l1 to l2 and l2 to l3
  l1-cli proxy-connect (l2-cli getinfo | jq .id)
end


function channel_ln_priv
  # Open a new channel from l1 to l2 and from l2 to l3 with 100,000 satoshis
  l1-cli fundchannel (l2-cli getinfo | jq .id) 100000 10000 false
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
  l1-cli pay (l2-cli invoice 5000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function l2_pay_l1
  # l2 will pay l1 500_000 msatoshis
  l2-cli pay (l1-cli invoice 5000 (openssl rand -hex 12) (openssl rand -hex 12) | jq -r '.bolt11')
end

function ln_message
  # Send a message from l1 to l2
  l1-cli waitsendpay (l1-cli message (l2-cli getinfo | jq .id) (openssl rand -hex 12) 1000 | jq -r '.payment_hash')
end


function stop_ln
  # Stop both lightning nodes and bitcoind
	test ! -f /tmp/l1-testnet/lightningd-testnet.pid || kill (cat "/tmp/l1-testnet/lightningd-testnet.pid"); rm /tmp/l1-testnet/lightningd-testnet.pid
	test ! -f /tmp/l2-testnet/lightningd-testnet.pid || kill (cat "/tmp/l2-testnet/lightningd-testnet.pid"); rm /tmp/l2-testnet/lightningd-testnet.pid
	# kill any plugins that might still be floating around
	pkill -f "$PATH_TO_LIGHTNING/lightningd/../plugins/lnproxy.py"
end

function cleanup_ln
  # Run stop_ln, remove aliases, remove environment variables and cleanup bitcoin and lightning testnet directories
  stop_ln
	functions -e l1-cli
	functions -e l1-log
	functions -e l2-cli
	functions -e l2-log
	functions -e start_ln
	functions -e restart_ln
	functions -e connect_ln
	functions -e connect_ln_proxy
	functions -e add_nodes
	functions -e stop_ln
	functions -e cleanup_ln
	functions -e set_ln_fees
	functions -e channel_ln_priv
	functions -e ln_message
	set -e PATH_TO_LIGHTNING
	set -e LIGHTNINGD
	set -e LCLI
  while true
  read --prompt "echo 'Do you wish to remove C-Lightning datadir? If using testnet, this will erase any coins in the wallet/channels!!!: ' " -l answer
  switch "$answer"
    case Y y
      rm -Rf /tmp/l1-testnet/; rm -Rf /tmp/l2-testnet/; break
    case N n
      break
    case \*
      echo "Please enter only y/n"
    end
  end
end
