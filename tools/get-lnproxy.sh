# Gets correct version of lnproxy plugin
# Run from lightning/ dir only

if [ -x cli/lightning-cli ] && [ -x lightningd/lightningd ]; then
  echo Downloading lnproxy plugin from github
fi

export LINK="https://raw.githubusercontent.com/willcl-ark/lnproxy/v$(pip show lnproxy | grep Version | cut -c10-)/plugin/lnproxy.py"
echo Using URL: $LINK

wget $LINK -O plugins/lnproxy.py

echo Making plugin executable so that C-Lightning loads it
chmod +x plugins/lnproxy.py

echo Done!
