FROM ubuntu:20.04
RUN export DEBIAN_FRONTEND='noninteractive' \
    && apt-get update \
    && apt-get install -y software-properties-common curl gnupg2 \
    && curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add - \
    && apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    && apt-get update && apt-get install --reinstall -y vault \
    && rm -rf /var/lib/apt/lists/* \
    && setcap cap_ipc_lock=+ep $(readlink -f $(which vault)) \
    && setcap -r /usr/bin/vault
    
COPY run.sh ./
CMD ./run.sh
