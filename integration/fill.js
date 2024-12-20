import 'dotenv/config'
import crypto from 'crypto'
import {concatHex, decodeEventLog, keccak256, toHex, encodeAbiParameters, createWalletClient, createPublicClient, http} from 'viem'
import {mekong} from 'viem/chains'
import { privateKeyToAccount } from 'viem/accounts'
import {eip7702Actions} from 'viem/experimental'
import {secp256k1} from "@noble/curves/secp256k1";
import DestinationSettler from '../out/DestinationSettler.sol/DestinationSettler.json' assert { type: 'json' }
import SenderCheck from '../out/SenderCheck.sol/SenderCheck.json' assert { type: 'json' }
import XAcccount from '../out/DestinationSettler.sol/XAccount.json' assert { type: 'json' }
import {CallByUserDefinition, CallsDefinition} from './structs.js'

function getRandomNonce() {
    // Generate 8 random bytes for a nonce (uint64)
    const nonceBytes = crypto.randomBytes(32);

    // Convert to a BigInt or number
    return BigInt(`0x${Buffer.from(nonceBytes).toString("hex")}`);
}

const relayerKey = process.env.PRIVATE_KEY
const relayer = privateKeyToAccount(relayerKey)

const relayerClient = createWalletClient({
  chain: mekong,
  transport: http(),
  account: relayer,
})

const userKey = process.env.USER_PRIVATE_KEY
const user = privateKeyToAccount(userKey)

const userClient = createWalletClient({
  chain: mekong,
  transport: http(),
  account: user,
}).extend(eip7702Actions())


const authorization = await userClient.signAuthorization({
  contractAddress: process.env.XACCOUNT_ADDRESS,
  delegate: true,
})

const nonce = getRandomNonce()
const calls = [
  {
    target: process.env.SENDERCHECK_ADDRESS,
    callData: "0x919840ad", // fn check()
    value: 0,
  },
]

console.log('calls ->', calls);

const encodedData = encodeAbiParameters(
  [CallsDefinition, {type: "uint256", name: "nonce"}],
  [calls, nonce],
)
const sigData = keccak256(encodedData)

const { r, s, recovery } = secp256k1.sign(sigData.slice(2), userKey.slice(2))
const v = recovery + 27 // Eth adjustment
const signature = concatHex([toHex(r), toHex(s), toHex(v)])
console.log('messageHash ->', sigData);
console.log('signature ->', signature);

const originData = encodeAbiParameters(
  [CallByUserDefinition],
  [[
    user.address,
    nonce,
    // Asset
    [
      "0x0000000000000000000000000000000000000000",
      0,
    ],
    7078815900, // Chain ID
    signature, // Call sig for verification
    calls,
  ]]
)

const orderId = keccak256(originData)

const hash = await relayerClient.writeContract({
  abi: DestinationSettler.abi,
  address: process.env.DESTINATIONSETTLER_ADDRESS,
  functionName: 'fill',
  args: [
    orderId,
    originData,
  ],
  authorizationList: [authorization]
})

console.log('fill created, waiting for tx hash ->', hash)

// Fetch the transaction receipt
const client = createPublicClient({
  chain: mekong,
  transport: http(),
})
const receipt = await client.waitForTransactionReceipt({
  hash,
  pollingInterval: 1000,
})

// Extract the logs
const decoded = receipt.logs.map((log) => {
  let decodedLog
  [SenderCheck, XAcccount].forEach((contract) => {
    try {
      decodedLog = decodeEventLog({
        abi: contract.abi,
        data: log.data,
        topics: log.topics,
      })
    } catch {
      return
    }
  })
  return decodedLog
})

console.log('Transaction Logs:', decoded)

decoded.forEach((log) => {
  if (log.eventName != 'check') return

  if (log.args.sender != user.address) {
    throw new Error(`Sender does not match delegator: ${decoded[0].args.sender} != ${user.address}`)
  }
})
