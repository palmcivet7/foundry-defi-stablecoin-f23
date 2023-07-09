# Foundry Defi Stablecoin

This project was made following along with a lesson from the Cyfrin Foundry course. Building an algorithmic stablecoin like this is an interesting learning experience, but I am extremely skeptical about the longevity of any stablecoin (or RWA token) that isn't 1:1 backed by a licensed custodian.

## Features to consider

1. (Relative Stability) Anchored/Pegged -> $1.00
   1. Chainlink Pricefeed
   2. Set a function to exchange ETH & BTC -> $$$
2. Stability Mechanism (Minting): Algorithmic (Decentralized)
   1. People can only mint the stablecoin with enough collateral
3. Collateral: Exogenous (Crypto)
   1. wETH
   2. wBTC

- calculate health factor function
- set health factor if debt is 0
- added a bunch of view functions

1. what are our invariants/properties?
   // 1. the total supply of dsc should always be less than the total value of collateral
   // 2. getter view functions should never revert

## To Do

Write more tests
