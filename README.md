# Vault Agent (Persistent) Docker Compose Setup

May 01, 2022

​      [        ![vault](https://d33wubrfki0l68.cloudfront.net/5045c92d1afa5de2fdf624342bcbe019edf5fb98/4f46d/static/c3ae3a7109d48731ebbf7502f82decd8/1c72d/vault.jpg)   ](https://www.spektor.dev/static/c3ae3a7109d48731ebbf7502f82decd8/c08c5/vault.jpg)    

**TL;DR:** You can find the code in this Github [repo](https://github.com/yossisp/vault-agent-docker-compose).

Recently I needed to integrate [Hashicorp Vault](https://www.hashicorp.com/products/vault) with a Java application. For local development I wanted to use [Vault Agent](https://www.vaultproject.io/docs/agent) which can connect to the Vault server. The advantage of using Vault  Agent is that it bears the brunt of authentication complexity with Vault server (including SSL certificates). Effectively, this means that a  client application can send HTTP requests to Vault Agent without any  need to authenticate. This setup is frequently used in the real world  for example by using [Agent Sidecar Injector](https://www.vaultproject.io/docs/platform/k8s/injector) inside a Kubernetes cluster. It makes it easy for client applications  inside a K8s pod to get/put information to a Vault server without each  one having to perform the tedious authentication process.

Surprisingly, I couldn’t find much information on using Vault with  Vault Agent via docker-compose, which in my opinion is by far the  easiest method to set up a Vault playground. I did find [this](https://gitlab.com/kawsark/vault-agent-docker/-/tree/master) example which served as the inspiration for this post however it  involves a more complex setup as well as using Postgres and Nginx. I’d  like to present the most minimal setup, the bare basics needed to spin  up a Vault Agent and access it locally via `localhost`.

**WARNING:** the setup is intentionally simplified, please don’t use it in production.

First of all we’ll use the official Vault docker images for the `docker-compose.yml`:

```yml
version: '3.7'

services:
  vault-agent:
    image: hashicorp/vault:1.9.6
    restart: always
    ports:
      - "8200:8200"
    volumes:
      - ./helpers:/helpers
    environment:
      VAULT_ADDR: "http://vault:8200"
    container_name: vault-agent
    entrypoint: "vault agent -log-level debug -config=/helpers/vault-agent.hcl"
    depends_on:
      vault:
        condition: service_healthy
  vault:
    image: hashicorp/vault:1.9.6
    restart: always
    volumes:
      - ./helpers:/helpers
      - vault_data:/vault/file
    ports:
      - "8201:8200/tcp"
    cap_add:
      - IPC_LOCK
    container_name: vault
    entrypoint: "vault server -config=/helpers/vault-config.hcl"
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:8200 || exit 1
      interval: 10s
      retries: 12
      start_period: 10s
      timeout: 10s

volumes:
  vault_data: {}
```

Here we’re using the same image to start Vault server in dev mode as  well as start the Vault Agent. In addition a volume is created for `helpers` directory which will contain:

1. The policy for Vault server `admin-policy.hcl`:

   ```hcl
   path "sys/health"
   {
   capabilities = ["read", "sudo"]
   }
   path "sys/policies/acl"
   {
   capabilities = ["list"]
   }
   path "sys/policies/acl/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "auth/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "sys/auth/*"
   {
   capabilities = ["create", "update", "delete", "sudo"]
   }
   path "sys/auth"
   {
   capabilities = ["read"]
   }
   path "kv/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "secret/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "identity/entity-alias"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "identity/entity-alias/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "identity/entity"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "identity/entity/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "sys/mounts/*"
   {
   capabilities = ["create", "read", "update", "delete", "list", "sudo"]
   }
   path "sys/mounts"
   {
   capabilities = ["read"]
   }
   ```

2. The policy for Vault Agent `vault-agent.hcl`:

   ```hcl
   pid_file = "./pidfile"
   vault {
   address = "http://vault:8200"
   retry {
   num_retries = 5
   }
   }
   auto_auth {
   method {
   type = "approle"
   config = {
     role_id_file_path = "/helpers/role_id"
     secret_id_file_path = "/helpers/secret_id"
     remove_secret_id_file_after_reading = false
   }
   }
   sink "file" {
   config = {
     path = "/helpers/sink_file"
   }
   }
   }
   cache {
   use_auto_auth_token = true
   }
   listener "tcp" {
   address = "0.0.0.0:8200"
   tls_disable = true
   }
   ```

3. The `init.sh` script which will create AppRole auth method:

   ```bash
   apk add jq curl
   export VAULT_ADDR=http://localhost:8200
   root_token=$(cat /helpers/keys.json | jq -r '.root_token')
   unseal_vault() {
   export VAULT_TOKEN=$root_token
   vault operator unseal -address=${VAULT_ADDR} $(cat /helpers/keys.json | jq -r '.keys[0]')
   vault login token=$VAULT_TOKEN
   }
   if [[ -n "$root_token" ]]
   then
     echo "Vault already initialized"
     unseal_vault
   else
     echo "Vault not initialized"
     curl --request POST --data '{"secret_shares": 1, "secret_threshold": 1}' http://127.0.0.1:8200/v1/sys/init > /helpers/keys.json
     root_token=$(cat /helpers/keys.json | jq -r '.root_token')
   
     unseal_vault
   
     vault secrets enable -version=2 kv
     vault auth enable approle
     vault policy write admin-policy /helpers/admin-policy.hcl
     vault write auth/approle/role/dev-role token_policies="admin-policy"
     vault read -format=json auth/approle/role/dev-role/role-id \
       | jq -r '.data.role_id' > /helpers/role_id
     vault write -format=json -f auth/approle/role/dev-role/secret-id \
       | jq -r '.data.secret_id' > /helpers/secret_id
   fi
   printf "\n\nVAULT_TOKEN=%s\n\n" $VAULT_TOKEN
   ```

4. Below is the config for the Vault server to be saved in `vault-config.hcl` file:

```hcl
storage "file" {
  # this path is used so that volume can be enabled https://hub.docker.com/_/vault
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
ui = true
```

Next we’ll create `startVault.sh` script to start Vault:

```shell
WAIT_FOR_TIMEOUT=120 # 2 minutes
docker-compose up --detach
echo Waiting for Vault Agent container to be up
curl https://raw.githubusercontent.com/eficode/wait-for/v2.2.3/wait-for | sh -s -- localhost:8200 -t $WAIT_FOR_TIMEOUT -- echo success
docker exec vault /bin/sh -c "source /helpers/init.sh"
docker restart vault-agent
```

After you created the above files in the `helpers` directory, the project structure should be as follows:

```text
.
├── docker-compose.yml
├── helpers
│   ├── admin-policy.hcl
│   ├── init.sh
│   ├── vault-agent.hcl
│   └── vault-config.hcl
└── startVault.sh
```

Finally, run `source startVault.sh` to start Vault server and Vault Agent.

Now any client application can access Vault Agent over `http://localhost:8200` on the host machine, for example the following command creates a secret name `hello`:

```shell
curl --request POST -H "Content-Type: application/json"  \
--data '{"data":{"foo":"bar"}}' http://localhost:8200/v1/kv/data/hello
```

while this command retrieves the secret name `hello`:

```shell
curl http://localhost:8200/v1/kv/data/hello
```

In addition Vault web UI is available at `http://localhost:8201/ui`. In order to log into the UI use the value of `root_token` field in `./helpers/key.json` file (using token login method in the UI).

Vault server uses file storage backend which makes this a persistent  setup (a docker volume is mounted), so that tokens data will persist  after machine restart or running `docker-compose down`.
