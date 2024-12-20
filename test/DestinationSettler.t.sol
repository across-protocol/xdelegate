pragma solidity ^0.8.0;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Test, console} from "forge-std/Test.sol";
import {DestinationSettler, XAccount} from "../src/DestinationSettler.sol";
import {SenderCheck} from "../src/SenderCheck.sol";
import {CallByUser, Asset, Call} from "../src/Structs.sol";

contract DestinationSettlerTest is Test {
    DestinationSettler public destinationSettler;
    XAccount public acc;
    SenderCheck public check;

    function setUp() public {
        destinationSettler = new DestinationSettler();
        acc = new XAccount();
        check = new SenderCheck();
    }

    function test_fill() public {
	bytes memory callData = abi.encodeWithSelector(
	    bytes4(keccak256("check()"))
	);
        console.logBytes(callData);
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
                target: address(check),
                callData: callData,
                value: 0
        });
        uint256 nonce = 1;
        bytes memory encoded = abi.encode(calls, nonce);
        bytes32 messageHash = keccak256(encoded);

        // Key for testing purposes.
        uint256 privateKey = 0x0df13f4069b3b6c63054adba655a9b5462326e803411c62510a27fd6cc3ef5ab;
        address signer = vm.addr(privateKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, messageHash);
        bytes memory signatureCheck = abi.encodePacked(r, s, v);


        CallByUser memory userCall = CallByUser({
            user: address(acc), // Can't use actual user address here because we can't simulate authorizations in forge.
            nonce: nonce,
            asset: Asset({
                token: 0x0000000000000000000000000000000000000000,
                amount: 0
            }),
            chainId: 31337,
            signature: signature,
            calls: calls
        });

        bytes memory originData = abi.encode(userCall);
        bytes32 orderId = keccak256(originData);
        console.logBytes(originData);
        console.logBytes32(orderId);

        // NB(bo): This will fail on signature check as XAccount is checking for both an authorization and a authorization sig on the user calls.
        destinationSettler.fill(orderId, originData);
    }
    
    // NB(bo): The deployed DestinationSettler contract is currently returning a failing signature check
    // while the manual check below using the same values passes.
    func test_signature_check() public {
        // manually check signature using Debug log values
        address signer = 0x8589ac73f24dD9135e18cCCe6718E3773FcC5EBD;
        bytes32 hash = 0x94e0128d9fb4d81959e7c6d064e595838084262736b846cd23a5290cec4156c4;
        bytes memory signature = hex"c48a0fe6c2c3d928d8a09e19fa0e390433a65707cf256d1fa904425c37a507c45d46015cc8c642d97fa963665601e08ab2b5baa1bb6295dc3e98d2eb469f66911b";
        bool isValid = SignatureChecker.isValidSignatureNow(
            signer, hash, signature
        );
        console.log("is sig valid?", isValid);
        console.logBytes(signature);
    }
}
