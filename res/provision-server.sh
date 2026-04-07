#!/bin/bash

set -euv -o pipefail
HERE=`realpath $(dirname $0)`
cd "$HERE/../.."
NEWUSER=ubuntu

sudo apt update
sudo apt install -y tmux

# create a (non-privileged) user to run the server:
sudo useradd -m $NEWUSER || true
sudo usermod -s /bin/bash $NEWUSER
sudo usermod -aG $NEWUSER `whoami`
echo "`whoami` ALL= ($NEWUSER) NOPASSWD: ALL
Defaults> $NEWUSER umask=0777" | sudo tee /etc/sudoers.d/99-nanosoldier

sudo -u $NEWUSER sh -c '[ -x "$HOME/.juliaup/bin/juliaup" ] || curl -fsSL https://install.julialang.org | sh -s -- --yes'
sudo -u $NEWUSER sh -c '$HOME/.juliaup/bin/juliaup config manifestversiondetect true'
sudo -u $NEWUSER sh -c '$HOME/.juliaup/bin/juliaup config autoinstallchannels true'

sudo -u $NEWUSER sh -c 'cd && mkdir -p .ssh && { [ -f .ssh/id_ed25519.pub ] || ssh-keygen -N "" -f .ssh/id_ed25519 -t ed25519; }'
echo "
Host nanosoldier? nanosoldier?.csail.mit.edu
  ProxyJump none
  User nanosoldier
" | sudo -u $NEWUSER tee -a /home/$NEWUSER/.ssh/config
sudo -u $NEWUSER touch /home/$NEWUSER/.ssh/authorized_keys
sudo -u $NEWUSER chmod 700 /home/$NEWUSER/.ssh/config
sudo -u $NEWUSER chmod 700 /home/$NEWUSER/.ssh/authorized_keys
sudo -u $NEWUSER sh -c 'cd && git config --global user.name "nanosoldier"'
sudo -u $NEWUSER sh -c 'cd && git config --global user.email "nanosoldierjulia@gmail.com"'
sudo -u $NEWUSER sh -c 'cd && ssh -T git@github.com' || true

[ -d PkgEval.jl ] || git clone https://github.com/JuliaCI/PkgEval.jl
sudo -u $NEWUSER sh -c "\$HOME/.juliaup/bin/julia --color=yes --project=$HERE/.. -e 'using Pkg; Pkg.instantiate()'"

set +v

echo
echo "-------------"
echo "manual steps (for master machine, not workers):"
echo "-------------"
echo
echo "install this ssh key in github for user @$NEWUSER at"
echo "  https://github.com/settings/ssh/new"
echo "and on all worker machines at /home/$NEWUSER/.ssh/authorized_keys"
sudo -u $NEWUSER cat /home/$NEWUSER/.ssh/id_ed25519.pub
echo
echo "and generate an auth-token for later at"
echo "  https://github.com/settings/tokens/new"
echo "  scopes: 'repo' (all), 'notifications'"
echo
echo "install this webhook in github at"
echo "  https://github.com/JuliaLang/julia/settings/hooks"
echo "  url: http://<this-ip>:<random-port>"
echo "  content-type: application/json"
echo "  secret: <random-string>"
echo "  events: 'Commit comments', 'Issue comments', 'Pull request review comments'"
echo
echo "firewall configuration:"
echo "  ensure TCP <random-port> is not blocked"
echo "  ensure ssh (TCP 22) is not blocked for your ip address"
echo "  ensure all other ports are blocked"
echo
echo "these special values, you will insert into env."
echo "to use, as user '$NEWUSER':"
echo "  cd `dirname $0`"
echo "  export GITHUB_AUTH=<auth-token>"
echo "  export GITHUB_SECRET=<random-string>"
echo "  export GITHUB_PORT=<random-port>"
echo "  export JULIA_PROJECT=`dirname $0`"
echo "  . ../cset/bin/activate"
echo "  setarch -R \$HOME/.juliaup/bin/julia -L bin/setup_test_ci.jl -e 'using Sockets; run(server, IPv4(0), ENV[\"GITHUB_PORT\"])'"
echo
echo "or with a helper script:"
echo "  (umask 007 && cp bin/run_base_ci.jl ..)"
echo "  (umask 007 && touch ../run_base_ci.stdout ../run_base_ci.stderr)"
echo "  sudo chgrp $NEWUSER ../run_base_ci.jl ../run_base_ci.stdout ../run_base_ci.stderr"
echo "  \${EDITOR:-vim} ../run_base_ci.jl"
echo "  ./run_base_ci"
