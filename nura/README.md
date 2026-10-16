# Nura network bootstrap scripts

These scripts bootstrap a fresh Nura chain from this repository. They target Linux VPS hosts and require a locally built `evmd` binary.

All scripts read `nura.env` (copied from `nura.env.example`) and share helpers from `lib.sh`.

## Debian 13 VPS

Build on the Debian VPS. Do not build the production binary on Windows and copy it over.

Install the native build dependencies on every VPS:

```bash
sudo apt update
sudo apt install -y build-essential ca-certificates curl git jq make sudo ufw
```

Install the Go version required by the repository's `go.mod` (currently Go 1.25.x), then verify:

```bash
go version
go env CGO_ENABLED   # must be 1
```

The build links go-ethereum's C `secp256k1`. With `CGO_ENABLED=0` the compile fails on `undefined: secp256k1.RecoverPubkey`.

```bash
git clone https://github.com/cosmos/evm.git ~/EVM
cd ~/EVM/nura
cp nura.env.example nura.env
chmod 700 *.sh
nano nura.env
```

## Settings you must change before launch

| Variable | Why |
|---|---|
| `EVM_CHAIN_ID` | The EIP-155 replay-protection ID. Must be identical on every validator and must not stay at cosmos/evm's default of `262144`. Claim one on [chainlist.org](https://chainlist.org). |
| `WRAPPED_NATIVE_ADDRESS` | The WNURA contract address. Immutable after launch. |
| `MIN_GAS_PRICE_WEI` | Feeds both the consensus-enforced feemarket floor and each node's local `minimum-gas-prices`. |
| `TOTAL_SUPPLY` | The entire supply of the chain, forever. Nothing is minted after genesis. |
| `GENESIS_ALLOCATIONS` | Treasury, ecosystem, and team accounts. Genesis is the only chance to create them. |
| `GENESIS_TIME` | Coordinated launch time, so the chain does not start whenever 2/3 of voting power happens to come online. |
| `GOV_MIN_DEPOSIT` | The SDK default is worth about 1e-11 whole tokens on an 18-decimal chain. |
| `PERSISTENT_PEERS` | Set per host. A validator that joins after launch needs at least the coordinator's `nodeid@host:26656`. |
| `GENESIS_SOURCE` | On every validator except the coordinator: where the coordinator's final genesis file landed on this host. The scripts install it into `NODE_HOME` from there. |

## Workflow

The chain launches with a single validator, the coordinator. Every validator account is funded in genesis, but only the coordinator signs a gentx; the others join after launch with `08_create_validator.sh` (see [Adding validators after launch](#adding-validators-after-launch)). Steps 1 to 6 below run on the coordinator.

**1. Build and install.** Also creates the unprivileged `evmd` service user. Every server needs a fresh build from this repository: the binary itself never mints (see [Token supply](#token-supply)).

```bash
sudo ./00_build.sh
```

**2. Initialize the node.** Save the printed account address and node ID.

To run the validator from an existing wallet key instead of a freshly generated one, import it under `VALIDATOR_KEY` first, and `01_init_node.sh` will use it. Import only that validator's own private key, never a mnemonic. The key is read inside a shell that already runs as `evmd`, so it never appears in the shell history or in the command line `sudo` logs:

```bash
sudo install -d -o evmd -g evmd -m 0750 /home/EVM/.evmd
sudo -u evmd bash -c 'cd /home/EVM/.evmd && read -rsp "Private key: " PK && echo && evmd keys unsafe-import-eth-key validator "$PK" --keyring-backend file --home /home/EVM/.evmd'
```

Run every manual `evmd` command the same way, as `evmd` from inside `NODE_HOME`. From anywhere else it panics with `could not create directory "data"`.

```bash
sudo ./01_init_node.sh
```

The address it prints must be the one listed for this validator in `VALIDATOR_ADDRESSES`.

**3. Prepare genesis.** Set `VALIDATOR_ADDRESSES` to every validator's account address, including the ones that join later, then:

```bash
sudo ./02_prepare_genesis.sh
```

This sets the denom across staking/mint/gov/evm/bank, fixes the supply (see below), sets the gov deposit *amounts* (not just denoms), enables the fee market with a real floor, replaces the example WEVMOS token pair with your own wrapped native token, drops the unimplemented vesting precompile from the active list, and caps `block.max_gas`.

The coordinator's own node gets this genesis installed automatically. Never copy a genesis into `NODE_HOME/config` by hand.

**4. Create and collect the gentx.**

```bash
sudo ./03_create_gentx.sh
```

Set `GENTX_FILES` to the gentx it wrote under `NODE_HOME/config/gentx`, then:

```bash
sudo ./04_collect_genesis.sh
```

`collect-gentxs` rewrites the genesis. This step prints the final SHA256 and writes it into the coordinator's `nura.env`. This final `GENESIS_HOME/config/genesis.json` and its checksum are what every later validator needs.

**5. Configure the node.** Installs the genesis, verifies its checksum, then writes `app.toml` and `config.toml`:

```bash
sudo ./05_configure_node.sh
```

This is what enables the EVM JSON-RPC (disabled by default in cosmos/evm) and sets `evm-chain-id`. Set `PERSISTENT_PEERS` and `EXTERNAL_ADDRESS` in `nura.env` first.

**6. Install the systemd service, then start.**

```bash
sudo ./06_install_service.sh
sudo ./07_start.sh
```

```bash
journalctl -u evmd -f
evmd status | jq '.sync_info'
```

## Adding validators after launch

Each further validator joins on its own server once the chain is running. Its account already holds its genesis balance, so all it needs is a synced node and one transaction.

Until there are four validators, losing any one of them halts the chain. With equal stakes, two or three validators cannot keep more than 2/3 of the voting power online after one goes down. Bring validators 2, 3, and 4 up in quick succession.

1. Run `00_build.sh`, import the validator's key if it comes from a wallet (step 2 above), then run `01_init_node.sh`. The printed address must match this validator's entry in the coordinator's `VALIDATOR_ADDRESSES`.
2. Copy the coordinator's final genesis to this server. In `nura.env`, set `GENESIS_SOURCE` to its path, `GENESIS_SHA256` to the checksum `04_collect_genesis.sh` printed, `PERSISTENT_PEERS` to at least the coordinator's `nodeid@host:26656`, and `EXTERNAL_ADDRESS` to this host. Use the same `GENTX_SELF_DELEGATION` as the coordinator.
3. Configure, install, and start the node:

   ```bash
   sudo ./05_configure_node.sh
   sudo ./06_install_service.sh
   sudo ./07_start.sh
   ```

4. Wait until the node has caught up. `catching_up` must be `false`:

   ```bash
   sudo -u evmd bash -c 'cd /home/EVM/.evmd && evmd status --home /home/EVM/.evmd' | jq '.sync_info.catching_up'
   ```

5. Bond the validator:

   ```bash
   sudo ./08_create_validator.sh
   ```

   It refuses to run while the node is still syncing or when this account is already a validator. It bonds `GENTX_SELF_DELEGATION` with the same commission as the genesis validator, and asks for the keyring passphrase and a confirmation before broadcasting.

## Running a validator with Docker (Dokploy)

`compose/` runs the same node in a container, for hosts managed by Dokploy or plain Docker Compose. The image builds `evmd` from this repository, bakes in `config/genesis.json`, and on every start runs `05_configure_node.sh` against a persistent volume, so the node is configured exactly like a systemd host. Use it on a server that does not already run `evmd.service`.

1. In Dokploy, create a **Compose** service of type Docker Compose from this repository and set the Compose Path to `./nura/compose/docker-compose.yml`. Turn **Autodeploy** off: a push to the branch would otherwise rebuild and restart the validator.
2. In the service's Environment tab, set the variables `docker-compose.yml` asks for: `MONIKER`, `PERSISTENT_PEERS` (the coordinator's `nodeid@host:26656`), `EXTERNAL_ADDRESS` (this server's public `host:26656`), `GENESIS_SHA256` (the coordinator's checksum; the node refuses to start on a mismatch), and `GENTX_SELF_DELEGATION`.
3. Open `26656/tcp` in this server's firewall, then deploy. The first build compiles `evmd` and needs about 4 GB of RAM; add swap on smaller servers.
4. Open a shell in the container (the service's terminal in Dokploy, or `docker exec -it <container> bash`). `whoami` must print `evmd`; as any other user the key lands outside the volume and is lost on the next deploy. Create the validator key, or import an existing private key:

   ```bash
   evmd keys add validator --algo eth_secp256k1 --keyring-backend file --home "$NODE_HOME"
   read -rsp "Private key: " PK && echo && evmd keys unsafe-import-eth-key validator "$PK" --keyring-backend file --home "$NODE_HOME"; unset PK
   ```

   Never put a key in a Dokploy environment variable; Dokploy stores and displays them.
5. Fund the printed address if genesis did not, with at least `GENTX_SELF_DELEGATION` plus fees.
6. Wait until `evmd status --home "$NODE_HOME" | jq .sync_info.catching_up` prints `false`, then bond the validator from the same terminal:

   ```bash
   /opt/nura/08_create_validator.sh
   ```

The node home, including `priv_validator_key.json` and the keyring, lives in the service's `evmd-home` volume. Back both up offline. Deleting the Dokploy service or its volume destroys the consensus key, and a second node started from a copy of the volume double-signs.

## Relaunching from scratch

`01_init_node.sh` reuses whatever `NODE_HOME` already holds, so an old chain must be removed first. On every host, back up `NODE_HOME`, then:

```bash
sudo ./uninstall.sh --yes
```

It stops and removes `evmd.service` and moves `NODE_HOME` aside (nothing is deleted). Refresh `nura.env` from `nura.env.example`, then run the workflow from step 2.

## Token supply

Nura has a **fixed supply of `TOTAL_SUPPLY` whole tokens and 0% inflation**. Every token that will ever exist is created in genesis, so `02_prepare_genesis.sh` is the only place the distribution is ever decided.

This is enforced in three places:

- **The binary never mints.** `evmd/app.go` gives the x/mint keeper a mint function that does nothing, so the begin blocker mints no tokens whatever the mint params say. The module stays wired in only because the shared test harness funds accounts through it.
- **The mint params are zero.** `02_prepare_genesis.sh` sets `inflation`, `inflation_max`, `inflation_min`, and `inflation_rate_change` to zero, so mint queries and explorers report the 0% that actually applies instead of the SDK's default 13%. `goal_bonded` stays at `0.67` only because the params validator rejects a zero value; it is inert.
- **`max_supply` is set to `TOTAL_SUPPLY`.** The SDK default of `0` means *unlimited*. It is a second guard in case a future binary restores the SDK's minting.

The allocation table is reconciled before anything is written: every address in `VALIDATOR_ADDRESSES` gets `GENESIS_BALANCE` (or its own amount, written `address:amount`), every `address:amount` pair in `GENESIS_ALLOCATIONS` gets its amount, and the script aborts unless the total equals `TOTAL_SUPPLY` exactly. It also rejects duplicate addresses and malformed bech32, and re-reads `bank.supply` from the finished file to confirm the chain will start with the intended number.

Two consequences worth deciding on deliberately:

- **Validators earn transaction fees only.** There are no staking rewards, so on a chain with no traffic there is no validator revenue. Budget for this, or fund validator operations from a treasury allocation.
- **Only a binary upgrade can change it.** A governance vote can still change the mint params, but the binary ignores them. Restoring inflation would take a software upgrade that every validator chooses to run.
- **Some upstream tests no longer pass.** The distribution precompile and ante integration suites enable inflation and loop until rewards accrue. On this binary nothing is minted, so they hang until the test timeout.

## Production notes

- Use at least four validators on separate hosts. One validator is not production-grade.
- CometBFT RPC, REST, gRPC, and JSON-RPC are bound to loopback by `05_configure_node.sh`; only P2P `26656` needs to be reachable. Restrict the rest at your host firewall as well, and serve public RPC from a separate non-validator node behind an authenticated TLS reverse proxy.
- Never use the `test` keyring backend; the scripts reject it.
- Never expose the `personal`, `debug`, or `miner` JSON-RPC namespaces; `05_configure_node.sh` rejects them.
- **Never run two nodes from a copy of the same `NODE_HOME`.** Duplicated `priv_validator_key.json` means double-signing, which is slashed and tombstoned permanently. Never roll back `priv_validator_state.json`.
- Back up `priv_validator_key.json` and the keyring offline, before the chain starts.
- Do not change the Bech32 prefix (`nura`, set in `evmd/config/bech32.go`) or `EVM_CHAIN_ID` after launch.
- Monitor block height, peer count, missed blocks, disk, and memory. Prometheus is enabled on `26660`, bound locally.

## راهنمای فارسی برای Debian 13

این اسکریپت‌ها برای اجرا روی VPS لینوکس Debian 13 آماده شده‌اند. روی Windows بیلد نگیرید؛ repository را روی هر VPS قرار دهید و همان‌جا binary را بسازید.

روی هر VPS:

```bash
sudo apt update
sudo apt install -y build-essential ca-certificates curl git jq make sudo ufw
go version
go env CGO_ENABLED   # باید 1 باشد
```

سپس:

```bash
git clone https://github.com/cosmos/evm.git ~/EVM
cd ~/EVM/nura
cp nura.env.example nura.env
nano nura.env
chmod 700 *.sh
```

قبل از اجرا حتماً این مقادیر را تغییر دهید: `EVM_CHAIN_ID` (نباید 262144 بماند و باید روی همه validatorها یکسان باشد)، `WRAPPED_NATIVE_ADDRESS`، `MIN_GAS_PRICE_WEI`، `GENESIS_TIME`، `GOV_MIN_DEPOSIT`، و مقادیر عرضهٔ توکن (`TOTAL_SUPPLY`، `GENESIS_BALANCE`، `GENESIS_ALLOCATIONS`).

### عرضهٔ ثابت توکن

عرضهٔ Nura ثابت است و inflation صفر است. تمام توکن‌ها فقط در genesis ساخته می‌شوند و بعد از آن هیچ توکن جدیدی mint نمی‌شود. برای همین `02_prepare_genesis.sh` تنها جایی است که توزیع توکن تعیین می‌شود؛ بعد از launch دیگر قابل اصلاح نیست.

`TOTAL_SUPPLY` کل عرضه است. هر آدرس در `VALIDATOR_ADDRESSES` مقدار `GENESIS_BALANCE` می‌گیرد (یا مقدار خودش اگر به‌صورت `address:amount` نوشته شود)، و بقیهٔ حساب‌ها (خزانه، تیم، اکوسیستم) به‌صورت جفت‌های `address:amount` در `GENESIS_ALLOCATIONS` نوشته می‌شوند. اسکریپت قبل از نوشتن هر فایلی جمع می‌زند و اگر مجموع دقیقاً برابر `TOTAL_SUPPLY` نباشد با خطا متوقف می‌شود، پس عرضهٔ اشتباه هیچ‌وقت وارد genesis نمی‌شود.

خود binary هم هیچ‌وقت mint نمی‌کند: حتی اگر پارامترهای mint با رأی governance تغییر کنند نادیده گرفته می‌شوند، و فقط یک software upgrade می‌تواند inflation را برگرداند. برای همین روی هر سرور باید binary را با `00_build.sh` از همین repository بسازید.

توجه: با inflation صفر، validatorها فقط کارمزد تراکنش‌ها را دریافت می‌کنند و هیچ staking reward وجود ندارد.

شبکه فقط با یک validator (coordinator) شروع می‌شود. حساب همهٔ validatorها در genesis پول می‌گیرد، ولی فقط coordinator gentx می‌سازد و بقیه بعد از launch با `08_create_validator.sh` وارد می‌شوند.

ترتیب اجرا روی coordinator:

```bash
sudo ./00_build.sh
sudo ./01_init_node.sh
sudo ./02_prepare_genesis.sh
sudo ./03_create_gentx.sh
sudo ./04_collect_genesis.sh  # قبلش GENTX_FILES را روی gentx خود coordinator بگذارید
sudo ./05_configure_node.sh
sudo ./06_install_service.sh
sudo ./07_start.sh
```

اگر کلید validator از یک wallet (مثلاً MetaMask) است، قبل از `01_init_node.sh` فقط private key همان validator را import کنید، هیچ‌وقت ۱۲ کلمه را روی سرور نبرید:

```bash
sudo install -d -o evmd -g evmd -m 0750 /home/EVM/.evmd
sudo -u evmd bash -c 'cd /home/EVM/.evmd && read -rsp "Private key: " PK && echo && evmd keys unsafe-import-eth-key validator "$PK" --keyring-backend file --home /home/EVM/.evmd'
```

کلید داخل shell خود کاربر `evmd` خوانده می‌شود، پس نه در history می‌ماند و نه در لاگ `sudo`. هر دستور `evmd` را همین‌طور، به‌عنوان کاربر `evmd` و از داخل `NODE_HOME` اجرا کنید، وگرنه با خطای `could not create directory "data"` متوقف می‌شود. آدرسی که `01_init_node.sh` چاپ می‌کند باید همان آدرس این validator در `VALIDATOR_ADDRESSES` باشد.

فایل genesis را هیچ‌وقت دستی داخل `NODE_HOME/config` کپی نکنید؛ اسکریپت‌ها خودشان این کار را می‌کنند. بعد از `04_collect_genesis.sh` مقدار SHA256 چاپ می‌شود و در `nura.env` همان coordinator نوشته می‌شود. فایل نهایی `GENESIS_HOME/config/genesis.json` و این SHA256 چیزی است که validatorهای بعدی لازم دارند.

### اضافه کردن validator بعد از launch

روی سرور هر validator جدید:

```bash
sudo ./00_build.sh
# در صورت نیاز import کلید (بالا را ببینید)
sudo ./01_init_node.sh
# در nura.env: GENESIS_SOURCE (مسیر genesis نهایی)، GENESIS_SHA256،
# PERSISTENT_PEERS (حداقل nodeid@host:26656 مربوط به coordinator)، EXTERNAL_ADDRESS
sudo ./05_configure_node.sh
sudo ./06_install_service.sh
sudo ./07_start.sh
# صبر کنید تا catching_up برابر false شود
sudo ./08_create_validator.sh
```

`08_create_validator.sh` تا وقتی node هنوز sync نشده یا این حساب از قبل validator است اجرا نمی‌شود. تا وقتی کمتر از ۴ validator دارید، خاموش شدن هر کدام شبکه را متوقف می‌کند؛ پس validatorهای ۲ تا ۴ را پشت سر هم و سریع بالا بیاورید.

فقط پورت `26656` برای P2P باز است. پورت‌های RPC و API روی loopback هستند و نباید مستقیماً عمومی شوند. کلید `priv_validator_key.json` را هرگز روی دو سرور همزمان اجرا نکنید؛ double-sign باعث slash و tombstone دائمی می‌شود.
