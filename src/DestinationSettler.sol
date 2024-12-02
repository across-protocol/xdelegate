pragma solidity ^0.8.0;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OriginSettler} from "./OriginSettler.sol";

struct Asset {
    address token;
    uint256 amount;
}

struct Call {
    address target;
    bytes callData;
    uint256 value;
}

struct CallByUser {
    address user; // User who delegated calldata and funded assets on origin chain.
    Asset asset; // token & amount, used to fund execution of calldata
    uint64 chainId; // should match chain id where calls are to be executed
    bytes32 delegateCodeHash; // expected code hash of the contract to which the user has delegated execution
    Call[] calls; // calldata to execute
}

/**
 * @notice Destination chain entrypoint contract for fillers relaying cross chain message containing delegated
 * calldata.
 * @dev This is a simple escrow contract that is encouraged to be modified by different xchain settlement systems
 * that might want to add features such as exclusive filling, deadlines, fee-collection, etc.
 * @dev This could be replaced by the Across SpokePool, for example, which gives fillers many features with which
 * to protect themselves from malicious users and moreover allows them to provide transparent pricing to users.
 * However, this contract could be bypassed almost completely by lightweight settlement systems that could essentially
 * combine its logic with the XAccount contract to avoid the extra transferFrom and approve steps required in a more
 * complex escrow system.
 */
contract DestinationSettler {
    using SafeERC20 for IERC20;

    mapping(bytes32 => bool) public fillStatuses;

    // Called by filler, who sees ERC7683 intent emitted on origin chain
    // containing the callsByUser data to be executed following a 7702 delegation.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external {
        (CallByUser memory callsByUser, OriginSettler.EIP7702AuthData memory authData) =
            abi.decode(originData, (CallByUser, OriginSettler.EIP7702AuthData));
        // Verify orderId?
        // require(orderId == keccak256(originData), "Wrong order data");

        // Pull funds into this settlement contract and perform any steps necessary to ensure that filler
        // receives a refund of their assets.
        _fundUserAndApproveXAccount(callsByUser);

        // Protect against duplicate fills.
        require(!fillStatuses[orderId], "Already filled");
        fillStatuses[orderId] = true;

        // TODO: Protect fillers from collisions with other fillers. Requires letting user set an exclusive relayer.

        // The following call will only succeed if the user has set a 7702 authorization to set its code
        // equal to the XAccount contract. This 7702 auth data could have been included in the origin chain
        // 7683 fillerData and subsequently could be submitted by the filler in a type 4 txn. The filler should have
        // seen the calldata emitted in an `Open` ERC7683 event on the sending chain.
        XAccount(payable(callsByUser.user)).xExecute(orderId, callsByUser, authData);

        // Perform any final steps required to prove that filler has successfully filled the ERC7683 intent.
        // For example, we could emit an event containing a unique hash of the fill that could be proved
        // on the origin chain via a receipt proof + RIP7755.
        // e.g. emit Executed(userCalldata)
    }

    // Pull funds into this settlement contract as escrow and use to execute user's calldata. Escrowed
    // funds will be paid back to filler after this contract successfully verifies the settled intent.
    // This step could be skipped by lightweight escrow systems that don't need to perform additional
    // validation on the filler's actions.
    function _fundUserAndApproveXAccount(CallByUser memory call) internal {
        // TODO: Link the escrowed funds back to the user in case the delegation step fails, we don't want
        // user to lose access to funds.
        IERC20(call.asset.token).safeTransferFrom(msg.sender, address(this), call.asset.amount);
        IERC20(call.asset.token).forceApprove(call.user, call.asset.amount);
    }
}

// TODO: Move to separate file once we are more confident in architecture. For now keep here for readability.

/**
 * @notice Singleton contract used by all users who want to sign data on origin chain and delegate execution of
 * their calldata on this chain to this contract.
 * @dev User must trust that this contract correctly verifies the user's cross chain signature as well as uses any
 * 7702 delegations they want to delegate to a filler on this chain to bring on-chain.
 */
contract XAccount {
    using SafeERC20 for IERC20;

    error CallReverted(uint256 index, Call[] calls);
    error InvalidCall(uint256 index, Call[] calls);

    mapping(bytes32 => bool) public executionStatuses;

    // Entrypoint function to be called by DestinationSettler contract on this chain. Should pull funds
    // to user's EOA and then execute calldata might require msg.sender = user EOA.
    // Assume user has 7702-delegated code already to this contract, or that the user instructed the filler
    // to submit the 7702 delegation data in the same transaction as the delegated calldata.
    // All calldata and 7702 authorization data is assumed to have been emitted on the origin chain in a ERC7683 intent.
    function xExecute(
        bytes32 orderId,
        CallByUser memory userCalls,
        OriginSettler.EIP7702AuthData memory authorizationData
    ) external {
        // The user should have signed a data blob containing delegated calldata as well as any 7702 authorization
        // transaction data they wanted the filler to submit on their behalf.

        // TODO: Prevent userCalldata + signature from being replayed.
        require(!executionStatuses[orderId], "Already executed");
        executionStatuses[orderId] = true;

        // Verify that the user signed the data blob.
        _verifyCalls(userCalls);
        // Verify that any included 7702 authorization data is as expected.
        _verify7702Delegation(userCalls, authorizationData);
        _fundUser(userCalls);
        _attemptCalls(userCalls.calls);
    }

    function _verifyCalls(CallByUser memory userCalls) internal view returns (bool) {
        // // TODO: How do we verify that userCalls.user is the expected user?
        require(userCalls.chainId == block.chainid);
    }

    function _verify7702Delegation(CallByUser memory userCalls, OriginSettler.EIP7702AuthData memory authorizationData)
        internal
    {
        // TODO: We might not need this function at all, because if the authorization data requires that this contract
        // is set as the delegation code, then xExecute would fail if the auth data is not submitted by the filler.
        // However, it might still be useful to verify that authorizationData includes some expected data like
        // the authorization_list includes chainId=this and address=this. This might not be necessary though.
        if (authorizationData.authlist.length == 0) {
            return;
        }
        OriginSettler.Authorization memory authList = authorizationData.authlist[0];
        require(authList.chainId == block.chainid);
        // TODO: Do we need to do anything with verifying a signature?
        require(
            SignatureChecker.isValidSignatureNow(userCalls.user, keccak256(abi.encode(authList)), authList.signature),
            "Invalid auth signature"
        );

        // TODO: Can we verify CallsByUser.delegateCodeHash for example?
    }

    function _attemptCalls(Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; ++i) {
            Call memory call = calls[i];

            // If we are calling an EOA with calldata, assume target was incorrectly specified and revert.
            if (call.callData.length > 0 && call.target.code.length == 0) {
                revert InvalidCall(i, calls);
            }

            (bool success,) = call.target.call{value: call.value}(call.callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    function _fundUser(CallByUser memory call) internal {
        IERC20(call.asset.token).safeTransferFrom(msg.sender, call.user, call.asset.amount);
    }

    // Used if the caller is trying to unwrap the native token to this contract.
    receive() external payable {}
}
