# Beedle

- Total Prize Pool: $20,000
  - HM Awards: $18,000
  - LQAG: $2,000

- Starts: July 24th, 2023
- Ends August 7th, 2023

- nSLOC: ~706
- Complexity: ~381
- Judging Ends August 14th, 2023

[//]: # (contest-details-open)
## Contest Details

Oracle free peer to peer perpetual lending
About Beedle - [Twitter](https://twitter.com/beedlefi)

[//]: # (contest-details-close)

[//]: # (scope-open)

## Scope

All contracts in `src` are in scope. 

```
src/
├── Beedle.sol
├── Fees.sol
├── Lender.sol
├── Staking.sol
├── interfaces
│   ├── IERC20.sol
│   └── ISwapRouter.sol
└── utils
    ├── Errors.sol
    ├── Ownable.sol
    └── Structs.sol
```

## Contract Overview

### `Lender.sol`

Lender is the main singleton contract for Beedle. It handles all borrowing, repayment, and refinancing.

### `Lending`

In order to be a lender you must create a lending pool. Lending pools are based on token pairs and any lender can have one pool per lending pair. When creating a pool, lenders choose several key inputs

`loanToken` - the token they are lending out
`collateralToken` - the token they are taking in as collateral
`minLoanSize` - the minimum loan size they are willing to take (this is to prevent griefing a lender with dust loans)
`poolBalance` - the amount of `loanToken` they want to deposit into the pool
`maxLoanRatio` - the highest LTV they are willing to take on the loan (this is multiplied by 10^18)
`auctionLength` - the length of liquidation auctions for their loans
`interestRate` - the interest rate they charge for their loans

After creating a pool, lenders can update these values at any time. 

### `Borrowing`

Once lending pools are created by lenders, anyone can borrow from a pool. When borrowing you will choose your `loanRatio` (aka LTV) and the amount you want to borrow. Most other loan parameters are set by the pool creator and not the borrower. After borrowing from a pool there are several things that can happen which we will break down next. 

1.  `Repaying`
Repayment is the most simple of all outcomes. When a user repays their loan, they send back the principal and any interest accrued. The repayment goes back to the lenders pool and the user gets their collateral back. 
2. `Refinancing`
Refinancing can only be called by the borrower. In a refinance, the borrower is able to move their loan to a new pool under new lending conditions. The contract does not force the borrower to fully repay their debt when moving potisitions. When refinancing, you must maintain the same loan and collateral tokens, but otherwise, all other parameters are able to be changed. 
3. `Giving A Loan`
When a lender no longer desires to be lending anymore they have two options. They can either send the loan into a liquidation auction (which we will get into next) or they can give the loan to another lender. Lenders can give away their loan at any point so long as, the pool they are giving it to offers same or better lending terms. 
4. `Auctioning A Loan`
When a lender no longer wants to be in a loan, but there is no lending pool available to give the loan to, lenders are able to put the loan up for auction. This is a Dutch Auction where the variable changing over time is the interest rate and it is increasing linearly. Anyone is able to match an active pool with a live auction when the parameters of that pool match that of the auction or are more favorable to the borrower. This is called buying the loan. If the auction finishes without anyone buying the loan, the loan is liquidated. Then the lender is able to withdraw the borrowers collateral and the loan is closed. 

### `Staking.sol`

This is a contract based on the code of `yveCRV` originally created by Andre Cronje. It tracks user balances over time and updates their share of a distribution on deposits and withdraws.

[//]: # (scope-close)

[//]: # (getting-started-open)

## Getting Started

Before diving into the codebase and this implementation of the Blend lending protocol, it is recommended that you read the [original paper by Paradigm and Blur](https://www.paradigm.xyz/2023/05/blend#continuous-loans)

# build
`forge init`

`forge install OpenZeppelin/openzeppelin-contracts`

`forge install vectorized/solady`

`forge build`

# test
`forge test`

# deploy
first copy the `.example.env` file and create your own `.env` file

`forge script script/LenderScript.s.sol:LenderScript --rpc-url $GOERLI_RPC_URL --broadcast --verify -vvvv`

[//]: # (getting-started-close)

[//]: # (known-issues-open)

## Known Issues

<p align="center">
No known issues reported.

[//]: # (known-issues-close)
 
