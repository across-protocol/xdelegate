const CallsDefinition = {
  type: "tuple[]",
  components: [
    {
      type: "address",
      name: "target",
    },
    {
      type: "bytes",
      name: "callData",
    },
    {
      type: "uint256",
      name: "value",
    },
  ],
}

const CallByUserDefinition = {
  type: "tuple",
  components: [
    {
      type: "address",
      name: "user",
    },
    {
      type: "uint256",
      name: "nonce",
    },
    {
      type: "tuple",
      name: "asset",
      components: [
        {
          type: "address",
          name: "token",
        },
        {
          type: "uint256",
          name: "amount",
        },
      ],
    },
    {
      type: "uint64",
      name: "chainId",
    },
    {
      type: "bytes",
      name: "signature",
    },
    CallsDefinition,
  ],
}

export {CallByUserDefinition, CallsDefinition}
