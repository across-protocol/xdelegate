import 'dotenv/config'
import {privateKeyToAccount} from 'viem/accounts'
import {createWalletClient, createPublicClient, http} from 'viem'
import {mekong} from 'viem/chains'
import SenderCheck from '../out/SenderCheck.sol/SenderCheck.json' assert {type: 'json'}
import DestinationSettler from '../out/DestinationSettler.sol/DestinationSettler.json' assert {type: 'json'}
import XAccount from '../out/DestinationSettler.sol/XAccount.json' assert {type: 'json'}

// Configured deployer account w/ gas.
const deployerKey = process.env.PRIVATE_KEY

const deployer = privateKeyToAccount(deployerKey)

const walletClient = createWalletClient({
  chain: mekong,  // Mekong is the only testnet w/ eip-7702 support atm
  transport: http(),
  account: deployer,
})
const client = createPublicClient({
  chain: mekong,
  transport: http(),
})

const nonce = await client.getTransactionCount({ address: deployer.address });
console.log('current nonce:', nonce);

console.log('deploying contracts (SenderCheck, DestinationSettler, XAccount)')
const hashes = await Promise.all([SenderCheck, DestinationSettler, XAccount].map((contract, idx) =>
    walletClient.deployContract({
      abi: contract.abi,
      bytecode: contract.bytecode.object,
      nonce: nonce + idx,
    })
))

console.log('waiting for receipts ->', hashes)

const receipts = await Promise.all(hashes.map(hash => client.waitForTransactionReceipt({
  hash,
  pollingInterval: 1000,
})))

console.log('receipts ->', receipts)
// Store these deployed contract addresses for integration testing.
console.log('SenderCheck contract address ->', receipts[0].contractAddress)
console.log('DestinationSettler contract address ->', receipts[1].contractAddress)
console.log('XAccount contract address ->', receipts[2].contractAddress)
