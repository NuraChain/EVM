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
| `GENESIS_TIME` | Coordinated launch time, so the chain does not start whenever 2/3 of voting power happens to come online. |
| `GOV_MIN_DEPOSIT` | The SDK default is worth about 1e-11 whole tokens on an 18-decimal chain. |
| `PERSISTENT_PEERS` | Set per host, after every validator has run `01_init_node.sh`. |
| `GENESIS_SOURCE` | On every validator except the coordinator: where the coordinator's genesis file landed on this host. The scripts install it into `NODE_HOME` from there. |

## Workflow

**1. Build and install on every VPS.** Also creates the unprivileged `evmd` service user.

```bash
sudo ./00_build.sh
```

**2. Initialize each validator.** Save the printed account address and node ID.

```bash
sudo ./01_init_node.sh
```

**3. On the coordinator**, set `VALIDATOR_ADDRESSES` to the collected account addresses, then:

```bash
sudo ./02_prepare_genesis.sh
```

This sets the denom across staking/mint/gov/evm/bank, sets the gov deposit *amounts* (not just denoms), enables the fee market with a real floor, replaces the example WEVMOS token pair with your own wrapped native token, drops the unimplemented vesting precompile from the active list, and caps `block.max_gas`.

The coordinator's own node gets this genesis installed automatically. Send `GENESIS_HOME/config/genesis.json` to every other validator, and have each set `GENESIS_SOURCE` in their `nura.env` to wherever the file landed. The scripts copy it into `NODE_HOME` from there; never copy a genesis into `NODE_HOME/config` by hand.

**4. On every validator**, create a gentx and send `config/gentx/*.json` back to the coordinator:

```bash
sudo ./03_create_gentx.sh
```

On the coordinator, set `GENTX_FILES`, then:

```bash
sudo ./04_collect_genesis.sh
```

`collect-gentxs` rewrites the genesis, so the file every validator signed against is now stale. This step prints the final SHA256 and writes it into the coordinator's `nura.env`. Send the new genesis to every other validator — replacing the one from step 3, at the same `GENESIS_SOURCE` path — and give them the checksum to put in `GENESIS_SHA256`.

**5. Configure each node.** Installs the genesis from `GENESIS_SOURCE`, verifies its checksum, then writes `app.toml` and `config.toml`:

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

قبل از اجرا حتماً این مقادیر را تغییر دهید: `EVM_CHAIN_ID` (نباید 262144 بماند و باید روی همه validatorها یکسان باشد)، `WRAPPED_NATIVE_ADDRESS`، `MIN_GAS_PRICE_WEI`، `GENESIS_TIME` و `GOV_MIN_DEPOSIT`.

ترتیب اجرا:

```bash
sudo ./00_build.sh          # روی همه VPSها
sudo ./01_init_node.sh      # روی همه VPSها
sudo ./02_prepare_genesis.sh # فقط روی coordinator
sudo ./03_create_gentx.sh   # روی همه VPSها
sudo ./04_collect_genesis.sh # فقط روی coordinator
sudo ./05_configure_node.sh # روی همه VPSها
sudo ./06_install_service.sh
sudo ./07_start.sh
```

فایل genesis را هیچ‌وقت دستی داخل `NODE_HOME/config` کپی نکنید؛ اسکریپت‌ها خودشان این کار را می‌کنند. روی coordinator، خروجی `02_prepare_genesis.sh` و `04_collect_genesis.sh` خودکار در `NODE_HOME` نصب می‌شود. روی بقیه validatorها فایل را از coordinator بگیرید و مسیرش را در `GENESIS_SOURCE` بنویسید؛ `03_create_gentx.sh` و `05_configure_node.sh` آن را نصب می‌کنند.

بعد از `04_collect_genesis.sh` مقدار SHA256 چاپ می‌شود و در `nura.env` همان coordinator نوشته می‌شود. توجه کنید که `collect-gentxs` فایل genesis را تغییر می‌دهد، پس **نسخهٔ نهایی** را دوباره به همه validatorها بدهید (جایگزین نسخهٔ مرحلهٔ قبل، در همان مسیر `GENESIS_SOURCE`) و هر validator مقدار SHA256 را در `GENESIS_SHA256` قرار دهد تا مطمئن شوید همه دقیقاً یک genesis دارند.

فقط پورت `26656` برای P2P باز است. پورت‌های RPC و API روی loopback هستند و نباید مستقیماً عمومی شوند. کلید `priv_validator_key.json` را هرگز روی دو سرور همزمان اجرا نکنید؛ double-sign باعث slash و tombstone دائمی می‌شود.
