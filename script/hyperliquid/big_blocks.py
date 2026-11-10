#!/usr/bin/env python3
"""Set HyperEVM big blocks with a Foundry keystore and the official SDK."""

import argparse
import getpass
import json
import os
from pathlib import Path
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state", choices=("on", "off"))
    parser.add_argument("--network", required=True, choices=("testnet", "mainnet"))
    parser.add_argument(
        "--account", default=os.environ.get("FOUNDRY_ACCOUNT"),
        help="Foundry keystore name (default: FOUNDRY_ACCOUNT)",
    )
    args = parser.parse_args()
    if not args.account or args.account in (".", "..") or Path(args.account).name != args.account:
        parser.error("provide a keystore name through --account or FOUNDRY_ACCOUNT")
    if sys.prefix == sys.base_prefix:
        parser.error("run big-blocks.sh to use the managed virtual environment")
    if not sys.stdin.isatty():
        parser.error("run in an interactive terminal for the keystore password prompt")

    import eth_account
    import requests
    from hyperliquid.exchange import Exchange
    from hyperliquid.utils import constants

    keystore_path = Path.home() / ".foundry" / "keystores" / args.account
    try:
        with keystore_path.open() as f:
            keystore = json.load(f)
    except (OSError, ValueError):
        parser.exit(1, "Cannot read the Foundry keystore as JSON.\n")
    try:
        password = getpass.getpass("Keystore password: ")
        key = eth_account.Account.decrypt(keystore, password)
        wallet = eth_account.Account.from_key(key)
        del key, password, keystore
    except (ValueError, KeyError, TypeError):
        parser.exit(1, "Cannot decrypt the keystore. Check its format and password.\n")

    api_url, rpc_url = {
        "testnet": (constants.TESTNET_API_URL, "https://rpc.hyperliquid-testnet.xyz/evm"),
        "mainnet": (constants.MAINNET_API_URL, "https://rpc.hyperliquid.xyz/evm"),
    }[args.network]
    enabled = args.state == "on"
    print(f"Wallet: {wallet.address}; network: {args.network}; big blocks: {args.state}", flush=True)
    try:
        exchange = Exchange(wallet, api_url, timeout=30)
        result = exchange.use_big_blocks(enabled)
        if not isinstance(result, dict) or result.get("status") != "ok":
            parser.exit(1, f"Hyperliquid rejects the action: {json.dumps(result)}\n")
        print("Hyperliquid accepts the action.", flush=True)
        for attempt in range(5):
            response = requests.post(
                rpc_url,
                json={"jsonrpc": "2.0", "id": 1, "method": "eth_usingBigBlocks", "params": [wallet.address]},
                timeout=30,
            )
            response.raise_for_status()
            state = response.json()
            if state.get("result") is enabled:
                print(f"RPC confirms big blocks: {args.state}")
                return 0
            if "error" in state:
                break
            if attempt < 4:
                time.sleep(1)
    except (requests.RequestException, ValueError):
        parser.exit(1, "Network request fails. Check eth_usingBigBlocks before retrying.\n")
    except Exception as error:
        # SDK exceptions can contain request details, so report only their type.
        parser.exit(1, f"SDK request fails ({type(error).__name__}). Check eth_usingBigBlocks before retrying.\n")
    parser.exit(1, "The action succeeds, but RPC verification fails. Check eth_usingBigBlocks before retrying.\n")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        sys.exit("Cancelled.")
