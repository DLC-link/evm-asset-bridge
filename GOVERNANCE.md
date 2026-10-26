# Governance of the BETH bridge

## What this document covers

The bridge locks ETH on Ethereum and releases it when enough attestors approve a withdrawal.
This document lists the powers over that bridge, what each power does, and who holds it.

## The two Safes

Two Safe multisig wallets hold the administrative powers over the bridge.
This document refers to them by these two names.

- **Multi-org Safe.** BitSafe and the operator partners control this Safe together. It holds the default admin role and drives the upgrade timelock. Every change that it makes needs the agreement of more than one organisation.
- **BitSafe Safe.** BitSafe alone controls this Safe. It holds the bridge admin role.

The Multi-org Safe decides who takes part in the bridge and which code the bridge runs.
The BitSafe Safe runs the bridge from day to day within those bounds.

## Who holds which power

| Power | Holder | Purpose |
| --- | --- | --- |
| Default admin | The Multi-org Safe | Decides who is an attestor and who holds every other role |
| Bridge admin | The BitSafe Safe | Sets the operational parameters and can stop the bridge |
| Attestor | The operator nodes | Approve withdrawals by signature |
| Sentry | A hot key that BitSafe runs | Can stop the bridge, nothing else |
| Upgrade authority | A timelock contract that the Multi-org Safe drives | Replaces the bridge code after a public waiting period |

BitSafe can set the operational parameters on its own.
BitSafe cannot add or remove an attestor on its own.
BitSafe cannot upgrade the bridge code on its own.

## Default admin

The default admin controls membership of every role on the bridge.
The Multi-org Safe holds this power, so BitSafe and the operator partners must agree on each change.

The default admin can:

- Grant the bridge admin, attestor, or sentry role to an account.
- Revoke the bridge admin, attestor, or sentry role from an account.
- Set the signature threshold to any value from two up to the attestor count.
- Start a handover of the default admin role to a new holder.
- Cancel a handover before the new holder accepts it.
- Change the handover delay, which takes effect after a wait.
- Cancel a pending change of the handover delay.

The default admin cannot grant or revoke its own role directly.
A handover completes only when the new holder accepts it after the delay.
The default admin can remove an attestor at any time, even below the signature threshold.
An attestor cannot give up the role on its own.

## Bridge admin

The bridge admin runs the bridge from day to day.
The BitSafe Safe holds this power.

The bridge admin can:

- Pause the bridge, which stops all deposits and withdrawals.
- Unpause the bridge.
- Set the minimum and maximum amount for one deposit.
- Set the minimum and maximum amount for one withdrawal.
- Set the withdrawal rate limit, which caps the total released in a time window.
- Set the withdrawal horizon, which caps how far ahead a withdrawal deadline can be.
- Void a withdrawal request, so no signed approval for it can ever pay out.
- Rescue tokens other than the bridged asset that someone sent to the bridge by mistake.
- Rescue stray ETH, only when the bridged asset is not ETH.
- Rescue surplus of the bridged asset above the locked total, so deposited funds stay out of reach.

The bridge admin cannot add or remove an attestor.

## Attestor

An attestor signs withdrawal approvals.
The operator nodes hold this role.

A withdrawal needs a set number of distinct attestor signatures.
The signature threshold defines that number.
Only the default admin adds or removes an attestor, and only the default admin sets the threshold.

## Sentry

The sentry can pause the bridge.
A hot key that BitSafe runs holds this role.

The sentry cannot unpause the bridge.
The sentry holds no other power.
The role exists so that a fast automated key can stop the bridge without any other power.

## Upgrades

The bridge runs behind a proxy.
The proxy admin contract decides which code the proxy runs.
The timelock owns the proxy admin contract.
Nobody administers the timelock except the timelock itself.
The Multi-org Safe is the proposer, the canceller, and the executor of the timelock.
BitSafe and the operator partners must therefore agree on every upgrade.

An upgrade follows four steps:

- The Multi-org Safe schedules the upgrade in the timelock.
- The timelock holds the upgrade for the configured delay.
- Anyone can see the pending upgrade on-chain during the delay.
- After the delay, the Multi-org Safe executes the upgrade.

The Multi-org Safe can cancel a pending upgrade at any time before execution.
The Multi-org Safe cannot shorten the delay of a pending upgrade.
The Multi-org Safe is the only account that can execute an upgrade.
If that Safe cannot act, no upgrade path remains.
The team accepts that tradeoff. It is the standard one for a timelock with a single executor.
A change of the delay itself must pass through the same scheduled process.
A deploy from this repo builds this design.

## Why the default admin sets the threshold

The threshold and the attestor set together define how many operators must agree on a withdrawal.
One role therefore owns both values.
