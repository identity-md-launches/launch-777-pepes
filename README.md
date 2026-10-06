# Pepes (PEPES)

Pepes is a fixed-supply ERC-20. Its constructor mints **1,000,000,000 PEPES** with
**18 decimals** to `msg.sender`, the immediate deploying address. The exact supply
in minor units is **1000000000000000000000000000** (`10^27`). Transfers have no fee.

The production contract is [`src/Pepes.sol`](src/Pepes.sol), implemented with the
vendored OpenZeppelin ERC-20. There is no owner, later minting, burning, pausing,
blacklisting, confiscation, upgrade mechanism, or external call during transfers.
Only a holder or a spender approved by that holder can move their tokens.

## Build and check

Requires Foundry and Solidity **0.8.26** installed in Foundry's compiler cache.
All Solidity dependencies and their licenses are ordinary files in `lib/`;
building and testing require no dependency downloads. See
[`DEPENDENCIES.md`](DEPENDENCIES.md) for versions, sources, and checksums.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun EVM, optimizer enabled with 200 runs,
`bytecode_hash = "none"`, and disabled CBOR metadata. FFI and filesystem permissions
are disabled. Tests use neither environment variables nor live networks.

The tests cover metadata, single constructor mint and its event, CREATE2 factory
ownership, exact transfers and launch-like movements, approvals/revocation,
finite and unlimited allowances, zero amounts, self-transfers, invalid addresses,
insufficient balances/allowances, atomic rollback, unauthorized spending, absent
administrative entry points, and prohibited runtime opcodes. Fuzz tests cover
amounts and recipients; stateful invariants check fixed supply, conservation of
balances, exact movements, and allowance accounting across sequences of calls.

The factory/distributor/pool transfer scenario is a local token compatibility test.
It does not instantiate Uniswap or test price formation, pool initialization,
liquidity accounting, or swaps. The supplied protected integration harness belongs
to the launch system and additionally needs its factory/pool contracts and launch
configuration, which are not present in this assignment.

## Deployment parameters

| Field | Value |
| --- | --- |
| Contract identifier | `src/Pepes.sol:Pepes` |
| Constructor arguments | None (`[]`; empty ABI encoding) |
| Transaction value | 0 |
| Name / symbol | `Pepes` / `PEPES` |
| Decimals | 18 |
| Total supply, minor units | `1000000000000000000000000000` |
| Initial recipient | Immediate constructor caller (`msg.sender`) |
| Transfer fee | 0 |
| Initialization calls / admin roles | None |

Deployment input is the compiled creation bytecode with no appended arguments.
For review without a wallet or network, inspect it with:

```sh
forge inspect src/Pepes.sol:Pepes abi
forge inspect src/Pepes.sol:Pepes bytecode
```

An EOA deployment gives the entire supply to that EOA. A factory using CREATE or
CREATE2 receives the entire supply itself; the transaction origin receives none
automatically. The factory must be able to transfer its tokens onward. The token
does not implement allocation, a distributor, a pool, or launch economics. Those
are responsibilities of the surrounding launch system. No chain addresses,
market capitalization, pool allocation, recipient, or CREATE2 salt are assumed
here. No transactions are broadcast by this project.

## Semantics and operational responsibilities

- Successful `transfer`, `approve`, and `transferFrom` calls return `true`;
  failures revert with OpenZeppelin ERC-20 custom errors. Transfers emit `Transfer`,
  including zero and self-transfers; explicit approvals emit `Approval`.
- Zero-value transfers between valid addresses are allowed. Transfers to the zero
  address and approvals to a zero spender revert. There is no burn entry point.
  Self-transfers require sufficient funds and leave balances unchanged;
  delegated self-transfers still consume a finite allowance.
- Approval replaces the previous allowance; zero revokes it. Maximum `uint256`
  approval is treated as unlimited and is not reduced by `transferFrom`.
  OpenZeppelin v5 does not emit `Approval` on allowance spending; integrations
  should query `allowance`. Use only needed approvals and handle allowance changes
  carefully: a spender may spend an existing allowance before its replacement
  transaction confirms. Revoking first does not undo prior spending.
- The deployer/launch operator is responsible for custody and distribution of the
  initial supply, choosing chain and launch parameters, checking that the chain
  supports Cancun, verifying deployed source/bytecode and metadata, and confirming
  that the initial balance and supply match the values above.
- There are no maintenance or administrator transactions. Holders are responsible
  for addresses and approvals. Tokens sent to contracts that cannot return them,
  including the Pepes contract itself, cannot be rescued by an administrator.
  Ordinary ETH transfers to Pepes revert; forced ETH cannot be recovered.
- Foundry unit, fuzz, and invariant checks are local validation, not an independent
  security audit. Independent adversarial review and the launch system's complete
  integration checks remain release responsibilities. Slither and Mythril are not
  part of the checks run for this assignment.
