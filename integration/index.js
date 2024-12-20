import { createWalletClient, createPublicClient, http } from 'viem'
import {mekong} from 'viem/chains'
import { privateKeyToAccount } from 'viem/accounts'
import {eip7702Actions} from 'viem/experimental'
import {decodeEventLog} from 'viem';
import DestinationSettler from './out/DestinationSettler.sol/DestinationSettler.json' assert { type: 'json' }

const authClient = createWalletClient({
  chain: mekong,
  transport: http(),
  account: privateKeyToAccount('0x7655ed3728cc5b9d705976080fef1d311ff4b3e2e431feea1a50e5c0903a6acb'),
}).extend(eip7702Actions());

const delegate = privateKeyToAccount('0x0df13f4069b3b6c63054adba655a9b5462326e803411c62510a27fd6cc3ef5ab');

const client = createWalletClient({
  chain: mekong,
  transport: http(),
  account: delegate,
}).extend(eip7702Actions());

const pubClient = createPublicClient({
  chain: mekong,
  transport: http(),
});

// const blockNumber = await client.getBlockNumber()

const authorization = await authClient.signAuthorization({
  contractAddress: '0xFf2dD641b018f99fdbD2fa5C7420faEF26690244',
  delegate: true,
});

const hash = await client.writeContract({
  abi: DestinationSettler.abi,
  //address: client.account.address,
  address: authClient.account.address,
  functionName: 'check',
  args: [],
  authorizationList: [authorization]
})

console.log('hash ->', hash);


await sleep(30000)

// Fetch the transaction receipt
const receipt = await pubClient.getTransactionReceipt({
  hash,
});

// Extract the logs
const decoded = receipt.logs.map((log) => decodeEventLog({
  abi: DestinationSettler.abi,
  data: log.data,
  topics: log.topics,
}));

console.log('Transaction Logs:', decoded)

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
