#!/usr/bin/env bash
# Runs on the CSL server (naranja7 - our account has /dev/kvm access there).
# Starts the course QEMU VM in a detached tmux session with SSH forwarded to
# host port $PORT, logs in on the serial console, and authorizes the project
# SSH key for root inside the VM.
# Afterwards the VM is reachable from the PC with: ssh hardsoft-vm
set -euo pipefail

IMG="/scratch/$USER/vm.img"
SRC_IMG="$HOME/jammy-server-cloudimg-amd64-disk-kvm.img"
PORT=22041
SESSION=hardsoft-vm
KEY_TAG=hardsoft

PUBKEY="$(grep "$KEY_TAG" ~/.ssh/authorized_keys | tail -n1 | tr -d '\r')"
[ -n "$PUBKEY" ] || { echo "Project key not found in ~/.ssh/authorized_keys"; exit 1; }

if [ ! -f "$IMG" ]; then
    echo "[vm] Copying VM image to $IMG ..."
    mkdir -p "$(dirname "$IMG")"
    cp "$SRC_IMG" "$IMG"
    # The stock cloud image has ~2 GB of space - grow it so pyperformance fits.
    qemu-img resize "$IMG" 22G
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "[vm] tmux session '$SESSION' already exists - reusing it"
else
    if (echo > /dev/tcp/localhost/$PORT) 2>/dev/null; then
        echo "[vm] Port $PORT is already taken on this server - edit PORT here and in ~/.ssh/config"; exit 1
    fi
    echo "[vm] Starting QEMU in tmux session '$SESSION' ..."
    tmux new-session -d -s "$SESSION" \
        "qemu-system-x86_64 -m 8192m -smp 4 -nographic -cpu host -accel kvm \
         -nic user,model=virtio-net-pci,hostfwd=tcp::$PORT-:22 \
         -drive file=$IMG,format=qcow2"
fi

pane() { tmux capture-pane -pJ -t "$SESSION" | grep -v '^$' | tail -n 3; }

echo "[vm] Waiting for the login prompt (first boot can take a few minutes) ..."
for _ in $(seq 1 120); do
    pane | grep -q 'login:' && break
    pane | grep -q 'root@' && break
    sleep 5
done

if pane | grep -q 'login:'; then
    read -rsp "[vm] VM root password (from the course guide): " VMPASS; echo
    tmux send-keys -t "$SESSION" root Enter
    sleep 2
    tmux send-keys -t "$SESSION" -l "$VMPASS"
    tmux send-keys -t "$SESSION" Enter
    unset VMPASS
    sleep 5
fi

pane | grep -q 'root@' || { echo "[vm] Not logged in. Attach with: tmux attach -t $SESSION"; pane; exit 1; }

echo "[vm] Authorizing the project SSH key inside the VM ..."
tmux send-keys -t "$SESSION" -l "mkdir -p /root/.ssh && chmod 700 /root/.ssh && grep -qF '$PUBKEY' /root/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys && ssh-keygen -A && systemctl restart ssh && echo KEY_INSTALLED_OK"
tmux send-keys -t "$SESSION" Enter
sleep 8

if tmux capture-pane -pJ -t "$SESSION" | grep -q '^KEY_INSTALLED_OK'; then
    echo "[vm] Done. VM is running in tmux session '$SESSION' with SSH on port $PORT."
else
    echo "[vm] Could not confirm the key install. Attach with: tmux attach -t $SESSION"; pane; exit 1
fi
