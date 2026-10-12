# Smart Contract Architecture

## Core Components

### beHYPE Token

The beHYPE token is an ERC-20 token representing staked HYPE:

- Standard ERC-20 functions with permit functionality
- Minting and burning functionality when users stake and withdraw HYPE

### WithdrawManager

The WithdrawManager manages instant and standard withdrawals (3 to 7 days) requests

- Manages withdrawal requests based on finalization determined by the oracle
- Standard withdrawal flow:
  1. beHYPE tokens are transferred to the withdrawal manager and a withdrawal request is issued. 
  Exchange rate at time of request determine the HYPE withdrawal amount.
  2. Off-chain service finalizes withdraws. beHYPE tokens are burnt and HYPE is transfer to the user 
- Allows for instant withdrawals for a fee
- Availability for instant withdrawals is determined by a minimum liquidity threshold as a percentage of TVL and a rate limiter

### StakingCore

Core staking contract 

- Provides the exchange rate between beHYPE and HYPE by calculating the total protocol balance:
  (StakingCore contract balance) + (StakingCore L1 stake account balance) + (StakingCore L1 spot balance)
- Admin functions leveraging CoreWriter for staking, unstaking, and rebalancing on the hyperCore

## Access Control System

### RoleRegistry

- Manages all roles for the beHYPE protocol
- `PauseProtocol` function for emergency pause of staking and withdrawals

### BeHYPETimelock

Timelock with 3 day delay controlling all upgrade roles for the protocol

## Cross Chain

`OFT` contracts and deployment scripts to be added at a later date

## Contract Deployed Addresses

| Contract | Testnet Address | Mainnet Address |
|----------|-----------------|-----------------|
| beHYPE | TBD | TBD |
| WithdrawManager | TBD | TBD |
| StakingCore | TBD | TBD |
| RoleRegistry | TBD | TBD |
| BeHYPETimelock | TBD | TBD |
