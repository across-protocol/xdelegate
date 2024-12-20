pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GaslessCrossChainOrder} from "./ERC7683.sol";
import {CallByUser, Call} from "./Structs.sol";
import {ResolvedCrossChainOrderLib} from "./ResolvedCrossChainOrderLib.sol";

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
contract DestinationSettler is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Store unique orders to prevent duplicate fills for the same order.
    mapping(bytes32 => bool) public fillStatuses;

    error InvalidOrderId();
    error DuplicateFill();

    event Debug(uint256 index);
    // Called by filler, who sees ERC7683 intent emitted on origin chain
    // containing the callsByUser data to be executed following a 7702 delegation.
    // @dev We don't use the last parameter `fillerData` in this function.
    function fill(bytes32 orderId, bytes calldata originData) external nonReentrant {
        (CallByUser memory callsByUser) = abi.decode(originData, (CallByUser));
        if (ResolvedCrossChainOrderLib.getOrderId(callsByUser) != orderId) revert InvalidOrderId();

        // Protect against duplicate fills.
        if (fillStatuses[orderId]) revert DuplicateFill();
        fillStatuses[orderId] = true;

        // TODO: Protect fillers from collisions with other fillers. Requires letting user set an exclusive relayer.

        // Pull funds into this settlement contract and perform any steps necessary to ensure that filler
        // receives a refund of their assets.
        //_fundAndApproveXAccount(callsByUser);

        // The following call will only succeed if the user has set a 7702 authorization to set its code
        // equal to the XAccount contract. The filler should have seen any auth data emitted in an OriginSettler
        // event on the sending chain.
        XAccount(payable(callsByUser.user)).xExecute(orderId, callsByUser);

        // Perform any final steps required to prove that filler has successfully filled the ERC7683 intent.
        // For example, we could emit an event containing a unique hash of the fill that could be proved
        // on the origin chain via a receipt proof + RIP7755.
        // e.g. emit Executed(orderId)
    }

    // Pull funds into this settlement contract as escrow and use to execute user's calldata. Escrowed
    // funds will be paid back to filler after this contract successfully verifies the settled intent.
    // This step could be skipped by lightweight escrow systems that don't need to perform additional
    // validation on the filler's actions.
    function _fundAndApproveXAccount(CallByUser memory call) internal {
        IERC20(call.asset.token).safeTransferFrom(msg.sender, address(this), call.asset.amount);
        IERC20(call.asset.token).forceApprove(call.user, call.asset.amount);
    }
}

// TODO: Move to separate file once we are more confident in architecture. For now keep here for readability.

/**
 * @notice Singleton contract used by all users who want to sign data on origin chain and delegate execution of
 * their calldata on this chain to this contract.
 */
contract XAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error CallReverted(uint256 index, Call[] calls);
    error InvalidCall(uint256 index, Call[] calls);
    error DuplicateExecution();
    error InvalidExecutionChainId();
    error InvalidUserSignature();

    /// @notice Store unique user ops to prevent duplicate executions.
    mapping(bytes32 => bool) public executionStatuses;
    event Debug(bool isValid, address xAccount, address user, bytes32 messageHash, bytes signature);

    /**
     * @notice Entrypoint function to be called by DestinationSettler contract on this chain. Should pull funds
     * to user's EOA and then execute calldata.
     * @dev Assume user has 7702-delegated code already to this contract.
     * @dev All calldata and 7702 authorization data is assumed to have been emitted on the origin chain in am ERC7683
     * intent creation event.
     */
    function xExecute(bytes32 orderId, CallByUser memory userCalls) external nonReentrant {
        bytes32 sigHash = keccak256(abi.encode(userCalls.calls, userCalls.nonce));
        bool isValid = SignatureChecker.isValidSignatureNow(
            address(this), sigHash, userCalls.signature
        );
        emit Debug(isValid, address(this), userCalls.user, sigHash, userCalls.signature);

        if (executionStatuses[orderId]) revert DuplicateExecution();
        executionStatuses[orderId] = true;

        // Verify that the user signed the data blob.
        //_verifyCalls(userCalls);
        // Verify that any included 7702 authorization data is as expected.
        _verify7702Delegation();
        //_fundUser(userCalls);

        // TODO: Should we allow user to handle case where the calls fail and they want to specify
        // a fallback recipient? This might not be neccessary since the user will have pulled funds
        // into their account so worst case they'll still have access to those funds.
        _attemptCalls(userCalls.calls);
    }

    function _verifyCalls(CallByUser memory userCalls) internal view {
        if (userCalls.chainId != block.chainid) revert InvalidExecutionChainId();
        // @dev address(this) should be the userCall.user's EOA.
        // TODO: Make the blob to sign EIP712-compatible (i.e. instead of keccak256(abi.encode(...)) set
        // this to SigningLib.getTypedDataHash(...)
        if (
            !SignatureChecker.isValidSignatureNow(
                address(this), keccak256(abi.encode(userCalls.calls, userCalls.nonce)), userCalls.signature
            )
        ) revert InvalidUserSignature();
    }

    function _verify7702Delegation() internal {
        // TODO: We might not need this function at all, because if the authorization data requires that this contract
        // is set as the delegation code, then xExecute would fail if the auth data is not submitted by the filler.
        // However, it might still be useful to verify that the delegate is set correctly, like checking EXTCODEHASH.
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
