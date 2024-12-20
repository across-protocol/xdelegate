# Integration tests

Integration tests for ERC-7683 x EIP-7702. 

Currently setup targets mekong (testnet w/ EIP-7702 support). 

Copy `.env.example` to `.env` and fill in env vars.

```shell
node deploy.js

# Fill in deployed contract addrs into `.env` file before running fill.js.

node fill.js
```
